#!/usr/bin/env bash
#
# Functional tests for `zclip use`.
#
# WARNING: `use` writes to the REAL system clipboard (NSPasteboard general).
# This script stashes your current clipboard up front and restores it on exit,
# but DON'T copy anything else while it runs. Plain-text only — non-text
# clipboard contents (images, files) cannot be restored.
#
# Run:  ./tests/use_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

save_clipboard # cleanup() restores it

section "use copies the entry content to the pasteboard"
reset_db
seed_entry 2 'PASTE_ME_42' 0
"$ZCLIP" use 2 >/dev/null 2>&1
assert_eq "PASTE_ME_42" "$(pbpaste)" "pasteboard holds entry content"

section "use bumps copied_at (touch)"
reset_db
# id=1 seeded with copied_at=0; after use it must be a real recent timestamp.
"$ZCLIP" use 1 >/dev/null 2>&1
new_ts="$(query "SELECT copied_at FROM entries WHERE id=1;")"
assert_eq "true" "$([[ "$new_ts" -gt 0 ]] && echo true || echo false)" \
    "copied_at updated from 0 to $new_ts"

section "use prints a confirmation line"
reset_db
out="$("$ZCLIP" use 1 2>&1)"
assert_contains "$out" "copied id=1" "confirmation mentions id"

section "unknown id → exit 1 with message"
reset_db
out="$("$ZCLIP" use 999 2>&1)"
assert_contains "$out" "no entry with id 999" "reports missing entry"
assert_exit 1 "unknown id exits 1" -- "$ZCLIP" use 999

section "bad input → exit 2"
reset_db
assert_exit 2 "missing <id> → exit 2"   -- "$ZCLIP" use
assert_exit 2 "non-numeric id → exit 2" -- "$ZCLIP" use abc

# dev.zclip.origin is a custom pasteboard UTI, unreadable from the shell. Its
# effect — the daemon skipping its own writes — is covered in daemon_test.sh.

finish
