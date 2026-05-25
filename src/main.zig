// CLI entry point. Parses argv, dispatches to one of three subcommands:
// `daemon`, `search`, or `use`.
//
// Lots of Zig idioms appear here for the first time, so this file is
// commented heavily for someone new to Zig. Look here first when an
// unfamiliar syntax shows up elsewhere.

// `@import` is a builtin (everything starting with `@` is). It returns the
// imported module as a struct value, which we then bind to a `const`.
// Importing "std" gives us the standard library.
const std = @import("std");

// Local aliases — just shorter names for things we'll use a lot.
const Io = std.Io;

// Importing our own files. Each .zig file is implicitly a struct whose
// public (`pub`) declarations are accessible from outside.
const clipboard = @import("clipboard.zig");
const db_mod = @import("db.zig");
const daemon = @import("daemon.zig");

// Multiline string literal. Every line starts with `\\` — Zig keeps them
// joined with newlines and avoids any escaping inside. The result is a
// regular `[]const u8` (Zig's normal string type: a slice of constant bytes).
const usage =
    \\zclip - persistent clipboard history
    \\
    \\Usage:
    \\  zclip daemon              Run the polling daemon (foreground)
    \\  zclip search <keyword>    Search history (substring match)
    \\  zclip use <id>            Put entry <id> back on the pasteboard
    \\
;

// `pub` makes this function visible to the Zig runtime, which calls it as the
// program entry point.
//
// `init: std.process.Init` is new in Zig 0.16 — the runtime hands us a
// pre-built object containing argv, an allocator, and an I/O handle.
//
// `!void` is an *error union* return type. The leading `!` means "either an
// error or void". Any caller must handle the error with `try` (re-throw) or
// `catch` (handle locally).
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // ---- Set up buffered writers for stdout and stderr ----
    //
    // Zig 0.16 split I/O behind an `Io` interface. To write to stdout we
    // allocate a stack buffer, construct a `File.Writer` over it, and use
    // the writer's `interface` field for actual `print`/`writeAll` calls.
    //
    // `var ... : [4096]u8 = undefined` — declare a 4096-byte array on the
    // stack. `[N]T` reads "array of N items of type T". `= undefined` means
    // "don't bother zero-initialising — I will overwrite it." Cheaper than
    // forcing the bytes to zero.
    //
    // `var` is mutable; `const` is not. Buffers must be `var` because the
    // writer writes into them.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err = &stderr_file_writer.interface;

    // ---- Arena allocator ----
    //
    // Zig has no garbage collector. Every allocation pairs with a free.
    // Threading individual frees through every function is tedious, so a
    // common pattern is an *arena*: an allocator that lends out memory
    // freely and frees everything at once when it dies.
    //
    // `page_allocator` is a low-level allocator that asks the OS for whole
    // memory pages. The arena sits on top of it and slices them up.
    //
    // `defer arena.deinit()` schedules `arena.deinit()` to run whenever this
    // scope exits, regardless of how (return, error, panic). Pairs
    // acquisition + cleanup right next to each other in the source.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // `arena.allocator()` returns a `std.mem.Allocator` value — a fat
    // pointer to the underlying arena. Other functions take this type.
    const alloc = arena.allocator();

    // ---- Parse arguments ----
    //
    // `init.minimal.args.toSlice(alloc)` returns `![][]const u8` — an
    // error-union of "slice of string slices".
    //
    // `try expr` is sugar for "if `expr` returned an error, return it from
    // *this* function; otherwise, unwrap the value." `try` only works inside
    // a function that itself returns an error-union (like our `!void`).
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        try err.writeAll(usage);
        try err.flush();
        std.process.exit(2); // 2 is the conventional "usage error" exit code.
    }

    const cmd = args[1];

    // Zig has no `==` for slices — comparing two strings means comparing
    // each byte. `std.mem.eql(u8, a, b)` is the explicit equivalent. The
    // `u8` argument tells it the element type.
    if (std.mem.eql(u8, cmd, "daemon")) {
        try daemon.run(alloc, out);
        return;
    }
    if (std.mem.eql(u8, cmd, "search")) {
        if (args.len < 3) {
            try err.writeAll("zclip search: missing <keyword>\n");
            try err.flush();
            std.process.exit(2);
        }
        try runSearch(alloc, out, args[2]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "use")) {
        if (args.len < 3) {
            try err.writeAll("zclip use: missing <id>\n");
            try err.flush();
            std.process.exit(2);
        }
        // `catch { ... }` is an *error handler block*. If `parseInt` errors,
        // run the block; otherwise unwrap the value into `id`.
        //
        // `std.process.exit` returns `noreturn`, so Zig knows the block
        // doesn't fall through and is happy to treat the whole expression
        // as producing an `i64`.
        const id = std.fmt.parseInt(i64, args[2], 10) catch {
            try err.print("zclip use: invalid id {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(2);
        };
        try runUse(alloc, out, err, id);
        try out.flush();
        return;
    }

    try err.writeAll(usage);
    try err.flush();
    std.process.exit(2);
}

// Build the absolute path to `history.db` from $HOME.
//
// Return type `![:0]u8` reads "error-union of (slice of `u8` with sentinel
// `0`)". The `:0` means "guaranteed to have a `0` byte right after the last
// readable element". This is Zig's representation of a C-style null-
// terminated string — needed because SQLite's C API expects `const char *`.
fn dbPath(allocator: std.mem.Allocator) ![:0]u8 {
    // `std.c.getenv` returns `?[*:0]u8` — an *optional* C string pointer.
    // The `?` means "might be null". `orelse expr` says "if non-null,
    // unwrap; if null, evaluate `expr` instead." Here we return an error.
    const home_cstr = std.c.getenv("HOME") orelse return error.MissingHome;

    // `std.mem.span(cstr)` walks a 0-terminated C pointer and turns it
    // into a proper Zig slice (with a length).
    const home = std.mem.span(home_cstr);

    // `allocPrintSentinel(... , 0)` is `allocPrint` plus "ensure a trailing
    // 0 byte". Required because the result will be passed to a C function.
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.local/share/zclip/history.db",
        .{home},
        0,
    );
}

// `w: anytype` is Zig's lightweight generics. The compiler stamps out a
// fresh copy of `runSearch` for each concrete type passed as `w`. This is
// how a function works for any "writer-like" value without a formal
// interface declaration.
fn runSearch(allocator: std.mem.Allocator, w: anytype, keyword: []const u8) !void {
    const path = try dbPath(allocator);
    defer allocator.free(path); // Pair allocation with cleanup right away.

    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    const results = try db.search(keyword, 50);
    defer db_mod.freeEntries(allocator, results);

    if (results.len == 0) {
        try w.print("no matches for {s}\n", .{keyword});
        return;
    }

    // `for (slice) |item|` iterates and binds each element to `item`. The
    // `|...|` (vertical bars) is Zig's "capture" syntax — you'll see it
    // again on `if (opt) |val|` and `catch |err|`.
    for (results) |entry| {
        try writeIsoTime(w, entry.copied_at);
        // `{d}` formats an integer, `{s}` formats a string. Format args
        // come as a tuple literal `.{ a, b, c }`.
        try w.print("  id={d}  ", .{entry.id});
        try writeTruncated(w, entry.content, 120);
        try w.writeByte('\n');
    }
}

fn runUse(allocator: std.mem.Allocator, w: anytype, err: anytype, id: i64) !void {
    const path = try dbPath(allocator);
    defer allocator.free(path);
    var db = try db_mod.Db.open(allocator, path);
    defer db.close();

    // `try db.getById(id)` unwraps the error union, leaving `?[]u8`
    // (an optional slice). Then `orelse { ... }` runs the block if null.
    // Combined, this is "error-or-null" handling in two lines.
    const content = (try db.getById(id)) orelse {
        try err.print("zclip use: no entry with id {d}\n", .{id});
        try err.flush();
        std.process.exit(1);
    };
    defer allocator.free(content);

    const pb = clipboard.Pasteboard.general();
    try pb.writeStringAsOrigin(allocator, content);
    try db.touch(id, daemon.unixNow());
    try w.print("copied id={d} ({d} bytes) to pasteboard\n", .{ id, content.len });
}

// Print `s` truncated to `max` bytes, with newlines/tabs collapsed to
// spaces so the output stays on one line.
fn writeTruncated(w: anytype, s: []const u8, max: usize) !void {
    var i: usize = 0;
    var written: usize = 0;
    // `while (cond) : (step)` is Zig's indexed loop — the `: (i += 1)`
    // runs at the end of each iteration. (Zig's `for` is iterator-style
    // only; for index-counting loops you use `while`.)
    while (i < s.len and written < max) : (i += 1) {
        const ch = s[i];
        // `if (cond) a else b` is an expression here, not a statement.
        // The whole `if` evaluates to `a` or `b` and is bound to `out_ch`.
        const out_ch: u8 = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
        try w.writeByte(out_ch);
        written += 1;
    }
    if (i < s.len) try w.writeAll("…");
}

// Format a Unix epoch second as "YYYY-MM-DD HH:MM".
fn writeIsoTime(w: anytype, epoch_seconds: i64) !void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const dt = es.getDaySeconds();
    // Format specifiers: `{d:0>4}` = decimal, padded to width 4 with `0`
    // on the left. Combined here to get e.g. `2026-05-25 02:55`.
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        dt.getHoursIntoDay(),
        dt.getMinutesIntoHour(),
    });
}
