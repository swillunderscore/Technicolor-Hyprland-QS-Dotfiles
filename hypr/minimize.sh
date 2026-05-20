#!/usr/bin/env bash
# Stash the window UNDER THE CURSOR on the special:minimized workspace.
# Falls back to the active window if cursor isn't over a window.
# Bound to SUPER+scroll — debounced so a fast scroll-wheel flick doesn't
# stack-minimize half your desktop in one motion.

LOCK="/tmp/hypr-minimize.lock"
DEBOUNCE_MS=350

now_ms() { date +%s%3N; }

if [ -f "$LOCK" ]; then
    last=$(cat "$LOCK" 2>/dev/null || echo 0)
    cur=$(now_ms)
    [ "$((cur - last))" -lt "$DEBOUNCE_MS" ] && exit 0
fi
now_ms > "$LOCK"

# Cursor coords (global coordinate space across all monitors)
cursor=$(hyprctl cursorpos -j 2>/dev/null)
cx=$(echo "$cursor" | jq -r '.x // empty')
cy=$(echo "$cursor" | jq -r '.y // empty')

clients=$(hyprctl clients -j)
addr=""

if [ -n "$cx" ] && [ -n "$cy" ]; then
    # Pick the topmost mapped window containing the cursor.
    # Visual stacking order in Hyprland (lowest sort key = on top):
    #   1. pinned (always on top across workspaces)
    #   2. floating (sits over tiles)
    #   3. tiled
    #   tiebreaker: lowest focusHistoryID = most recently focused
    addr=$(echo "$clients" | jq -r --argjson cx "$cx" --argjson cy "$cy" '
        [.[] | select(
            .mapped == true and .hidden == false and
            (.workspace.id // 0) > 0 and
            (.at[0] // 0) <= $cx and $cx < ((.at[0] // 0) + (.size[0] // 0)) and
            (.at[1] // 0) <= $cy and $cy < ((.at[1] // 0) + (.size[1] // 0))
        )] | sort_by(
            (if .pinned   then 0 else 1 end),
            (if .floating then 0 else 1 end),
            (.focusHistoryID // 999999)
        ) | .[0].address // empty
    ')
fi

# Fall back to active window if cursor isn't over anything
if [ -z "$addr" ]; then
    addr=$(hyprctl activewindow -j | jq -r '.address // empty')
fi

[ -z "$addr" ] && exit 0

# Don't re-stash a window that's already minimized
ws_name=$(echo "$clients" | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')
[ "$ws_name" = "special:minimized" ] && exit 0

hyprctl dispatch movetoworkspacesilent "special:minimized,address:$addr"
