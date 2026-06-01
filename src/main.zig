// CLI entry point. Dispatches `daemon`, `query`, `use`, `tag`, `untag`.

const std = @import("std");
const Io = std.Io;

const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const daemon = @import("daemon.zig");

const usage =
    \\zclip - persistent clipboard history
    \\
    \\Usage:
    \\  zclip daemon              Run the polling daemon (foreground)
    \\  zclip query               Dump all entries as a JSON array
    \\  zclip use <id>            Put entry <id> back on the pasteboard
    \\
;

// Zig 0.16: runtime passes a pre-built `Init` with argv, allocator, I/O.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 0.16 File.Writer: stack buffer + interface pointer for print/writeAll.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_file_writer.interface;

    // Arena: CLI commands are short-lived; one bulk free on exit beats
    // tracking individual frees.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        try err.writeAll(usage);
        try err.flush();
        std.process.exit(2);
    }

    const cmd = args[1];
    const environ = init.minimal.environ;

    if (std.mem.eql(u8, cmd, "daemon")) {
        try daemon.run(alloc, io, environ, out);
        return;
    }
    if (std.mem.eql(u8, cmd, "use")) {
        if (args.len < 3) {
            try err.writeAll("zclip use: missing <id>\n");
            try err.flush();
            std.process.exit(2);
        }
        const id = std.fmt.parseInt(i64, args[2], 10) catch {
            try err.print("zclip use: invalid id {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(2);
        };
        try runUse(alloc, environ, io, out, err, id);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "tag")) {
        if (args.len < 3) {
            try err.writeAll("zclip tag: missing <id>\n");
            try err.flush();
            std.process.exit(2);
        } else if (args.len < 4) {
            try err.writeAll("zclip tag: missing <tag>\n");
            try err.flush();
            std.process.exit(2);
        }

        const id = std.fmt.parseInt(i64, args[2], 10) catch {
            try err.print("zclip tag: invalid id {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(2);
        };

        const trimmed = std.mem.trim(u8, args[3], " \t\r\n");
        if (trimmed.len == 0) {
            try err.print("zclip tag: invalid tag {s}\n", .{args[3]});
            try err.flush();
            std.process.exit(2);
        }

        const buf = try alloc.alloc(u8, trimmed.len);
        const tag = std.ascii.lowerString(buf, trimmed);

        try runTag(alloc, environ, err, id, tag);

        return;
    }
    if (std.mem.eql(u8, cmd, "untag")) {
        if (args.len < 3) {
            try err.writeAll("zclip untag: missing <id>\n");
            try err.flush();
            std.process.exit(2);
        } else if (args.len < 4) {
            try err.writeAll("zclip untag: missing <tag>\n");
            try err.flush();
            std.process.exit(2);
        }

        const id = std.fmt.parseInt(i64, args[2], 10) catch {
            try err.print("zclip untag: invalid id {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(2);
        };

        const trimmed = std.mem.trim(u8, args[3], " \t\r\n");
        if (trimmed.len == 0) {
            try err.print("zclip untag: invalid tag {s}\n", .{args[3]});
            try err.flush();
            std.process.exit(2);
        }

        const buf = try alloc.alloc(u8, trimmed.len);
        const tag = std.ascii.lowerString(buf, trimmed);

        try runUntag(alloc, environ, err, id, tag);

        return;
    }
    if (std.mem.eql(u8, cmd, "query")) {
        if (args.len == 2) {
            try runQuery(alloc, environ, out);
            try out.flush();
            return;
        }
    }

    try err.writeAll(usage);
    try err.flush();
    std.process.exit(2);
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
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const results = try db.getEntries();
    defer db_mod.freeEntries(allocator, results);

    // Raycast client only needs id + content; map off Entry so copied_at is
    // dropped from the wire shape rather than serializing the whole row.
    const JsonEntry = struct { id: i64, content: []const u8 };
    const rows = try allocator.alloc(JsonEntry, results.len);
    for (results, rows) |entry, *row| {
        row.* = .{ .id = entry.id, .content = entry.content };
    }

    // Stringify escapes content for us; empty slice emits `[]` (empty-DB case).
    try std.json.Stringify.value(rows, .{}, w);
    try w.writeByte('\n');
}

fn runUse(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    io: Io,
    w: anytype,
    err: anytype,
    id: i64,
) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);
    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const content = (try db.getById(id)) orelse {
        try err.print("zclip use: no entry with id {d}\n", .{id});
        try err.flush();
        std.process.exit(1);
    };
    defer allocator.free(content);

    const pb = clipboard.Pasteboard.general();
    try pb.writeStringAsOrigin(allocator, content);
    try db.touch(id, daemon.unixNow(io));
    try w.print("copied id={d} ({d} bytes) to pasteboard\n", .{ id, content.len });
}

fn runTag(allocator: std.mem.Allocator, environ: std.process.Environ, err: anytype, entry_id: i64, tag: []const u8) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    db.insertTag(tag) catch |e| {
        try err.print("{s} - Failed to insert tag {s}\n", .{ @errorName(e), tag });
        try err.flush();
        std.process.exit(1);
    };

    const tag_id = try db.getTagIdByName(tag) orelse {
        try err.print("Failed to get tag id for tag {s}\n", .{tag});
        try err.flush();
        std.process.exit(1);
    };

    db.insertEntryTag(entry_id, tag_id) catch |e| {
        try err.print("{s} - Failed to insert entry tag for entry_id {d} and tag_id {d}\n", .{ @errorName(e), entry_id, tag_id });
        try err.flush();
        std.process.exit(1);
    };
}

fn runUntag(allocator: std.mem.Allocator, environ: std.process.Environ, err: anytype, entry_id: i64, tag: []const u8) !void {
    const path = try dbPath(allocator, environ);
    defer allocator.free(path);

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const tag_id = try db.getTagIdByName(tag) orelse return;
    db.deleteEntryTag(entry_id, tag_id) catch |e| {
        try err.print("{s} - Failed to delete entry tag for entry_id {d} and tag_id {d}\n", .{ @errorName(e), entry_id, tag_id });
        try err.flush();
        std.process.exit(1);
    };
}

// Truncate to `max` bytes; collapse newlines/tabs to spaces so each
// result stays on one line.
fn writeTruncated(w: anytype, s: []const u8, max: usize) !void {
    var i: usize = 0;
    var written: usize = 0;
    while (i < s.len and written < max) : (i += 1) {
        const ch = s[i];
        const out_ch: u8 = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
        try w.writeByte(out_ch);
        written += 1;
    }
    if (i < s.len) try w.writeAll("…");
}

// "YYYY-MM-DD HH:MM" from Unix epoch seconds.
fn writeIsoTime(w: anytype, epoch_seconds: i64) !void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const dt = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        dt.getHoursIntoDay(),
        dt.getMinutesIntoHour(),
    });
}
