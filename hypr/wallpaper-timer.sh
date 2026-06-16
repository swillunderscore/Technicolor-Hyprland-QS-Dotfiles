#!/usr/bin/env bash
# Wallpaper auto-cycle timer with a configurable interval, a pause toggle, and
# pause-while-fullscreen (so it won't churn the CPU or flash a transition during
# a game / fullscreen video). Config: ~/.config/hypr/wallpaper-timer.conf
#   INTERVAL_MIN=<minutes>  PAUSED=0|1  PAUSE_ON_FULLSCREEN=0|1
# The config is re-read every tick, so Settings changes apply without a restart.
set -u
CONF="$HOME/.config/hypr/wallpaper-timer.conf"
TICK=15   # seconds between checks — keeps pause/interval changes responsive

# single instance: a stale daemon from a previous reload must not stack
exec 9>"/tmp/wallpaper-timer.lock" 2>/dev/null
flock -n 9 || exit 0

read_conf() {
    INTERVAL_MIN=60; PAUSED=0; PAUSE_ON_FULLSCREEN=1
    [ -f "$CONF" ] || return
    while IFS='=' read -r k v; do
        case "$k" in
            INTERVAL_MIN)        INTERVAL_MIN="${v%%.*}";;   # tolerate "60.0"
            PAUSED)              PAUSED="$v";;
            PAUSE_ON_FULLSCREEN) PAUSE_ON_FULLSCREEN="$v";;
        esac
    done < "$CONF"
    case "$INTERVAL_MIN" in ''|*[!0-9]*) INTERVAL_MIN=60;; esac
    [ "$INTERVAL_MIN" -lt 1 ] && INTERVAL_MIN=1
}

fullscreen_present() {
    local n
    n=$(hyprctl clients -j 2>/dev/null | jq '[.[] | select(.fullscreen >= 2)] | length' 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

elapsed=0
while true; do
    sleep "$TICK"
    read_conf
    [ "$PAUSED" = "1" ] && continue                 # frozen while paused
    elapsed=$((elapsed + TICK))
    [ "$elapsed" -lt "$((INTERVAL_MIN * 60))" ] && continue
    # interval elapsed — hold off if a fullscreen app is up (fires once it closes)
    if [ "$PAUSE_ON_FULLSCREEN" = "1" ] && fullscreen_present; then continue; fi
    "$HOME/.config/hypr/wallpaper-cycle.sh" random
    elapsed=0
done
