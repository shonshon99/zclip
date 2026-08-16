#!/usr/bin/env bash
#
# Functional tests for `zclip daemon`.
#
# WARNING: the daemon polls the REAL system clipboard. This script stashes your
# clipboard up front and restores it on exit — DON'T copy anything else while it
# runs, or you'll race the daemon and may see spurious captured entries.
#
# Poll interval is 1s, so capture tests sleep ~2s; the whole script takes ~10s.
#
# Run:  ./tests/daemon_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

save_clipboard # cleanup() restores it

LOG="$TMP_HOME/daemon.log"
LOG2="$TMP_HOME/daemon2.log"

section "missing storage dir → actionable hint, nonzero exit"
# Wipe WITHOUT recreating: the daemon must refuse to auto-create.
rm -rf "$ZDIR"
out="$("$ZCLIP" daemon 2>&1)"
code=$?
assert_contains "$out" "storage directory missing" "prints missing-dir hint"
assert_eq "true" "$([[ "$code" -ne 0 ]] && echo true || echo false)" \
    "exits nonzero when dir absent (got $code)"

section "daemon captures a new clipboard entry into the DB"
reset_db
start_daemon "$LOG"; pid=$DAEMON_PID
sleep 1 # let it take the lock and snapshot the initial changeCount
printf 'DAEMON_CAPTURE_X1' | pbcopy
sleep 2 # a full poll tick plus margin
assert_eq 1 "$(query "SELECT COUNT(*) FROM entries WHERE content='DAEMON_CAPTURE_X1';")" \
    "copied text landed in entries"
stop_daemon "$pid"

section "duplicate copy bumps copied_at instead of inserting a new row"
reset_db
start_daemon "$LOG"; pid=$DAEMON_PID
sleep 1
printf 'DUP_TEXT_Y2' | pbcopy
sleep 2
printf 'something-else' | pbcopy # advance changeCount
sleep 2
printf 'DUP_TEXT_Y2' | pbcopy # same content again → upsert by hash
sleep 2
assert_eq 1 "$(query "SELECT COUNT(*) FROM entries WHERE content='DUP_TEXT_Y2';")" \
    "repeated content stays a single row (upsertByHash)"
stop_daemon "$pid"

section "second instance refuses to start (single-instance lock)"
reset_db
start_daemon "$LOG"; pid=$DAEMON_PID
sleep 1
# Foreground: should hit the pidfile flock and bail fast.
out2="$("$ZCLIP" daemon 2>&1)"
assert_contains "$out2" "another instance is already running" \
    "second daemon reports the lock"
stop_daemon "$pid"

section "SIGTERM triggers clean shutdown"
reset_db
start_daemon "$LOG"; pid=$DAEMON_PID
sleep 1
stop_daemon "$pid" TERM
assert_contains "$(cat "$LOG")" "shutting down" "logged clean shutdown"
assert_eq "false" "$(kill -0 "$pid" 2>/dev/null && echo true || echo false)" \
    "process is gone after SIGTERM"

section "daemon ignores its own 'zclip use' write (origin marker)"
reset_db
seed_entry 5 'ORIGIN_SKIP_Z3' 0
start_daemon "$LOG"; pid=$DAEMON_PID
sleep 1
# `use` writes content tagged dev.zclip.origin; the daemon must not re-capture it.
"$ZCLIP" use 5 >/dev/null 2>&1
sleep 2
# One row (the seeded one) — no daemon-inserted dup.
assert_eq 1 "$(query "SELECT COUNT(*) FROM entries WHERE content='ORIGIN_SKIP_Z3';")" \
    "no duplicate entry from the daemon's own paste"
stop_daemon "$pid"

finish
