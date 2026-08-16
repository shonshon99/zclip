#!/usr/bin/env bash
#
# Functional tests for image entries: daemon capture, `zclip thumb`,
# `zclip use` on an image, and the JSON shape `query` emits for one.
#
# WARNING: this suite writes an IMAGE to the REAL system clipboard. It stashes
# your clipboard up front and restores it on exit, but the restore is
# plain-text only — whatever you had copied comes back as text, or as nothing
# if it wasn't text. Don't copy anything else while it runs.
#
# Run:  ./tests/image_test.sh   (from repo root, after `zig build`)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

save_clipboard # cleanup() restores it

# --- daemon capture ---------------------------------------------------------

section "daemon stores an image: original on disk, thumbnail in the DB"
reset_db
log="$TMP_HOME/daemon.log"
start_daemon "$log"
sleep 1
copy_image_to_clipboard "$SAMPLE_PNG"
sleep 2
stop_daemon "$DAEMON_PID"

assert_eq "1" "$(query "SELECT count(*) FROM entries WHERE kind='image';")" \
    "one image entry recorded"
assert_eq "public.png" "$(query "SELECT uti FROM images;")" \
    "captured as PNG (probe order prefers it over TIFF)"
assert_eq "1024|768" "$(query "SELECT width || '|' || height FROM images;")" \
    "original dimensions stored, not the thumbnail's"
assert_eq "true" \
    "$([[ "$(query "SELECT length(thumb) FROM images;")" -gt 0 ]] && echo true || echo false)" \
    "thumbnail blob is non-empty"
# Decode the stored blob rather than trusting a number written beside it —
# proves ImageIO actually downscaled and emitted a valid PNG.
assert_eq "512|384" \
    "$(png_dims "$("$ZCLIP" thumb "$(query "SELECT id FROM entries WHERE kind='image';")")")" \
    "stored thumbnail is a real PNG, capped at 512px, aspect preserved"
assert_eq "text" "$(query "SELECT kind FROM entries WHERE id=1;")" \
    "seeded text entry still reads back as kind=text"

section "the original is written to \$ZDIR/images, content-addressed"
img_path="$(query "SELECT path FROM images;")"
assert_eq "true" "$([[ -f "$img_path" ]] && echo true || echo false)" \
    "file exists at the recorded path"
assert_contains "$img_path" "$ZDIR/images/" "stored under the images dir"
# Filename is the sha256 of the bytes, so it must match what the DB hashed.
assert_eq "$(query "SELECT lower(hex(hash)) FROM entries WHERE kind='image';").png" \
    "$(basename "$img_path")" "filename is the content hash"
assert_eq "$(stat -f%z "$SAMPLE_PNG")" "$(stat -f%z "$img_path")" \
    "archived bytes are the untouched original, not the thumbnail"

section "re-copying the same image bumps, never duplicates"
before_ts="$(query "SELECT copied_at FROM entries WHERE kind='image';")"
sqlite3 "$DB" "UPDATE entries SET copied_at=0 WHERE kind='image';"
start_daemon "$log"
sleep 1
copy_image_to_clipboard "$SAMPLE_PNG"
sleep 2
stop_daemon "$DAEMON_PID"
assert_eq "1" "$(query "SELECT count(*) FROM entries WHERE kind='image';")" \
    "still one image entry (dedup by hash)"
assert_eq "true" \
    "$([[ "$(query "SELECT copied_at FROM entries WHERE kind='image';")" -gt 0 ]] && echo true || echo false)" \
    "copied_at bumped back up from 0"

section "use on an image puts the original back without re-capturing it"
img_id="$(query "SELECT id FROM entries WHERE kind='image';")"
start_daemon "$log"
sleep 1
"$ZCLIP" use "$img_id" >/dev/null 2>&1
sleep 2
stop_daemon "$DAEMON_PID"
assert_eq "2" "$(query "SELECT count(*) FROM entries;")" \
    "no new entry — dev.zclip.origin kept the daemon off its own write"

# --- query JSON -------------------------------------------------------------

section "query emits kind + dimensions for images, content for text"
reset_db
seed_image_entry 2 '/tmp/zclip-fake.png' 5
out="$("$ZCLIP" query)"
assert_contains "$out" '"kind":"image"' "image row tagged kind=image"
assert_contains "$out" '"width":1024,"height":768' "dimensions present for the label"
assert_contains "$out" '"path":"/tmp/zclip-fake.png"' "path to the original present"
assert_contains "$out" '"kind":"text","content":"hello world"' "text rows unchanged apart from kind"

section "image rows carry no content key, text rows no image keys"
# emit_null_optional_fields=false — absent, not null, so clients key off
# presence instead of null-checking every field.
assert_eq "0" "$(printf '%s' "$out" | grep -c '"content":null')" "no null content emitted"
assert_eq "0" "$(printf '%s' "$out" | grep -c '"width":null')" "no null width emitted"

# --- thumb ------------------------------------------------------------------

section "thumb writes the blob to the cache dir and prints its path"
thumb_path="$("$ZCLIP" thumb 2)"
assert_eq "$ZDIR/cache/2.png" "$thumb_path" "prints the cache path"
assert_eq "true" "$([[ -f "$thumb_path" ]] && echo true || echo false)" "file written"
assert_eq "$(query "SELECT length(thumb) FROM images WHERE entry_id=2;")" \
    "$(stat -f%z "$thumb_path")" "file holds exactly the stored blob"

section "thumb is idempotent and serves the cached file on repeat calls"
# Blank the blob: a second call still printing a valid path proves it never
# went back to the DB.
sqlite3 "$DB" "UPDATE images SET thumb=x'00' WHERE entry_id=2;"
assert_eq "$thumb_path" "$("$ZCLIP" thumb 2)" "same path returned"
assert_eq "true" \
    "$([[ "$(stat -f%z "$thumb_path")" -gt 1 ]] && echo true || echo false)" \
    "cached file untouched by the blob edit"

section "thumb on a text entry → exit 1 with message"
out="$("$ZCLIP" thumb 1 2>&1)"
assert_contains "$out" "no image entry with id 1" "reports non-image entry"
assert_exit 1 "text entry exits 1" -- "$ZCLIP" thumb 1

section "thumb bad input → exit 2"
assert_exit 2 "missing <id> → exit 2" -- "$ZCLIP" thumb
assert_exit 2 "non-numeric id → exit 2" -- "$ZCLIP" thumb abc

section "use on an image whose file has vanished → exit 1"
reset_db
seed_image_entry 2 "$ZDIR/images/gone.png" 5
out="$("$ZCLIP" use 2 2>&1)"
assert_contains "$out" "image file missing" "reports the missing original"
assert_exit 1 "missing file exits 1" -- "$ZCLIP" use 2

finish
