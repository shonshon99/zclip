# zclip

Persistent clipboard history daemon for macOS. Zig + libsqlite3 + NSPasteboard.

This file: what a future Claude session needs to be productive immediately.
Forward-looking roadmap + Raycast-complement strategy: `ROADMAP.md`.

## Workflow context — READ FIRST

Primary clipboard UX = **Raycast** (history picker + named snippets with dynamic placeholders). Raycast retains ~1 month; snippets are static, content-only.

**zclip's role: long-term back-of-house archive.** Not a picker. Specializes in what Raycast structurally cannot offer:

- Permanent retention (years, not weeks)
- Rich metadata captured at copy time (source app, URL provenance, project/cwd) — planned
- Programmatic CLI access (pipe, query, export)
- Insights derivable only from long-tail history
- Safety guarantees that scale with retention (encryption at rest, secret audits)

Do NOT rebuild Raycast's picker UI. Do NOT compete on snippet expansion. Complement.

Build order and deferred features live in `ROADMAP.md`. Update that file when scope shifts.

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
src/clipboard.zig  NSPasteboard wrapper via mitchellh/zig-objc
src/db.zig         SQLite wrapper (translate-c on src/sqlite_c.h)
src/daemon.zig     Poll loop, pidfile lock (Io.Dir.createFile), signal handlers
src/sqlite_c.h     Shim header — `#include <sqlite3.h>` for build-system translate-c
build.zig          translate-c sqlite3, link AppKit/Foundation; link_libc
build.zig.zon      minimum_zig_version = "0.16.0"
.zigversion        0.16.0
```

## Zig version

Pinned to **0.16.0** in both `build.zig.zon` and `.zigversion`. The codebase uses 0.16-idiomatic APIs throughout: `pub fn main(init: std.process.Init)`, `std.Io.File.Writer`, `std.Io.Dir.createFile` with advisory lock options, `std.Io.sleep`, `std.Io.Timestamp.now`, `init.minimal.environ.getPosix`. If you bump or downgrade Zig, expect rework in `main.zig` and `daemon.zig` first.

Zig is pre-1.0 and breaks meaningful APIs every minor release. Treat any LLM-generated Zig as a draft — compile with the pinned version immediately, cross-check stdlib symbols against the 0.16 release notes, and trust the compiler error over the LLM.

## Critical gotchas

**Signal handling stays on libc.** `daemon.zig` declares `extern "c" fn signal` and uses raw `SIGINT`/`SIGTERM` constants because `std.posix.sigaction` on Darwin requires a typed-enum handler signature that's awkward to satisfy, and 0.16's Io interface doesn't expose signal handlers. Don't try to "modernize" this without checking the Darwin sigaction prototype first.

**SQLite C bindings via build-system translate-c, not `@cImport`.** `build.zig` runs `b.addTranslateC` on `src/sqlite_c.h` and exposes the result as `@import("sqlite_c")`. `@cImport` in source files is deprecated in 0.16. Add new SQLite symbols by editing the shim header, not by re-introducing `@cImport`.

**SQLite destructor sentinels.** `c.SQLITE_TRANSIENT` and `c.SQLITE_STATIC` are macro-expanded as `((destructor_type)-1)` and `((destructor_type)0)`. translate-c emits these as `@ptrFromInt(...)` which fails Zig's fn-pointer alignment check at comptime. Workaround in `db.zig`: declare `const SQLITE_STATIC: c.sqlite3_destructor_type = null` and pass null. Safe because all bound buffers outlive `sqlite3_finalize` in our usage.

**NSPasteboard goes through `mitchellh/zig-objc`.** `clipboard.zig` calls `objc.getClass("...")` and `obj.msgSend(Return, "selector:", .{args})`. The lib synthesizes the `objc_msgSend` cast per call site from the Return type + args tuple — no per-selector boilerplate needed. Earlier revisions hand-rolled the FFI (extern `objc_msgSend` + `Send*` fn-pointer typedefs + a `msg(comptime T)` ptrCast helper); git history has the reference if you ever need to inline it again.

**Daemon poll loop wraps each tick in an `objc.AutoreleasePool`.** Methods like `[NSString stringWithUTF8String:]`, `[pb types]`, and `[pb stringForType:]` return autoreleased Obj-C objects. With no pool on the thread they accumulate in a process-global pool that never drains. Pool push/pop per iteration bounds growth. `readString` copies bytes into the caller's allocator *before* the pool drains — don't pass any raw NSString-owned pointer past the `defer pool.deinit()`.

**Origin marker prevents daemon feedback loop.** `zclip use` writes content tagged with custom type `dev.zclip.origin`. Daemon's poll checks `pb.hasOrigin()` and skips. Don't strip this from `writeStringAsOrigin`.

**Concealed-type filter is the only password-leak defense.** Daemon skips entries where pasteboard has `org.nspasteboard.ConcealedType` (1Password/Bitwarden/Keychain). If you add new write paths or remove the check, sensitive content lands in the DB plaintext. This is defense-in-depth only — apps that don't set the type (Slack, browsers pasting from docs) bypass it. Long-term mitigation is encryption at rest + retroactive secret audit (`ROADMAP.md` step 6).

**WAL mode + single-instance.** DB opened with `PRAGMA journal_mode=WAL` so CLI reads don't block daemon writes. Daemon enforces single instance by passing `.lock = .exclusive, .lock_nonblocking = true` to `Io.Dir.createFile` on the pidfile; lock acquisition is atomic with the open(2). Contention surfaces as `error.WouldBlock`. `truncate = false` preserves the previous PID until `writePid` overwrites via `setLength(io, 0)` + `writePositionalAll`.

## Schema

```sql
entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
index on hash, index on copied_at
```

Hash = raw SHA256 (32 bytes). `upsertByHash` updates `copied_at` on match, inserts on miss. Returns `true` for insert, `false` for bump — daemon uses this to log differently.

Schema is managed by the `MIGRATIONS` runner in `db.zig` (PRAGMA `user_version`), run from `Db.open` (so CLI and daemon both migrate; idempotent). To change schema: **append** a new SQL string to `MIGRATIONS` — never edit/reorder/delete an existing entry (each has already run and bumped `user_version` on live DBs). Target version = `MIGRATIONS.len`. Each step runs in its own `BEGIN IMMEDIATE` transaction. `ROADMAP.md` step 1 (source-app + URL provenance) is the first consumer.

## Comment style

Concise WHY-comments across all files. Explain non-obvious reasoning: version-pinned API choices, FFI/C ABI constraints, gotchas, security-load-bearing checks, ownership/lifetime contracts. **Don't** explain basic Zig syntax (`try`, `catch`, `defer`, `errdefer`, captures, `anytype`, optional unwrap, slice equality, error unions, format specifiers, `[*c]`/`[*:0]` pointer kinds) — author has internalized those. All source files trimmed 2026-05-28.

## Known tradeoffs

- **DB growth is unbounded by design.** Permanent retention is the value proposition vs. Raycast. Pruning via raw SQL is always available; auto-eviction intentionally not implemented.
- **Plaintext at rest.** Concealed-type filter catches password-manager copies, but anything not flagged (API keys pasted from docs, tokens in terminal output) ends up readable on disk. FileVault covers stolen-laptop threat; same-account access still sees plaintext. Mitigation tracked in `ROADMAP.md` step 6.
- **Polling latency.** 1-second poll loses copies made and overwritten inside the gap. macOS exposes no public pasteboard-change notification — polling is the standard approach across clipboard tools.
