#!/usr/bin/env bash
#
# Run every zclip functional suite. Exits nonzero if any suite fails.
#
#   ./tests/run_all.sh          # all suites
#   ./tests/run_all.sh --safe   # skip suites that touch the real clipboard
#                                 (use, daemon)
#
# Pasteboard-touching suites stash/restore your clipboard, but --safe lets you
# run in CI or while working without any clipboard interference.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SAFE_ONLY=0
[[ "${1:-}" == "--safe" ]] && SAFE_ONLY=1

suites=(tag_test.sh search_test.sh)
if [[ "$SAFE_ONLY" -eq 0 ]]; then
    suites+=(use_test.sh daemon_test.sh)
fi

rc=0
for s in "${suites[@]}"; do
    echo "############################################"
    echo "# $s"
    echo "############################################"
    if ! bash "$DIR/$s"; then
        rc=1
    fi
    echo
done

if [[ "$rc" -eq 0 ]]; then
    echo "ALL SUITES PASSED"
else
    echo "SOME SUITES FAILED"
fi
exit "$rc"
