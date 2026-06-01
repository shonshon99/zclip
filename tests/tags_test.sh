#!/usr/bin/env bash
#
# Functional tests for `zclip tags`. Pure DB read — no pasteboard. Emits a
# minified JSON array of tag-name strings, alphabetical. Feeds the Raycast
# tag-filter dropdown. Run: ./tests/tags_test.sh (after `zig build`).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "no tags → empty array, exit 0"
reset_db
out="$("$ZCLIP" tags 2>/dev/null)"
assert_eq "[]" "$out" "no tags → []"
assert_exit 0 "empty still exits 0" -- "$ZCLIP" tags

section "lists every tag name, alphabetical"
reset_db
seed_entry 2 'second' 10
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 2 home >/dev/null 2>&1
out="$("$ZCLIP" tags 2>/dev/null)"
assert_eq '["home","work"]' "$out" "alphabetical JSON string array"

section "each tag appears once regardless of how many entries carry it"
reset_db
seed_entry 2 'second' 10
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 2 work >/dev/null 2>&1
out="$("$ZCLIP" tags 2>/dev/null)"
assert_eq '["work"]' "$out" "tag deduped across entries"

section "names emitted lowercased (tag command lowercases before insert)"
reset_db
"$ZCLIP" tag 1 WORK >/dev/null 2>&1
out="$("$ZCLIP" tags 2>/dev/null)"
assert_eq '["work"]' "$out" "stored + emitted lowercase"

finish
