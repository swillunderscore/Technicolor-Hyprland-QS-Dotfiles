#!/usr/bin/env bash
# Restore a stashed window to the focused monitor's current workspace and focus it.
# Args: $1 = window address (e.g. 0x55a3b4c5d6e7) — as reported by hyprctl

addr="$1"
[ -z "$addr" ] && exit 1

cur_ws=$(hyprctl activeworkspace -j | jq -r '.id')
# movetoworkspace = unminimize; focuswindow = focus; alterzorder top = raise it
# above other floating windows (without this it restores but stays behind them).
hyprctl --batch "dispatch movetoworkspace $cur_ws,address:$addr ; dispatch focuswindow address:$addr ; dispatch alterzorder top,address:$addr"
