#!/usr/bin/env bash
#
# Functional tests for `zclip tag`. Pure DB command — no pasteboard.
# Run:  ./tests/tag_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "tag attaches to an entry"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
assert_eq 1 "$(query "SELECT COUNT(*) FROM tags WHERE name='work';")" \
    "tags row created"
assert_eq 1 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "entry_tags link created"

section "tag is idempotent (same tag twice → one link)"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 1 work >/dev/null 2>&1
assert_eq 1 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "no duplicate link row"
assert_eq 1 "$(query "SELECT COUNT(*) FROM tags WHERE name='work';")" \
    "no duplicate tag row"

section "case-insensitive: Work / WORK collapse to one tag"
reset_db
"$ZCLIP" tag 1 Work >/dev/null 2>&1
"$ZCLIP" tag 1 WORK >/dev/null 2>&1
assert_eq 1 "$(query "SELECT COUNT(*) FROM tags;")" \
    "single tags row across case variants"
assert_eq "work" "$(query "SELECT name FROM tags LIMIT 1;")" \
    "stored name normalized to lowercase"

section "whitespace is trimmed before storing"
reset_db
"$ZCLIP" tag 1 "  spaced  " >/dev/null 2>&1
assert_eq 1 "$(query "SELECT COUNT(*) FROM tags WHERE name='spaced';")" \
    "leading/trailing whitespace stripped"

section "two distinct tags on one entry"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 1 urgent >/dev/null 2>&1
assert_eq 2 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "two links on entry 1"

section "exit codes for bad input"
reset_db
assert_exit 2 "missing <id> → exit 2"   -- "$ZCLIP" tag
assert_exit 2 "missing <tag> → exit 2"  -- "$ZCLIP" tag 1
assert_exit 2 "non-numeric id → exit 2" -- "$ZCLIP" tag abc work
assert_exit 2 "empty tag (whitespace only) → exit 2" -- "$ZCLIP" tag 1 "   "

section "tagging a non-existent entry fails (FK enforced)"
reset_db
assert_exit 1 "unknown entry id → exit 1" -- "$ZCLIP" tag 999 work
assert_eq 0 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=999;")" \
    "no orphan link row written"

finish
