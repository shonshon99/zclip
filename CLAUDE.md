# zclip

Persistent clipboard history daemon for macOS. Zig + libsqlite3 + NSPasteboard.

This file: what a future Claude session needs to be productive immediately —
over-arching project facts grounded in the source. Forward-looking plans live in
the issue tracker, not here.

## What zclip is

zclip is a permanent clipboard store. The daemon polls NSPasteboard and inserts
every copy into a single SQLite file the user owns, retaining it indefinitely (no
auto-eviction). Duplicate content is deduped by hash and its `copied_at` bumped.
Entries carry user-assigned tags. The CLI (`daemon`, `search`, `use`, `tag`)
exposes the archive; `use` writes an entry back to the pasteboard, so zclip can
back an external picker that searches the archive and pastes a chosen entry.

What zclip provides over a stock clipboard manager:

- Permanent retention (years, not weeks).
- User tags on any entry.
- A single local SQLite file the user fully owns, queryable directly.

## Commands

```
zig build                 # produces zig-out/bin/zclip
zig build run -- daemon   # run daemon via build system
./zig-out/bin/zclip daemon
./zig-out/bin/zclip search <keyword>   # LIKE keyword match over content
./zig-out/bin/zclip use <id>           # rewrite entry to the pasteboard
./zig-out/bin/zclip tag <id> <tag>     # attach one tag to an entry (lowercased)
```

DB lives at `~/.local/share/zclip/history.db`. Pidfile at `~/.local/share/zclip/zclip.pid`.

### Functional tests

```
./tests/run_all.sh          # all suites (tag, search, use, daemon)
./tests/run_all.sh --safe   # skip clipboard-touching suites (use, daemon) — for CI
```

Each suite sources `tests/lib.sh`, which sets `HOME` to a fresh `mktemp -d` so the
real `~/.local/share/zclip` is never touched; `trap cleanup EXIT` removes that temp
HOME. One throwaway HOME per suite.

## Layout

```
src/main.zig       CLI router, search/use/tag commands, ISO timestamp formatting
src/clipboard.zig  NSPasteboard wrapper via mitchellh/zig-objc
src/db.zig         SQLite wrapper (translate-c on src/sqlite_c.h)
src/daemon.zig     Poll loop, pidfile lock (Io.Dir.createFile), signal handlers
src/sqlite_c.h     Shim header — `#include <sqlite3.h>` for build-system translate-c
build.zig          translate-c sqlite3, link AppKit/Foundation; link_libc
build.zig.zon      minimum_zig_version = "0.16.0"
.zigversion        0.16.0
tests/run_all.sh   Runs every suite; --safe skips clipboard-touching ones
tests/lib.sh       Shared: isolated temp HOME, schema bootstrap, assert helpers
tests/*_test.sh    Per-command suites: tag, search, use, daemon
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

**Concealed-type filter is the only password-leak defense.** Daemon skips entries where pasteboard has `org.nspasteboard.ConcealedType` (1Password/Bitwarden/Keychain). If you add new write paths or remove the check, sensitive content lands in the DB plaintext. This is defense-in-depth only — apps that don't set the type (Slack, browsers pasting from docs) bypass it.

**WAL mode + single-instance.** DB opened with `PRAGMA journal_mode=WAL` so CLI reads don't block daemon writes. Daemon enforces single instance by passing `.lock = .exclusive, .lock_nonblocking = true` to `Io.Dir.createFile` on the pidfile; lock acquisition is atomic with the open(2). Contention surfaces as `error.WouldBlock`. `truncate = false` preserves the previous PID until `writePid` overwrites via `setLength(io, 0)` + `writePositionalAll`.

## Schema

```sql
-- v1
entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
index on hash, index on copied_at
-- v2 (tags)
tags(id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
entry_tags(entry_id → entries.id, tag_id → tags.id, PK(entry_id, tag_id))
  both FKs ON DELETE CASCADE; index on tag_id
```

Hash = raw SHA256 (32 bytes). `upsertByHash` updates `copied_at` on match, inserts on miss. Returns `true` for insert, `false` for bump — daemon uses this to log differently.

Schema is managed by the `MIGRATIONS` runner in `db.zig` (PRAGMA `user_version`), run from `Db.open` (so CLI and daemon both migrate; idempotent). To change schema: **append** a new SQL string to `MIGRATIONS` — never edit/reorder/delete an existing entry (each has already run and bumped `user_version` on live DBs). Target version = `MIGRATIONS.len`. Each step runs in its own `BEGIN IMMEDIATE` transaction.

**`PRAGMA foreign_keys=ON` is load-bearing for `entry_tags`.** It's per-connection and OFF by default, so `Db.open` runs it *before* `migrate()` (the pragma is a no-op inside the migration runner's `BEGIN IMMEDIATE`). Without it, deleting an entry orphans its `entry_tags` rows instead of cascading. Don't move or drop this.

## Comment style

Concise WHY-comments across all files. Explain non-obvious reasoning: version-pinned API choices, FFI/C ABI constraints, gotchas, security-load-bearing checks, ownership/lifetime contracts. **Don't** explain basic Zig syntax (`try`, `catch`, `defer`, `errdefer`, captures, `anytype`, optional unwrap, slice equality, error unions, format specifiers, `[*c]`/`[*:0]` pointer kinds) — author has internalized those.

## Known tradeoffs

- **DB growth is unbounded by design.** Permanent retention is the value proposition. Pruning via raw SQL is always available; auto-eviction intentionally not implemented.
- **Plaintext at rest.** Concealed-type filter catches password-manager copies, but anything not flagged (API keys pasted from docs, tokens in terminal output) ends up readable on disk. FileVault covers the stolen-laptop threat; same-account access still sees plaintext.
- **Polling latency.** 1-second poll loses copies made and overwritten inside the gap. macOS exposes no public pasteboard-change notification — polling is the standard approach across clipboard tools.

## Design principles

- Local-first. Single SQLite file the user fully owns.
- Daemon stays minimal: poll and insert. Heavy work runs in CLI subcommands triggered out-of-band.
- WAL mode — CLI reads never block daemon writes.
- `dev.zclip.origin` marker and `ConcealedType` filter are both load-bearing — don't strip (see gotchas).
- Schema changes go through the `MIGRATIONS` runner — append-only, never edit a shipped entry.
