#!/usr/bin/env bash
# Build (and cache) a static thumbnail for every wallpaper in the configured
# folder, then print "<source><TAB><thumb>" lines for the Settings cover-flow.
#
# Thumbs are 16:9 PNGs keyed on the source path; we regenerate only when the
# source is newer than its thumb, so this is instant after the first run. First
# frame for gif/webp via ImageMagick; one decoded frame for mp4/webm via ffmpeg.
set -u

WALLPAPER_DIR="$(cat "$HOME/.config/hypr/wallpaper-dir.conf" 2>/dev/null)"
[ -z "$WALLPAPER_DIR" ] && WALLPAPER_DIR="$HOME/Wallpapers/animated"
THUMB_DIR="$HOME/.cache/hypr-wallpaper-thumbs"
W=480; H=270
mkdir -p "$THUMB_DIR"

# Same file set + sort order as wallpaper-cycle.sh, so indices line up.
mapfile -t FILES < <(find "$WALLPAPER_DIR" -maxdepth 1 -type f \
    \( -name '*.gif' -o -name '*.webp' -o -name '*.webm' -o -name '*.mp4' \
       -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -size +0c | sort)

for f in "${FILES[@]}"; do
    key="$(printf '%s' "$f" | md5sum | cut -d' ' -f1)"
    thumb="$THUMB_DIR/$key.png"
    if [ ! -s "$thumb" ] || [ "$f" -nt "$thumb" ]; then
        ext="${f##*.}"; ext="${ext,,}"
        if [ "$ext" = "mp4" ] || [ "$ext" = "webm" ]; then
            ffmpeg -hide_banner -loglevel error -y -i "$f" -frames:v 1 \
                -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H}" \
                "$thumb" </dev/null >/dev/null 2>&1
        else
            # [0] = first frame/layer (animated gif/webp or plain image alike)
            magick "${f}[0]" -resize "${W}x${H}^" -gravity center -extent "${W}x${H}" "$thumb" >/dev/null 2>&1
        fi
    fi
    [ -s "$thumb" ] && printf '%s\t%s\n' "$f" "$thumb"
done
