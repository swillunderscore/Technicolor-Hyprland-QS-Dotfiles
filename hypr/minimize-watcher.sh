#!/usr/bin/env bash
# Listens for Hyprland minimize events. When an app's CSD minimize button (or
# any xdg_toplevel.set_minimized request) fires, stash the window on
# special:minimized — same as the SUPER+scroll bind.
#
# Event format from socket2: "minimize>>WINDOWADDRESS,STATE"
#   STATE = 1 → minimize requested
#   STATE = 0 → unminimize requested

SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

socat -U - "UNIX-CONNECT:$SOCK" | while read -r line; do
    [[ "$line" != minimize\>\>* ]] && continue

    rest="${line#minimize>>}"
    addr="${rest%%,*}"
    state="${rest##*,}"

    [ -z "$addr" ] && continue
    # hyprctl returns addresses as 0xHEX; the event drops the prefix
    [[ "$addr" != 0x* ]] && addr="0x$addr"

    if [ "$state" = "1" ]; then
        # Skip if already on special:minimized (some apps spam the request)
        ws_name=$(hyprctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')
        [ "$ws_name" = "special:minimized" ] && continue

        hyprctl dispatch movetoworkspacesilent "special:minimized,address:$addr"

    elif [ "$state" = "0" ]; then
        # Unminimize → restore to current workspace and focus it
        cur_ws=$(hyprctl activeworkspace -j | jq -r '.id')
        hyprctl --batch "dispatch movetoworkspace $cur_ws,address:$addr ; dispatch focuswindow address:$addr"
    fi
done
