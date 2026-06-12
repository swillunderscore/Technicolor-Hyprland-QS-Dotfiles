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
    # "Raycast": hyprctl clients lists windows in STACK ORDER (the same vector
    # alterzorder manipulates) — so among windows under the cursor, the one
    # LATEST in the array is the one actually rendered on top. Ranking:
    #   pinned first, then floating over tiled (separate render passes), then
    #   true-fullscreen (2 = games) demoted below floats covering them — but
    #   NOT fullscreen 1 (super+V maximize), which legitimately sits on top —
    #   finally raw stack position (highest index = topmost).
    addr=$(echo "$clients" | jq -r --argjson cx "$cx" --argjson cy "$cy" '
        [to_entries[] | {i: .key, w: .value} | select(
            .w.mapped == true and .w.hidden == false and
            (.w.workspace.id // 0) > 0 and
            (.w.at[0] // 0) <= $cx and $cx < ((.w.at[0] // 0) + (.w.size[0] // 0)) and
            (.w.at[1] // 0) <= $cy and $cy < ((.w.at[1] // 0) + (.w.size[1] // 0))
        )] | sort_by(
            (if .w.pinned   then 0 else 1 end),
            (if .w.floating then 0 else 1 end),
            (if (.w.fullscreen // 0) == 2 then 1 else 0 end),
            (-.i)
        ) | .[0].w.address // empty
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
