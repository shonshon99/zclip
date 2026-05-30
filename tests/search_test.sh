#!/usr/bin/env bash
#
# Functional tests for `zclip search`. Pure DB read — no pasteboard.
# Matching is `content LIKE %keyword%`, ordered by copied_at DESC, LIMIT 50.
# Run:  ./tests/search_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Seed a known corpus. reset_db already inserts id=1 'hello world' @0.
seed_corpus() {
    reset_db
    seed_entry 2 'goodbye world' 10
    seed_entry 3 'apple pie'     20
    seed_entry 4 'HELLO CAPS'    30
}

section "substring match returns the entry"
seed_corpus
out="$("$ZCLIP" search apple 2>&1)"
assert_contains "$out" "id=3" "found 'apple pie' by substring"

section "keyword matching multiple rows returns all of them"
seed_corpus
out="$("$ZCLIP" search world 2>&1)"
assert_contains "$out" "id=1" "world → hello world"
assert_contains "$out" "id=2" "world → goodbye world"

section "LIKE is case-insensitive (ASCII)"
seed_corpus
out="$("$ZCLIP" search hello 2>&1)"
assert_contains "$out" "id=1" "lowercase query matches 'hello world'"
assert_contains "$out" "id=4" "lowercase query matches 'HELLO CAPS'"

section "results ordered newest-first (copied_at DESC)"
seed_corpus
# Both 'world' rows match; id=2 (copied_at=10) is newer than id=1 (0),
# so id=2 must appear before id=1 in output.
out="$("$ZCLIP" search world 2>&1)"
pos2=$(echo "$out" | grep -n "id=2" | cut -d: -f1)
pos1=$(echo "$out" | grep -n "id=1" | cut -d: -f1)
assert_eq "true" "$([[ "$pos2" -lt "$pos1" ]] && echo true || echo false)" \
    "newer entry (id=2) listed above older (id=1)"

section "no match prints a friendly message, exits 0"
seed_corpus
out="$("$ZCLIP" search zzzznope 2>&1)"
assert_contains "$out" "no matches for zzzznope" "reports no matches"
assert_exit 0 "no-match still exits 0" -- "$ZCLIP" search zzzznope

section "missing keyword → exit 2"
seed_corpus
assert_exit 2 "search with no <keyword> → exit 2" -- "$ZCLIP" search

section "limit caps results at 50"
reset_db
# Seed 60 rows all containing 'bulk'; search must return at most 50 lines.
for i in $(seq 100 159); do seed_entry "$i" "bulk $i" "$i"; done
count="$("$ZCLIP" search bulk 2>&1 | grep -c 'id=')"
assert_eq "true" "$([[ "$count" -le 50 ]] && echo true || echo false)" \
    "at most 50 rows returned (got $count)"

finish
