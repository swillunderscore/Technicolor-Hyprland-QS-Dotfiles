#!/usr/bin/env bash
# Compose the system-wide hyprglass tint_color from glass-tint.conf and apply it
# (live + persisted, via hyprglass-set.sh). Settings → Glass → Tint writes the
# config; the wallpaper pipeline re-runs this so "wallpaper" mode follows the
# palette (and the Colors-tab HSV sliders, since those are baked into colors.env).
#
# glass-tint.conf:  MODE=wallpaper|custom   STRENGTH=0..1   COLOR=rrggbb (custom)
set -u
CONF="$HOME/.config/hypr/glass-tint.conf"
mode="wallpaper"; strength="0"; color="ffffff"
if [ -f "$CONF" ]; then
    while IFS='=' read -r k v; do
        case "$k" in MODE) mode="$v";; STRENGTH) strength="$v";; COLOR) color="$(printf '%s' "$v" | tr -d ' #')";; esac
    done < "$CONF"
fi

aa="$(awk "BEGIN{printf \"%02x\", int($strength*255+0.5)}" 2>/dev/null)"
[ -z "$aa" ] && aa="00"

if [ "$aa" = "00" ]; then
    tint="0x00000000"
else
    if [ "$mode" = "wallpaper" ]; then
        rgb="$(grep '^FOCUSED=' "$HOME/.config/quickshell/colors.env" 2>/dev/null | cut -d= -f2 | tr -d ' #')"
        [ -z "$rgb" ] && rgb="$color"
    else
        rgb="$color"
    fi
    tint="0x${aa}${rgb}"
fi

"$HOME/.config/hypr/hyprglass-set.sh" tint_color "$tint" >/dev/null 2>&1
