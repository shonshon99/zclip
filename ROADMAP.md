# zclip Roadmap — Raycast-backed clipboard manager

## Workflow context

**zclip is the primary clipboard store.** The daemon captures every copy and keeps it permanently in SQLite. The front-end is a Raycast extension (step 3) that searches zclip and pastes from it, **replacing Raycast's built-in Clipboard History**. zclip owns the data; Raycast is the picker UI.

> **Strategy reversed 2026-05-30.** zclip was previously framed as a "back-of-house archive, not a picker" that complemented Raycast's native history, capturing rich source-app/URL provenance Raycast couldn't. That direction is dropped:
> - Provenance columns (`source_app`/`source_title`/`source_url`) are **out** — sparse (browser-only, NULL for Slack/terminal), bloat per row, no consumer worth the AppleScript cost.
> - **User-applied tags** replace them as the metadata worth keeping.
> - The Raycast extension now **is** the picker, backed by `zclip query --json` + `zclip use`.

What zclip provides over a stock clipboard manager:

- Permanent retention (years, not weeks)
- User tags + tag search
- Auto-classification by `kind` at insert
- Programmatic CLI + JSON (queryable dataset, not just a paste buffer)
- Encryption at rest + secret audits that scale with retention

Still out of scope: **snippet expansion** (named snippets with dynamic placeholders stay Raycast's). zclip only *detects* snippet candidates (step 4).

---

## Recommended build order

Each item is a milestone; earlier items unlock later ones. GitHub issues track the detail — numbers below in parentheses.

### 1. Tag entries + search by tag (#2)

**Pain:** The archive is one undifferentiated blob. Want to label important entries and recall them by label.

**Build:**
- Normalized many-to-many schema (append to the `MIGRATIONS` runner):
  ```sql
  CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
  CREATE TABLE entry_tags (
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    tag_id   INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
    PRIMARY KEY (entry_id, tag_id)
  );
  CREATE INDEX entry_tags_tag_idx ON entry_tags(tag_id);
  ```
  `PRAGMA foreign_keys = ON` is per-connection and OFF by default — set it in `Db.open` or the cascades won't fire.
- CLI: `zclip tag <id> <tag>...`, `zclip untag <id> <tag>...`, `zclip tags`.
- `zclip search --tag <name>` (repeatable, AND semantics), composes with keyword match. Output appends `· #tags`.

### 2. Classify entries by kind on insert (#3)

**Pain:** Want a coarse machine-assigned type so the archive is sliceable and secrets are detectable without manual tagging.

**Build:**
- `kind` column + index. Heuristic classifier `src/classify.zig`: `secret`, `url`, `json`, `code`, `email`, `path`, `command`, `prose` (strict precedence, first match wins; secret first).
- Daemon classifies before insert. `zclip search` output appends `· kind=<kind>`.
- Feeds the `secret` exclusion in step 4 and the audit in step 6.

### 3. Raycast extension — zclip-backed picker, replaces Clipboard History (#7)

**Pain:** Want the permanent archive reachable in Raycast muscle memory, not a separate keybind.

**Build:**
- TypeScript Raycast extension, **Search zclip** command: text input → `zclip query --json` (step 5) → list view, as-you-type filter.
- Per-item actions: **Paste/Copy** (`zclip use <id>` writes to pasteboard — already implemented), **Show details**, **Copy tags**.
- README documents disabling Raycast's native Clipboard History so the two don't double-capture.
- Tagging/managing stays CLI-only for v1 (search + paste-back is the surface).

### 4. Snippet candidate detector (#8)

**Pain:** You copy the same kubectl/SSH/regex block dozens of times but never notice it should be a snippet.

**Build:**
- `zclip suggest-snippets`: normalize whitespace, hash, group identical-after-normalization, rank by frequency × recency.
- Skip `kind = secret` (from step 2). Emit a Raycast Quicklink (`raycast://extensions/raycast/snippets/create-snippet?...`) per candidate — one click promotes to a Raycast snippet. zclip *teaches* Raycast what to remember; expansion stays Raycast's.

### 5. Structured query CLI (#5)

**Pain:** Want the archive as a queryable dataset and the JSON feed the Raycast extension consumes.

**Build:**
- `zclip query` with `--kind`, `--tag` (AND), `--from`/`--to`, `--limit`, `--format human|jsonl|json`.
- `zclip pipe <id>` (raw content to stdout), `zclip recent --kind <k>`.
- JSON/JSONL enables `jq`/`fx` chains **and** backs step 3's Search command. (Land the query JSON before/with the extension.)

### 6. FTS5 full-text search (#9)

**Pain:** `LIKE '%x%'` over years of data gets slow; search is now the primary interaction.

**Build:**
- SQLite FTS5 virtual table over `content`. Migrate `zclip search` off `LIKE`. (Migration runner already in place — #1, done.)

### 7. Encryption at rest + secret audit + encrypted backup (#11, #12, #13)

**Pain:** Long retention amplifies risk — year-old API keys in plaintext SQLite; laptop loss = lose the whole archive.

**Build:**
- **Encryption at rest (#11):** SQLCipher or app-layer AES-GCM on `content`. Key in macOS Keychain (`Security.framework`). Daemon unlocks on launch.
- **`zclip audit secrets` (#12):** regex-scan the archive (reuses step 2's `secret` patterns), masked preview, `--purge`.
- **Encrypted backup/restore (#13):** `zclip backup` → encrypted dump; `zclip restore`. Disaster recovery as first-class workflow.

### 8. Semantic search (#14)

**Pain:** "That AWS throttling error I copied last summer" — no exact keyword match; FTS5 misses paraphrases.

**Build:**
- Local embedding model embeds entries on insert; vectors in `sqlite-vss`. `zclip ask "..."` → top-k cosine matches.

---

## Deferred follow-ups

- **Per-app deny rules (#6)** — `~/.config/zclip/rules.toml` blocklist of bundle ids. Daemon reads the **frontmost app bundle id transiently** at copy time (`NSWorkspace.frontmostApplication`) and skips insert on a match — no stored column. Defense in depth over the `ConcealedType` filter. Land after steps 1–3 are stable.

## Deferred (revisit only if pain shows up)

- **Image clipboard + OCR** — text-first for now.
- **Stack paste / multi-cursor** — niche.
- **Transform pipeline on paste**.
- **Cross-device sync** — only if multi-year multi-device archive becomes a clear pain.
- **Diff between revisions of same content**.
- **Shell-history correlation** — powerful but invasive (zsh/fish hooks).
- **Freeform notes on entries** — was a planned feature (old #4), dropped in favor of tags; revive only if tags prove insufficient.

---

## Design principles

- Local-first. Single SQLite file the user fully owns.
- Daemon stays minimal: poll, classify, insert. Heavy work (embeddings, audits, suggest-snippets) runs in CLI subcommands triggered out-of-band.
- WAL mode. CLI reads never block daemon writes.
- Don't strip the `dev.zclip.origin` feedback-loop marker or the `ConcealedType` filter — both load-bearing.
- Schema changes go through the `MIGRATIONS` runner (`db.zig`) — append-only, never edit a shipped entry. Document each migration here when added.
