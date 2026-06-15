#!/usr/bin/env bash
# Decode only the HEAVY animated wallpapers (>HEAVY_FRAMES frames) into awww's
# cache, and record them as the "keep list".
#
# Why only the heavy ones: awww 0.12.1's per-apply latency grows ~linearly with
# the number of files in its cache (~0.77ms each), so a large cache makes the
# 21-frame reveal laggy. Caching everything is self-defeating. Heavy gifs are
# the only ones worth pinning — cold-decoding them costs seconds (the 841-frame
# one ~20s), while light gifs re-decode in a few hundred ms, hidden by the
# reveal. wallpaper-cycle.sh prunes the cache after each change down to the
# current wallpaper plus this keep list.
#
# Run once, and again after adding/removing wallpapers.
set -u

ANIM_DIR="$(cat "$HOME/.config/hypr/wallpaper-dir.conf" 2>/dev/null)"
[ -z "$ANIM_DIR" ] && ANIM_DIR="$HOME/Wallpapers/animated"
KEEP_LIST="$HOME/.cache/hypr-heavy-wallpapers.txt"
HEAVY_FRAMES=60
FLAGS=(--fill-color 000000 --resize crop --filter Nearest -t none --transition-fps 255)
CUR="$(cat /tmp/wallpaper-current-path 2>/dev/null || true)"

echo "scanning for heavy gifs (>$HEAVY_FRAMES frames)..."
: > "$KEEP_LIST"
shopt -s nullglob nocaseglob
for f in "$ANIM_DIR"/*.webp "$ANIM_DIR"/*.gif; do
    n="$(identify "$f" 2>/dev/null | wc -l)"
    [ "$n" -gt "$HEAVY_FRAMES" ] && printf '%s\n' "$f" >> "$KEEP_LIST"
done

count="$(wc -l < "$KEEP_LIST")"
echo "found $count heavy wallpapers; caching them (each is briefly displayed)..."
while IFS= read -r f; do
    awww img "$f" "${FLAGS[@]}" >/dev/null 2>&1
    echo "  cached $(basename "$f")"
done < "$KEEP_LIST"

# Restore whatever was showing.
[ -n "$CUR" ] && [ -f "$CUR" ] && awww img "$CUR" "${FLAGS[@]}" >/dev/null 2>&1
echo "done. awww cache: $(du -sh "$HOME/.cache/awww" 2>/dev/null | cut -f1); keep-list: $KEEP_LIST"
