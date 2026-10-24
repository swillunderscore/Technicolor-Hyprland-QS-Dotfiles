#!/usr/bin/env bash
# Settings → Wallpaper "Shows in": move one wallpaper into the folder's light/
# or dark/ subfolder, or back into the folder itself (= both modes). See
# wallpaper-list.sh. Prints the new path.
#   wallpaper-mode-move.sh <wallpaper> light|dark|both
set -u
SRC="${1:-}"; TO="${2:-}"
DIR="$(cat "$HOME/.config/hypr/wallpaper-dir.conf" 2>/dev/null)"
[ -z "$DIR" ] && DIR="$HOME/Wallpapers/animated"
case "$TO" in
    light|dark) DEST="$DIR/$TO" ;;
    both)       DEST="$DIR" ;;
    *)          echo "usage: $0 <wallpaper> light|dark|both" >&2; exit 2 ;;
esac
# Only wallpapers from the folder itself or its light/ and dark/.
case "$SRC" in
    "$DIR"/*.*|"$DIR"/light/*.*|"$DIR"/dark/*.*) ;;
    *) echo "not in $DIR: $SRC" >&2; exit 1 ;;
esac
[ -f "$SRC" ] || { echo "no such wallpaper: $SRC" >&2; exit 1; }
NEW="$DEST/$(basename "$SRC")"
[ "$SRC" = "$NEW" ] && { echo "$NEW"; exit 0; }
# Names must stay unique across all three: the pi and the phone get them
# flattened into one folder (wallpaper-push.sh).
for d in "$DIR" "$DIR/light" "$DIR/dark"; do
    other="$d/$(basename "$SRC")"
    [ "$other" != "$SRC" ] && [ -e "$other" ] && { echo "a wallpaper with that name is already in $d" >&2; exit 1; }
done
mkdir -p "$DEST" && mv -n -- "$SRC" "$NEW" || exit 1
# The one on screen moved: keep pointing at it, so the next change still
# transitions from it and pause/unpause still find it.
[ "$(cat /tmp/wallpaper-current-path 2>/dev/null)" = "$SRC" ] && echo "$NEW" > /tmp/wallpaper-current-path
echo "$NEW"
