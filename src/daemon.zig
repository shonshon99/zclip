//! Polling daemon: every 1s, read NSPasteboard.changeCount, and if it
//! moved, insert/update the SQLite entry.
//!
//! Single-instance enforced with flock on a pidfile.
//! SIGINT/SIGTERM trigger a clean shutdown via an atomic flag.
//!
//! BEGINNER NOTES
//! --------------
//! This file leans heavily on libc directly because Zig 0.16's standard
//! library was mid-refactor when zclip was written — most file/syscall
//! wrappers in `std.posix` and `std.fs` were temporarily removed. So we
//! declare the C functions ourselves with `extern "c" fn` and call them
//! straight.
//!
//! Even in a "stable" Zig, calling these functions ultimately boils down
//! to the same C-ABI syscall: there's no "pure Zig" way to open a file or
//! sleep, because those operations are kernel features and the kernel
//! exposes itself through C calling conventions on every Unix.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// ---- libc bindings ----------------------------------------------------------
//
// Each `extern "c" fn` declares "this function lives in libc — the linker
// will find it; call it using the C calling convention." We're not
// implementing these; we're just naming them so we can call them.

// `[*:0]const u8` = C string (many-item pointer, null-terminated).
// `c_int`, `c_long`, `c_uint` are Zig types that match C's int sizes for
// the target platform.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: c_long) c_int;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, offset: c_long) isize;

// Flag constants from macOS's <fcntl.h> and <sys/file.h>. Hardcoded
// rather than `@cImport`ed for the four values we actually need.
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200; // value is darwin-specific (Linux uses 0x40)
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;

// `extern struct` means "lay this out exactly the way C would, no field
// reordering or padding optimisations". Required when passing structs by
// pointer to C functions.
const Timespec = extern struct { sec: c_long, nsec: c_long };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn time(t: ?*c_long) c_long;

/// Current Unix timestamp (seconds since epoch). Wraps libc's `time(NULL)`.
pub fn unixNow() i64 {
    return @intCast(time(null));
}

fn sleepSeconds(s: c_long) void {
    const req = Timespec{ .sec = s, .nsec = 0 };
    _ = nanosleep(&req, null);
}

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");

const poll_interval_sec: c_long = 1;

// ---- Signal handling --------------------------------------------------------
//
// `std.atomic.Value(T)` wraps a `T` so you can read/write it atomically.
// Required here because the signal handler runs in a special context that
// can interleave with the main loop — without atomic ops, reads and
// writes could tear or be reordered by the compiler.
//
// `.init(true)` is the value-init syntax — Zig figures out the type from
// the variable annotation.
var running: std.atomic.Value(bool) = .init(true);

// A signal handler must use the C calling convention because the kernel
// calls it. `?*const fn (c_int) callconv(.c) void` reads:
//   optional pointer to a const function taking a c_int, using the C
//   calling convention, returning void.
const SigHandler = ?*const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SigHandler) SigHandler;

// `callconv(.c)` on our own function says: "compile this function so its
// entry point uses the C calling convention." Necessary because the
// kernel, when delivering a signal, calls us using C-ABI rules.
//
// `_: c_int` names the parameter `_` — Zig insists every parameter is
// either used or explicitly marked unused with `_`.
fn signalHandler(_: c_int) callconv(.c) void {
    // `.seq_cst` is sequential consistency — the strictest memory ordering.
    // For a single bool flag this is the right safe default.
    running.store(false, .seq_cst);
}

fn installSignalHandlers() void {
    _ = signal(2, signalHandler); // SIGINT  (Ctrl-C in a terminal)
    _ = signal(15, signalHandler); // SIGTERM (`kill <pid>`)
}

fn getpid() i32 {
    return @intCast(std.c.getpid());
}

fn writePid(fd: c_int) !void {
    _ = ftruncate(fd, 0);
    var buf: [32]u8 = undefined;
    // `bufPrint` writes formatted text into an existing buffer (no
    // allocation). Returns a slice referring to the *used* portion.
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{getpid()});
    _ = pwrite(fd, s.ptr, s.len, 0);
}

/// Main entry point for `zclip daemon`. Sets up the storage dir, takes
/// the pidfile lock, opens SQLite, then enters the poll loop until a
/// signal flips `running` to false.
pub fn run(allocator: std.mem.Allocator, log_w: anytype) !void {
    installSignalHandlers();

    // ---- Build paths under ~/.local/share/zclip ----
    const home_cstr = std.c.getenv("HOME") orelse return error.MissingHome;
    const home = std.mem.span(home_cstr);
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.local/share/zclip", .{home});
    defer allocator.free(dir_path);
    try mkdirP(allocator, dir_path);

    // `allocPrintSentinel(..., 0)` allocates a formatted string AND
    // appends a 0 byte so the result is also valid as a C string.
    // Required because flock's path and SQLite's path both go to C.
    const pid_path = try std.fmt.allocPrintSentinel(allocator, "{s}/zclip.pid", .{dir_path}, 0);
    defer allocator.free(pid_path);
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/history.db", .{dir_path}, 0);
    defer allocator.free(db_path);

    // ---- Acquire the single-instance lock ----
    //
    // `catch |err| switch (err) { ... }` is the exhaustive error handler:
    // for each possible error tag, either handle it or rethrow with
    // `return err`. The compiler verifies every case is covered.
    const pid_fd = acquirePidfileSimple(pid_path) catch |err| switch (err) {
        error.AlreadyRunning => {
            try log_w.writeAll("zclip daemon: another instance is already running\n");
            try log_w.flush();
            return;
        },
        else => return err,
    };
    defer _ = close(pid_fd);
    try writePid(pid_fd);

    // ---- Open the database ----
    var db = try db_mod.Db.open(allocator, db_path);
    defer db.close();

    // ---- Grab the pasteboard and snapshot the current change counter ----
    const pb = clipboard.Pasteboard.general();
    var last_change: i64 = pb.changeCount();

    try log_w.print("zclip daemon started (pid={d}, db={s})\n", .{ getpid(), db_path });
    try log_w.flush();

    // ---- Poll loop ----
    while (running.load(.seq_cst)) {
        sleepSeconds(poll_interval_sec);
        // A signal might have flipped the flag while we were asleep.
        if (!running.load(.seq_cst)) break;

        const cc = pb.changeCount();
        if (cc == last_change) continue; // nothing happened this tick
        last_change = cc;

        // Skip password-manager copies — they tag the pasteboard with
        // org.nspasteboard.ConcealedType to opt out of history tools.
        if (pb.hasConcealed()) {
            try log_w.writeAll("  skip: concealed entry\n");
            try log_w.flush();
            continue;
        }

        // Skip writes that came from `zclip use` (they carry our origin
        // tag). This prevents a self-triggered loop.
        if (pb.hasOrigin()) continue;

        // `(try x) orelse continue;` — try unwraps the error union;
        // orelse handles the optional. If readString returns null (no
        // text on the pasteboard), skip this tick.
        const content = (try pb.readString(allocator)) orelse continue;
        defer allocator.free(content);
        if (content.len == 0) continue;

        // `[Sha256.digest_length]u8` declares an array sized at compile
        // time from a constant on the SHA256 type. Yields `[32]u8`.
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

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// Recursive mkdir -p via libc. Walks up the path until it finds an
/// existing parent, then walks back down creating directories.
///
/// `0o755` is an octal literal — the standard "rwxr-xr-x" file mode.
fn mkdirP(allocator: std.mem.Allocator, path: []const u8) !void {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    if (mkdir(z.ptr, 0o755) == 0) return;

    // `std.c._errno().*` reads the `errno` thread-local. `_errno()` is a
    // function returning a `*c_int`; `.*` dereferences it (like C's
    // `*errno_ptr`).
    const e = std.c._errno().*;

    // EEXIST = 17 on darwin: directory already there, treat as success.
    if (e == 17) return;
    // ENOENT = 2: parent missing — recurse on the parent path.
    if (e == 2) {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.CannotCreateDir;
        if (slash == 0) return error.CannotCreateDir;
        try mkdirP(allocator, path[0..slash]);
        if (mkdir(z.ptr, 0o755) == 0) return;
        if (std.c._errno().* == 17) return;
        return error.CannotCreateDir;
    }
    return error.CannotCreateDir;
}

/// Open the pidfile and grab an exclusive non-blocking flock. Returns
/// `error.AlreadyRunning` if another process holds the lock.
fn acquirePidfileSimple(pid_path: [:0]const u8) !c_int {
    const fd = open(pid_path.ptr, O_WRONLY | O_CREAT, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    // `errdefer` runs only on the error path — releases the fd if flock
    // fails, leaves it open on success (the caller owns it).
    errdefer _ = close(fd);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        // EWOULDBLOCK == EAGAIN == 35 on darwin
        if (std.c._errno().* == 35) return error.AlreadyRunning;
        return error.FlockFailed;
    }
    return fd;
}
