# zclip

Persistent clipboard history daemon for macOS. Zig + libsqlite3 + NSPasteboard.

Design doc: `zclip-handoff.md` (motivation, schema rationale, post-POC roadmap).
This file: just what a future Claude session needs to be productive immediately.

## Commands

```
zig build                 # produces zig-out/bin/zclip
zig build run -- daemon   # run daemon via build system
./zig-out/bin/zclip daemon
./zig-out/bin/zclip search <keyword>
./zig-out/bin/zclip use <id>
```

DB lives at `~/.local/share/zclip/history.db`. Pidfile at `~/.local/share/zclip/zclip.pid`.

## Layout

```
src/main.zig       CLI router, search/use commands, ISO timestamp formatting
src/clipboard.zig  NSPasteboard wrapper (hand-rolled objc_msgSend FFI)
src/db.zig         SQLite wrapper (@cImport sqlite3.h)
src/daemon.zig     Poll loop, pidfile flock, signal handlers, mkdir -p
build.zig          Links sqlite3, AppKit, Foundation; link_libc
build.zig.zon      minimum_zig_version = "0.16.0"
.zigversion        0.16.0
```

## Zig version

Pinned to **0.16.0** in both `build.zig.zon` and `.zigversion`. Originally aimed at 0.15.2 but 0.16 introduced incompatible APIs (`pub fn main(init: std.process.Init)`, `std.Io.File.Writer`). If you bump or downgrade Zig, expect rework in `main.zig` first.

## Critical gotchas

**0.16 Io refactor stripped most syscalls from std.** These were removed and replaced via libc extern fns:
- `std.posix.open`, `std.posix.flock`, `std.posix.ftruncate`, `std.posix.pwrite`, `std.posix.close`, `std.posix.getenv`
- `std.fs.cwd`, `std.fs.makeDirAbsolute`, `Dir.makePath`
- `std.Thread.sleep`
- `std.time.timestamp`
- `std.posix.sigaction` (Darwin variant has typed-enum handler signature; use libc `signal()` instead)

When adding code, prefer libc extern fn over searching std for the equivalent. The std API is mid-flux.

**SQLite destructor sentinels.** `c.SQLITE_TRANSIENT` and `c.SQLITE_STATIC` are macro-expanded as `((destructor_type)-1)` and `((destructor_type)0)`. translate-c emits these as `@ptrFromInt(...)` which fails Zig's fn-pointer alignment check at comptime. Workaround in `db.zig`: declare `const SQLITE_STATIC: c.sqlite3_destructor_type = null` and pass null. Safe because all bound buffers outlive `sqlite3_finalize` in our usage.

**NSPasteboard FFI is hand-rolled.** `@cImport(<objc/runtime.h>)` is fragile through translate-c. `clipboard.zig` declares `objc_getClass`, `sel_registerName`, `objc_msgSend` directly as extern fns and casts `objc_msgSend` per call site with `msg(SendIdToId)` helpers. Add new selectors by extending the `Send*` typedefs.

**Origin marker prevents daemon feedback loop.** `zclip use` writes content tagged with custom type `dev.zclip.origin`. Daemon's poll checks `pb.hasOrigin()` and skips. Don't strip this from `writeStringAsOrigin`.

**Concealed-type filter is the only password-leak defense.** Daemon skips entries where pasteboard has `org.nspasteboard.ConcealedType` (1Password/Bitwarden/Keychain). If you add new write paths or remove the check, sensitive content lands in the DB plaintext.

**WAL mode + single-instance.** DB opened with `PRAGMA journal_mode=WAL` so CLI reads don't block daemon writes. Daemon enforces single instance via `flock(LOCK_EX | LOCK_NB)` on the pidfile — `EWOULDBLOCK` (errno 35 on Darwin) maps to `error.AlreadyRunning`.

## Schema

```sql
entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
index on hash, index on copied_at
```

Hash = raw SHA256 (32 bytes). `upsertByHash` updates `copied_at` on match, inserts on miss. Returns `true` for insert, `false` for bump — daemon uses this to log differently.

## Things deliberately not done (post-POC)

- launchd `.plist` for auto-start at login
- FTS5 (currently `LIKE '%keyword%'`)
- Non-text clipboard (images, files, RTF)
- Encryption at rest
- Eviction / retention limits
- Relative timestamps (currently ISO `YYYY-MM-DD HH:MM`)
- `zclip status`, `zclip pin`, `zclip create` named snippets

When adding any of these, update `zclip-handoff.md` extensions table and note schema migrations explicitly — there's no migration runner yet (schema lives inline in `db.zig`).
