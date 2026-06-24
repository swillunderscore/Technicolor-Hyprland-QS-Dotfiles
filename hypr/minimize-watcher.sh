#!/usr/bin/env bash
# Listens for Hyprland minimize events. When an app's CSD minimize button (or
# any xdg_toplevel.set_minimized request) fires, stash the window on
# special:minimized — same as the SUPER+scroll bind.
#
# Event format from socket2: "minimize>>WINDOWADDRESS,STATE"
#   STATE = 1 → minimize requested
#   STATE = 0 → unminimize requested

SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# Restore a minimized window to the current workspace, focus it, and raise it
# above other floating windows (alterzorder top).
unminimize() {
    local addr="$1" cur_ws
    cur_ws=$(hyprctl activeworkspace -j | jq -r '.id')
    hyprctl --batch "dispatch movetoworkspace $cur_ws,address:$addr ; dispatch focuswindow address:$addr ; dispatch alterzorder top,address:$addr"
}

socat -U - "UNIX-CONNECT:$SOCK" | while read -r line; do
    case "$line" in
        minimize\>\>*)
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
                unminimize "$addr"
            fi
            ;;

        urgent\>\>*)
            # An app asked to RAISE/activate a window (xdg-activation) — e.g. Brave
            # opening a link in an existing window, or Dolphin reusing a window. If
            # that window is minimized, un-minimize it; otherwise leave it alone
            # (just the normal urgency hint).
            #
            # EXCEPT chat apps: Telegram/Discord/Vesktop set the urgent flag on
            # EVERY incoming message, so un-minimizing them on urgency pops the
            # window (and fires a read receipt) on every single message — which
            # is why Telegram kept opening itself from minimized on a new DM.
            # Keep the un-minimize for genuine attention requests; skip these.
            addr="${line#urgent>>}"
            [ -z "$addr" ] && continue
            [[ "$addr" != 0x* ]] && addr="0x$addr"
            info=$(hyprctl clients -j | jq -r --arg a "$addr" \
                '.[] | select(.address == $a) | "\(.workspace.name // "")|\(.class // "")"' 2>/dev/null)
            ws_name="${info%%|*}"
            class="${info#*|}"
            case "$(printf '%s' "$class" | tr '[:upper:]' '[:lower:]')" in
                *telegram*|*vesktop*|*discord*) continue ;;
            esac
            [ "$ws_name" = "special:minimized" ] && unminimize "$addr"
            ;;
    esac
done
