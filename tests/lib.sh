#!/usr/bin/env bash
#
# Shared functional-test harness for zclip. Source this from each test file:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides: isolated temp HOME (so zclip's DB never touches the real
# ~/.local/share/zclip), schema bootstrap + entry seeding, assertion helpers,
# background-daemon tracking, and best-effort clipboard save/restore for the
# tests that exercise the real NSPasteboard.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZCLIP="$REPO_ROOT/zig-out/bin/zclip"

if [[ ! -x "$ZCLIP" ]]; then
    echo "error: $ZCLIP not found — run 'zig build' first" >&2
    exit 1
fi

# Isolated HOME. zclip resolves its DB as $HOME/.local/share/zclip/history.db
# (main.zig dbPath), so a throwaway HOME fully sandboxes storage.
TMP_HOME="$(mktemp -d)"
export HOME="$TMP_HOME"
DB="$TMP_HOME/.local/share/zclip/history.db"
ZDIR="$TMP_HOME/.local/share/zclip"

PASS=0
FAIL=0

# Daemons launched in the background, killed on exit.
DAEMON_PIDS=()
# Whether we stashed the real clipboard and owe a restore.
CLIP_SAVED=0
CLIP_BACKUP=""

# --- cleanup ---------------------------------------------------------------

cleanup() {
    # Kill any tracked background daemon first so it stops touching the DB.
    local pid
    for pid in "${DAEMON_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done
    # Restore the user's clipboard if a test stashed it.
    if [[ "$CLIP_SAVED" -eq 1 ]]; then
        printf '%s' "$CLIP_BACKUP" | pbcopy 2>/dev/null
    fi
    # Remove ONLY the throwaway temp HOME (created by mktemp -d, ours alone).
    # NEVER widen this to a shared dir like ~/.local.
    rm -rf "$TMP_HOME"
}
trap cleanup EXIT

# --- DB helpers ------------------------------------------------------------

# Fresh DB seeded with one known entry (id=1). Each test calls this first.
reset_db() {
    # Scope the wipe to zclip's leaf dir only — never the shared .local parent.
    rm -rf "$ZDIR"
    mkdir -p "$ZDIR"
    # No `zclip add` exists; `search` opens the DB and runs the migration
    # runner, creating the schema. Then seed entries directly with sqlite3.
    "$ZCLIP" search __bootstrap__ >/dev/null 2>&1
    seed_entry 1 'hello world' 0
}

# seed_entry <id> <content> <copied_at>
seed_entry() {
    sqlite3 "$DB" \
        "INSERT INTO entries (id, content, hash, copied_at) VALUES ($1, '$2', x'00', $3);"
}

# query <sql> → prints scalar result
query() { sqlite3 "$DB" "$1"; }

# --- assertions ------------------------------------------------------------

# assert_eq <expected> <actual> <message>
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        echo "  ok: $3"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $3 (expected '$1', got '$2')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        echo "  ok: $3"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $3 (output missing '$2')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_exit <expected_code> <message> -- <cmd...>
assert_exit() {
    local expected="$1" msg="$2"
    shift 3 # drop expected, msg, literal "--"
    "$@" >/dev/null 2>&1
    assert_eq "$expected" "$?" "$msg"
}

section() { echo; echo "== $1 =="; }

# finish: print summary, exit nonzero if any test failed (CI-friendly).
finish() {
    echo
    echo "-------------------------------------"
    echo "passed: $PASS   failed: $FAIL"
    [[ "$FAIL" -eq 0 ]]
}

# --- clipboard (real NSPasteboard) -----------------------------------------

# Stash the user's current clipboard text once; cleanup restores it.
save_clipboard() {
    if [[ "$CLIP_SAVED" -eq 0 ]]; then
        CLIP_BACKUP="$(pbpaste 2>/dev/null)"
        CLIP_SAVED=1
    fi
}

# --- background daemon -----------------------------------------------------

# start_daemon <logfile> → sets global DAEMON_PID, tracks it for cleanup.
#
# Sets a global rather than echoing the pid: a `pid="$(start_daemon)"` capture
# would launch the daemon inside a command-substitution subshell, making it a
# grandchild the main shell can't `wait` on — `stop_daemon`'s wait would return
# instantly and race the still-exiting process.
start_daemon() {
    "$ZCLIP" daemon >"$1" 2>&1 &
    DAEMON_PID=$!
    DAEMON_PIDS+=("$DAEMON_PID")
}

# stop_daemon <pid> [signal] — default TERM; waits for it to exit.
stop_daemon() {
    local pid="$1" sig="${2:-TERM}"
    kill -"$sig" "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}
