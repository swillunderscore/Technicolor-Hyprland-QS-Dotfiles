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
    hyprctl --batch "dispatch hl.dsp.window.move({workspace=\"$cur_ws\", window=\"address:$addr\"}) ; dispatch hl.dsp.focus({window=\"address:$addr\"}) ; dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:$addr\"})"
}

cur_focus=""
prev_focus=""

socat -U - "UNIX-CONNECT:$SOCK" | while read -r line; do
    case "$line" in
        activewindowv2\>\>*)
            # Focus history for the toast-bounce below.
            a="${line#activewindowv2>>}"
            [ -z "$a" ] && continue
            [[ "$a" != 0x* ]] && a="0x$a"
            [ "$a" = "$cur_focus" ] && continue
            prev_focus="$cur_focus"
            cur_focus="$a"
            ;;

        openwindow\>\>*)
            # TOAST GUARD. Steam's friend/achievement notifications (and any
            # future app doing the same thing) open a tiny real window on
            # whatever monitor they like, and a new window takes focus - so a
            # toast on the other screen yanks the keyboard mid-typing. Rule:
            # if a freshly opened window is toast-sized AND stole focus AND
            # the previously focused window lives on a DIFFERENT monitor,
            # bounce focus straight back. Deliberately generic - no app list.
            # Small dialogs a user opens on purpose (polkit, pickers) are
            # bigger than the threshold or on the same monitor, so they keep
            # focus.
            rest="${line#openwindow>>}"
            addr="${rest%%,*}"
            [ -z "$addr" ] && continue
            [[ "$addr" != 0x* ]] && addr="0x$addr"
            sleep 0.15   # let size/position/focus settle
            info=$(hyprctl clients -j | jq -r --arg a "$addr" \
                '.[] | select(.address == $a) | "\(.size[0]) \(.size[1]) \(.monitor)"' 2>/dev/null)
            [ -z "$info" ] && continue
            read -r w h mon <<< "$info"
            act=$(hyprctl activewindow -j | jq -r '"\(.address) \(.monitor)"' 2>/dev/null)
            read -r act_addr act_mon <<< "$act"
            [ "$act_addr" = "$addr" ] || continue          # it did not take focus
            [ $(( ${w:-9999} * ${h:-9999} )) -lt 70000 ] || continue   # not toast-sized
            # who had focus before this window appeared (event order safe)
            if [ "$cur_focus" = "$addr" ]; then before="$prev_focus"; else before="$cur_focus"; fi
            [ -n "$before" ] || continue
            before_mon=$(hyprctl clients -j | jq -r --arg a "$before" \
                '.[] | select(.address == $a) | .monitor' 2>/dev/null)
            [ -n "$before_mon" ] && [ "$before_mon" != "$mon" ] || continue
            hyprctl dispatch 'hl.dsp.focus({last=true})' >/dev/null 2>&1
            ;;

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
                hyprctl dispatch "hl.dsp.window.move({workspace=\"special:minimized\", window=\"address:$addr\", follow=false})"
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
