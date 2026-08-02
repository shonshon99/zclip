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
const MIGRATIONS = [_][]const u8{
    // v1
    //
    // Column order is deliberate in both tables: the one big payload goes
    // LAST. A row is stored as a single record (header of serial types, then
    // column bodies in declaration order), and anything past the local page
    // payload — roughly page_size minus 35 bytes, so ~4KB by default — spills
    // onto a chain of overflow pages. Reading a column means skipping every
    // preceding column's bytes, so a small column declared after a 200KB
    // thumbnail costs an overflow-chain walk to reach. Keeping all the
    // fixed-size metadata ahead of `content`/`thumb` means it's readable
    // straight off the leaf page.
    \\CREATE TABLE IF NOT EXISTS entries (
    \\  id        INTEGER PRIMARY KEY,
    \\  kind      TEXT NOT NULL DEFAULT 'text',
    \\  hash      BLOB NOT NULL,
    \\  copied_at INTEGER NOT NULL,
    \\  content   TEXT,
    \\  CHECK (kind IN ('text', 'image')),
    \\  CHECK ((kind = 'text') = (content IS NOT NULL))
    \\);
    \\CREATE INDEX IF NOT EXISTS entries_hash_idx ON entries(hash);
    \\CREATE INDEX IF NOT EXISTS entries_copied_at_idx ON entries(copied_at);
    \\
    \\CREATE TABLE IF NOT EXISTS images (
    \\  entry_id     INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    \\  path         TEXT NOT NULL,
    \\  mime         TEXT NOT NULL,
    \\  width        INTEGER NOT NULL,
    \\  height       INTEGER NOT NULL,
    \\  byte_len     INTEGER NOT NULL,
    \\  thumb        BLOB NOT NULL
    \\);
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

pub const Kind = enum { text, image };

/// Image row joined onto an entry. Strings owned by the caller's allocator.
///
/// The pixels live in two places on purpose: the untouched original sits at
/// `path` on disk (that's what `zclip use` puts back on the pasteboard), while
/// only the downscaled thumbnail is a BLOB in the DB, so `history.db` stays
/// small enough that CLI reads remain instant.
pub const ImageMeta = struct {
    path: []u8,
    mime: []u8,
    /// Dimensions of the original, not the thumbnail — this is what clients
    /// render as e.g. "Image (1024x1024)".
    width: i64,
    height: i64,
    /// Size of the original file at `path`.
    byte_len: i64,
};

pub const Entry = struct {
    id: i64,
    kind: Kind,
    /// Set iff `kind == .text`; the schema CHECKs the two agree.
    content: ?[]u8,
    /// Set iff `kind == .image`.
    image: ?ImageMeta,
    copied_at: i64,
};

/// Everything needed to archive a freshly-copied image. `thumb` is PNG bytes
/// regardless of the original's `mime`.
pub const NewImage = struct {
    path: []const u8,
    mime: []const u8,
    width: i64,
    height: i64,
    byte_len: i64,
    thumb: []const u8,
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
        // Every step below is fallible. Without this the handle escapes on
        // those paths, unlike the failed-open branch above which does close.
        errdefer _ = c.sqlite3_close(db.handle);

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

    /// Existing entry id for `hash`, or null. Probing by hash rather than
    /// content is the dedup key: a 32-byte indexed compare beats scanning a
    /// possibly-huge TEXT column, and it's the only workable probe for images
    /// (whose bytes aren't in the DB at all).
    ///
    /// Callers bump `copied_at` via `touch` on a hit so re-copied content
    /// resurfaces as most-recent, and insert on a miss. Not one transaction:
    /// safe only because the daemon is the sole writer (single-instance via
    /// the pidfile lock).
    pub fn findByHash(self: *Db, hash: []const u8) Error!?i64 {
        const stmt = try self.prepare("SELECT id FROM entries WHERE hash = ? LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_blob(
            stmt,
            1,
            hash.ptr,
            @intCast(hash.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;
        return c.sqlite3_column_int64(stmt, 0);
    }

    /// Insert a text entry. Returns its id.
    pub fn insertText(
        self: *Db,
        content: []const u8,
        hash: []const u8,
        now: i64,
    ) Error!i64 {
        const ins = try self.prepare(
            "INSERT INTO entries (kind, content, hash, copied_at) VALUES ('text', ?, ?, ?);",
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
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Insert an image entry plus its `images` row. Returns the entry id.
    ///
    /// Wrapped in a transaction, unlike `insertText`: an entries row without
    /// its images row would satisfy the schema but render as a broken entry
    /// forever, and there's no second write to repair it.
    pub fn insertImage(
        self: *Db,
        hash: []const u8,
        now: i64,
        img: NewImage,
    ) Error!i64 {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        const id = blk: {
            const ins = try self.prepare(
                "INSERT INTO entries (kind, content, hash, copied_at) VALUES ('image', NULL, ?, ?);",
            );
            defer _ = c.sqlite3_finalize(ins);
            if (c.sqlite3_bind_blob(
                ins,
                1,
                hash.ptr,
                @intCast(hash.len),
                SQLITE_STATIC,
            ) != c.SQLITE_OK) return Error.BindFailed;
            if (c.sqlite3_bind_int64(ins, 2, now) != c.SQLITE_OK) return Error.BindFailed;
            if (c.sqlite3_step(ins) != c.SQLITE_DONE) return Error.StepFailed;
            break :blk c.sqlite3_last_insert_rowid(self.handle);
        };

        // Columns are named, so this is decoupled from the table's own order —
        // it just mirrors it for readability.
        const ins_img = try self.prepare(
            "INSERT INTO images (entry_id, path, mime, width, height, byte_len, thumb)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?);",
        );
        defer _ = c.sqlite3_finalize(ins_img);
        if (c.sqlite3_bind_int64(ins_img, 1, id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_text(
            ins_img,
            2,
            img.path.ptr,
            @intCast(img.path.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_text(
            ins_img,
            3,
            img.mime.ptr,
            @intCast(img.mime.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(ins_img, 4, img.width) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(ins_img, 5, img.height) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(ins_img, 6, img.byte_len) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_blob(
            ins_img,
            7,
            img.thumb.ptr,
            @intCast(img.thumb.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_step(ins_img) != c.SQLITE_DONE) return Error.StepFailed;

        try self.exec("COMMIT;");
        return id;
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

    // LEFT JOIN, not two queries: image rows are a minority, and the join
    // keeps one ordered pass over entries. Column order is load-bearing —
    // `rowToEntry` indexes it positionally.
    const entry_select =
        "SELECT e.id, e.kind, e.content, e.copied_at," ++
        " i.path, i.mime, i.width, i.height, i.byte_len" ++
        " FROM entries e LEFT JOIN images i ON i.entry_id = e.id";

    pub fn getEntries(self: *Db) Error![]Entry {
        const stmt = try self.prepare(entry_select ++ " ORDER BY e.copied_at DESC;");
        defer _ = c.sqlite3_finalize(stmt);
        return self.collectEntries(stmt);
    }

    /// Entries carrying `tag`, newest first. No cap — the tag is the bound.
    /// `tags.name` is COLLATE NOCASE, so the match is case-insensitive.
    pub fn getEntriesByTag(self: *Db, tag: []const u8) Error![]Entry {
        const stmt = try self.prepare(
            entry_select ++
                " JOIN entry_tags et ON et.entry_id = e.id" ++
                " JOIN tags t ON t.id = et.tag_id" ++
                " WHERE t.name = ? ORDER BY e.copied_at DESC;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(
            stmt,
            1,
            tag.ptr,
            @intCast(tag.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        return self.collectEntries(stmt);
    }

    // Drains a prepared `entry_select` into an owned slice. Finalizing the
    // stmt stays with the caller.
    fn collectEntries(self: *Db, stmt: *c.sqlite3_stmt) Error![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        // errdefer (not defer): on success, caller owns `out` and freeing
        // here would be a use-after-free.
        errdefer {
            for (out.items) |e| freeEntry(self.allocator, e);
            out.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.StepFailed;

            const entry = try self.rowToEntry(stmt);
            errdefer freeEntry(self.allocator, entry);
            out.append(self.allocator, entry) catch return Error.OutOfMemory;
        }

        return out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    // Positional decode of one `entry_select` row.
    fn rowToEntry(self: *Db, stmt: *c.sqlite3_stmt) Error!Entry {
        const kind_text = (try self.dupeText(stmt, 1)) orelse return Error.StepFailed;
        defer self.allocator.free(kind_text);
        // An unknown kind means the DB was written by a newer zclip; failing
        // is better than silently mis-rendering the row.
        const kind = std.meta.stringToEnum(Kind, kind_text) orelse return Error.StepFailed;

        const content = try self.dupeText(stmt, 2);
        errdefer if (content) |ct| self.allocator.free(ct);

        // Columns 4-8 are all NULL for text rows (the LEFT JOIN found no
        // images row), so only read them when the kind says they're there.
        const image: ?ImageMeta = if (kind == .image) blk: {
            const path = (try self.dupeText(stmt, 4)) orelse return Error.StepFailed;
            errdefer self.allocator.free(path);
            const mime = (try self.dupeText(stmt, 5)) orelse return Error.StepFailed;
            break :blk .{
                .path = path,
                .mime = mime,
                .width = c.sqlite3_column_int64(stmt, 6),
                .height = c.sqlite3_column_int64(stmt, 7),
                .byte_len = c.sqlite3_column_int64(stmt, 8),
            };
        } else null;

        return .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .kind = kind,
            .content = content,
            .image = image,
            .copied_at = c.sqlite3_column_int64(stmt, 3),
        };
    }

    // Copies a TEXT column out, mapping SQL NULL to Zig null. The pointer
    // sqlite hands back dies at the next step/finalize, hence the dupe.
    fn dupeText(self: *Db, stmt: *c.sqlite3_stmt, col: c_int) Error!?[]u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(ptr))[0..len],
        ) catch Error.OutOfMemory;
    }

    /// Fetch one entry by id. Caller owns it — free with `freeEntry`.
    pub fn getEntryById(self: *Db, id: i64) Error!?Entry {
        const stmt = try self.prepare(entry_select ++ " WHERE e.id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;
        return try self.rowToEntry(stmt);
    }

    /// Thumbnail PNG bytes for an image entry, or null if `id` isn't one.
    /// Caller owns the slice.
    pub fn getThumb(self: *Db, id: i64) Error!?[]u8 {
        const stmt = try self.prepare("SELECT thumb FROM images WHERE entry_id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;

        const ptr = c.sqlite3_column_blob(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0) return null;
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(ptr))[0..len],
        ) catch Error.OutOfMemory;
    }

    /// All tag names, alphabetical. Caller owns the slice and each name
    pub fn getTagNames(self: *Db) Error![][]u8 {
        const stmt = try self.prepare("SELECT name FROM tags ORDER BY name;");
        defer _ = c.sqlite3_finalize(stmt);

        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |n| self.allocator.free(n);
            out.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.StepFailed;

            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const name = self.allocator.dupe(
                u8,
                @as([*]const u8, @ptrCast(text_ptr))[0..text_len],
            ) catch return Error.OutOfMemory;
            out.append(self.allocator, name) catch return Error.OutOfMemory;
        }

        return out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
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

/// Free one `Entry`'s owned strings. Which ones exist depends on `kind`.
pub fn freeEntry(allocator: std.mem.Allocator, e: Entry) void {
    if (e.content) |ct| allocator.free(ct);
    if (e.image) |im| {
        allocator.free(im.path);
        allocator.free(im.mime);
    }
}

/// Free an `Entry` slice — each entry's owned strings plus the slice itself.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(allocator, e);
    allocator.free(entries);
}

/// Free a tag-name slice — each name plus the slice.
pub fn freeTagNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}
