//! Polling daemon: every 1s, read NSPasteboard.changeCount, and if it
//! moved, insert/update the SQLite entry.
//!
//! Single-instance enforced with flock on a pidfile.
//! SIGINT/SIGTERM trigger a clean shutdown via an atomic flag.
//!
//! Leans on libc directly because Zig 0.16's std was mid-refactor and
//! most `std.posix` / `std.fs` wrappers were temporarily missing.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// ---- libc bindings ----------------------------------------------------------

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: c_long) c_int;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, offset: c_long) isize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

// Darwin-specific values — Linux differs (notably O_CREAT=0x40 on Linux).
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
const F_OK: c_int = 0;

// `extern struct` forces C layout so the kernel sees the fields where it
// expects them.
const Timespec = extern struct { sec: c_long, nsec: c_long };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn time(t: ?*c_long) c_long;

pub fn unixNow() i64 {
    return @intCast(time(null));
}

fn sleepSeconds(s: c_long) void {
    const req = Timespec{ .sec = s, .nsec = 0 };
    _ = nanosleep(&req, null);
}

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const objc = @import("objc");

const poll_interval_sec: c_long = 1;

// ---- Signal handling --------------------------------------------------------

// Atomic because the signal handler can interrupt the poll loop on the
// same thread — without atomic ops, reads/writes could tear or be
// reordered around the load in the while-condition.
var running: std.atomic.Value(bool) = .init(true);

// `callconv(.c)` is required because the kernel invokes signal handlers
// using the platform C ABI, not Zig's internal calling convention.
const SigHandler = ?*const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SigHandler) SigHandler;

fn signalHandler(_: c_int) callconv(.c) void {
    running.store(false, .seq_cst);
}

fn installSignalHandlers() void {
    _ = signal(2, signalHandler); // SIGINT
    _ = signal(15, signalHandler); // SIGTERM
}

fn getpid() i32 {
    return @intCast(std.c.getpid());
}

fn writePid(fd: c_int) !void {
    _ = ftruncate(fd, 0);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{getpid()});
    _ = pwrite(fd, s.ptr, s.len, 0);
}

/// Main entry point for `zclip daemon`. Sets up the storage dir, takes
/// the pidfile lock, opens SQLite, then enters the poll loop until a
/// signal flips `running` to false.
pub fn run(allocator: std.mem.Allocator, log_w: anytype) !void {
    installSignalHandlers();

    // Sentinel-0 paths because access/flock/SQLite all take `const char *`.
    const home_cstr = std.c.getenv("HOME") orelse return error.MissingHome;
    const home = std.mem.span(home_cstr);
    const dir_path = try std.fmt.allocPrintSentinel(allocator, "{s}/.local/share/zclip", .{home}, 0);
    defer allocator.free(dir_path);

    // Deliberately do NOT auto-create the storage dir — print an
    // actionable hint and bail. User must opt in.
    if (access(dir_path.ptr, F_OK) != 0) {
        try log_w.print("zclip daemon: storage directory missing: {s}\n", .{dir_path});
        try log_w.print("  create it with: mkdir -p {s}\n", .{dir_path});
        try log_w.flush();
        return error.MissingStorageDir;
    }

    const pid_path = try std.fmt.allocPrintSentinel(allocator, "{s}/zclip.pid", .{dir_path}, 0);
    defer allocator.free(pid_path);

    const pid_fd = acquirePidfileSimple(pid_path) catch |err| switch (err) {
        error.AlreadyRunning => {
            try log_w.writeAll("zclip daemon: another instance is already running\n");
            try log_w.flush();
            return;
        },
        else => return err,
    };
    defer _ = close(pid_fd);

    // Write PID into the (already-locked) pidfile so `kill`/`pgrep` can
    // find this daemon.
    try writePid(pid_fd);

    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/history.db", .{dir_path}, 0);
    defer allocator.free(db_path);

    var db = try db_mod.Db.open(allocator, db_path);
    defer db.close();

    const pb = clipboard.Pasteboard.general();
    var last_change: i64 = pb.changeCount();

    try log_w.print("zclip daemon started (pid={d}, db={s})\n", .{ getpid(), db_path });
    try log_w.flush();

    while (running.load(.seq_cst)) {
        sleepSeconds(poll_interval_sec);
        if (!running.load(.seq_cst)) break;

        // Per-tick autorelease pool: Obj-C calls below (`stringWithUTF8String:`,
        // `[pb types]`, etc.) return autoreleased objects. Without a pool on
        // this thread they accumulate in a process-global pool that never drains.
        //
        // SAFETY: `pb.readString` copies bytes into the caller's allocator
        // before returning. Don't pass any raw NSString-owned pointer past
        // the defer below.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const cc = pb.changeCount();
        if (cc == last_change) continue;
        last_change = cc;

        // Password-manager opt-out — only defense against logging secrets.
        if (pb.hasConcealed()) {
            try log_w.writeAll("  skip: concealed entry\n");
            try log_w.flush();
            continue;
        }

        // Skip our own writes from `zclip use` to prevent a feedback loop.
        if (pb.hasOrigin()) continue;

        const content = (try pb.readString(allocator)) orelse continue;
        defer allocator.free(content);
        if (content.len == 0) continue;

        var hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(content, &hash, .{});

        const now: i64 = unixNow();
        const inserted = try db.upsertByHash(content, &hash, now);
        if (inserted) {
            try log_w.print("  + new entry ({d} bytes)\n", .{content.len});
        } else {
            try log_w.print("  ~ bumped existing entry\n", .{});
        }
        try log_w.flush();
    }

    try log_w.writeAll("zclip daemon: shutting down\n");
    try log_w.flush();
}

/// Open the pidfile and grab an exclusive non-blocking flock. Returns
/// `error.AlreadyRunning` if another process holds the lock.
fn acquirePidfileSimple(pid_path: [:0]const u8) !c_int {
    const fd = open(pid_path.ptr, O_WRONLY | O_CREAT, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    // errdefer fires only on the error path — caller owns fd on success.
    errdefer _ = close(fd);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        // EWOULDBLOCK == EAGAIN == 35 on darwin
        if (std.c._errno().* == 35) return error.AlreadyRunning;
        return error.FlockFailed;
    }
    return fd;
}
