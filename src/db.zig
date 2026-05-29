//! SQLite wrapper.
//!
//! Schema:
//!   entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
//!   index on hash, index on copied_at
//!
//! `upsertByHash` updates `copied_at` if the same content has been seen
//! before (matched by SHA256), otherwise inserts.
//!
//! Bindings come from translate-c run over `src/sqlite_c.h` and wired into
//! the build as the `sqlite_c` module (see `build.zig`). 0.16 deprecated
//! source-level `@cImport` in favor of build-system translate-c.

const std = @import("std");

pub const c = @import("sqlite_c");

// SQLite's `SQLITE_TRANSIENT` and `SQLITE_STATIC` are macros expanding to
// `((destructor_type)-1)` and `((destructor_type)0)`. translate-c emits
// them as `@ptrFromInt(...)` which fails Zig's fn-pointer alignment check
// at comptime.
//
// All bind sites below keep buffers alive past `sqlite3_finalize`, so
// SQLITE_STATIC semantics hold and we can pass null (SQLite treats null
// as "caller manages buffer lifetime").
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const Error = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    OutOfMemory,
};

pub const Entry = struct {
    id: i64,
    content: []u8, // owned by caller's allocator
    copied_at: i64,
};

pub const Db = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!Db {
        var h: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &h);
        if (rc != c.SQLITE_OK or h == null) {
            // Failed open may still allocate a handle that needs closing.
            if (h) |hh| _ = c.sqlite3_close(hh);
            return Error.OpenFailed;
        }
        var db: Db = .{ .handle = h.?, .allocator = allocator };

        // WAL lets CLI readers run concurrently with daemon writes
        // instead of serialising through a rollback journal.
        try db.exec("PRAGMA journal_mode=WAL;");
        // synchronous=NORMAL: tiny crash-recovery risk for big throughput.
        // Fine for clipboard history.
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

    /// One-off statement (no parameters, no result rows). For pragmas and DDL.
    pub fn exec(self: *Db, sql: []const u8) Error!void {
        const z = self.allocator.dupeSentinel(u8, sql, 0) catch return Error.OutOfMemory;
        defer self.allocator.free(z);

        var err: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, z.ptr, null, null, &err);
        if (rc != c.SQLITE_OK) {
            if (err != null) c.sqlite3_free(err);
            return Error.ExecFailed;
        }
    }

    /// Caller must `defer _ = c.sqlite3_finalize(stmt);` on the result.
    fn prepare(self: *Db, sql: []const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK or stmt == null) return Error.PrepareFailed;
        return stmt.?;
    }

    /// Upsert by content hash. Returns true if a new row was inserted,
    /// false if an existing row's `copied_at` was bumped.
    pub fn upsertByHash(
        self: *Db,
        content: []const u8,
        hash: []const u8,
        now: i64,
    ) Error!bool {
        const find_sql = "SELECT id FROM entries WHERE hash = ? LIMIT 1;";
        const find_stmt = try self.prepare(find_sql);
        defer _ = c.sqlite3_finalize(find_stmt);

        if (c.sqlite3_bind_blob(
            find_stmt,
            1,
            hash.ptr,
            @intCast(hash.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;

        const step_rc = c.sqlite3_step(find_stmt);
        if (step_rc == c.SQLITE_ROW) {
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

    /// Bump `copied_at` without touching content/hash. Used by `zclip use`
    /// so the just-used entry surfaces as most recent.
    pub fn touch(self: *Db, id: i64, now: i64) Error!void {
        const stmt = try self.prepare("UPDATE entries SET copied_at = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, now) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.StepFailed;
    }

    /// Substring search via LIKE. Caller owns the returned slice and each
    /// `entry.content` — release everything via `freeEntries`.
    pub fn search(
        self: *Db,
        keyword: []const u8,
        limit: u32,
    ) Error![]Entry {
        const pattern = std.fmt.allocPrint(
            self.allocator,
            "%{s}%",
            .{keyword},
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(pattern);

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

        var out: std.ArrayList(Entry) = .empty;

        // errdefer (not defer): on success, caller owns `out` and freeing
        // here would be a use-after-free.
        errdefer {
            for (out.items) |e| self.allocator.free(e.content);
            out.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.StepFailed;

            const id = c.sqlite3_column_int64(stmt, 0);
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

        return out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Fetch one entry's content by id. Caller owns the slice.
    pub fn getById(self: *Db, id: i64) Error!?[]u8 {
        const stmt = try self.prepare("SELECT content FROM entries WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BindFailed;
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;
        const text_ptr = c.sqlite3_column_text(stmt, 0);
        const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(text_ptr))[0..text_len],
        ) catch Error.OutOfMemory;
    }
};

/// Free a slice returned by `search` — both per-entry `content` buffers
/// and the slice itself.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.content);
    allocator.free(entries);
}
