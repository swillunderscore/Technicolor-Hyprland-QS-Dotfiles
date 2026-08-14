#!/usr/bin/env bash
# window-grab.sh <address> — pick a window up onto the cursor and hand it to
# Hyprland's own interactive move, so it follows the pointer exactly as if you
# were holding Super and dragging it. Ends when you release the button.
#
# Called by the bar's workspace-dot preview: start dragging a window tile and
# the real window comes to you. The point is to move a window off another
# monitor without touching the keyboard — the case that matters when you're
# driving the desktop from a phone over Moonlight.
set -u

ADDR="${1:?usage: window-grab.sh <address>}"

info=$(hyprctl clients -j | jq -r --arg a "$ADDR" \
    '.[] | select(.address==$a) | "\(.floating) \(.size[0]) \(.size[1])"')
[ -z "$info" ] && exit 0
read -r FLOATING W H <<<"$info"

# Bring it to the workspace you're actually looking at first. Without this a
# window on another monitor would be dragged around over there, out of sight.
WS=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({ workspace = \"$WS\" })" >/dev/null 2>&1
# Focus follows the window across the move; re-assert so the drag targets it.
hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })" >/dev/null 2>&1

# Only a floating window can sit wherever the pointer is; a tiled one would just
# swap with whatever it lands on, so leave its position to the tiler.
if [ "$FLOATING" = "true" ]; then
    pos=$(hyprctl cursorpos | tr -d ' ')
    CX=${pos%%,*}; CY=${pos##*,}
    if [[ "$CX" =~ ^-?[0-9]+$ && "$CY" =~ ^-?[0-9]+$ ]]; then
        hyprctl dispatch "hl.dsp.window.move({ x = $((CX - W / 2)), y = $((CY - H / 2)) })" >/dev/null 2>&1
    fi
fi

# Hand over to the compositor. It tracks the pointer and stops on button release.
hyprctl dispatch 'hl.dsp.window.drag()' >/dev/null 2>&1
