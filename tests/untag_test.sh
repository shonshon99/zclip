#!/usr/bin/env bash
#
# Functional tests for `zclip untag`. Pure DB command — no pasteboard.
# Run:  ./tests/untag_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "untag detaches a tag from an entry"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" untag 1 work >/dev/null 2>&1
assert_eq 0 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "entry_tags link removed"
assert_eq 1 "$(query "SELECT COUNT(*) FROM tags WHERE name='work';")" \
    "tags row itself retained"

section "untag leaves other tags on the entry intact"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" tag 1 urgent >/dev/null 2>&1
"$ZCLIP" untag 1 work >/dev/null 2>&1
assert_eq 1 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "only the named link removed"
assert_eq "urgent" "$(query "SELECT t.name FROM tags t JOIN entry_tags et ON et.tag_id=t.id WHERE et.entry_id=1;")" \
    "remaining link is the other tag"

section "re-untag is a no-op (exit 0)"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" untag 1 work >/dev/null 2>&1
assert_exit 0 "second untag of same tag → exit 0" -- "$ZCLIP" untag 1 work
assert_eq 0 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "still detached after re-untag"

section "untag of a never-created tag name is a no-op (exit 0)"
reset_db
assert_exit 0 "unknown tag name → exit 0" -- "$ZCLIP" untag 1 ghost
assert_eq 0 "$(query "SELECT COUNT(*) FROM tags WHERE name='ghost';")" \
    "no phantom tags row created"

section "untag normalizes case and whitespace like tag"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
"$ZCLIP" untag 1 "  WORK  " >/dev/null 2>&1
assert_eq 0 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "mixed-case/whitespace arg matches stored 'work'"

section "exit codes for bad input"
reset_db
assert_exit 2 "missing <id> → exit 2"   -- "$ZCLIP" untag
assert_exit 2 "missing <tag> → exit 2"  -- "$ZCLIP" untag 1
assert_exit 2 "non-numeric id → exit 2" -- "$ZCLIP" untag abc work
assert_exit 2 "empty tag (whitespace only) → exit 2" -- "$ZCLIP" untag 1 "   "

section "deleting an entry cascades its entry_tags rows (FK ON DELETE CASCADE)"
reset_db
"$ZCLIP" tag 1 work >/dev/null 2>&1
# foreign_keys is per-connection and OFF by default — turn it on for this
# raw delete so the cascade actually fires (mirrors Db.open's pragma).
sqlite3 "$DB" "PRAGMA foreign_keys=ON; DELETE FROM entries WHERE id=1;"
assert_eq 0 "$(query "SELECT COUNT(*) FROM entry_tags WHERE entry_id=1;")" \
    "orphan links cascaded away"

finish
