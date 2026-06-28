#!/usr/bin/env bash
# Stash the window UNDER THE CURSOR on the special:minimized workspace (raycast
# via window-under-cursor.sh; falls back to the active window). Bound to
# SUPER+scroll — debounced so a fast scroll-wheel flick doesn't stack-minimize
# half the desktop in one motion.

LOCK="/tmp/hypr-minimize.lock"
DEBOUNCE_MS=350

now_ms() { date +%s%3N; }
if [ -f "$LOCK" ]; then
    last=$(cat "$LOCK" 2>/dev/null || echo 0)
    [ "$(( $(now_ms) - last ))" -lt "$DEBOUNCE_MS" ] && exit 0
fi
now_ms > "$LOCK"

addr=$("$HOME/.config/hypr/window-under-cursor.sh")
[ -z "$addr" ] && exit 0

# Don't re-stash a window that's already minimized.
ws_name=$(hyprctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')
[ "$ws_name" = "special:minimized" ] && exit 0

hyprctl dispatch "hl.dsp.window.move({workspace=\"special:minimized\", window=\"address:$addr\", follow=false})"
