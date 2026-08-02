//! Polling daemon: every 1s, read NSPasteboard.changeCount, and if it
//! moved, insert/update the SQLite entry.
//!
//! Single-instance enforced via advisory file lock on the pidfile.
//! SIGINT/SIGTERM trigger a clean shutdown via an atomic flag.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const image = @import("image.zig");
const objc = @import("objc");

const poll_interval: Io.Duration = .fromSeconds(1);

/// Longest side of the stored thumbnail, in pixels. Sized for a Retina
/// preview pane (~350pt ≈ 700px) without putting megabytes per entry in the
/// DB; the untouched original stays on disk for `zclip use`.
const thumb_max_px: u32 = 512;

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

/// Unix epoch seconds via the `real` (wall-clock) Io clock.
pub fn unixNow(io: Io) i64 {
    const ns = Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

fn writePid(file: Io.File, io: Io) !void {
    try file.setLength(io, 0);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{getpid()});
    try file.writePositionalAll(io, s, 0);
}

/// Main entry point for `zclip daemon`. Verifies storage dir, takes the
/// pidfile lock, opens SQLite, then enters the poll loop until a signal
/// flips `running` to false.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    log_w: anytype,
) !void {
    installSignalHandlers();

    const home = environ.getPosix("HOME") orelse return error.MissingHome;
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.local/share/zclip", .{home});
    defer allocator.free(dir_path);

    // Deliberately do NOT auto-create the storage dir — print an
    // actionable hint and bail. User must opt in.
    Io.Dir.cwd().access(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try log_w.print("zclip daemon: storage directory missing: {s}\n", .{dir_path});
            try log_w.print("  create it with: mkdir -p {s}\n", .{dir_path});
            try log_w.flush();
            return error.MissingStorageDir;
        },
        else => return err,
    };

    // Subdirectory of a dir the user already opted into, and derived data
    // rather than the user's DB — so unlike `dir_path` above, creating it is
    // not a decision to put to the user. Idempotent.
    const images_dir = try std.fmt.allocPrint(allocator, "{s}/images", .{dir_path});
    defer allocator.free(images_dir);
    try Io.Dir.cwd().createDirPath(io, images_dir);

    const pid_path = try std.fmt.allocPrint(allocator, "{s}/zclip.pid", .{dir_path});
    defer allocator.free(pid_path);

    // Single-instance gate via flock — an in-memory mutex can't span
    // processes, so we lock a file both can name; the kernel arbitrates the
    // shared inode. Any dedicated path works; reusing the pidfile lets one
    // file serve both the lock and the `kill`/`pgrep` PID readout.
    //
    // `.exclusive` + `.lock_nonblocking` takes the flock atomically with
    // open(2) — no TOCTOU window. `truncate = false` preserves the old PID
    // until `writePid` overwrites it. OS drops the lock on exit/crash, so no
    // stale lock blocks a restart.
    var pid_file = Io.Dir.cwd().createFile(io, pid_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            try log_w.writeAll("zclip daemon: another instance is already running\n");
            try log_w.flush();
            return;
        },
        else => return err,
    };
    defer pid_file.close(io);

    // Write PID into the (already-locked) pidfile so `kill`/`pgrep` can
    // find this daemon.
    try writePid(pid_file, io);

    // SQLite's C API wants `const char *`; keep the sentinel-0 path here.
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/history.db", .{dir_path}, 0);
    defer allocator.free(db_path);

    var db = try db_mod.Db.open(allocator, db_path);
    defer db.close();

    const pb = clipboard.Pasteboard.general();
    var last_change: i64 = pb.changeCount();

    try log_w.print("zclip daemon started (pid={d}, db={s})\n", .{ getpid(), db_path });
    try log_w.flush();

    while (running.load(.seq_cst)) {
        // `.awake` clock — pauses during system suspend on macOS so the
        // daemon doesn't wake on sleep to find a backlog of changeCount diffs.
        Io.sleep(io, poll_interval, .awake) catch |err| switch (err) {
            error.Canceled => break,
        };
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

        // Text wins when both are present. Rich-text copies (Word, browsers,
        // Preview selections) routinely publish a TIFF rendering alongside
        // the plain text, and the text is what the user meant to copy.
        if (try pb.readString(allocator)) |content| {
            defer allocator.free(content);
            if (content.len > 0) {
                try recordText(io, &db, log_w, content);
                continue;
            }
        }

        if (pb.imageType()) |img_type| {
            try recordImage(allocator, io, &db, log_w, pb, img_type, images_dir);
        }
    }

    try log_w.writeAll("zclip daemon: shutting down\n");
    try log_w.flush();
}

fn recordText(io: Io, db: *db_mod.Db, log_w: anytype, content: []const u8) !void {
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &hash, .{});

    const now: i64 = unixNow(io);
    if (try db.findByHash(&hash)) |id| {
        // Bump so re-copied content resurfaces as most-recent.
        try db.touch(id, now);
        try log_w.print("  ~ bumped existing entry\n", .{});
    } else {
        _ = try db.insertText(content, &hash, now);
        try log_w.print("  + new entry ({d} bytes)\n", .{content.len});
    }
    try log_w.flush();
}

/// Archive the original bytes to `images_dir` and record entry + thumbnail.
///
/// Decode failures are logged and swallowed: an image the daemon can't parse
/// is a skipped clipboard event, not a reason to take down history capture.
fn recordImage(
    allocator: std.mem.Allocator,
    io: Io,
    db: *db_mod.Db,
    log_w: anytype,
    pb: clipboard.Pasteboard,
    img_type: clipboard.Pasteboard.ImageType,
    images_dir: []const u8,
) !void {
    const bytes = (try pb.readData(allocator, img_type.uti)) orelse return;
    defer allocator.free(bytes);

    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &hash, .{});

    const now: i64 = unixNow(io);
    if (try db.findByHash(&hash)) |id| {
        try db.touch(id, now);
        try log_w.print("  ~ bumped existing image\n", .{});
        try log_w.flush();
        return;
    }

    // Before touching disk, so an undecodable image leaves nothing behind.
    const summary = image.summarize(allocator, bytes, thumb_max_px) catch |err| {
        try log_w.print("  skip: undecodable image ({s})\n", .{@errorName(err)});
        try log_w.flush();
        return;
    };
    defer allocator.free(summary.thumb);

    // Content-addressed filename. Dedup already happened by hash above, so
    // this path is only ever written once per distinct image — and if a
    // previous run died between file write and insert, the rewrite is
    // byte-identical.
    const path = try std.fmt.allocPrint(allocator, "{s}/{x}.{s}", .{
        images_dir,
        &hash,
        img_type.ext,
    });
    defer allocator.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

    // Nothing collects orphans: `images.path` sits outside every FK cascade, so
    // a file whose insert failed would be referenced by nothing and deleted by
    // nobody. The insert is the commit point — unwind the file if we don't
    // reach it. Deliberately a `catch`, not an `errdefer`: an errdefer here
    // would also fire on a later log-write failure and unlink a file the
    // committed row points at.
    _ = db.insertImage(&hash, now, .{
        .path = path,
        .mime = img_type.mime,
        .width = summary.width,
        .height = summary.height,
        .byte_len = @intCast(bytes.len),
        .thumb = summary.thumb,
    }) catch |err| {
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return err;
    };

    try log_w.print("  + new image {d}x{d} {s} ({d} bytes)\n", .{
        summary.width,
        summary.height,
        img_type.mime,
        bytes.len,
    });
    try log_w.flush();
}
