#!/usr/bin/env bash
slot=$1

ws=$(hyprctl clients -j | jq -r "[.[] | select(.workspace.id > 0)] | sort_by(.workspace.id) | .[$((slot-1))].workspace.id // empty")

[ -z "$ws" ] && exit 0

"$HOME/.config/hypr/workspace-goto.sh" "$ws"
