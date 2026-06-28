#!/usr/bin/env bash
# Click-to-go: slide the carousel until the clicked monitor shows $target ws.
# Args:
#   $1 = target workspace id
#   $2 = monitor id that was clicked (defaults to 0)

target=$1
clicked_mon=${2:-0}
[ -z "$target" ] && exit 1

MOVE_SCRIPT="$HOME/.config/hypr/workspace-move.sh"
max_steps=20

# Sorted-by-x monitor ids so we know the leftmost/rightmost in slot order
get_slot_ids() {
    hyprctl monitors -j | jq -r 'sort_by(.x) | .[] | .id'
}

for i in $(seq 1 $max_steps); do
    state=$(hyprctl monitors -j)
    current=$(echo "$state" | jq --argjson m "$clicked_mon" '[.[] | select(.id == $m)][0].activeWorkspace.id')

    [ "$current" -eq "$target" ] 2>/dev/null && {
        hyprctl dispatch "hl.dsp.focus({monitor=\"$clicked_mon\"})"
        exit 0
    }

    mapfile -t slot_ids < <(get_slot_ids)
    leftmost=${slot_ids[0]}
    rightmost=${slot_ids[$((${#slot_ids[@]} - 1))]}

    if [ "$target" -gt "$current" ]; then
        # Slide right: pre-focus rightmost so move.sh actually slides instead of just shifting focus
        hyprctl dispatch "hl.dsp.focus({monitor=\"$rightmost\"})"
        "$MOVE_SCRIPT" right
    else
        hyprctl dispatch "hl.dsp.focus({monitor=\"$leftmost\"})"
        "$MOVE_SCRIPT" left
    fi

    sleep 0.05
done

hyprctl dispatch "hl.dsp.focus({monitor=\"$clicked_mon\"})"
