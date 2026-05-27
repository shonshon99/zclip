//! Thin SQLite wrapper for zclip.
//!
//! Schema:
//!   entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
//!   index on hash, index on copied_at
//!
//! `upsertByHash` updates `copied_at` if the same content has been seen
//! before (matched by SHA256), otherwise inserts. This keeps recency
//! accurate without exploding storage on repeat copies.
//!
//! BEGINNER NOTES
//! --------------
//! SQLite is a C library. To call it from Zig we run the "translate-c"
//! tool over a thin shim header (`src/sqlite_c.h`) and import the result
//! as a regular Zig module. After this import, every `c.sqlite3_*`
//! function is just an `extern "c" fn` underneath.
//!
//! Why an import and not `@cImport`? Zig 0.16 deprecated source-level
//! `@cImport` in favor of running translate-c through the build system.
//! The wiring lives in `build.zig` (`b.addTranslateC` + `addImport`).
//!
//! SQLite's "prepared statement" lifecycle is:
//!     prepare → bind args → step (until SQLITE_DONE or row) → finalize
//! We follow this dance for every query, using `defer` to make sure
//! `finalize` always runs.

const std = @import("std");

// `@import("sqlite_c")` pulls in the translate-c output that build.zig
// wired up under that name. The module exposes every `sqlite3_*` symbol
// and every `SQLITE_*` constant from sqlite3.h.
pub const c = @import("sqlite_c");

// SQLITE_TRANSIENT (((destructor_type)-1)) and SQLITE_STATIC (0) are
// sentinel "function pointers" defined as macros in the SQLite header.
// translate-c can't fold them into a typed fn-pointer at comptime because
// Zig requires fn pointers to be aligned, and `-1`/`0` aren't.
//
// All callers below keep the bound buffers alive until after `finalize` —
// so SQLITE_STATIC semantics are correct, and we can simply pass null as
// the destructor. SQLite treats null as "no destructor, caller manages
// the buffer's lifetime", which is exactly what we want.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ---- Error set --------------------------------------------------------------
//
// In Zig, errors are values from named *error sets*. This declares a set
// with six possible error values. Functions can return `Error!T` to mean
// "either a success of type T, or one of these errors." Errors are
// enum-like value tags with zero runtime cost — no allocation, no
// stack-trace capture unless one actually propagates to a panic.
pub const Error = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    OutOfMemory,
};

// A search result row, with `content` already copied into caller-owned
// memory (so the caller is responsible for freeing it).
pub const Entry = struct {
    id: i64,
    content: []u8, // owned by caller's allocator
    copied_at: i64,
};

pub const Db = struct {
    // `*c.sqlite3` is a pointer to SQLite's connection struct. We never
    // look inside it; SQLite gives us the pointer and we hand it back.
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    /// Open or create the database at `path`, initialise schema and pragmas.
    ///
    /// `path: [:0]const u8` is a 0-terminated slice (Zig's representation
    /// of "this is safe to pass to a C function expecting `const char *`").
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!Db {
        // `?*c.sqlite3` is an *optional* pointer — possibly null. We give
        // SQLite its address via `&h`; SQLite fills it in.
        var h: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &h);
        if (rc != c.SQLITE_OK or h == null) {
            // Even on failure, SQLite may have allocated a handle that
            // needs closing. `if (h) |hh|` unwraps the optional: "if h is
            // non-null, bind the inner pointer to `hh` and run the body."
            // `_ = expr` discards a return value (Zig insists you do
            // *something* with every value).
            if (h) |hh| _ = c.sqlite3_close(hh);
            return Error.OpenFailed;
        }
        // `h.?` is the *unwrap* operator. Since we've just checked that
        // h is non-null, `h.?` safely extracts the inner pointer. If we
        // were wrong and h were null, this would panic.
        var db: Db = .{ .handle = h.?, .allocator = allocator };

        // WAL mode: lets readers run concurrently with one writer (vs the
        // default which serialises everything via a rollback journal).
        try db.exec("PRAGMA journal_mode=WAL;");
        // synchronous=NORMAL trades a tiny crash-recovery risk for a big
        // throughput win. fine for a clipboard history.
        try db.exec("PRAGMA synchronous=NORMAL;");
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS entries (
            \\  id        INTEGER PRIMARY KEY,
            \\  content   TEXT NOT NULL,
            \\  hash      BLOB NOT NULL,
            \\  copied_at INTEGER NOT NULL
            \\);
        );
        try db.exec("CREATE INDEX IF NOT EXISTS entries_hash_idx ON entries(hash);");
        try db.exec("CREATE INDEX IF NOT EXISTS entries_copied_at_idx ON entries(copied_at);");
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute a one-off SQL statement (no parameters, no result rows).
    /// Used for pragmas and CREATE TABLE/INDEX.
    pub fn exec(self: *Db, sql: []const u8) Error!void {
        var err: [*c]u8 = null;
        // `[*c]u8` is the "C pointer" type — semi-magical, can be null,
        // can be cast to many things. Used here because that's exactly
        // what sqlite3_exec wants as out-param for the error message.
        //
        // dupeSentinel makes a 0-terminated copy. We could also just pass
        // `sql.ptr` if we knew the caller always provided a sentinel
        // slice — but the API takes plain `[]const u8` for convenience.
        const z = self.allocator.dupeSentinel(u8, sql, 0) catch return Error.OutOfMemory;
        defer self.allocator.free(z);
        const rc = c.sqlite3_exec(self.handle, z.ptr, null, null, &err);
        if (rc != c.SQLITE_OK) {
            if (err != null) c.sqlite3_free(err);
            return Error.ExecFailed;
        }
    }

    /// Helper for the prepare → step pattern. Returns the prepared
    /// statement, which the caller is responsible for finalising (use
    /// `defer _ = c.sqlite3_finalize(stmt);`).
    fn prepare(self: *Db, sql: []const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            // `@intCast` converts between integer types. sql.len is usize,
            // sqlite3_prepare_v2 wants c_int. The cast asserts the value
            // fits (true for any reasonable SQL string).
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK or stmt == null) return Error.PrepareFailed;
        return stmt.?;
    }

    /// Upsert by content hash.
    /// Returns true if a new row was inserted, false if an existing row's
    /// `copied_at` was bumped.
    pub fn upsertByHash(
        self: *Db,
        content: []const u8,
        hash: []const u8,
        now: i64,
    ) Error!bool {
        // ---- 1. Look up existing row by hash ----
        const find_sql = "SELECT id FROM entries WHERE hash = ? LIMIT 1;";
        const find_stmt = try self.prepare(find_sql);
        // `defer` schedules cleanup at scope exit. Pair acquisition with
        // release immediately so it's visually obvious nothing leaks.
        defer _ = c.sqlite3_finalize(find_stmt);

        if (c.sqlite3_bind_blob(
            find_stmt,
            1, // 1-based parameter index (the first `?`)
            hash.ptr,
            @intCast(hash.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;

        // `sqlite3_step` returns SQLITE_ROW if a row is ready, SQLITE_DONE
        // if no more rows, or an error code otherwise.
        const step_rc = c.sqlite3_step(find_stmt);
        if (step_rc == c.SQLITE_ROW) {
            // Found a match — bump its copied_at.
            const existing_id = c.sqlite3_column_int64(find_stmt, 0);
            const upd = try self.prepare("UPDATE entries SET copied_at = ? WHERE id = ?;");
            defer _ = c.sqlite3_finalize(upd);
            if (c.sqlite3_bind_int64(upd, 1, now) != c.SQLITE_OK) return Error.BindFailed;
            if (c.sqlite3_bind_int64(upd, 2, existing_id) != c.SQLITE_OK) return Error.BindFailed;
            if (c.sqlite3_step(upd) != c.SQLITE_DONE) return Error.StepFailed;
            return false;
        } else if (step_rc != c.SQLITE_DONE) {
            return Error.StepFailed;
        }

        // ---- 2. No existing row — insert a fresh one ----
        const ins = try self.prepare(
            "INSERT INTO entries (content, hash, copied_at) VALUES (?, ?, ?);",
        );
        defer _ = c.sqlite3_finalize(ins);
        if (c.sqlite3_bind_text(
            ins,
            1,
            content.ptr,
            @intCast(content.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_blob(
            ins,
            2,
            hash.ptr,
            @intCast(hash.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(ins, 3, now) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_step(ins) != c.SQLITE_DONE) return Error.StepFailed;
        return true;
    }

    /// Bump `copied_at` on an existing row without touching content/hash.
    /// Used by `zclip use` so the just-used entry surfaces as most recent.
    pub fn touch(self: *Db, id: i64, now: i64) Error!void {
        const stmt = try self.prepare("UPDATE entries SET copied_at = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, now) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.StepFailed;
    }

    /// Substring search via SQL LIKE. `keyword` is wrapped with `%`.
    /// Caller owns the returned slice and each `entry.content` — use
    /// `freeEntries` to release everything.
    pub fn search(
        self: *Db,
        keyword: []const u8,
        limit: u32,
    ) Error![]Entry {
        // Build the LIKE pattern dynamically — needs allocation.
        const pattern = std.fmt.allocPrint(
            self.allocator,
            "%{s}%",
            .{keyword},
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(pattern);

        // `++` is Zig's compile-time string concatenation. Lets us split
        // a long SQL literal across lines without runtime cost.
        const stmt = try self.prepare(
            "SELECT id, content, copied_at FROM entries " ++
                "WHERE content LIKE ? ESCAPE '\\' " ++
                "ORDER BY copied_at DESC LIMIT ?;",
        );
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(
            stmt,
            1,
            pattern.ptr,
            @intCast(pattern.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int(stmt, 2, @intCast(limit)) != c.SQLITE_OK) return Error.BindFailed;

        // `.empty` is the canonical empty-ArrayList value (idiomatic in
        // Zig 0.14+). Equivalent to `ArrayList(Entry).init(...)` in older
        // versions but doesn't require an allocator until you actually
        // append something.
        var out: std.ArrayList(Entry) = .empty;

        // `errdefer` is like `defer` but only runs if the function returns
        // an *error*. On success the caller takes ownership of `out` and
        // these frees would be a use-after-free; on error we clean up.
        errdefer {
            for (out.items) |e| self.allocator.free(e.content);
            out.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.StepFailed;

            const id = c.sqlite3_column_int64(stmt, 0);
            // `sqlite3_column_text` returns a `[*c]const u8` — a C
            // "anything-goes" pointer. We re-cast to `[*]const u8` (Zig's
            // many-item pointer) and slice it with `[0..len]` to get a
            // proper `[]const u8`.
            const text_ptr = c.sqlite3_column_text(stmt, 1);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const content = self.allocator.dupe(
                u8,
                @as([*]const u8, @ptrCast(text_ptr))[0..text_len],
            ) catch return Error.OutOfMemory;
            const copied_at = c.sqlite3_column_int64(stmt, 2);
            out.append(self.allocator, .{
                .id = id,
                .content = content,
                .copied_at = copied_at,
            }) catch return Error.OutOfMemory;
        }

        // `toOwnedSlice` converts the ArrayList into a plain `[]Entry`
        // slice. The ArrayList's header is freed; the data buffer is
        // handed off to the caller.
        return out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Fetch a single entry's content by id. Caller owns the slice.
    pub fn getById(self: *Db, id: i64) Error!?[]u8 {
        const stmt = try self.prepare("SELECT content FROM entries WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BindFailed;
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null; // no row matched
        if (rc != c.SQLITE_ROW) return Error.StepFailed;
        const text_ptr = c.sqlite3_column_text(stmt, 0);
        const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(text_ptr))[0..text_len],
        ) catch Error.OutOfMemory;
    }
};

/// Free a slice returned by `search` — both the per-entry `content`
/// buffers and the slice itself.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.content);
    allocator.free(entries);
}
