//! Polling daemon: every 1s, read NSPasteboard.changeCount and insert/update
//! the SQLite entry if it moved. Single-instance via an advisory lock on the
//! pidfile; SIGINT/SIGTERM shut down cleanly through an atomic flag.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const image = @import("image.zig");
const objc = @import("objc");

const poll_interval: Io.Duration = .fromSeconds(1);

/// Longest side of the stored thumbnail, in pixels. Sized for a Retina preview
/// pane (~350pt ≈ 700px) without putting megabytes per entry in the DB.
const thumb_max_px: u32 = 512;

// ---- Signal handling --------------------------------------------------------

// Atomic because the handler interrupts the poll loop on the same thread:
// plain reads/writes could tear or reorder around the while-condition's load.
var running: std.atomic.Value(bool) = .init(true);

// `callconv(.c)`: the kernel invokes signal handlers with the platform C ABI.
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

/// Unix epoch seconds off the `real` (wall-clock) Io clock.
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

/// Entry point for `zclip daemon`: verify storage dir, take the pidfile lock,
/// open SQLite, then poll until a signal flips `running` to false.
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

    // Never auto-create the storage dir — the user must opt in.
    Io.Dir.cwd().access(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try log_w.print("zclip daemon: storage directory missing: {s}\n", .{dir_path});
            try log_w.print("  create it with: mkdir -p {s}\n", .{dir_path});
            try log_w.flush();
            return error.MissingStorageDir;
        },
        else => return err,
    };

    // Derived data inside a dir the user already opted into, so unlike
    // `dir_path` this one is ours to create. Idempotent.
    const images_dir = try std.fmt.allocPrint(allocator, "{s}/images", .{dir_path});
    defer allocator.free(images_dir);
    try Io.Dir.cwd().createDirPath(io, images_dir);

    const pid_path = try std.fmt.allocPrint(allocator, "{s}/zclip.pid", .{dir_path});
    defer allocator.free(pid_path);

    // Single-instance gate via flock: a mutex can't span processes, so both
    // lock a file the kernel arbitrates. Reusing the pidfile lets one file
    // serve as both lock and `kill`/`pgrep` PID readout.
    //
    // `.exclusive` + `.lock_nonblocking` takes the lock atomically with open(2)
    // (no TOCTOU); `truncate = false` keeps the old PID until `writePid`
    // overwrites it. The OS drops the lock on exit/crash, so none goes stale.
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

    try writePid(pid_file, io);

    // Sentinel-0: SQLite's C API wants `const char *`.
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/history.db", .{dir_path}, 0);
    defer allocator.free(db_path);

    var db = try db_mod.Db.open(allocator, db_path);
    defer db.close();

    const pb = clipboard.Pasteboard.general();
    var last_change: i64 = pb.changeCount();

    try log_w.print("zclip daemon started (pid={d}, db={s})\n", .{ getpid(), db_path });
    try log_w.flush();

    while (running.load(.seq_cst)) {
        // `.awake` pauses during system suspend, so waking from sleep doesn't
        // find a backlog of changeCount diffs.
        Io.sleep(io, poll_interval, .awake) catch |err| switch (err) {
            error.Canceled => break,
        };
        if (!running.load(.seq_cst)) break;

        // The Obj-C calls below return autoreleased objects; with no pool on
        // this thread they pile up in a process-global one that never drains.
        // `pb.readString` copies before returning — don't pass any raw
        // NSString-owned pointer past this defer.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const cc = pb.changeCount();
        if (cc == last_change) continue;
        last_change = cc;

        // nspasteboard.org opt-out markers. Concealed is the only thing keeping
        // a password manager's clipboard out of the DB — don't remove it.
        if (pb.hasConcealed()) {
            try log_w.writeAll("  skip: concealed entry\n");
            try log_w.flush();
            continue;
        }
        // "User had no intention to Copy" — noise, not a security boundary.
        if (pb.hasAutoGenerated()) {
            try log_w.writeAll("  skip: auto-generated entry\n");
            try log_w.flush();
            continue;
        }

        // Skip our own `zclip use` writes — otherwise, feedback loop.
        if (pb.hasOrigin()) continue;

        // Text wins when both are present: rich-text copies publish a TIFF
        // rendering alongside the plain text, and the text is what was meant.
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
        try db.touch(id, now);
        try log_w.print("  ~ bumped existing entry\n", .{});
    } else {
        _ = try db.insertText(content, &hash, now);
        try log_w.print("  + new entry ({d} bytes)\n", .{content.len});
    }
    try log_w.flush();
}

/// Archive the original bytes to `images_dir` and record entry + thumbnail.
/// Decode failures are logged and swallowed — an unparseable image is a skipped
/// clipboard event, not a reason to take down history capture.
fn recordImage(
    allocator: std.mem.Allocator,
    io: Io,
    db: *db_mod.Db,
    log_w: anytype,
    pb: clipboard.Pasteboard,
    img_type: clipboard.Pasteboard.ImageType,
    images_dir: []const u8,
) !void {
    const bytes = (try pb.readData(allocator, img_type.uti.ptr)) orelse return;
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

    // Content-addressed: dedup above means this path is written once per
    // distinct image, and a rewrite after a crashed run is byte-identical.
    const path = try std.fmt.allocPrint(allocator, "{s}/{x}.{s}", .{
        images_dir,
        &hash,
        img_type.ext,
    });
    defer allocator.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

    // `images.path` sits outside every FK cascade, so a file whose insert
    // failed is referenced by nothing and collected by nobody. The insert is
    // the commit point — unwind the file if we don't reach it. A `catch`, not
    // an `errdefer`: an errdefer would also fire on a later log-write failure
    // and unlink a file the committed row points at.
    _ = db.insertImage(&hash, now, .{
        .path = path,
        .uti = img_type.uti,
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
        img_type.uti,
        bytes.len,
    });
    try log_w.flush();
}
