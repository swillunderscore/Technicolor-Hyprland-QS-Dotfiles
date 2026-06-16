#!/usr/bin/env bash
# Write the wofi font include from the UI font (~/.config/hypr/font.conf, default
# "SF Pro"). wofi/style.css @imports this; run at login (exec-once) and whenever
# Settings → System changes the font. font.css is gitignored + regenerated, so
# the font choice survives repo updates.
set -u
FONT="$(cat "$HOME/.config/hypr/font.conf" 2>/dev/null)"
[ -z "$FONT" ] && FONT="SF Pro"
printf '* { font-family: "%s", "SF Pro", sans-serif; }\n' "$FONT" > "$HOME/.config/hypr/wofi/font.css"
