#!/usr/bin/env bash
# Listens to Hyprland's socket2 for active-window changes. Each time a window
# gets focus, clear the persistent notification count for any app whose key
# matches the focused window's class. Pairs with notif-bump.sh which feeds
# counts from mako.

SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

socat -U - "UNIX-CONNECT:$SOCK" | while read -r line; do
    case "$line" in
        activewindow\>\>*)
            rest="${line#activewindow>>}"
            class="${rest%%,*}"
            [ -z "$class" ] && continue
            ~/.config/quickshell/notif-clear.sh "$class" &
            ;;
    esac
done
