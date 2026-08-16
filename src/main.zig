// CLI entry point. Dispatches `daemon`, `query`, `tags`, `use`, `tag`, `untag`.

const std = @import("std");
const Io = std.Io;

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const daemon = @import("daemon.zig");

const usage =
    \\zclip - persistent clipboard history
    \\
    \\Usage:
    \\  zclip daemon                                Run the polling daemon (foreground)
    \\  zclip query [--tag <name>] [--limit <n>]    Dump entries as a JSON array (optionally one tag)
    \\  zclip tags                                  Dump all tag names as a JSON array
    \\  zclip use <id>                              Put entry <id> back on the pasteboard
    \\  zclip thumb <id>                            Write image <id>'s thumbnail to the cache, print its path
    \\  zclip tag <id> <tag>                        Attach one tag to an entry
    \\  zclip untag <id> <tag>                      Remove one tag from an entry
    \\
;

// Dispatch is one exhaustive switch, so a new variant won't compile until it's
// handled.
const Command = enum { daemon, use, thumb, query, tags, tag, untag };

const QueryFlag = enum {
    tag,
    limit,

    pub fn fromArg(arg: []const u8) ?QueryFlag {
        if (!isFlagShaped(arg)) return null;
        return std.meta.stringToEnum(QueryFlag, arg[2..]);
    }
};

fn isFlagShaped(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--");
}

// Exit codes match README's table: 2 = bad invocation, 1 = runtime failure.
// The test suites assert on both. stderr is best-effort — a failed write must
// not change the exit code.

/// Bad invocation: unknown command or flag, missing or unparsable argument.
fn failUsageMsg(w: *Io.Writer, msg: []const u8) noreturn {
    w.writeAll(msg) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

/// Bad invocation, with the offending value formatted into the message.
fn failUsage(w: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    w.print(fmt, args) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

/// Runtime failure: well-formed invocation, impossible work (no such id,
/// missing image file, pasteboard or DB refusal).
fn failRuntime(w: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    w.print(fmt, args) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

// Zig 0.16: runtime passes a pre-built `Init` with argv, allocator, I/O.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_file_writer.interface;

    // CLI commands are short-lived; one bulk free on exit beats tracking frees.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) failUsageMsg(err, usage);

    const environ = init.minimal.environ;
    const command = std.meta.stringToEnum(Command, args[1]) orelse
        failUsageMsg(err, usage);

    switch (command) {
        .daemon => try daemon.run(alloc, io, environ, out),
        .use, .thumb => {
            if (args.len < 3) failUsage(err, "zclip {s}: missing <id>\n", .{@tagName(command)});

            const id = std.fmt.parseInt(i64, args[2], 10) catch
                failUsage(err, "zclip {s}: invalid id {s}\n", .{ @tagName(command), args[2] });
            if (command == .use)
                try runUse(alloc, environ, io, out, err, id)
            else
                try runThumb(alloc, environ, io, out, err, id);
            try out.flush();
        },
        .tag, .untag => {
            if (args.len != 4) failUsage(
                err,
                "zclip {s}: usage: zclip {s} <id> <tag>\n",
                .{ @tagName(command), @tagName(command) },
            );

            const id = std.fmt.parseInt(i64, args[2], 10) catch
                failUsage(err, "zclip {s}: invalid id {s}\n", .{ @tagName(command), args[2] });

            const trimmed = std.mem.trim(u8, args[3], " \t\r\n");
            if (trimmed.len == 0) failUsage(
                err,
                "zclip {s}: invalid tag {s}\n",
                .{ @tagName(command), args[3] },
            );

            const buf = try alloc.alloc(u8, trimmed.len);
            const tag = std.ascii.lowerString(buf, trimmed);

            if (command == .tag)
                try runTag(alloc, environ, err, id, tag)
            else
                try runUntag(alloc, environ, err, id, tag);
        },
        .query => {
            var tag_value: ?[]const u8 = null;
            var limit_value: ?u32 = null;

            // Tracks flags, not values: `--tag ""` is a seen flag with an empty
            // value, and repeating it is still an error.
            var seen: std.EnumSet(QueryFlag) = .empty;

            var index: usize = 2;
            while (index < args.len) : (index += 2) {
                const flag = QueryFlag.fromArg(args[index]) orelse
                    failUsage(err, "zclip {s}: unknown flag {s} provided\n", .{ @tagName(command), args[index] });

                // A flag-shaped token is never a value: `query --tag --limit 5`
                // would otherwise bind the tag to "--limit" and exit 0 with an
                // empty array instead of reporting the missing value.
                if (index + 1 >= args.len or isFlagShaped(args[index + 1])) failUsage(
                    err,
                    "zclip {s}: missing value for --{s} flag\n",
                    .{ @tagName(command), @tagName(flag) },
                );

                if (seen.contains(flag)) failUsage(
                    err,
                    "zclip {s}: multiple values for --{s} flag\n",
                    .{ @tagName(command), @tagName(flag) },
                );
                seen.insert(flag);

                switch (flag) {
                    // Trim to match stored names: tag/untag trim before insert.
                    .tag => tag_value = std.mem.trim(u8, args[index + 1], " \t\r\n"),
                    .limit => limit_value = std.fmt.parseInt(u32, args[index + 1], 10) catch
                        failUsage(err, "zclip {s}: invalid limit {s}\n", .{ @tagName(command), args[index + 1] }),
                }
            }

            try runQuery(alloc, environ, out, tag_value, limit_value);
            try out.flush();
        },
        .tags => {
            try runTags(alloc, environ, out);
            try out.flush();
        },
    }
}

fn storageDir(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const home = environ.getPosix("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/zclip", .{home});
}

// Returns sentinel-0 slice — SQLite's C API needs `const char *`.
fn dbPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![:0]u8 {
    const home = environ.getPosix("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.local/share/zclip/history.db",
        .{home},
        0,
    );
}

fn runQuery(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    w: *Io.Writer,
    tag: ?[]const u8,
    limit: ?u32,
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const results = if (tag) |t|
        try db.getEntriesByTag(t, limit)
    else
        try db.getEntries(limit);
    defer db_mod.freeEntries(allocator, results);

    // One flat shape for both kinds; the irrelevant half is null and omitted,
    // so text rows serialise as they always did and clients switch on `kind`.
    // No thumbnail BLOB: base64ing every image into a listing that's re-read
    // per keystroke would cost megabytes. Clients call `zclip thumb <id>`.
    const JsonEntry = struct {
        id: i64,
        kind: []const u8,
        content: ?[]const u8 = null,
        /// Dimensions of the original, for labels like "Image (1024x1024)".
        width: ?i64 = null,
        height: ?i64 = null,
        /// Original on disk — what `zclip use` puts back on the pasteboard.
        path: ?[]const u8 = null,
        byte_len: ?i64 = null,
    };

    const rows = try allocator.alloc(JsonEntry, results.len);
    for (results, rows) |entry, *row| {
        row.* = .{ .id = entry.id, .kind = @tagName(entry.kind), .content = entry.content };
        if (entry.image) |img| {
            row.width = img.width;
            row.height = img.height;
            row.path = img.path;
            row.byte_len = img.byte_len;
        }
    }

    try std.json.Stringify.value(rows, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

fn runTags(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    w: *Io.Writer,
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const names = try db.getTagNames();
    defer db_mod.freeTagNames(allocator, names);

    try std.json.Stringify.value(names, .{}, w);
    try w.writeByte('\n');
}

fn runUse(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    io: Io,
    w: *Io.Writer,
    err: *Io.Writer,
    id: i64,
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);
    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const entry = (try db.getEntryById(id)) orelse
        failRuntime(err, "zclip use: no entry with id {d}\n", .{id});
    defer db_mod.freeEntry(allocator, entry);

    const pb = clipboard.Pasteboard.general();

    // AppKit's verdict, carried out of the switch so failure is handled once
    // for both kinds — and before `touch`. Bumping copied_at for content that
    // never reached the pasteboard reorders history around a non-event.
    const Written = struct { ok: bool, byte_len: usize };
    const written: Written = switch (entry.kind) {
        .text => blk: {
            // Non-null for .text per the schema's CHECK.
            const content = entry.content.?;
            break :blk .{
                .ok = try pb.writeStringAsOrigin(allocator, content),
                .byte_len = content.len,
            };
        },
        .image => blk: {
            const img = entry.image.?;

            // The untouched original, not the thumbnail — that exists only for
            // cheap previews.
            const bytes = Io.Dir.cwd().readFileAlloc(io, img.path, allocator, .unlimited) catch
                failRuntime(err, "zclip use: image file missing: {s}\n", .{img.path});
            defer allocator.free(bytes);

            // Stored UTI goes back verbatim, no lookup, so a row written by a
            // build that captures more image types still restores correctly.
            break :blk .{
                .ok = pb.writeDataAsOrigin(bytes, img.uti.ptr),
                .byte_len = bytes.len,
            };
        },
    };

    if (!written.ok) failRuntime(err, "zclip use: pasteboard rejected the write for id {d}\n", .{id});

    try db.touch(id, daemon.unixNow(io));
    try w.print("copied id={d} ({d} bytes) to pasteboard\n", .{ id, written.byte_len });
}

/// Materialise image `id`'s thumbnail into the cache dir and print its path.
/// Clients render by path, so the BLOB has to become a file somewhere; doing it
/// here keeps `query` cheap and the cache regenerable (deleting it costs a
/// re-run, never data).
fn runThumb(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    io: Io,
    w: *Io.Writer,
    err: *Io.Writer,
    id: i64,
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);
    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const dir = try storageDir(allocator, environ);
    defer allocator.free(dir);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{dir});
    defer allocator.free(cache_dir);
    try Io.Dir.cwd().createDirPath(io, cache_dir);

    // Keyed by rowid, which SQLite recycles after a delete (no AUTOINCREMENT),
    // so any future prune path must unlink this file or the next entry landing
    // on that id serves the previous one's thumbnail.
    const out_path = try std.fmt.allocPrint(allocator, "{s}/{d}.png", .{ cache_dir, id });
    defer allocator.free(out_path);

    // A thumbnail never changes, so an existing file is always current. Only
    // FileNotFound means "not cached yet" — anything else (a permission problem
    // on the cache dir) must surface instead of being retried forever.
    if (Io.Dir.cwd().access(io, out_path, .{})) |_| {
        try w.print("{s}\n", .{out_path});
        return;
    } else |access_err| switch (access_err) {
        error.FileNotFound => {},
        else => return access_err,
    }

    const thumb = (try db.getThumb(id)) orelse
        failRuntime(err, "zclip thumb: no image entry with id {d}\n", .{id});
    defer allocator.free(thumb);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = thumb });
    try w.print("{s}\n", .{out_path});
}

fn runTag(allocator: std.mem.Allocator, environ: std.process.Environ, err: *Io.Writer, entry_id: i64, tag: []const u8) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    db.insertTag(tag) catch |e|
        failRuntime(err, "{s} - Failed to insert tag {s}\n", .{ @errorName(e), tag });

    const tag_id = try db.getTagIdByName(tag) orelse
        failRuntime(err, "Failed to get tag id for tag {s}\n", .{tag});

    db.insertEntryTag(entry_id, tag_id) catch |e| failRuntime(
        err,
        "{s} - Failed to insert entry tag for entry_id {d} and tag_id {d}\n",
        .{ @errorName(e), entry_id, tag_id },
    );
}

fn runUntag(allocator: std.mem.Allocator, environ: std.process.Environ, err: *Io.Writer, entry_id: i64, tag: []const u8) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const tag_id = try db.getTagIdByName(tag) orelse return;
    db.deleteEntryTag(entry_id, tag_id) catch |e| failRuntime(
        err,
        "{s} - Failed to delete entry tag for entry_id {d} and tag_id {d}\n",
        .{ @errorName(e), entry_id, tag_id },
    );
}
