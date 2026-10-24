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

CYCLE="$HOME/.config/hypr/wallpaper-cycle.sh"
THEME="$HOME/.config/hypr/theme-mode.py"

# A light/dark switch wakes this loop with USR1 (theme-mode.py), so it lands
# at the switch instead of on the next tick. The pid file is how it's found.
echo $$ > "${XDG_RUNTIME_DIR:-/tmp}/wallpaper-timer.pid"
SLEEP_PID=""
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null' USR1

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

# Does the wallpaper on screen belong to the current light/dark mode's list?
fits_mode() {
    local cur
    cur=$(cat /tmp/wallpaper-current-path 2>/dev/null)
    [ -z "$cur" ] && return 0
    "$HOME/.config/hypr/wallpaper-list.sh" | grep -qxF -- "$cur"
}

# Colors only, for the wallpaper already on screen — what a light/dark switch
# does while the wallpaper itself is held.
recolor() {
    local cur
    cur=$(cat /tmp/wallpaper-current-path 2>/dev/null)
    [ -n "$cur" ] && nice -n 10 python3 "$HOME/.config/hypr/wallpaper-colors.py" "$cur" >/dev/null 2>&1
    "$HOME/.config/quickshell/notif-theme-mako.sh" >/dev/null 2>&1
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

# PAUSE IS PART OF THE SEQUENCE, not just this loop skipping its turn. A mirror
# derives its picture from the clock, so if this machine merely stopped
# changing, the mirror would carry on without it. Each pause/unpause instead
# anchors the sequence at the wallpaper on screen (see wallpaper-cycle.sh
# anchor and wallpaper-seed.py step_now), and the anchor's hook tells the
# mirror.
#
# That push can fail — mirror unreachable — and nothing else would retry it: the
# hourly push runs from the cycle, and the cycle doesn't run while paused. So
# until the mirror hook acknowledges this paused value (it writes ACK once the
# mirror has stored it), retry here, backing off to 5 minutes. No hook = no mirror
# = nothing to retry.
HOOK="$HOME/.config/hypr/wallpaper-cycle.local.sh"
ACK="/tmp/wallpaper-mirror-paused"
PREV_PAUSED=""
PENDING=0
next_try=0
backoff=$TICK
# A change held back by a fullscreen app is OWED, not skipped. It used to wait
# for the NEXT boundary, so after a game the desktop sat an hour behind a
# mirror that had changed on time. Now it fires on the first tick with no
# fullscreen app, and lands on the clock's current step — the mirror's.
OWED=0
# LIGHT/DARK MODE (theme-mode.py). On a switch the colors follow at once; the
# wallpaper moves to the new mode's list unless something holds it (pause,
# fullscreen) — then it waits exactly like an hourly change would. MODE_NOW is
# the last mode seen ("" until the first tick); MODE_DUE = a switch the
# wallpaper hasn't followed yet.
MODE_NOW=""
MODE_DUE=0
while true; do
    read_conf
    # First pass only records the state: at login the cycle's own hourly push
    # already carries it.
    if [ -n "$PREV_PAUSED" ] && [ "$PAUSED" != "$PREV_PAUSED" ]; then
        # Unpausing onto a wallpaper from the other mode (the switch happened
        # during the pause): don't anchor a sequence on it, start a new one on
        # a wallpaper that fits. Shuffle tells the mirror like anchor does.
        act=anchor
        [ "$PAUSED" = "0" ] && ! fits_mode && act=shuffle
        # Leaves PREV_PAUSED unchanged on failure, so the next tick retries.
        if "$CYCLE" "$act"; then
            PREV_PAUSED="$PAUSED"
            PENDING=1; backoff=$TICK; next_try=$(( $(date +%s) + TICK ))
            # A shuffle that lost the lock to another change: retry below.
            [ "$act" = "shuffle" ] && ! fits_mode && MODE_DUE=1
        fi
    else
        PREV_PAUSED="$PAUSED"
    fi
    if [ "$PENDING" = "1" ]; then
        if [ ! -x "$HOOK" ] || [ "$(cat "$ACK" 2>/dev/null)" = "$PAUSED" ]; then
            PENDING=0
        elif [ "$(date +%s)" -ge "$next_try" ]; then
            # Detached and non-stacking, so an unreachable mirror never delays a
            # wallpaper change here.
            ( flock -n 8 || exit 0; timeout 15 "$HOOK" state >/dev/null 2>&1 ) \
                8>/tmp/wallpaper-mirror-push.lock 9>&- &
            next_try=$(( $(date +%s) + backoff ))
            backoff=$(( backoff * 2 )); [ "$backoff" -gt 300 ] && backoff=300
        fi
    fi
    now=$(date +%s)
    boundary=$(python3 "$SEEDER" boundary 2>/dev/null)
    case "$boundary" in ''|*[!0-9]*) boundary=$((now + TICK)) ;; esac
    wait=$((boundary - now))
    [ "$wait" -gt "$TICK" ] && wait=$TICK
    [ "$wait" -lt 1 ] && wait=1
    sleep "$wait" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""

    mode=$("$THEME" now 2>/dev/null)
    if [ -n "$MODE_NOW" ] && [ -n "$mode" ] && [ "$mode" != "$MODE_NOW" ]; then
        if [ "$PAUSED" = "1" ] || { [ "$PAUSE_ON_FULLSCREEN" = "1" ] && fullscreen_present; }; then
            recolor
        fi
        MODE_DUE=1
    fi
    [ -n "$mode" ] && MODE_NOW="$mode"

    # Frozen while paused. Nothing is owed either: pausing anchored the
    # sequence at the wallpaper on screen, so that one IS current. (A light/
    # dark switch during the pause is settled at unpause, above.)
    [ "$PAUSED" = "1" ] && { OWED=0; MODE_DUE=0; continue; }
    now=$(date +%s)
    # woke for the tick, not the change (unless one is owed)
    [ "$now" -lt "$boundary" ] && [ "$OWED" = "0" ] && [ "$MODE_DUE" = "0" ] && continue
    # Boundary reached (or owed) — hold off while a fullscreen app is up.
    # Nothing is lost by waiting: the step comes from the clock, so when it does
    # fire it lands on whichever wallpaper is current rather than replaying a
    # backlog.
    if [ "$PAUSE_ON_FULLSCREEN" = "1" ] && fullscreen_present; then OWED=1; continue; fi
    OWED=0; MODE_DUE=0
    # random lands on the sequence's pick in the current mode's list — the same
    # one a mirror in that mode computes.
    "$CYCLE" random
    # Another change held the lock: try the mode switch again next tick.
    fits_mode || MODE_DUE=1
done
