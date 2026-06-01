#!/usr/bin/env bash
#
# Functional tests for `zclip query`. Pure DB read — no pasteboard.
# Emits a minified JSON array of {id, content} objects, newest first
# (copied_at DESC). `--tag <name>` filters to entries carrying that single
# tag (no comma-split, no AND). Run: ./tests/query_test.sh (after `zig build`).

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
    '[{"id":3,"content":"third"},{"id":2,"content":"second"},{"id":1,"content":"hello world"}]' \
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
    '[{"id":3,"content":"third"},{"id":1,"content":"hello world"}]' \
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

section "malformed invocations → exit 2"
seed_corpus
assert_exit 2 "--tag with no value → exit 2"      -- "$ZCLIP" query --tag
assert_exit 2 "unknown positional arg → exit 2"   -- "$ZCLIP" query foo
assert_exit 2 "extra arg after --tag → exit 2"    -- "$ZCLIP" query --tag work extra
assert_exit 2 "unknown flag → exit 2"             -- "$ZCLIP" query --kind url

finish
