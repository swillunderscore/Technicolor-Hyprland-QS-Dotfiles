#!/usr/bin/env bash
# Run a window action on the window UNDER THE CURSOR, not the keyboard-focused
# one. With input:follow_mouse=2 the pointer focus is detached from keyboard
# focus, so the built-in togglefloating/fullscreen dispatchers act on the wrong
# (focused) window when you mean the one you're hovering. These resolve the
# hovered window via window-under-cursor.sh and target it by address — matching
# how minimize already behaves.
#
#   Usage: window-action.sh <float|maximize|close>
#
# Per-action debounce so key-repeat can't chain the action as the stack shifts.

action="${1:?usage: window-action.sh <float|maximize|close>}"
LOCK="/tmp/hypr-winaction-$action.lock"
DEBOUNCE_MS=350

now_ms() { date +%s%3N; }
if [ -f "$LOCK" ]; then
    last=$(cat "$LOCK" 2>/dev/null || echo 0)
    [ "$(( $(now_ms) - last ))" -lt "$DEBOUNCE_MS" ] && exit 0
fi
now_ms > "$LOCK"

addr=$("$HOME/.config/hypr/window-under-cursor.sh")
[ -z "$addr" ] && exit 0

case "$action" in
    float)
        hyprctl dispatch togglefloating "address:$addr"
        ;;
    maximize)
        # `fullscreen` takes no window arg (acts on the active window), so focus
        # the hovered window first, then toggle maximize. cursor:no_warps=true
        # keeps focuswindow from jerking the pointer. --batch so it's atomic.
        hyprctl --batch "dispatch focuswindow address:$addr ; dispatch fullscreen 1"
        ;;
    close)
        hyprctl dispatch closewindow "address:$addr"
        ;;
    *)
        exit 1
        ;;
esac
