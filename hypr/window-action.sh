#!/usr/bin/env bash
# Run a window action on the window UNDER THE CURSOR, not the keyboard-focused
# one. With input:follow_mouse=2 the pointer focus is detached from keyboard
# focus, so the built-in togglefloating/fullscreen dispatchers act on the wrong
# (focused) window when you mean the one you're hovering. These resolve the
# hovered window via window-under-cursor.sh and target it by address — matching
# how minimize already behaves.
#
#   Usage: window-action.sh <float|maximize|close>
#          window-action.sh move <l|r|u|d>
#
# Per-action debounce so key-repeat can't chain the action as the stack shifts.
# Move is exempt: its bind doesn't repeat, and the cursor rides along with the
# window, so a quick Left-then-Up hits the same window on purpose. Moves are
# serialized instead, so the second one sees where the first one put things.

action="${1:?usage: window-action.sh <float|maximize|close|move DIR>}"
LOCK="/tmp/hypr-winaction-$action.lock"
DEBOUNCE_MS=350

if [ "$action" = "move" ]; then
    exec 9>"$LOCK"
    flock 9
else
    now_ms() { date +%s%3N; }
    if [ -f "$LOCK" ]; then
        last=$(cat "$LOCK" 2>/dev/null || echo 0)
        [ "$(( $(now_ms) - last ))" -lt "$DEBOUNCE_MS" ] && exit 0
    fi
    now_ms > "$LOCK"
fi

addr=$("$HOME/.config/hypr/window-under-cursor.sh")
[ -z "$addr" ] && exit 0

case "$action" in
    float)
        hyprctl dispatch "hl.dsp.window.float({window=\"address:$addr\"})"
        ;;
    maximize)
        # `fullscreen` takes no window arg (acts on the active window), so focus
        # the hovered window first, then toggle maximize. cursor:no_warps=true
        # keeps focuswindow from jerking the pointer. --batch so it's atomic.
        hyprctl --batch "dispatch hl.dsp.focus({window=\"address:$addr\"}) ; dispatch hl.dsp.window.fullscreen({mode=1})"
        ;;
    close)
        hyprctl dispatch "hl.dsp.window.close({window=\"address:$addr\"})"
        ;;
    move)
        dir="${2:-}"
        case "$dir" in l|r|u|d) ;; *) exit 1 ;; esac
        # The mouse follows the window (cursor:no_warps=true stops Hyprland
        # doing it), landing on the same spot inside it -- as a fraction, so a
        # tiled window that changes size still ends up under the cursor.
        geom() {
            hyprctl clients -j | jq -r --arg a "$addr" \
                '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'
        }
        read -r x0 y0 w0 h0 <<< "$(geom)"
        IFS=', ' read -r cx cy <<< "$(hyprctl cursorpos)"
        hyprctl dispatch "hl.dsp.window.move({direction=\"$dir\", window=\"address:$addr\"})" >/dev/null
        read -r x1 y1 w1 h1 <<< "$(geom)"
        [ -z "$x1" ] || [ "$x1 $y1 $w1 $h1" = "$x0 $y0 $w0 $h0" ] && exit 0
        [ "${w0:-0}" -gt 0 ] && [ "${h0:-0}" -gt 0 ] || exit 0
        nx=$(( x1 + (cx - x0) * w1 / w0 ))
        ny=$(( y1 + (cy - y0) * h1 / h0 ))
        hyprctl dispatch "hl.dsp.cursor.move({x=$nx, y=$ny})" >/dev/null
        ;;
    *)
        exit 1
        ;;
esac
