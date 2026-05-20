#!/usr/bin/env bash
# Restore a stashed window to the focused monitor's current workspace and focus it.
# Args: $1 = window address (e.g. 0x55a3b4c5d6e7) — as reported by hyprctl

addr="$1"
[ -z "$addr" ] && exit 1

cur_ws=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl --batch "dispatch movetoworkspace $cur_ws,address:$addr ; dispatch focuswindow address:$addr"
