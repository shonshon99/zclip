# zclip — contributor notes

Persistent clipboard history daemon for macOS. Zig + libsqlite3 + NSPasteboard.

**User-facing docs (what zclip is, install, every command, JSON schema, exit
codes) live in [README.md](README.md).** This file is the opposite audience:
invariants, FFI/ABI gotchas, and version-pinned choices a future session needs
before touching the code. Forward-looking plans live in the issue tracker.

## Layout

```
src/main.zig       CLI router, query/use/thumb/tag/untag commands, JSON formatting
src/clipboard.zig  NSPasteboard wrapper via mitchellh/zig-objc
src/db.zig         SQLite wrapper (translate-c on src/sqlite_c.h)
src/daemon.zig     Poll loop, pidfile lock (Io.Dir.createFile), signal handlers
src/image.zig      ImageIO thumbnailing — hand-declared C externs, NOT translate-c
src/sqlite_c.h     Shim header — `#include <sqlite3.h>` for build-system translate-c
build.zig          translate-c sqlite3, link AppKit/Foundation/ImageIO/CG/CF; link_libc
build.zig.zon      minimum_zig_version = "0.16.0"
.zigversion        0.16.0
tests/run_all.sh   Runs every suite; --safe skips clipboard-touching ones
tests/lib.sh       Shared: isolated temp HOME, schema bootstrap, assert helpers
tests/fixtures/    Committed 1024x768 PNG driving the image suite
tests/*_test.sh    Per-command suites: tag, untag, query, tags, use, daemon, image
tools/pbdump.swift Diagnostic: dumps the live pasteboard's flavours + metadata
raycast/src/zclip.ts    Extension↔CLI boundary: execs the binary, parses its JSON
raycast/src/search.tsx  "Search Clipboard" — list/detail panes, tag filter, tagging
raycast/src/run-daemon.tsx  no-view command that starts the daemon
```

The Raycast extension is the reference consumer of the CLI's contract — it is
the reason `query` emits JSON, `thumb` prints a bare path, and `use` exists at
all. It is a separate npm project (`cd raycast && npm install`); `npx ray build`
and `npx ray lint` are the checks, and neither runs from `zig build` or
`tests/run_all.sh`. Changing a command's output shape means changing `zclip.ts`
in the same commit.

Each test suite sources `tests/lib.sh`, which sets `HOME` to a fresh `mktemp -d`
so the real `~/.local/share/zclip` is never touched; `trap cleanup EXIT` removes
that temp HOME. One throwaway HOME per suite. (How to run: README → Tests.)

`tools/pbdump.swift` answers "what did that app *actually* publish?" — run it
after copying from a given app to see every UTI on the pasteboard with byte
counts and image dimensions. That's the evidence behind `image_types`' probe
order and the text-before-image rule below. Not part of the build or the test
suite; Swift because it needs no FFI bindings to maintain. Output is
content-free by default so it's safe to paste into an issue; `--text` opts into
previewing textual flavours.

## Zig version

Pinned to **0.16.0** in both `build.zig.zon` and `.zigversion`. The codebase uses 0.16-idiomatic APIs throughout: `pub fn main(init: std.process.Init)`, `std.Io.File.Writer`, `std.Io.Dir.createFile` with advisory lock options, `std.Io.sleep`, `std.Io.Timestamp.now`, `init.minimal.environ.getPosix`. If you bump or downgrade Zig, expect rework in `main.zig` and `daemon.zig` first.

Zig is pre-1.0 and breaks meaningful APIs every minor release. Treat any LLM-generated Zig as a draft — compile with the pinned version immediately, cross-check stdlib symbols against the 0.16 release notes, and trust the compiler error over the LLM.

## Critical gotchas

**Signal handling stays on libc.** `daemon.zig` declares `extern "c" fn signal` and uses raw `SIGINT`/`SIGTERM` constants because `std.posix.sigaction` on Darwin requires a typed-enum handler signature that's awkward to satisfy, and 0.16's Io interface doesn't expose signal handlers. Don't try to "modernize" this without checking the Darwin sigaction prototype first.

**SQLite C bindings via build-system translate-c, not `@cImport`.** `build.zig` runs `b.addTranslateC` on `src/sqlite_c.h` and exposes the result as `@import("sqlite_c")`. `@cImport` in source files is deprecated in 0.16. Add new SQLite symbols by editing the shim header, not by re-introducing `@cImport`.

**SQLite destructor sentinels.** `c.SQLITE_TRANSIENT` and `c.SQLITE_STATIC` are macro-expanded as `((destructor_type)-1)` and `((destructor_type)0)`. translate-c emits these as `@ptrFromInt(...)` which fails Zig's fn-pointer alignment check at comptime. Workaround in `db.zig`: declare `const SQLITE_STATIC: c.sqlite3_destructor_type = null` and pass null. Safe because all bound buffers outlive `sqlite3_finalize` in our usage.

**ImageIO bindings are hand-written externs — translate-c cannot parse the Apple SDK headers.** `src/image.zig` declares ~20 CF/CG/ImageIO symbols with `extern "c"` instead of following the `sqlite_c.h` + `addTranslateC` convention. Two blockers, in order: CGColorSpace.h writes `CGFloat whitePoint[CG_NONNULL_ARRAY 3]` and clang hard-errors on a nullability specifier inside an array bound (fixable by `#undef`ing the nullability macros in a shim); then CGPath.h declares `typedef void (^CGPathApplyBlock)(...)` unguarded, and blocks need `-fblocks`, which `std.Build.Step.TranslateC` has no API to pass — it exposes include paths and `-D` macros, nothing else. Narrowing the includes doesn't dodge it either; CGPath.h arrives transitively via CGImage.h. Don't "restore consistency" by re-adding a shim header without re-checking those two facts.

**CF ownership rules apply in `image.zig`.** "Create"/"Copy" in a CF function name means we own the result and must `CFRelease` it; "Get" means we borrow. `CFDataCreateWithBytesNoCopy` + `kCFAllocatorNull` reads straight out of the Zig slice — every CF object derived from it must die before that slice's owner returns. The options dict passes null callbacks, so it does *not* retain its values; the `CFNumber` must outlive it (defer order handles this).

**Text beats image when the pasteboard offers both.** Rich-text copies publish a TIFF rendering alongside the plain text. The daemon checks `readString` first and only falls through to `imageType()` when there's no non-empty string. Flipping that order turns every copied paragraph into a screenshot.

**`images.path` files are not covered by any cascade.** `entry_tags` cascades on entry delete; the file at `images.path` does not. Any future delete/prune path must unlink the file itself, or `images/` grows forever with orphans.

**The `cache/<id>.png` layout is encoded in two places.** `runThumb` in `main.zig` builds it from `storageDir` + rowid; `cachedThumbPath` in `raycast/src/zclip.ts` reconstructs the same string from `homedir()`. The extension does that so an already-materialised thumbnail is discoverable with one `existsSync` instead of a subprocess — that's what lets the list paint row icons in the same frame as the rows, rather than popping them in as `zclip thumb` results arrive. Nothing enforces the two agree, and divergence fails *soft*: every stat misses, the extension silently falls back to `zclip thumb` per row, and the only symptom is the pop-in returning. If you change `storageDir` or the filename convention, grep the extension. Emitting a `thumb_path` field from `query` would collapse this back to one definition, at the cost of a wider JSON contract.

**Cache filenames are keyed by rowid, which SQLite recycles.** Both `runThumb`'s comment and the extension's stat-based lookup assume `cache/<id>.png` belongs to entry `<id>`. Without `AUTOINCREMENT`, a delete frees that rowid for reuse, so a future prune path must unlink the cache file too — otherwise the next entry to land on the id serves the previous one's thumbnail. Same hazard as `images.path` above, one more place to fix.

**NSPasteboard goes through `mitchellh/zig-objc`.** `clipboard.zig` calls `objc.getClass("...")` and `obj.msgSend(Return, "selector:", .{args})`. The lib synthesizes the `objc_msgSend` cast per call site from the Return type + args tuple — no per-selector boilerplate needed. Earlier revisions hand-rolled the FFI (extern `objc_msgSend` + `Send*` fn-pointer typedefs + a `msg(comptime T)` ptrCast helper); git history has the reference if you ever need to inline it again.

**Daemon poll loop wraps each tick in an `objc.AutoreleasePool`.** Methods like `[NSString stringWithUTF8String:]`, `[pb types]`, and `[pb stringForType:]` return autoreleased Obj-C objects. With no pool on the thread they accumulate in a process-global pool that never drains. Pool push/pop per iteration bounds growth. `readString` copies bytes into the caller's allocator *before* the pool drains — don't pass any raw NSString-owned pointer past the `defer pool.deinit()`.

**Origin marker prevents daemon feedback loop.** `zclip use` writes content tagged with custom type `dev.zclip.origin`. Daemon's poll checks `pb.hasOrigin()` and skips. Don't strip this from `writeStringAsOrigin`.

**Concealed-type filter is the only password-leak defense.** Daemon skips entries where pasteboard has `org.nspasteboard.ConcealedType` (1Password/Bitwarden/Keychain). If you add new write paths or remove the check, sensitive content lands in the DB plaintext. This is defense-in-depth only — apps that don't set the type (Slack, browsers pasting from docs) bypass it.

**WAL mode + single-instance.** DB opened with `PRAGMA journal_mode=WAL` so CLI reads don't block daemon writes. Daemon enforces single instance by passing `.lock = .exclusive, .lock_nonblocking = true` to `Io.Dir.createFile` on the pidfile; lock acquisition is atomic with the open(2). Contention surfaces as `error.WouldBlock`. `truncate = false` preserves the previous PID until `writePid` overwrites via `setLength(io, 0)` + `writePositionalAll`.

## Raycast extension gotchas

Thumbnail loading in `search.tsx` looks over-engineered and is not. Three
distinct hazards shape it — the first one shipped and had to be chased down, the
other two were sidestepped during the same work. All three are easy to
reintroduce by "simplifying".

**The thumbnail prefetch must never cancel in-flight work.** A thumbnail is
immutable and keyed by rowid, so a result arriving after a re-render, a tag
switch, or an unmount is still correct — and React 18 makes `setState` on an
unmounted component a no-op, so there is nothing to leak. The original version
cancelled on effect cleanup: any double-invoke (StrictMode on mount, or a tag
switch mid-prefetch) discarded the running batch while its ids stayed marked in
the `requested` ref, so nothing re-queued them and exactly `POOL_SIZE` rows kept
the placeholder icon permanently. The symptom is deceptive: *some* images load
and which ones varies per launch, which reads like a flaky CLI rather than a
React lifecycle bug. (It isn't the CLI — 200 concurrent `zclip thumb` calls,
cold cache and warm, fail zero times.)

**`requested` tracks requested, not in-flight.** Ids stay marked after they
resolve. That is what lets the prefetch effect depend on `entries` alone; adding
`thumbs` to the dep array re-enters on every resolution and spawns a fresh pool
each time.

**Seed the thumb map in the same tick as `setEntries`, and compute it outside
the updater.** React batches the two `setState`s into one render, so the first
frame with rows already has its icons — split across ticks and the pop-in comes
straight back. `seedCachedThumbs` mutates the `requested` ref, so calling it
inline inside the `setThumbs` updater would make the updater impure; StrictMode
double-invokes updaters, the second call finds every id already marked, returns
`{}`, and silently drops the whole seed.

**`zclip thumb` still runs, just not on the warm path.** It is the only thing
that can turn the `images.thumb` BLOB into a file, so a never-before-seen image
costs one subprocess, once, ever. `query` and `tags` remain one exec each per
open.

## Schema & migrations

User-facing schema summary is in README. Mechanics and invariants that matter
when changing it:

```sql
-- v1
entries(id INTEGER PK, kind TEXT NOT NULL DEFAULT 'text', hash BLOB,
        copied_at INTEGER, content TEXT NULL)
  CHECK kind IN ('text','image'); CHECK (kind='text') = (content IS NOT NULL)
index on hash, index on copied_at
images(entry_id PK → entries.id ON DELETE CASCADE, path, uti, width, height,
       byte_len, thumb BLOB)
  uti = pasteboard type, not a MIME type — the pasteboard is the only producer
  and only consumer, so `use` hands it straight back to setData:forType:
  no thumb dimensions column — the PNG's IHDR chunk already carries them
tags(id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
entry_tags(entry_id → entries.id, tag_id → tags.id, PK(entry_id, tag_id))
  both FKs ON DELETE CASCADE; index on tag_id
```

Hash = raw SHA256 (32 bytes) of the copied text, or of the original image bytes. Dedup for both kinds runs through `findByHash`; the daemon `touch`es on a hit and `insertText`/`insertImage`s on a miss, logging each differently. `insertImage` is transactional because a half-written image entry (entries row, no images row) is unrepairable.

The second CHECK is what lets `rowToEntry` trust `kind` and skip reading the joined columns for text rows. `entry_select` in `db.zig` is a LEFT JOIN with a **positional** column list — `rowToEntry` indexes it by number, so reordering the SELECT silently corrupts every read. (Table column order is a separate thing and safe to change: every statement names its columns.)

**The big payload column is declared last in both tables** — `entries.content`, `images.thumb`. A row is one record: header of serial types, then column bodies in declaration order, with anything past the local page payload (~`page_size - 35`, so ~4KB by default) spilling onto overflow pages. Reaching a column means skipping all preceding column bytes, so a small column sitting after a 200KB thumbnail costs an overflow-chain walk per row. Declaring metadata first keeps it on the leaf page. Don't reorder a big BLOB/TEXT to the middle for tidiness.

Images split across two stores on purpose: the original stays on disk at `images/<sha256>.<ext>` (content-addressed, so re-copying never writes twice), and only the 512px PNG thumbnail is a BLOB. Putting multi-MB screenshots in the DB would make every `zclip query` pay for them.

Schema is managed by the `MIGRATIONS` runner in `db.zig` (PRAGMA `user_version`), run from `Db.open` (so CLI and daemon both migrate; idempotent).

**`PRAGMA foreign_keys=ON` is load-bearing for `entry_tags`.** It's per-connection and OFF by default, so `Db.open` runs it *before* `migrate()` (the pragma is a no-op inside the migration runner's `BEGIN IMMEDIATE`). Without it, deleting an entry orphans its `entry_tags` rows instead of cascading. Don't move or drop this.

## Comment style

Concise WHY-comments across all files. Explain non-obvious reasoning: version-pinned API choices, FFI/C ABI constraints, gotchas, security-load-bearing checks, ownership/lifetime contracts. **Don't** explain basic Zig syntax (`try`, `catch`, `defer`, `errdefer`, captures, `anytype`, optional unwrap, slice equality, error unions, format specifiers, `[*c]`/`[*:0]` pointer kinds) — author has internalized those.

## Design principles

- Local-first. Single SQLite file the user fully owns.
- Daemon stays minimal: poll and insert. Heavy work runs in CLI subcommands triggered out-of-band.
- WAL mode — CLI reads never block daemon writes.
- `dev.zclip.origin` marker and `ConcealedType` filter are both load-bearing — don't strip (see gotchas).
- Schema changes go through the `MIGRATIONS` runner — append-only, never edit a shipped entry.
- DB growth is unbounded **by design** — permanent retention is the value proposition; auto-eviction intentionally not implemented.
- Bulk bytes live on disk, derived previews live in the DB. `cache/` is fully regenerable from the DB; `images/` is not — it's the only copy of each original.
