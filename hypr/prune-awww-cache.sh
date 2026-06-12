#!/bin/bash
# Prune awww's cache down to the current wallpaper plus the pinned heavy gifs
# (precache-wallpapers.sh writes the keep-list). awww 0.12.1's per-`awww img`
# latency grows ~linearly with the number of files in its cache (~0.77ms each),
# so an unbounded cache makes the 21-frame reveal laggy. Reveal-frame BMPs and
# light gifs re-decode cheaply, so they aren't kept.
#
# wallpaper-cycle.sh invokes this detached (setsid) after each change. The short
# sleep keeps the work clear of the animation the final apply just started —
# running it inline there caused a small post-transition hitch. Pure bash, no
# per-file subprocesses, so it's a few ms of work.
#
# Usage: prune-awww-cache.sh <current-wallpaper-path>
chosen="$1"
awww_cache="$HOME/.cache/awww/$(awww --version 2>/dev/null | awk '{print $2}')"
keep_list="$HOME/.cache/hypr-heavy-wallpapers.txt"
[ -d "$awww_cache" ] || exit 0

sleep 1   # let the new animation settle before churning the cache dir

declare -A keep
[ -n "$chosen" ] && keep["${chosen//\//_}"]=1
if [ -f "$keep_list" ]; then
    while IFS= read -r p; do
        [ -n "$p" ] && keep["${p//\//_}"]=1
    done < "$keep_list"
fi

shopt -s nullglob
for cf in "$awww_cache"/*_crop_Argb; do
    base="${cf##*/}"        # basename, no subprocess
    key="${base%%__*}"      # strip __<WxH>_crop_Argb; keys contain no '__'
    [ -n "${keep[$key]:-}" ] || rm -f "$cf"
done
