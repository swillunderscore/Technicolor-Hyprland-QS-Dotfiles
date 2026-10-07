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

# FIRES AT THE STEP BOUNDARY, not on an elapsed counter.
#
# This used to count up 15 seconds at a time and fire when the count reached
# the interval. That drifts: the count restarts whenever this script does, and
# it has no relationship to the sequence, whose step comes from the clock. So
# the desktop changed wallpaper at some arbitrary offset from the boundary the
# other device was using — both correct about WHICH wallpaper, an arbitrary number of
# minutes apart about WHEN.
#
# Now both sides compute the same instant, `epoch + (step+1) * period`, and
# sleep until it. The tick still bounds the sleep so a config change or an
# unpause is noticed within 15 seconds.
SEEDER="$HOME/.config/hypr/wallpaper-seed.py"
while true; do
    read_conf
    now=$(date +%s)
    boundary=$(python3 "$SEEDER" boundary 2>/dev/null)
    case "$boundary" in ''|*[!0-9]*) boundary=$((now + TICK)) ;; esac
    wait=$((boundary - now))
    [ "$wait" -gt "$TICK" ] && wait=$TICK
    [ "$wait" -lt 1 ] && wait=1
    sleep "$wait"

    [ "$PAUSED" = "1" ] && continue                 # frozen while paused
    now=$(date +%s)
    [ "$now" -lt "$boundary" ] && continue          # woke for the tick, not the change
    # Boundary reached — hold off if a fullscreen app is up. Nothing is lost by
    # waiting: the step comes from the clock, so when it does fire it lands on
    # whichever wallpaper is current rather than replaying a backlog.
    if [ "$PAUSE_ON_FULLSCREEN" = "1" ] && fullscreen_present; then continue; fi
    "$HOME/.config/hypr/wallpaper-cycle.sh" random
done
