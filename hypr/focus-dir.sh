#!/usr/bin/env bash
# Super+arrow: move keyboard focus in a direction, then put the mouse in the
# middle of the window that got it, so hover-targeted binds (Super+Esc,
# Super+Shift+arrows, Super+scroll) act on what was just focused.
# cursor:no_warps=true stops Hyprland doing the warp itself.
#
#   Usage: focus-dir.sh <l|r|u|d>
# Focus didn't land on a different window (edge, empty monitor) = mouse stays.

dir="${1:?usage: focus-dir.sh l|r|u|d}"
case "$dir" in l|r|u|d) ;; *) exit 1 ;; esac

before=$(hyprctl activewindow -j | jq -r '.address // empty')
hyprctl dispatch "hl.dsp.focus({direction=\"$dir\"})" >/dev/null
read -r addr x y w h < <(hyprctl activewindow -j \
    | jq -r 'select(.address != null) | "\(.address) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
[ -z "$addr" ] || [ "$addr" = "$before" ] && exit 0
hyprctl dispatch "hl.dsp.cursor.move({x=$((x + w / 2)), y=$((y + h / 2))})" >/dev/null
