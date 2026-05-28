# zclip Roadmap — Raycast Complement

## Workflow context

Primary clipboard UX = **Raycast** (history picker + named snippets with dynamic placeholders).
Raycast clipboard history is bounded to ~1 month. Raycast snippets are static, content-only.

**zclip's role: long-term back-of-house archive.** Not a picker. Specializes in what Raycast structurally cannot offer:

- Permanent retention (years, not weeks)
- Rich metadata captured at copy time (source app, URL provenance, project/cwd)
- Programmatic CLI access (pipe, query, export)
- Insights derivable only from long-tail history
- Safety guarantees that matter more as retention grows

Do NOT rebuild Raycast's picker UI. Do NOT compete on snippet expansion. Complement.

---

## Recommended build order

Each item below is a milestone. Earlier items unlock later ones (metadata at capture time is a prerequisite for filtered queries, audits, project tags, etc.).

### 1. Source-app + URL provenance capture

**Pain:** Six months later — "where did I copy this from?" Raycast forgets context after eviction.

**Build:**
- At copy time, capture `NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier` and window title.
- For Safari/Chrome/Arc, capture active tab URL via AppleScript (`osascript -e`) or Accessibility API.
- Persist alongside content in `entries`.

**Schema additions:**
```sql
ALTER TABLE entries ADD COLUMN source_app TEXT;       -- bundle id, e.g. "com.apple.Safari"
ALTER TABLE entries ADD COLUMN source_title TEXT;     -- window/tab title at copy time
ALTER TABLE entries ADD COLUMN source_url TEXT;       -- browser URL when available
```

`zclip show <id>` displays: `Safari · 2025-08-12 14:32 · https://news.ycombinator.com/item?id=...`.

Foundation for everything below. Start the data accumulating now even before any UI consumes it.

### 2. Annotations + structured query

**Pain:** Archive is one undifferentiated blob. Want to slice by date, source, kind. Want to attach "why" to important entries.

**Build:**
- `notes` column (free-text, FTS-indexed).
- `kind` column (heuristic classifier: `url`, `code`, `json`, `email`, `command`, `path`, `secret`, `prose`).
- CLI:
  ```
  zclip note <id> "PR #123 review feedback from Alex"
  zclip query --kind=url --from 2025-12 --source com.slack --format jsonl
  zclip recent --kind=prose | pbcopy
  zclip pipe <id> | jq .
  ```
- JSON/JSONL output enables `jq`/`fx`/`miller` chains. Becomes a queryable dataset, not just a paste buffer.

**Schema:**
```sql
ALTER TABLE entries ADD COLUMN note TEXT;
ALTER TABLE entries ADD COLUMN kind TEXT;             -- classifier output
CREATE INDEX IF NOT EXISTS entries_kind_idx ON entries(kind);
CREATE INDEX IF NOT EXISTS entries_source_app_idx ON entries(source_app);
```

### 3. Raycast extension: "Search zclip" + "Archive to zclip"

**Pain:** Don't want a separate keybind or picker for the long tail. Stay in Raycast muscle memory.

**Build:**
- Raycast extension (TypeScript) with two commands:
  - **Archive to zclip** — action on a Raycast history item. Shells out to `zclip archive --tag <tag> --note <note>` to permanently retain (and annotate) before Raycast evicts.
  - **Search zclip** — text input → calls `zclip query --json` → renders results. Actions: "Copy", "Paste", "Show details", "Open source URL".
- Raycast picker becomes a unified front for both the 30-day cache (native) and the multi-year archive (zclip-backed).

### 4. Snippet candidate detector + Raycast Quicklink integration

**Pain:** You copy the same kubectl/SSH/regex block 50× over months but never notice it should be a snippet.

**Build:**
- `zclip suggest-snippets` analyzes archive: normalize whitespace, hash, group identical/near-identical strings, rank by frequency × recency.
- Output:
  ```
  47×  kubectl --context prod get pods -n foo
  31×  ssh -J bastion.acme.com prod-app-01
  22×  (^|\s)(\S+@\S+\.\S+)(\s|$)
  ```
- For each, emit a Raycast Quicklink URL (`raycast://extensions/raycast/snippets/create-snippet?text=...&name=...`) — one click promotes to Raycast snippet.
- zclip *teaches* you what to promote. Closes the loop between archive and Raycast snippets.

### 5. FTS5 + Core Spotlight indexing

**Pain:** `LIKE '%x%'` over years of data gets slow. Don't want yet another picker keybind for old archive.

**Build:**
- Migrate to SQLite FTS5 virtual table on `content + note + source_title`. (Schema migration runner first — see Known Tradeoffs in `zclip-handoff.md`.)
- Index entries into macOS Core Spotlight via `CSSearchableItemAttributeSet`. Cmd-Space → system-wide hit on year-old clipboard. Zero new keybinds, taps existing search habit.

### 6. Encryption at rest + retroactive secret audit + encrypted backup

**Pain:** Long retention amplifies risk. Year-old API keys sitting in plaintext SQLite = bad. Laptop loss = lose entire multi-year archive.

**Build:**
- **Encryption at rest:** SQLCipher (drop-in libsqlite3 replacement) OR app-layer AES-GCM on `content` + `note` columns. Key in macOS Keychain via `Security.framework` (`SecItemCopyMatching`). Daemon unlocks on launch — no passphrase friction.
- **`zclip audit secrets`:** Regex-scan entire archive for `aws_secret`, `jwt`, `bearer`, `ghp_`, `sk-`, PEM blocks, credit-card Luhn. Lists with masked preview. `--purge` removes. Run on schedule.
- **Encrypted backup:** Nightly `zclip backup` → age-encrypted SQLite dump pushed to S3/iCloud Drive/git LFS. `zclip restore <url>` on new machine. Disaster recovery as first-class workflow.

### 7. Semantic search (`sqlite-vss` + local embeddings)

**Pain:** "That AWS throttling error I copied last summer" — no exact keyword match. FTS5 won't catch paraphrases.

**Build:**
- Local embedding model (BGE-small, ~30MB, CoreML-optimized) embeds entries on insert.
- Store vectors in `sqlite-vss` extension table.
- `zclip ask "aws rate limit error from spring"` → top-k cosine matches.
- Moat feature. Structurally impossible for Raycast (30-day cache, no embeddings).

---

## Deferred (not in current build order)

Listed for completeness; revisit only if pain shows up:

- **Image clipboard + OCR** — Raycast already handles image history acceptably for the 30-day window.
- **Stack paste / multi-cursor** — niche; Raycast covers most multi-paste workflows.
- **Transform pipeline on paste** — Raycast snippet placeholders cover the common case.
- **Cross-device sync** — Raycast Pro sync handles short-term; address only if multi-year multi-device archive becomes a clear pain.
- **Diff between revisions of same content** — interesting but no acute pain.
- **Shell-history correlation** — powerful for retroactive debugging but invasive (requires zsh/fish hooks).

---

## Cross-cutting prerequisites

Before items 2+ land cleanly, two pieces of plumbing are worth introducing:

1. **Migration runner** — `PRAGMA user_version` based. Schema lives in numbered `.sql` files (or inline `const MIGRATIONS = .{ ... }`). Daemon runs pending migrations on startup. Current schema lives inline in `db.zig`; once column #2 lands, do this first.
2. **Per-app rules config** — `~/.config/zclip/rules.toml` with `deny.bundle_ids = [...]`. Daemon checks `frontmostApplication` (already needed for #1) before insert. Defense in depth on top of `ConcealedType` filter.

---

## Design principles (carried forward from handoff)

- Local-first. Single SQLite file the user fully owns.
- Daemon stays minimal: poll, classify, insert. Heavy work (embeddings, OCR, audits) runs in CLI subcommands or background workers triggered out-of-band.
- WAL mode. CLI reads never block daemon writes.
- Don't strip the `dev.zclip.origin` feedback-loop marker or the `ConcealedType` filter — both are load-bearing.
- Schema changes go through the migration runner once introduced. Document each migration in this file when added.
