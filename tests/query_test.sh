#!/usr/bin/env bash
#
# Functional tests for `zclip query`. Pure DB read — no pasteboard.
# Emits a minified JSON array of {id, content} objects, newest first
# (copied_at DESC, id DESC). `--tag <name>` filters to entries carrying that
# single tag (no comma-split, no AND); `--limit <n>` caps the row count and
# applies after the tag filter. Run: ./tests/query_test.sh (after `zig build`).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Seed a known corpus. reset_db already inserts id=1 'hello world' @0.
seed_corpus() {
    reset_db
    seed_entry 2 'second' 10
    seed_entry 3 'third'  20
}

section "query dumps all entries, newest-first, as minified JSON"
seed_corpus
out="$("$ZCLIP" query 2>/dev/null)"
assert_eq \
    '[{"id":3,"kind":"text","content":"third"},{"id":2,"kind":"text","content":"second"},{"id":1,"kind":"text","content":"hello world"}]' \
    "$out" "exact JSON, copied_at DESC ordering"

section "objects carry only id + content (no copied_at, no tags)"
seed_corpus
out="$("$ZCLIP" query 2>/dev/null)"
assert_eq "false" "$([[ "$out" == *copied_at* ]] && echo true || echo false)" \
    "no copied_at field leaked"
assert_eq "false" "$([[ "$out" == *tags* ]] && echo true || echo false)" \
    "no tags field leaked"

section "content is JSON-escaped"
reset_db
seed_entry 2 'say "hi"' 10
out="$("$ZCLIP" query 2>/dev/null)"
assert_contains "$out" '"content":"say \"hi\""' "embedded quotes escaped"

section "empty DB → empty array, exit 0"
rm -rf "$ZDIR"; mkdir -p "$ZDIR"
"$ZCLIP" query >/dev/null 2>&1   # bootstrap schema, no entries
out="$("$ZCLIP" query 2>/dev/null)"
assert_eq "[]" "$out" "no entries → []"
assert_exit 0 "empty DB still exits 0" -- "$ZCLIP" query

section "--tag returns only entries carrying that tag, newest-first"
seed_corpus
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 3 work >/dev/null 2>&1
out="$("$ZCLIP" query --tag work 2>/dev/null)"
assert_eq \
    '[{"id":3,"kind":"text","content":"third"},{"id":1,"kind":"text","content":"hello world"}]' \
    "$out" "work-tagged entries only, copied_at DESC"

section "--tag match is case-insensitive (tags.name COLLATE NOCASE)"
seed_corpus
"$ZCLIP" tag 1 work >/dev/null 2>&1
out_lower="$("$ZCLIP" query --tag work 2>/dev/null)"
out_upper="$("$ZCLIP" query --tag WORK 2>/dev/null)"
assert_eq "$out_lower" "$out_upper" "WORK and work return the same rows"

section "--tag value is a single literal name, not comma-split"
seed_corpus
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 2 home >/dev/null 2>&1
# 'work,home' is one tag name that doesn't exist → no match, not work AND home.
out="$("$ZCLIP" query --tag 'work,home' 2>/dev/null)"
assert_eq "[]" "$out" "comma value treated as one literal tag → []"

section "--tag with no matching tag → empty array, exit 0"
seed_corpus
out="$("$ZCLIP" query --tag nonexistent 2>/dev/null)"
assert_eq "[]" "$out" "unknown tag → []"
assert_exit 0 "no-match still exits 0" -- "$ZCLIP" query --tag nonexistent

section "--limit caps the result to the newest N"
seed_corpus
out="$("$ZCLIP" query --limit 2 2>/dev/null)"
assert_eq \
    '[{"id":3,"kind":"text","content":"third"},{"id":2,"kind":"text","content":"second"}]' \
    "$out" "newest 2 rows only, copied_at DESC"
out="$("$ZCLIP" query --limit 1 2>/dev/null)"
assert_eq '[{"id":3,"kind":"text","content":"third"}]' "$out" \
    "--limit 1 → the single most recent entry"

section "--limit 0 → empty array, exit 0"
seed_corpus
out="$("$ZCLIP" query --limit 0 2>/dev/null)"
assert_eq "[]" "$out" "zero rows requested → []"
assert_exit 0 "--limit 0 still exits 0" -- "$ZCLIP" query --limit 0

section "--limit above the row count returns everything"
seed_corpus
# Pins the no-breaking-change guarantee: omitting the flag equals unbounded.
unbounded="$("$ZCLIP" query 2>/dev/null)"
assert_eq "$unbounded" "$("$ZCLIP" query --limit 999999 2>/dev/null)" \
    "--limit 999999 matches the unbounded result"
# Smoke test only: proves a u32 above c_int's range round-trips. It can't catch
# a regression to sqlite3_bind_int — such values truncate to a negative int,
# which SQLite reads as unbounded, giving the same answer. Zig won't narrow u32
# to c_int implicitly, so that regression fails at compile time instead.
assert_eq "$unbounded" "$("$ZCLIP" query --limit 4000000000 2>/dev/null)" \
    "--limit past c_int range still returns every row"

section "copied_at ties break by id DESC, so --limit is deterministic"
# All three share copied_at, so nothing but the id tiebreaker orders them.
reset_db
seed_entry 2 'second' 0
seed_entry 3 'third'  0
assert_eq '[{"id":3,"kind":"text","content":"third"}]' \
    "$("$ZCLIP" query --limit 1 2>/dev/null)" "highest id wins the tie"
# The assertion that bites. Untagged, the plan reverse-walks
# entries_copied_at_idx, whose trailing key is the rowid — id DESC falls out
# whether the SQL asks or not, so the case above can't catch a dropped
# tiebreaker. The tagged plan sorts through a temp b-tree fed in rowid order,
# where a missing tiebreaker flips this to id=1.
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 2 work >/dev/null 2>&1
"$ZCLIP" tag 3 work >/dev/null 2>&1
assert_eq '[{"id":3,"kind":"text","content":"third"}]' \
    "$("$ZCLIP" query --tag work --limit 1 2>/dev/null)" \
    "tie broken the same way through the sorter"

section "--limit applies after --tag filtering"
seed_corpus
# Tag the two OLDER rows, leaving id=3 untagged: a limit applied before the tag
# filter would see id=3 first and return [] or the wrong row.
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 2 work >/dev/null 2>&1
out="$("$ZCLIP" query --tag work --limit 1 2>/dev/null)"
assert_eq '[{"id":2,"kind":"text","content":"second"}]' "$out" \
    "newest work-tagged row, not the newest row overall"
assert_eq "[]" "$("$ZCLIP" query --tag work --limit 0 2>/dev/null)" \
    "--tag with --limit 0 → []"

section "flag order is irrelevant"
seed_corpus
"$ZCLIP" tag 2 work >/dev/null 2>&1
assert_eq \
    "$("$ZCLIP" query --tag work --limit 1 2>/dev/null)" \
    "$("$ZCLIP" query --limit 1 --tag work 2>/dev/null)" \
    "--tag/--limit and --limit/--tag agree"

section "malformed invocations → exit 2"
seed_corpus
assert_exit 2 "--tag with no value → exit 2"      -- "$ZCLIP" query --tag
assert_exit 2 "unknown positional arg → exit 2"   -- "$ZCLIP" query foo
assert_exit 2 "extra arg after --tag → exit 2"    -- "$ZCLIP" query --tag work extra
assert_exit 2 "unknown flag → exit 2"             -- "$ZCLIP" query --kind url
assert_exit 2 "--limit with no value → exit 2"    -- "$ZCLIP" query --limit
assert_exit 2 "trailing bare --limit → exit 2"    -- "$ZCLIP" query --tag work --limit
assert_exit 2 "negative --limit → exit 2"         -- "$ZCLIP" query --limit -1
assert_exit 2 "non-numeric --limit → exit 2"      -- "$ZCLIP" query --limit abc
assert_exit 2 "fractional --limit → exit 2"       -- "$ZCLIP" query --limit 1.5
assert_exit 2 "--limit past u32 → exit 2"         -- "$ZCLIP" query --limit 4294967296
assert_exit 2 "--limit given twice → exit 2"      -- "$ZCLIP" query --limit 1 --limit 2
assert_exit 2 "--tag given twice → exit 2"        -- "$ZCLIP" query --tag a --tag b
# A flag-shaped token is never a value: without this rule the tag binds to the
# literal "--limit" and the command exits 0 with [], hiding the typo.
assert_exit 2 "--tag eating a flag → exit 2"      -- "$ZCLIP" query --tag --limit 5
assert_exit 2 "--limit eating a flag → exit 2"    -- "$ZCLIP" query --limit --tag work

finish
