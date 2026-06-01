//! SQLite wrapper.
//!
//! Schema:
//!   entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
//!   index on hash, index on copied_at
//!
//! `upsertByHash` updates `copied_at` if the same content has been seen
//! before (matched by SHA256), otherwise inserts.
//!
//! Schema is created/upgraded by the `MIGRATIONS` runner (PRAGMA
//! user_version) on `open`, not inline — append a migration for any change.
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

// Ordered schema migrations. MIGRATIONS[i] is the SQL that upgrades the DB
// from `user_version` i to i+1; the target version is `MIGRATIONS.len`.
//
// Append-only contract: never edit, reorder, or delete an existing entry —
// each string has already run (and bumped user_version) on live databases,
// so changing one would silently desync those installs from fresh ones. New
// schema changes go in a NEW trailing entry. A single entry may hold several
// `;`-separated statements; sqlite3_exec runs them all.
const MIGRATIONS = [_][]const u8{
    // v1 — initial schema
    \\CREATE TABLE IF NOT EXISTS entries (
    \\  id        INTEGER PRIMARY KEY,
    \\  content   TEXT NOT NULL,
    \\  hash      BLOB NOT NULL,
    \\  copied_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS entries_hash_idx ON entries(hash);
    \\CREATE INDEX IF NOT EXISTS entries_copied_at_idx ON entries(copied_at);
    \\
    \\CREATE TABLE IF NOT EXISTS tags (
    \\  id        INTEGER PRIMARY KEY,
    \\  name      TEXT NOT NULL UNIQUE COLLATE NOCASE
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS entry_tags (
    \\  entry_id  INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    \\  tag_id    INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    \\  PRIMARY KEY (entry_id, tag_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS entry_tags_tag_idx ON entry_tags(tag_id);
};

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
        // foreign_keys is per-connection and OFF by default. Required for the
        // entry_tags ON DELETE CASCADE to fire — without it, deleting an entry
        // orphans its link rows. Must run before migrate(): the pragma is a
        // no-op inside a transaction and migrate() opens BEGIN IMMEDIATE.
        try db.exec("PRAGMA foreign_keys=ON;");

        // journal_mode/synchronous/foreign_keys are per-connection and re-run
        // every open; schema lives in the versioned migration runner instead.
        // Idempotent, so CLI invocations that open the DB are safe even before
        // the daemon.
        try db.migrate();
        return db;
    }

    /// Read the current `PRAGMA user_version` (0 on a fresh DB).
    fn userVersion(self: *Db) Error!usize {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.StepFailed;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    /// Apply every migration above the DB's current `user_version`, each in
    /// its own transaction, bumping `user_version` after each. No-op when
    /// already at `MIGRATIONS.len` (idempotent re-runs).
    fn migrate(self: *Db) Error!void {
        // Cheap unlocked pre-check: the common case (DB already current, hit
        // by every CLI open) skips the write lock entirely.
        if (try self.userVersion() >= MIGRATIONS.len) return;

        // Re-check the version *inside* each transaction. The pre-check above
        // is unlocked, so a concurrent opener could advance user_version
        // between it and BEGIN IMMEDIATE. Reading under the write lock makes
        // check-then-apply atomic: the process that loses the BEGIN IMMEDIATE
        // race sees the bumped version and won't re-run a (possibly
        // non-idempotent) step.
        while (true) {
            // IMMEDIATE grabs the write lock up front so only one process
            // applies a step; ROLLBACK on any failure keeps the step atomic.
            try self.exec("BEGIN IMMEDIATE;");
            errdefer self.exec("ROLLBACK;") catch {};

            const v = try self.userVersion();
            if (v >= MIGRATIONS.len) {
                // Nothing left (we won nothing, or another process did the
                // work while we waited for the lock). Release and stop.
                try self.exec("COMMIT;");
                break;
            }

            try self.exec(MIGRATIONS[v]);

            // user_version can't be bound as a parameter — format the literal.
            // v+1 is the version this step produces; usize, no injection risk.
            var buf: [64]u8 = undefined;
            const sql = std.fmt.bufPrint(
                &buf,
                "PRAGMA user_version = {d};",
                .{v + 1},
            ) catch return Error.ExecFailed;
            try self.exec(sql);
            try self.exec("COMMIT;");
        }
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
        // Step 1 — probe by hash, not content. 32-byte indexed compare beats
        // scanning a possibly-huge TEXT column; this is the dedup key.
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

        // Step 2 — hash already present: bump copied_at so re-copied content
        // resurfaces as most-recent. Return false so the daemon logs a bump,
        // not a new entry. SQLITE_ROW = match; SQLITE_DONE = none (fall to insert).
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

        // Step 3 — no match: insert the new entry. Return true so the daemon
        // logs it as new. Not wrapped in a txn with step 1 — safe only because
        // the daemon is the sole writer (single-instance via pidfile lock).
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

    pub fn getEntries(self: *Db) Error![]Entry {
        const stmt = try self.prepare(
            "SELECT id, content, copied_at FROM entries ORDER BY copied_at DESC;",
        );
        defer _ = c.sqlite3_finalize(stmt);

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

    pub fn insertTag(self: *Db, tag: []const u8) Error!void {
        const stmt = try self.prepare("INSERT OR IGNORE INTO tags (name) VALUES (?);");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(
            stmt,
            1,
            tag.ptr,
            @intCast(tag.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return Error.StepFailed;
    }

    pub fn getTagIdByName(self: *Db, tag: []const u8) Error!?i64 {
        const stmt = try self.prepare("SELECT id FROM tags WHERE name = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(
            stmt,
            1,
            tag.ptr,
            @intCast(tag.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;

        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn insertEntryTag(self: *Db, entry_id: i64, tag_id: i64) Error!void {
        const stmt = try self.prepare("INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) VALUES (?, ?);");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, entry_id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, tag_id) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return Error.StepFailed;
    }

    pub fn deleteEntryTag(self: *Db, entry_id: i64, tag_id: i64) Error!void {
        const stmt = try self.prepare("DELETE FROM entry_tags WHERE entry_id = ? AND tag_id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, entry_id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, tag_id) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return Error.StepFailed;
    }
};

/// Free a slice returned by `search` — both per-entry `content` buffers
/// and the slice itself.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.content);
    allocator.free(entries);
}
