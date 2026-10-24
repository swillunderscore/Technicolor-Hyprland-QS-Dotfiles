#!/usr/bin/env bash
# The wallpaper list every script shares. ONE file set and ONE order, so a
# sequence index means the same wallpaper to the cycle, the Settings thumbnails
# and a mirror (the phone) — if two of them disagree, both sides show "the
# right" wallpaper and nothing reports it.
#
# Light/dark mode: wallpapers loose in the folder show in both modes; the ones
# in its light/ and dark/ subfolders only in that mode.
#   wallpaper-list.sh             the current mode's list (theme-mode.py now)
#   wallpaper-list.sh light|dark  that mode's list
#   wallpaper-list.sh all         every wallpaper
# Absolute paths, one per line, sorted by their path inside the folder.
set -u
DIR="$(cat "$HOME/.config/hypr/wallpaper-dir.conf" 2>/dev/null)"
[ -z "$DIR" ] && DIR="$HOME/Wallpapers/animated"
MODE="${1:-}"
[ -z "$MODE" ] && MODE="$("$HOME/.config/hypr/theme-mode.py" now 2>/dev/null)"
case "$MODE" in
    light|dark) SUBS=("$MODE") ;;
    all)        SUBS=(light dark) ;;
    *)          SUBS=() ;;   # mode unknown: the loose ones still work
esac

list_dir() {
    find "$1" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.webp' -o -name '*.webm' \
        -o -name '*.mp4' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -size +0c
}
{
    list_dir "$DIR"
    for s in "${SUBS[@]}"; do [ -d "$DIR/$s" ] && list_dir "$DIR/$s"; done
} | LC_ALL=C sort
