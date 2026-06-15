#!/usr/bin/env bash
# Print the address of the window UNDER THE CURSOR (the "raycast"), or the
# active window if the cursor isn't over one. Shared by window-action.sh
# (Super+Space/V/C) and minimize.sh (Super+scroll) so the stacking-order
# ranking lives in exactly one place.
#
# Needed because input:follow_mouse=2 detaches pointer focus from keyboard
# focus — the built-in dispatchers act on the KEYBOARD-focused window, not the
# hovered one, so anything that should act "on the window under the cursor"
# resolves the target here and dispatches by address instead.

cursor=$(hyprctl cursorpos -j 2>/dev/null)
cx=$(echo "$cursor" | jq -r '.x // empty')
cy=$(echo "$cursor" | jq -r '.y // empty')
addr=""

if [ -n "$cx" ] && [ -n "$cy" ]; then
    # Topmost mapped window containing the cursor. hyprctl clients lists windows
    # in stack order; among those under the cursor, rank pinned > floating >
    # tiled, demote true-fullscreen (2 = games) below floats covering them, then
    # the highest stack index (latest in the array = rendered on top) wins.
    addr=$(hyprctl clients -j | jq -r --argjson cx "$cx" --argjson cy "$cy" '
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

# Fall back to the active window if the cursor isn't over anything.
[ -z "$addr" ] && addr=$(hyprctl activewindow -j | jq -r '.address // empty')

printf '%s' "$addr"
