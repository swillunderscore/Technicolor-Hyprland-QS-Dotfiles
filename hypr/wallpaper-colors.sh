#!/bin/bash
echo "COLORS SCRIPT STARTED $(date)" >> /tmp/cycle-debug.log
# ============================================================
# wallpaper-colors.sh
# Called after wallpaper changes. Extracts colors.
# Quickshell watches colors.env directly — no bar restart needed.
# ============================================================
WALLPAPER_DIR="$HOME/Wallpapers/animated"
STATE_FILE="/tmp/wallpaper-current-index"
# Figure out current wallpaper
mapfile -t WALLPAPERS < <(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.webp' -o -name '*.webm' -o -name '*.mp4' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -size +0c | sort)
INDEX=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
CURRENT="${WALLPAPERS[$INDEX]}"
[ -z "$CURRENT" ] && exit 0
# Extract colors — quickshell watches colors.env automatically
python3 ~/.config/hypr/wallpaper-colors.py "$CURRENT"
