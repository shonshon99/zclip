#!/usr/bin/env bash
#
# End-to-end smoke test for zclip.
#
# Exercises the full daemon ↔ DB ↔ CLI loop on real macOS infrastructure:
#   1. Builds the binary.
#   2. Starts the daemon (single-instance flock, real NSPasteboard polling).
#   3. Mutates the clipboard via `pbcopy` twice; verifies the daemon inserted
#      both entries by searching the DB.
#   4. Runs `zclip use <id>` to write an entry back; verifies via `pbpaste`.
#   5. Confirms the origin marker prevents a feedback loop — the daemon
#      should log exactly 2 inserts (not 3), because its own `use` write
#      is tagged `dev.zclip.origin` and skipped on the next poll.
#
# SIDE EFFECTS (no isolation — DB path is hardcoded in src/db.zig):
#   - Inserts 2 rows into ~/.local/share/zclip/history.db.
#   - Overwrites the system clipboard contents (you lose whatever was there).
#   - Requires no other zclip daemon to be running (flock conflict).
#
# Usage:  ./scripts/smoke.sh
# Exit:   0 on full pass, 1 on any check fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/zig-out/bin/zclip"
DAEMON_LOG="$(mktemp -t zclip-smoke.XXXXXX.log)"
TAG="smoke-$$"

cleanup() {
    if [[ -n "${DPID:-}" ]] && kill -0 "$DPID" 2>/dev/null; then
        kill "$DPID" 2>/dev/null || true
        wait "$DPID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> build"
(cd "$REPO_ROOT" && zig build)

echo "==> check no daemon already running"
if pgrep -f "$BIN daemon" >/dev/null; then
    fail "another zclip daemon is running; stop it first"
fi

echo "==> start daemon"
"$BIN" daemon >"$DAEMON_LOG" 2>&1 &
DPID=$!
sleep 1
kill -0 "$DPID" 2>/dev/null || fail "daemon died on startup. log:
$(cat "$DAEMON_LOG")"

echo "==> write two distinct values via pbcopy"
A="${TAG}-A"
B="${TAG}-B"
printf '%s' "$A" | pbcopy
sleep 1.5
printf '%s' "$B" | pbcopy
sleep 1.5

echo "==> verify both entries indexed"
"$BIN" search "$TAG" | grep -q "$A" || fail "entry A not in search results"
"$BIN" search "$TAG" | grep -q "$B" || fail "entry B not in search results"

echo "==> use entry A → expect pbpaste to return A"
ID_A="$("$BIN" search "$A" | sed -n 's/.*id=\([0-9]*\).*/\1/p' | head -1)"
[[ -n "$ID_A" ]] || fail "could not parse id for entry A"
"$BIN" use "$ID_A"
sleep 1
CLIP="$(pbpaste)"
[[ "$CLIP" == "$A" ]] || fail "pbpaste returned [$CLIP], expected [$A]"

echo "==> verify origin marker suppressed daemon feedback loop"
INSERTS="$(grep -c '+ new entry' "$DAEMON_LOG" || true)"
[[ "$INSERTS" == "2" ]] || fail "expected 2 inserts in daemon log, got $INSERTS. log:
$(cat "$DAEMON_LOG")"

echo "==> PASS"
echo "daemon log: $DAEMON_LOG"
