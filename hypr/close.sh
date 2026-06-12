#!/usr/bin/env bash
# Close the window UNDER THE CURSOR (same raycast as minimize.sh), falling
# back to the active window if the cursor isn't over anything.
# Bound to SUPER+C / SUPER+ESC — debounced so key-repeat can't chain-close
# windows as the stack shifts under the cursor.

LOCK="/tmp/hypr-close.lock"
DEBOUNCE_MS=350

now_ms() { date +%s%3N; }

if [ -f "$LOCK" ]; then
    last=$(cat "$LOCK" 2>/dev/null || echo 0)
    cur=$(now_ms)
    [ "$((cur - last))" -lt "$DEBOUNCE_MS" ] && exit 0
fi
now_ms > "$LOCK"

cursor=$(hyprctl cursorpos -j 2>/dev/null)
cx=$(echo "$cursor" | jq -r '.x // empty')
cy=$(echo "$cursor" | jq -r '.y // empty')

clients=$(hyprctl clients -j)
addr=""

if [ -n "$cx" ] && [ -n "$cy" ]; then
    # Topmost mapped window containing the cursor — see minimize.sh for the
    # full ranking rationale (pinned > floating > tiled, true-fullscreen
    # games demoted, stack index as the tiebreaker).
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

if [ -z "$addr" ]; then
    addr=$(hyprctl activewindow -j | jq -r '.address // empty')
fi

[ -z "$addr" ] && exit 0

# closewindow = same graceful close request as killactive, just targeted
hyprctl dispatch closewindow "address:$addr"
