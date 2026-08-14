#!/usr/bin/env bash
# window-grab.sh <address> — make a window follow the cursor while you drag its
# tile in the bar's workspace preview, so you can move a window off another
# monitor without touching the keyboard. That's the case that matters when
# you're driving the desktop from a phone over Moonlight.
#
# Why this loops instead of calling Hyprland's own interactive move: the drag
# starts on the quickshell popup, so the popup holds the pointer grab and the
# compositor never sees a button held down ON THE WINDOW. hl.dsp.window.drag()
# therefore starts and immediately ends — the window jumps to the cursor once
# and then sits there. Following the pointer ourselves sidesteps that entirely.
#
# The bar creates the flag file before launching this and deletes it on mouse
# release. The timeout is a backstop in case it never gets to (bar restarted
# mid-drag, session died).
set -u

ADDR="${1:?usage: window-grab.sh <address>}"
FLAG=/tmp/tc-window-drag
TIMEOUT=30

info=$(hyprctl clients -j | jq -r --arg a "$ADDR" \
    '.[] | select(.address==$a) | "\(.floating) \(.size[0]) \(.size[1])"')
[ -z "$info" ] && exit 0
read -r FLOATING W H <<<"$info"

# Bring it to the workspace you're looking at first, or you'd be dragging it
# around on the monitor you can't see.
WS=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({ workspace = \"$WS\" })" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })" >/dev/null 2>&1

# A tiled window can't sit under the pointer — it would just swap with whatever
# it lands on — so it gets the workspace move and nothing more.
[ "$FLOATING" = "true" ] || exit 0

follow() {
    local pos cx cy
    pos=$(hyprctl cursorpos 2>/dev/null | tr -d ' ') || return 1
    cx=${pos%%,*}; cy=${pos##*,}
    [[ "$cx" =~ ^-?[0-9]+$ && "$cy" =~ ^-?[0-9]+$ ]] || return 1
    hyprctl dispatch "hl.dsp.window.move({ x = $((cx - W / 2)), y = $((cy - H / 2)) })" >/dev/null 2>&1
}

follow                       # snap to the cursor immediately
deadline=$((SECONDS + TIMEOUT))
while [ -e "$FLAG" ] && [ "$SECONDS" -lt "$deadline" ]; do
    follow
    sleep 0.02
done
follow                       # one last update so it lands where you released
