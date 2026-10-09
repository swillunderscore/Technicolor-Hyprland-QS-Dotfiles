#!/usr/bin/env bash
# Make an offscreen monitor behave as if it weren't there.
#
# Offscreen = powered off (monitor-power.sh -> tc-monitors-off) and not the one
# a Moonlight client is streaming (stream-screens.sh -> tc-stream-output). The
# monitor is still connected and Hyprland still treats it as a screen, so
# without this the mouse wanders onto it, which moves monitor focus there, so
# the next window opens there too -- and window rules can pin apps to it (a
# file picker opening where nobody can see it).
#
# Event-driven (socket2), and it only ever moves the cursor, focus and windows:
#   focusedmon onto an offscreen monitor
#       mouse crossed over   -> cursor back to the nearest point of the visible
#                               monitor, focus back with it (a wall)
#       keyboard/activation  -> bring the focused window over to the visible
#                               monitor's workspace (alt-tab, a notification)
#   openwindow on an offscreen monitor -> move it to the visible monitor
# It never disables or moves a monitor: monitor reconfiguration is the code
# path behind every Hyprland crash this desktop has had.
# Nothing visible at all (everything off, no stream) = nobody is looking: no-op.

RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$RUN/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
LOG="$RUN/offscreen-guard.log"
log() { echo "[$(date +%T.%3N)] $*" >> "$LOG"; }

exec 8>"$RUN/offscreen-guard.lock"
flock -n 8 || exit 0

# Sets OFFSCREEN (space-separated names) and TARGET (the visible monitor to
# send things to: the streamed one if it's visible, else the leftmost visible).
# Returns 1 when nothing is offscreen.
compute() {
    local stream off name mons
    stream=$(cat "$RUN/tc-stream-output" 2>/dev/null)
    off=$(cat "$RUN/tc-monitors-off" 2>/dev/null)
    OFFSCREEN=""
    for name in $off; do [ "$name" != "$stream" ] && OFFSCREEN+=" $name "; done
    [ -n "$OFFSCREEN" ] || return 1
    mons=$(hyprctl monitors -j)
    TARGET=$(jq -r --arg off "$OFFSCREEN" --arg s "$stream" '
        [.[] | .name as $n | select(($off | contains(" " + $n + " ")) | not)] | sort_by(.x)
        | (map(select(.name == $s)) + .)[0].name // empty' <<< "$mons")
    [ -n "$TARGET" ] || return 1          # everything offscreen: nobody looking
    MONS=$mons
}
is_off() { [[ "$OFFSCREEN" == *" $1 "* ]]; }

target_ws() { jq -r --arg t "$TARGET" '.[] | select(.name == $t) | .activeWorkspace.id' <<< "$MONS"; }

on_focusedmon() {   # NAME
    compute || return
    is_off "$1" || return
    local cx cy x y w h
    IFS=', ' read -r cx cy <<< "$(hyprctl cursorpos)"
    read -r x y w h < <(jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.x) \(.y) \(.width) \(.height)"' <<< "$MONS")
    if [ "$cx" -ge "$x" ] && [ "$cx" -lt $((x + w)) ] && [ "$cy" -ge "$y" ] && [ "$cy" -lt $((y + h)) ]; then
        # The mouse crossed over: put it back where it left the visible one.
        read -r x y w h < <(jq -r --arg n "$TARGET" '.[] | select(.name == $n) | "\(.x) \(.y) \(.width) \(.height)"' <<< "$MONS")
        local nx=$cx ny=$cy
        [ "$nx" -lt "$x" ] && nx=$x; [ "$nx" -ge $((x + w)) ] && nx=$((x + w - 1))
        [ "$ny" -lt "$y" ] && ny=$y; [ "$ny" -ge $((y + h)) ] && ny=$((y + h - 1))
        hyprctl --batch "dispatch hl.dsp.cursor.move({x=$nx, y=$ny}) ; dispatch hl.dsp.focus({monitor=\"$TARGET\"})" >/dev/null
        log "wall: cursor $cx,$cy on $1 -> $nx,$ny on $TARGET"
    else
        # Focus went there some other way. Bring the window it went to.
        local addr
        addr=$(hyprctl activewindow -j | jq -r --argjson ws "$(target_ws)" \
            'select(.address != null and .workspace.id > 0 and .workspace.id != $ws) | .address')
        if [ -n "$addr" ]; then
            hyprctl --batch "dispatch hl.dsp.window.move({workspace=\"$(target_ws)\", window=\"address:$addr\"}) ; dispatch hl.dsp.focus({window=\"address:$addr\"})" >/dev/null
            log "focus: brought $addr from $1 to $TARGET"
        else
            hyprctl dispatch "hl.dsp.focus({monitor=\"$TARGET\"})" >/dev/null
            log "focus: $1 has nothing focused, back to $TARGET"
        fi
    fi
}

on_openwindow() {   # ADDR (no 0x)
    compute || return
    local addr="0x$1" mon ws active
    sleep 0.05   # let rules (monitor/workspace) land before reading where it went
    read -r mon ws < <(hyprctl clients -j | jq -r --arg a "$addr" \
        --argjson m "$MONS" '.[] | select(.address == $a) | .monitor as $id
        | "\($m[] | select(.id == $id) | .name) \(.workspace.id)"')
    [ -n "$mon" ] && [ "${ws:-0}" -gt 0 ] || return     # gone, or special (minimized)
    is_off "$mon" || return
    active=$(hyprctl activewindow -j | jq -r '.address // empty')
    local cmd="dispatch hl.dsp.window.move({workspace=\"$(target_ws)\", window=\"address:$addr\"})"
    [ "$active" = "$addr" ] && cmd+=" ; dispatch hl.dsp.focus({window=\"address:$addr\"})"
    hyprctl --batch "$cmd" >/dev/null
    log "open: $addr opened on $mon -> workspace $(target_ws) on $TARGET"
}

# Through an fd, so killing this PID ends socat too (never broad-kill socat:
# the other watchers use it).
exec 3< <(socat -U - "UNIX-CONNECT:$SOCK" 2>/dev/null)
sock_pid=$!
trap 'kill "$sock_pid" 2>/dev/null' EXIT
trap 'exit 0' TERM INT HUP
log "started (pid $$)"
while IFS= read -r -u 3 line; do
    case "$line" in
        focusedmon\>\>*) n=${line#focusedmon>>}; on_focusedmon "${n%%,*}" ;;
        openwindow\>\>*) a=${line#openwindow>>}; on_openwindow "${a%%,*}" ;;
    esac
done
