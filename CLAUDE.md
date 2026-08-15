# zclip — contributor notes

Persistent clipboard history daemon for macOS. Zig + libsqlite3 + NSPasteboard.

**User-facing docs (what zclip is, install, every command, JSON schema, exit
codes, schema summary) live in [README.md](README.md).** This file is the
opposite audience: invariants, FFI/ABI gotchas, and version-pinned choices a
future session needs before touching the code.

## Commands

```sh
zig build                    # -> zig-out/bin/zclip
./tests/run_all.sh           # all suites
./tests/run_all.sh --safe    # skips clipboard-touching suites (use, daemon, image)
cd raycast && npx ray build && npx ray lint   # extension checks, NOT run by zig build or run_all.sh
```

## Conventions

- Branch `feature/<slug>` or `fix/<slug>` off `main`; land via PR merge commit.
  Don't push to `main` directly.
- Conventional Commits: `feat:` `fix:` `docs:` `test:` `chore:` `refactor:`
  `ci:`. Subject only — bodies are rare, reserved for non-obvious why.
- CI (`.github/workflows/ci.yml`) runs `zig build` + `tests/run_all.sh --safe` on
  every PR and push to `main`. `macos-latest` is mandatory: the build links
  AppKit/Foundation and resolves sqlite3 from the Darwin SDK. Zig resolves from
  `build.zig.zon`'s `minimum_zig_version` — don't hardcode it in the workflow.

## Layout

```
src/main.zig       CLI router, query/use/thumb/tag/untag commands, JSON formatting
src/clipboard.zig  NSPasteboard wrapper via mitchellh/zig-objc
src/db.zig         SQLite wrapper (translate-c on src/sqlite_c.h)
src/daemon.zig     Poll loop, pidfile lock (Io.Dir.createFile), signal handlers
src/image.zig      ImageIO thumbnailing — hand-declared C externs, NOT translate-c
src/sqlite_c.h     Shim header — `#include <sqlite3.h>` for build-system translate-c
build.zig          translate-c sqlite3, link AppKit/Foundation/ImageIO/CG/CF; link_libc
tests/lib.sh       Shared: isolated temp HOME (fresh mktemp -d per suite), assert helpers
tests/fixtures/    Committed 1024x768 PNG driving the image suite
tools/pbdump.swift Diagnostic: dumps live pasteboard's flavours + metadata
raycast/src/zclip.ts        Extension↔CLI boundary: execs the binary, parses its JSON
raycast/src/search.tsx      "Search Clipboard" — list/detail panes, tag filter, tagging
raycast/src/run-daemon.tsx  no-view command that starts the daemon
```

The Raycast extension is the reference consumer of the CLI's contract — the
reason `query` emits JSON, `thumb` prints a bare path, and `use` exists at all.
Changing a command's output shape means changing `zclip.ts` in the same commit.

`tools/pbdump.swift` is the evidence behind `image_types`' probe order and the
text-before-image rule below. Swift because it needs no FFI bindings to maintain.

## Common tasks

**Adding a subcommand** touches six places:

1. `main.zig`: add the variant to the `Command` enum — dispatch is one exhaustive
   `switch`, so it won't compile until handled, which is deliberate. Then the
   `usage` literal and a `run<Name>` fn beside `runQuery`/`runUse`/`runThumb`.
2. Reuse `storageDir` / `dbPath`. `dbPath` returns a sentinel-0 slice because
   SQLite's C API needs `const char *`.
3. Match existing exit codes: 2 = bad invocation, 1 = runtime failure. Tests
   assert these.
4. `tests/<cmd>_test.sh` sourcing `tests/lib.sh`, registered in `run_all.sh`'s
   `suites=()` — inside the `--safe` guard if it touches the real pasteboard, or
   CI goes flaky.
5. `README.md`: the `## Commands` block plus a `### zclip <cmd>` section.
6. `raycast/src/zclip.ts`, only if the extension consumes it.

## Zig version

Pinned to **0.16.0** in both `build.zig.zon` and `.zigversion`. The codebase uses
0.16-idiomatic APIs throughout: `pub fn main(init: std.process.Init)`,
`std.Io.File.Writer`, `std.Io.Dir.createFile` with advisory lock options,
`std.Io.sleep`, `std.Io.Timestamp.now`, `init.minimal.environ.getPosix`. If you
bump or downgrade Zig, expect rework in `main.zig` and `daemon.zig` first.

## Security invariants

**Concealed-type filter is the only password-leak defense.** Daemon skips entries
where the pasteboard has `org.nspasteboard.ConcealedType` (1Password, Bitwarden,
Keychain). If you add a write path or remove the check, sensitive content lands
in the DB plaintext. Defense-in-depth only — apps that don't set the type (Slack,
browsers) bypass it.

**Origin marker prevents daemon feedback loop.** `zclip use` writes content
tagged with custom type `dev.zclip.origin`; the poll checks `pb.hasOrigin()` and
skips. Don't strip this from `writeStringAsOrigin`.

## FFI & runtime gotchas

**Signal handling stays on libc.** `daemon.zig` declares `extern "c" fn signal`
and uses raw `SIGINT`/`SIGTERM` because `std.posix.sigaction` on Darwin requires
a typed-enum handler signature that's awkward to satisfy, and 0.16's Io interface
doesn't expose signal handlers. Check the Darwin sigaction prototype before
"modernizing" this.

**SQLite C bindings via build-system translate-c, not `@cImport`.** `build.zig`
runs `b.addTranslateC` on `src/sqlite_c.h` and exposes it as
`@import("sqlite_c")` (`@cImport` in source is deprecated in 0.16). Add new
SQLite symbols by editing the shim header.

**SQLite destructor sentinels.** `SQLITE_TRANSIENT`/`SQLITE_STATIC` expand to
`((destructor_type)-1)` / `((destructor_type)0)`; translate-c emits
`@ptrFromInt(...)`, which fails Zig's fn-pointer alignment check at comptime.
`db.zig` declares `const SQLITE_STATIC: c.sqlite3_destructor_type = null` and
passes null — safe because all bound buffers outlive `sqlite3_finalize` here.

**ImageIO bindings are hand-written externs — translate-c cannot parse the Apple
SDK headers.** Two blockers: CGColorSpace.h writes `CGFloat
whitePoint[CG_NONNULL_ARRAY 3]` and clang hard-errors on a nullability specifier
inside an array bound (fixable by `#undef`ing the nullability macros); then
CGPath.h declares `typedef void (^CGPathApplyBlock)(...)` unguarded, and blocks
need `-fblocks`, which `std.Build.Step.TranslateC` has no API to pass. Narrowing
the includes doesn't dodge it — CGPath.h arrives via CGImage.h. Re-check both
before re-adding a shim header "for consistency".

**CF ownership rules apply in `image.zig`.** "Create"/"Copy" means we own the
result and must `CFRelease` it; "Get" means we borrow.
`CFDataCreateWithBytesNoCopy` + `kCFAllocatorNull` reads straight out of the Zig
slice, so every CF object derived from it must die before that slice's owner
returns. The options dict passes null callbacks and so does *not* retain its
values; the `CFNumber` must outlive it (defer order handles this).

**Text beats image when the pasteboard offers both.** Rich-text copies publish a
TIFF rendering alongside the plain text. The daemon checks `readString` first and
only falls through to `imageType()` when there's no non-empty string. Flipping
that order turns every copied paragraph into a screenshot.

**NSPasteboard goes through `mitchellh/zig-objc`** — `obj.msgSend(Return,
"selector:", .{args})` synthesizes the `objc_msgSend` cast per call site. Earlier
revisions hand-rolled the FFI; git history has the reference.

**Daemon poll loop wraps each tick in an `objc.AutoreleasePool`.** `[NSString
stringWithUTF8String:]`, `[pb types]`, `[pb stringForType:]` return autoreleased
objects; with no pool on the thread they pile up in a process-global one that
never drains. `readString` copies bytes into the caller's allocator *before* the
pool drains — don't pass a raw NSString-owned pointer past `defer pool.deinit()`.

**WAL mode + single-instance.** `PRAGMA journal_mode=WAL` so CLI reads don't
block daemon writes. Single instance comes from `.lock = .exclusive,
.lock_nonblocking = true` on the pidfile's `Io.Dir.createFile` — acquisition is
atomic with the open(2), contention surfaces as `error.WouldBlock`.
`truncate = false` preserves the previous PID until `writePid` overwrites via
`setLength(io, 0)` + `writePositionalAll`.

**`cache/<id>.png` — two hazards, one filename.** `runThumb` builds it from
`storageDir` + rowid; `cachedThumbPath` in `zclip.ts` rebuilds it from
`homedir()`, so a materialised thumbnail is findable with one `existsSync`
instead of a subprocess — that's what paints row icons in the first frame.

- *Divergence fails soft.* Change `storageDir` or the convention and every stat
  misses: the extension silently falls back to `zclip thumb` per row and the only
  symptom is icon pop-in. Grep the extension. Emitting `thumb_path` from `query`
  would collapse this to one definition, at the cost of a wider JSON contract.
- *Deletes orphan it.* `entry_tags` cascades; `cache/<id>.png` and the file at
  `images.path` do not. Rowids are recycled without `AUTOINCREMENT`, so a stale
  cache file serves the *previous* entry's thumbnail to whatever lands on that
  id. Any future prune path must unlink both.

## Raycast extension gotchas

Thumbnail loading in `search.tsx` looks over-engineered and is not. Four rules,
all easy to reintroduce by "simplifying":

- **The prefetch must never cancel in-flight work.** Thumbnails are immutable and
  keyed by rowid, so a late result is still correct. Cancelling on effect cleanup
  meant any double-invoke (StrictMode, or a tag switch mid-prefetch) discarded
  the running batch while its ids stayed marked in `requested`, so exactly
  `POOL_SIZE` rows kept the placeholder icon forever. Deceptive symptom: *some*
  images load, which ones varies per launch — reads like a flaky CLI.
- **`requested` tracks requested, not in-flight.** Ids stay marked after they
  resolve. That's what lets the prefetch effect depend on `entries` alone; adding
  `thumbs` re-enters on every resolution and spawns a fresh pool each time.
- **Seed the thumb map in the same tick as `setEntries`, computed outside the
  updater.** React batches both `setState`s into one render, so the first frame
  with rows already has icons. `seedCachedThumbs` mutates the `requested` ref, so
  calling it inside the `setThumbs` updater makes the updater impure — StrictMode
  double-invokes, the second call finds every id marked, returns `{}`, and
  silently drops the seed.
- **`zclip thumb` still runs, just off the warm path.** It alone turns the
  `images.thumb` BLOB into a file, so a never-before-seen image costs one
  subprocess, once, ever. `query` and `tags` stay one exec per open.

## Schema invariants

Schema summary is in README. What matters when changing it:

- **`entry_select` in `db.zig` is a LEFT JOIN with a positional column list** —
  `rowToEntry` indexes by number, so reordering the SELECT silently corrupts
  every read. (Table column order is separate and safe to change: every statement
  names its columns.)
- **The `(kind='text') = (content IS NOT NULL)` CHECK** is what lets `rowToEntry`
  trust `kind` and skip reading the joined columns for text rows.
- **The big payload column is declared last in both tables** (`entries.content`,
  `images.thumb`) so metadata stays on the leaf page instead of behind an
  overflow-chain walk. Don't reorder a big BLOB/TEXT to the middle for tidiness.
- **`insertImage` is transactional** — a half-written image entry (entries row,
  no images row) is unrepairable.
- **`PRAGMA foreign_keys=ON` is load-bearing for `entry_tags`.** Per-connection
  and OFF by default, so `Db.open` runs it *before* `migrate()` (it's a no-op
  inside the migration runner's `BEGIN IMMEDIATE`). Without it, deleting an entry
  orphans `entry_tags` rows instead of cascading. Don't move or drop this.
- Migrations run from the `MIGRATIONS` runner in `db.zig` (PRAGMA
  `user_version`), called by `Db.open` so CLI and daemon both migrate; idempotent.

## Comment style

Concise WHY-comments. Explain non-obvious reasoning: version-pinned API choices,
FFI/C ABI constraints, security-load-bearing checks, ownership/lifetime
contracts. **Don't** explain basic Zig syntax — the author has internalized it.
