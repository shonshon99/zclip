#!/usr/bin/env bash
#
# Shared functional-test harness. Source from each test file:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides an isolated temp HOME (so the real ~/.local/share/zclip is never
# touched), entry seeding, assertions, daemon tracking, and best-effort
# clipboard save/restore.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZCLIP="$REPO_ROOT/zig-out/bin/zclip"
FIXTURES="$REPO_ROOT/tests/fixtures"
# Committed rather than generated, so image tests don't depend on which
# wallpapers a given macOS install ships. Larger than the 512px thumbnail cap,
# so a downscale that silently no-ops fails a dimension assertion.
SAMPLE_PNG="$FIXTURES/sample_1024x768.png"

if [[ ! -x "$ZCLIP" ]]; then
    echo "error: $ZCLIP not found — run 'zig build' first" >&2
    exit 1
fi

# zclip resolves its DB under $HOME (main.zig dbPath), so a throwaway HOME
# fully sandboxes storage.
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
    # Daemons first, so they stop touching the DB.
    local pid
    for pid in "${DAEMON_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done
    if [[ "$CLIP_SAVED" -eq 1 ]]; then
        printf '%s' "$CLIP_BACKUP" | pbcopy 2>/dev/null
    fi
    # ONLY the throwaway mktemp -d HOME. NEVER widen this to a shared dir
    # like ~/.local.
    rm -rf "$TMP_HOME"
}
trap cleanup EXIT

# --- DB helpers ------------------------------------------------------------

# Fresh DB seeded with one known entry (id=1). Each test calls this first.
reset_db() {
    # Leaf dir only — never the shared .local parent.
    rm -rf "$ZDIR"
    mkdir -p "$ZDIR"
    # There's no `zclip add`; `query` opens the DB, which runs the migrations
    # and creates the schema. Entries are then seeded with sqlite3 directly.
    "$ZCLIP" query >/dev/null 2>&1
    seed_entry 1 'hello world' 0
}

# seed_entry <id> <content> <copied_at>
seed_entry() {
    sqlite3 "$DB" \
        "INSERT INTO entries (id, content, hash, copied_at) VALUES ($1, '$2', x'00', $3);"
}

# seed_image_entry <id> <path> <copied_at> [width] [height]
#
# Fakes what the daemon writes: a content-less entries row plus its images row.
# The thumb blob is a stand-in, not a real PNG — tests needing decodable pixels
# go through the daemon and the pasteboard instead.
seed_image_entry() {
    local id="$1" path="$2" ts="$3" w="${4:-1024}" h="${5:-768}"
    sqlite3 "$DB" "
        INSERT INTO entries (id, kind, content, hash, copied_at)
        VALUES ($id, 'image', NULL, randomblob(32), $ts);
        INSERT INTO images (entry_id, path, uti, width, height, byte_len, thumb)
        VALUES ($id, '$path', 'public.png', $w, $h, 4242, x'89504E47');
    "
}

# Puts a PNG on the real pasteboard as image data, not a file reference.
# «class PNGf» is the four-char code for public.png, the daemon's first probe.
copy_image_to_clipboard() {
    osascript -e "set the clipboard to (read (POSIX file \"$1\") as «class PNGf»)" >/dev/null
}

query() { sqlite3 "$DB" "$1"; }

# png_dims <file> → "<width>|<height>", read from the file's own IHDR chunk.
# The DB stores no thumbnail dimensions.
png_dims() {
    sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null |
        awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "|" h}'
}

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

# Summary; exits nonzero if any test failed.
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
# A global rather than an echoed pid: `pid="$(start_daemon)"` would launch the
# daemon in a command-substitution subshell, making it a grandchild the main
# shell can't `wait` on — stop_daemon would return instantly and race the
# still-exiting process.
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
