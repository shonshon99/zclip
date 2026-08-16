const std = @import("std");

pub const c = @import("sqlite_c");

// translate-c emits SQLITE_STATIC/TRANSIENT as @ptrFromInt, which fails Zig's
// fn-pointer alignment check. null means the same thing: every bind site here
// keeps its buffer alive past sqlite3_finalize.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// MIGRATIONS[i] upgrades the DB from `user_version` i to i+1; target is
// MIGRATIONS.len.
const MIGRATIONS = [_][]const u8{
    // v1
    //
    // The big payload column goes LAST in both tables. Columns are stored in
    // declaration order and anything past ~4KB spills to overflow pages, so a
    // small column declared after a 200KB thumbnail costs a chain walk to
    // reach. Metadata first means it reads straight off the leaf page.
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
    \\  uti          TEXT NOT NULL,
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
/// Pixels live in two places: the untouched original at `path` on disk (what
/// `zclip use` restores), and only the thumbnail as a BLOB, so history.db stays
/// small enough for instant CLI reads.
pub const ImageMeta = struct {
    path: []u8,
    /// Pasteboard type the original was captured under. Handed straight back to
    /// `setData:forType:`, so a value written by a newer build still
    /// round-trips. Sentinel-terminated to cross to NSString without a re-copy.
    uti: [:0]u8,
    /// Dimensions of the original, not the thumbnail.
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
/// regardless of the original's `uti`.
pub const NewImage = struct {
    path: []const u8,
    uti: []const u8,
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
        // Every step below is fallible; without this the handle escapes.
        errdefer _ = c.sqlite3_close(db.handle);

        // WAL so CLI reads don't serialise behind daemon writes.
        try db.exec("PRAGMA journal_mode=WAL;");
        // Tiny crash-recovery risk for big throughput. Fine for clipboard history.
        try db.exec("PRAGMA synchronous=NORMAL;");
        // Per-connection and OFF by default; without it, deleting an entry
        // orphans its entry_tags rows instead of cascading. Must precede
        // migrate(): the pragma is a no-op inside its BEGIN IMMEDIATE.
        try db.exec("PRAGMA foreign_keys=ON;");

        // Idempotent, so every CLI open is safe even before the daemon runs.
        try db.migrate();
        return db;
    }

    fn userVersion(self: *Db) Error!usize {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.StepFailed;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    /// Apply every migration above the DB's `user_version`, one transaction
    /// each. No-op when already current.
    fn migrate(self: *Db) Error!void {
        // Unlocked pre-check: the common case (already current, every CLI open)
        // skips the write lock entirely.
        if (try self.userVersion() >= MIGRATIONS.len) return;

        // The version is re-read *inside* each transaction because the
        // pre-check above is unlocked. Reading under the write lock makes
        // check-then-apply atomic, so the loser of the BEGIN IMMEDIATE race
        // sees the bumped version instead of re-running a step.
        while (true) {
            // IMMEDIATE takes the write lock up front; ROLLBACK keeps the step
            // atomic on failure.
            try self.exec("BEGIN IMMEDIATE;");
            errdefer self.exec("ROLLBACK;") catch {};

            const v = try self.userVersion();
            if (v >= MIGRATIONS.len) {
                // Nothing left, or another process did it while we waited.
                try self.exec("COMMIT;");
                break;
            }

            try self.exec(MIGRATIONS[v]);

            // user_version can't be bound as a parameter. usize, no injection risk.
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

    /// Existing entry id for `hash`, or null. Hash is the dedup key: a 32-byte
    /// indexed compare beats scanning a huge TEXT column, and it's the only
    /// probe that works for images (whose bytes aren't in the DB at all).
    ///
    /// Callers `touch` on a hit and insert on a miss. Not one transaction —
    /// safe only because the daemon is the sole writer (pidfile lock).
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
    /// Transactional, unlike `insertText`: an entries row without its images
    /// row satisfies the schema but is a broken entry forever — nothing
    /// repairs it.
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

        const ins_img = try self.prepare(
            "INSERT INTO images (entry_id, path, uti, width, height, byte_len, thumb)" ++
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
            img.uti.ptr,
            @intCast(img.uti.len),
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

    /// Bump `copied_at` so the entry resurfaces as most recent.
    pub fn touch(self: *Db, id: i64, now: i64) Error!void {
        const stmt = try self.prepare("UPDATE entries SET copied_at = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, now) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(stmt, 2, id) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.StepFailed;
    }

    // LEFT JOIN, not two queries: one ordered pass over entries. Reordering
    // these columns silently corrupts every read — `rowToEntry` indexes them
    // positionally.
    const entry_select =
        "SELECT e.id, e.kind, e.content, e.copied_at," ++
        " i.path, i.uti, i.width, i.height, i.byte_len" ++
        " FROM entries e LEFT JOIN images i ON i.entry_id = e.id";

    /// All entries, newest first. A null `limit` binds -1, which SQLite reads
    /// as unbounded, so one statement serves both the capped and uncapped call.
    /// `e.id DESC` breaks `copied_at` ties so a limit returns stable rows; it's
    /// free, since `entries_copied_at_idx` trails with the rowid anyway.
    pub fn getEntries(self: *Db, limit: ?u32) Error![]Entry {
        const stmt = try self.prepare(
            entry_select ++
                " ORDER BY e.copied_at DESC, e.id DESC" ++
                " LIMIT ?;",
        );
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(
            stmt,
            1,
            limit orelse -1,
        ) != c.SQLITE_OK) return Error.BindFailed;

        return self.collectEntries(stmt);
    }

    /// Entries carrying `tag`, newest first. Same null-limit rule as
    /// `getEntries`, but no early exit: the tag drives the scan, so every
    /// tagged row is fetched and sorted first and the limit only bounds the
    /// sorter. Match is case-insensitive (`tags.name` is COLLATE NOCASE).
    pub fn getEntriesByTag(self: *Db, tag: []const u8, limit: ?u32) Error![]Entry {
        const stmt = try self.prepare(
            entry_select ++
                " JOIN entry_tags et ON et.entry_id = e.id" ++
                " JOIN tags t ON t.id = et.tag_id" ++
                " WHERE t.name = ? ORDER BY e.copied_at DESC, e.id DESC" ++
                " LIMIT ?;",
        );
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(
            stmt,
            1,
            tag.ptr,
            @intCast(tag.len),
            SQLITE_STATIC,
        ) != c.SQLITE_OK) return Error.BindFailed;
        if (c.sqlite3_bind_int64(
            stmt,
            2,
            limit orelse -1,
        ) != c.SQLITE_OK) return Error.BindFailed;

        return self.collectEntries(stmt);
    }

    // Drains a prepared `entry_select` into an owned slice. Caller finalizes
    // the stmt.
    fn collectEntries(self: *Db, stmt: *c.sqlite3_stmt) Error![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        // errdefer, not defer: on success the caller owns `out`.
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
        // Unknown kind means a newer zclip wrote the DB — fail rather than
        // mis-render the row.
        const kind = std.meta.stringToEnum(Kind, kind_text) orelse return Error.StepFailed;

        const content = try self.dupeText(stmt, 2);
        errdefer if (content) |ct| self.allocator.free(ct);

        // Columns 4-8 are NULL for text rows (LEFT JOIN found no images row).
        const image: ?ImageMeta = if (kind == .image) blk: {
            const path = (try self.dupeText(stmt, 4)) orelse return Error.StepFailed;
            errdefer self.allocator.free(path);
            const uti = (try self.dupeTextZ(stmt, 5)) orelse return Error.StepFailed;
            break :blk .{
                .path = path,
                .uti = uti,
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

    // Copies a TEXT column out, SQL NULL → Zig null. Must dupe: sqlite's
    // pointer dies at the next step/finalize.
    fn dupeText(self: *Db, stmt: *c.sqlite3_stmt, col: c_int) Error!?[]u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(ptr))[0..len],
        ) catch Error.OutOfMemory;
    }

    // As `dupeText`, but re-terminates for C APIs wanting [*:0]const u8:
    // `sqlite3_column_bytes` excludes the NUL, so a plain dupe wouldn't have one.
    fn dupeTextZ(self: *Db, stmt: *c.sqlite3_stmt, col: c_int) Error!?[:0]u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return self.allocator.dupeSentinel(
            u8,
            @as([*]const u8, @ptrCast(ptr))[0..len],
            0,
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

    /// Thumbnail PNG bytes for an image entry. Caller owns the slice. Null
    /// means exactly one thing: `id` has no `images` row.
    pub fn getThumb(self: *Db, id: i64) Error!?[]u8 {
        const stmt = try self.prepare("SELECT thumb FROM images WHERE entry_id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return Error.BindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.StepFailed;

        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        // sqlite3_column_blob answers NULL for a zero-length blob, so the cast
        // below is only valid when there are bytes. Return an empty slice, not
        // null — the row exists, and conflating the two made `zclip thumb`
        // report the entry missing.
        if (len == 0) return self.allocator.alloc(u8, 0) catch Error.OutOfMemory;

        const ptr = c.sqlite3_column_blob(stmt, 0);
        return self.allocator.dupe(
            u8,
            @as([*]const u8, @ptrCast(ptr))[0..len],
        ) catch Error.OutOfMemory;
    }

    /// All tag names, alphabetical. Caller owns the slice and each name.
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

pub fn freeEntry(allocator: std.mem.Allocator, e: Entry) void {
    if (e.content) |ct| allocator.free(ct);
    if (e.image) |im| {
        allocator.free(im.path);
        allocator.free(im.uti);
    }
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(allocator, e);
    allocator.free(entries);
}

pub fn freeTagNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}
