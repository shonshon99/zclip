# zclip

Persistent clipboard history daemon for macOS.

zclip is a **permanent** clipboard store. A background daemon polls the macOS
pasteboard and writes every copy into a single SQLite file you own, keeping it
indefinitely — no auto-eviction. Duplicate content is deduped by hash. Any entry
can be tagged. A CLI exposes the archive as JSON and can re-paste any entry, so
zclip can back an external picker (e.g. a Raycast extension) that loads the
archive, filters it client-side, and pastes a chosen entry.

What zclip gives you over a stock clipboard manager:

- **Permanent retention** — years, not weeks.
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

# 3. In another shell, list everything as JSON.
zclip query

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

The directory must exist before first run; the daemon prints an actionable hint
and exits non-zero if it is missing. The DB is plain SQLite — query it directly
with the `sqlite3` CLI any time.

## Commands

```
zclip daemon                  Run the polling daemon (foreground)
zclip query [--tag <name>]    Dump entries as a JSON array (newest first)
zclip use <id>                Write entry <id> back to the pasteboard
zclip tag <id> <tag>          Attach one tag to an entry
zclip untag <id> <tag>        Remove one tag from an entry
```

### `zclip daemon`

Starts the poll loop in the foreground. Each tick reads the pasteboard; new
content is inserted, duplicate content bumps the existing entry's recency. Only
one daemon may run at a time (enforced by an exclusive lock on the pidfile); a
second invocation reports the lock and exits. `SIGINT` / `SIGTERM` shut it down
cleanly.

The following copies are **never** recorded:

- Entries flagged `org.nspasteboard.ConcealedType` (1Password, Bitwarden,
  Keychain) — defense against capturing passwords. Note: apps that don't set the
  type (Slack, browsers) bypass this.
- zclip's own `zclip use` writes, marked with a private `dev.zclip.origin`
  pasteboard type, so re-pasting doesn't create a feedback loop.

### `zclip query [--tag <name>]`

Dumps entries as a **JSON array**, newest first (`copied_at DESC`). This is the
single read command the external picker calls — zclip does no server-side text
search; it returns rows and the client filters them in memory.

- No argument → **all** entries.
- `--tag <name>` → only entries carrying that one tag. Single tag only; the
  value is one literal name (`--tag work,home` matches a tag literally named
  `work,home`, it is **not** split). The match is case-insensitive.

Each object carries exactly `id` and `content`. `copied_at` orders the rows but
is not emitted. An empty DB or no matches prints `[]` and exits 0.

Output schema:

```json
[
  { "id": 42, "content": "the copied text" },
  { "id": 41, "content": "an earlier copy" }
]
```

`content` is JSON-escaped. Output is minified (one line) with a trailing newline.

### `zclip use <id>`

Looks up entry `<id>` and writes its content back to the pasteboard (so you can
paste it), then bumps the entry's recency. Prints `copied id=<id> (<n> bytes) to
pasteboard`. Unknown id → message on stderr, exit 1.

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
./tests/run_all.sh           # all suites (tag, untag, query, use, daemon)
./tests/run_all.sh --safe    # skip clipboard-touching suites (use, daemon) — for CI
```

## Design notes

- **Local-first.** One SQLite file you fully own; no network, no cloud.
- **Unbounded growth by design.** Permanent retention is the point. Prune with
  raw SQL if you ever need to; auto-eviction is intentionally not implemented.
- **Plaintext at rest.** The concealed-type filter catches password-manager
  copies, but anything not flagged (API keys pasted from docs, tokens in
  terminal output) is readable on disk. FileVault covers the stolen-laptop
  threat; same-account access still sees plaintext.
- **Polling latency.** The 1-second poll can miss a copy that is overwritten
  inside the gap. macOS exposes no pasteboard-change notification, so polling is
  the standard approach.

## Schema

```sql
entries(id INTEGER PK, content TEXT, hash BLOB, copied_at INTEGER)
tags(id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
entry_tags(entry_id → entries.id, tag_id → tags.id, PK(entry_id, tag_id))
```

`hash` is a raw SHA-256 of the content (dedup key). Tag names use
`COLLATE NOCASE`, so tag matching is case-insensitive. Migrations are managed by
an append-only runner keyed on `PRAGMA user_version`.
