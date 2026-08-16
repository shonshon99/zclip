# zclip

Persistent clipboard history daemon for macOS.

zclip is a **permanent** clipboard store. A background daemon polls the macOS
pasteboard and writes every copy — text or image — into a single SQLite file you
own, keeping it indefinitely — no auto-eviction. Duplicate content is deduped by
hash. Any entry can be tagged. A CLI exposes the archive as JSON and can
re-paste any entry, so zclip can back an external picker (e.g. a Raycast
extension) that loads the archive, filters it client-side, and pastes a chosen
entry.

What zclip gives you over a stock clipboard manager:

- **Permanent retention** — years, not weeks.
- **Text and images**, with previewable thumbnails for the latter.
- **User tags** on any entry.
- **A single local SQLite file you fully own**, queryable directly.

## Requirements

- macOS (uses `NSPasteboard` via AppKit/Foundation).
- [Zig **0.16.0**](https://ziglang.org/download/) — pinned in `.zigversion` and
  `build.zig.zon`. Other versions will not compile.
- `libsqlite3` (ships with macOS).

## Build

```sh
zig build                 # produces zig-out/bin/zclip
```

The binary lands at `zig-out/bin/zclip`. Put it on your `PATH` if you like.

## Quick start

```sh
# 1. Start the daemon (foreground — runs until you stop it).
zclip daemon

# 2. Copy things normally (Cmd-C). The daemon records each copy.

# 3. In another shell, list everything as JSON — or just the newest few.
zclip query
zclip query --limit 20

# 4. Tag an entry, filter by tag, and paste it back.
zclip tag 42 work
zclip query --tag work
zclip use 42
```

Run the daemon under a process manager (e.g. `launchd`) if you want it to start
at login. zclip itself stays minimal: it polls and inserts; everything else is
an out-of-band CLI command.

## Storage

| Path | Purpose |
|---|---|
| `~/.local/share/zclip/history.db` | SQLite database (WAL mode) |
| `~/.local/share/zclip/zclip.pid`  | Daemon pidfile / single-instance lock |
| `~/.local/share/zclip/images/`    | Original image files, named by content hash |
| `~/.local/share/zclip/cache/`     | Thumbnails materialised by `zclip thumb` |

The top-level directory must exist before first run; the daemon prints an
actionable hint and exits non-zero if it is missing. `images/` and `cache/` are
created automatically. The DB is plain SQLite — query it directly with the
`sqlite3` CLI any time.

`cache/` is disposable: every file in it can be regenerated from the database,
so deleting it costs one re-run of `zclip thumb` and never loses data.
`images/` is **not** — it holds the only copy of each original image.

## Commands

```
zclip daemon                              Run the polling daemon (foreground)
zclip query [--tag <name>] [--limit <n>]  Dump entries as a JSON array (newest first)
zclip tags                                Dump all tag names as a JSON array
zclip use <id>                            Write entry <id> back to the pasteboard
zclip thumb <id>                          Materialise image <id>'s thumbnail, print its path
zclip tag <id> <tag>                      Attach one tag to an entry
zclip untag <id> <tag>                    Remove one tag from an entry
```

### `zclip daemon`

Starts the poll loop in the foreground. Each tick reads the pasteboard; new
content is inserted, duplicate content bumps the existing entry's recency. Only
one daemon may run at a time (enforced by an exclusive lock on the pidfile); a
second invocation reports the lock and exits. `SIGINT` / `SIGTERM` shut it down
cleanly.

**Images.** When a copy carries image data rather than text, the daemon archives
the original bytes to `~/.local/share/zclip/images/<sha256>.<ext>` and stores a
downscaled PNG thumbnail (longest side 512px) in the database, along with the
original's pixel dimensions, pasteboard type (`public.png`, not a MIME type),
and file size. PNG is preferred, then TIFF, then JPEG — a single copy often
lands on the pasteboard under several of these at once, and PNG is lossless and
far smaller than TIFF.

Text wins when a copy offers both: rich-text sources (Word, browsers, Preview
selections) routinely publish a TIFF rendering alongside the plain text, and the
text is what you meant to copy.

Text entries store the plain-text flavour only. A rich-text copy's `public.rtf`
and `public.html` flavours are dropped, so `zclip use` pastes unstyled text.

The following copies are **never** recorded:

- Entries flagged `org.nspasteboard.ConcealedType` (1Password, Bitwarden,
  Keychain) — defense against capturing passwords. Note: apps that don't set the
  type (Slack, browsers) bypass this.
- zclip's own `zclip use` writes, marked with a private `dev.zclip.origin`
  pasteboard type, so re-pasting doesn't create a feedback loop.

### `zclip query [--tag <name>] [--limit <n>]`

Dumps entries as a **JSON array**, newest first (`copied_at DESC, id DESC`).
This is the single read command the external picker calls — zclip does no
server-side text search; it returns rows and the client filters them in memory.

- No argument → **all** entries.
- `--tag <name>` → only entries carrying that one tag. Single tag only; the
  value is one literal name (`--tag work,home` matches a tag literally named
  `work,home`, it is **not** split). The match is case-insensitive.
- `--limit <n>` → at most `n` rows. Applied **after** any `--tag` filter, so
  `--tag work --limit 5` is the five newest *work* entries, not the work
  entries among the five newest. `n` is an unsigned 32-bit integer; `--limit 0`
  prints `[]` and exits 0. Omit the flag for no cap.

Flags may be given in either order. Repeating a flag, omitting its value, or
giving `--limit` a negative or non-numeric argument exits 2. A value starting
with `--` counts as omitted, so `--tag --limit 5` is a missing-value error
rather than a search for a tag named `--limit`.

`id DESC` is a tiebreaker, not a sort key you should depend on for meaning: it
only decides the order of entries sharing a `copied_at`, so that a given
`--limit` returns the same rows on every call.

Every object carries `id` and `kind` (`"text"` or `"image"`). The remaining keys
depend on the kind, and keys that don't apply are **omitted entirely** rather
than emitted as `null`, so a client can switch on presence. `copied_at` orders
the rows but is not emitted. An empty DB or no matches prints `[]` and exits 0.

| Key | Kind | Meaning |
|---|---|---|
| `content`  | text  | The copied text, JSON-escaped |
| `width`    | image | Pixel width of the **original** |
| `height`   | image | Pixel height of the **original** |
| `path`     | image | Absolute path to the original file on disk |
| `byte_len` | image | Size of that file in bytes |

Output schema:

```json
[
  { "id": 42, "kind": "text", "content": "the copied text" },
  { "id": 41, "kind": "image", "width": 1024, "height": 768,
    "path": "/Users/you/.local/share/zclip/images/3f9a....png", "byte_len": 846235 }
]
```

`width`/`height` are the original's, which is what a picker wants for a label
like `Image (1024x768)`. Thumbnails are deliberately **not** in this payload —
base64ing every image into a listing that gets re-read on each keystroke would
cost megabytes. Fetch them per-selection with `zclip thumb <id>`.

Output is minified (one line) with a trailing newline.

### `zclip tags`

Dumps every tag name as a **JSON array of strings**, alphabetical. Feeds the
external picker's tag filter (so it can offer the set of tags without scanning
entries). No tags → `[]`, exit 0.

```json
["home", "work"]
```

### `zclip use <id>`

Looks up entry `<id>` and writes its content back to the pasteboard (so you can
paste it), then bumps the entry's recency. Prints `copied id=<id> (<n> bytes) to
pasteboard`. Unknown id → message on stderr, exit 1.

For an image entry this writes the **original** file's bytes, not the
thumbnail — you paste exactly what you copied. If the original has been deleted
from `images/`, it reports the missing path and exits 1.

### `zclip thumb <id>`

Writes image `<id>`'s stored thumbnail to `~/.local/share/zclip/cache/<id>.png`
and prints that path. This is how a picker previews an image: `query` gives it
the list, `thumb` gives it a file to render for whichever row is selected.

The write is skipped when the file is already there — an entry's thumbnail never
changes, so repeat calls just re-print the path. A text entry (or unknown id) →
message on stderr, exit 1.

```sh
zclip thumb 41
# /Users/you/.local/share/zclip/cache/41.png
```

### `zclip tag <id> <tag>` / `zclip untag <id> <tag>`

Attach or remove one tag on an entry. Tag names are trimmed and lowercased
before storage. Both take exactly `<id> <tag>`; wrong arg count prints a usage
line and exits 2.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Runtime failure (e.g. unknown id, DB error) |
| 2 | Bad invocation (usage error, unparsable id, missing storage dir) |

## Tests

Functional tests live in `tests/` — one suite per command, each driving the real
binary against an isolated temp `HOME` so your real archive is never touched.

```sh
./tests/run_all.sh           # all suites (tag, untag, query, tags, use, daemon, image)
./tests/run_all.sh --safe    # skip clipboard-touching suites (use, daemon, image) — for CI
```

`image_test.sh` copies an image to your real pasteboard; like the other
clipboard suites it stashes and restores what was there, but the restore is
text-only.

## Design notes

- **Local-first.** One SQLite file you fully own; no network, no cloud.
- **Unbounded growth by design.** Permanent retention is the point. Prune with
  raw SQL if you ever need to; auto-eviction is intentionally not implemented.
  Images make this bite faster — deleting an entry's row does **not** remove its
  file from `images/`, so a manual prune should clear both.
- **Originals on disk, thumbnails in the DB.** Keeping multi-megabyte
  screenshots out of `history.db` is what keeps `zclip query` instant; the
  512px thumbnail is small enough to live inline and is all a preview needs.
- **Plaintext at rest.** The concealed-type filter catches password-manager
  copies, but anything not flagged (API keys pasted from docs, tokens in
  terminal output) is readable on disk. FileVault covers the stolen-laptop
  threat; same-account access still sees plaintext.
- **Polling latency.** The 1-second poll can miss a copy that is overwritten
  inside the gap. macOS exposes no pasteboard-change notification, so polling is
  the standard approach.

## Schema

```sql
entries(id INTEGER PK, kind TEXT, hash BLOB, copied_at INTEGER, content TEXT NULL)
images(entry_id → entries.id PK, path TEXT, uti TEXT, width INTEGER,
       height INTEGER, byte_len INTEGER, thumb BLOB)
tags(id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
entry_tags(entry_id → entries.id, tag_id → tags.id, PK(entry_id, tag_id))
```

`hash` is a raw SHA-256 of the content — the copied text for a text entry, the
original image bytes for an image one — and is the dedup key for both. `kind` is
`'text'` or `'image'`; `content` is set for text entries and NULL for images,
which get a row in `images` instead (CHECK constraints enforce both). `uti` is
the macOS pasteboard type the image was captured under (`public.png`,
`public.tiff`, `public.jpeg`) and is what `zclip use` writes it back as; `thumb`
is PNG regardless of it. Tag names use `COLLATE NOCASE`, so tag
matching is case-insensitive. Migrations are managed by an append-only runner
keyed on `PRAGMA user_version`.

`content` and `thumb` are declared last in their tables on purpose: SQLite lays
a row out in declaration order and spills whatever exceeds ~4KB onto overflow
pages, so keeping the small metadata columns ahead of the large payload lets
them be read without walking that chain.
