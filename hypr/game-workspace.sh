#!/usr/bin/env bash

EXCLUDED_CLASSES=("org.telegram.desktop" "com.gabm.satty")

is_excluded() {
    local class="$1"
    for excl in "${EXCLUDED_CLASSES[@]}"; do
        if [[ "$class" == "$excl" ]]; then
            return 0
        fi
    done
    return 1
}

handle() {
    if [[ "$1" == "fullscreen>>1" ]]; then
        sleep 0.3
        active=$(hyprctl activewindow -j)
        is_fs=$(echo "$active" | jq -r '.fullscreen')
        addr=$(echo "$active" | jq -r '.address')
        ws_id=$(echo "$active" | jq -r '.workspace.id')
        monitor=$(echo "$active" | jq -r '.monitor')
        class=$(echo "$active" | jq -r '.class')

        if is_excluded "$class"; then
            return
        fi

        if [ "$monitor" -eq 0 ] && [ "$is_fs" != "0" ]; then
            others=$(hyprctl clients -j | jq -r \
                --arg ws "$ws_id" --arg addr "$addr" \
                '[.[] | select(.workspace.id == ($ws | tonumber) and .address != $addr)] | .[].address')
            if [ -n "$others" ]; then
                max_id=$(hyprctl workspaces -j | jq '[.[] | select(.id > 0)] | max_by(.id) | .id')
                new_ws=$((max_id + 1))
                while IFS= read -r win_addr; do
                    hyprctl dispatch "hl.dsp.window.move({workspace=\"$new_ws\", window=\"address:$win_addr\"})"
                done <<< "$others"
            fi
        fi
    fi
}

socat -U - UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" | while read -r line; do
    handle "$line"
done
