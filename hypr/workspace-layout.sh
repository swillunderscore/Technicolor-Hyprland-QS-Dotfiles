#!/usr/bin/env bash
# workspace-layout.sh — Output JSON of window layouts for a given workspace
# Usage: workspace-layout.sh <workspace_id>
# Returns JSON array of windows with their positions, sizes, appId, title, address

WS_ID="$1"
[ -z "$WS_ID" ] && echo "[]" && exit 0

# Get monitor resolution for the workspace (or default)
# We need this to know the coordinate space
MON_INFO=$(hyprctl monitors -j)

# Get all clients, filter to the target workspace
hyprctl clients -j | jq --argjson ws "$WS_ID" '[
    .[] | select(.workspace.id == $ws and .mapped == true and .hidden == false) |
    {
        address: .address,
        title: .title,
        class: .class,
        x: .at[0],
        y: .at[1],
        w: .size[0],
        h: .size[1],
        floating: .floating,
        fullscreen: (.fullscreen != 0)
    }
]'
