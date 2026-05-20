#!/usr/bin/env bash
ws=$1

# Nerd font icons via codepoint (so encoding is correct)
FILLED=$(printf '\u25CF')
HOLLOW=$(printf '\u25CB')

mon_data=$(hyprctl monitors -j 2>/dev/null)
ws_data=$(hyprctl workspaces -j 2>/dev/null)

focused_ws=$(echo "$mon_data" | jq '.[] | select(.focused == true) | .activeWorkspace.id')
visible_ids=$(echo "$mon_data" | jq -r '[.[].activeWorkspace.id] | .[]')

# How many windows on this workspace?
ws_windows=$(echo "$ws_data" | jq "[.[] | select(.id == $ws)] | if length > 0 then .[0].windows else 0 end")

# Is it visible on a monitor?
is_visible=0
for a in $visible_ids; do
    [ "$a" = "$ws" ] && is_visible=1
done

# Highest workspace that has windows
highest_occupied=$(echo "$ws_data" | jq '[.[] | select(.id > 0 and .windows > 0)] | if length > 0 then max_by(.id).id else 0 end')

# Highest visible workspace
highest_visible=0
for a in $visible_ids; do
    [ "$a" -gt "$highest_visible" ] && highest_visible=$a
done

# The ceiling: show dots up to whichever is higher
ceiling=$highest_occupied
[ "$highest_visible" -gt "$ceiling" ] && ceiling=$highest_visible

# Beyond the ceiling and not visible: hide
if [ "$ws" -gt "$ceiling" ] && [ "$is_visible" -eq 0 ]; then
    echo '{"text":""}'
    exit 0
fi

# Focused
if [ "$focused_ws" = "$ws" ]; then
    echo "{\"text\":\"${FILLED}\", \"class\":\"focused\"}"
    exit 0
fi

# Visible on another monitor
if [ "$is_visible" -eq 1 ]; then
    echo "{\"text\":\"${FILLED}\", \"class\":\"visible\"}"
    exit 0
fi

# Has windows
if [ "${ws_windows:-0}" -gt 0 ]; then
    echo "{\"text\":\"${FILLED}\", \"class\":\"occupied\"}"
    exit 0
fi

# Empty but below the ceiling (gap workspace)
if [ "$ws" -le "$ceiling" ]; then
    echo "{\"text\":\"${HOLLOW}\", \"class\":\"empty\"}"
    exit 0
fi

echo '{"text":""}'
