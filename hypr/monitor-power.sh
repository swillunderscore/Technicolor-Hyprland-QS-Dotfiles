#!/usr/bin/env bash
# Turn displays off/on over DDC (works remotely, e.g. from a Moonlight
# stream) and keep track of which ones are off.
#
#   monitor-power.sh off|on|toggle NAME   e.g. toggle DP-2
#   monitor-power.sh watch                daemon (started from hyprland.lua)
#
# Off = DDC power mode (VCP D6) 04. Hyprland never finds out, so it keeps
# drawing the output and a stream of that output keeps working. Not dpms:
# dpms stops drawing, which would freeze a stream of it.
#
# State:
#   $XDG_RUNTIME_DIR/tc-monitors-off          names of displays that are off
#   $XDG_RUNTIME_DIR/tc-monitor-power/NAME    "turned off from here" flag;
#                                             holds truthful|lies (below)
# The bar reads tc-monitors-off: an off display that isn't being streamed
# (stream-screens.sh) is offscreen, so its workspace dot is a diamond and
# workspace-move.sh won't hand focus to it.
#
# Measured on two real monitors (2026-10-07), and why every step below exists:
#  - ASUS VP249 (DP-2): D6 04 blanks it, it keeps answering DDC and reads
#    back 04; D6 01 wakes it.
#  - MSI G273Q (DP-1): D6 04 only lands with --noverify (the verify read
#    fails). Blank, but it LIES: still reads D6 01 and its old brightness,
#    so polling can't see it -- hence the flag. D6 01 does NOT wake it; a
#    1 s dpms off/on does (the signal coming back wakes it).
#  - A power-BUTTON off: the display stops answering DDC entirely (the
#    ASUS first reads 05), and the kernel logs "EDID err ... on connector:
#    NAME" at the press. One button press from the MSI's D6 standby is a
#    FULL off, the next press turns it on.
#  - A display that is fully off (button) can't be woken over DDC. Only
#    displays turned off from here can be turned back on remotely.
#  - The MSI resets its brightness ~4-16 s after any cold power-on (read
#    0, once 26), so power-on re-applies the saved slider value
#    (~/.config/hypr/.ddc-brightness-NAME). One-shot per power-on, not an
#    enforcement poll: slider/OSD changes afterwards are left alone.

RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OFF="$RUN/tc-monitors-off"
FLAGS="$RUN/tc-monitor-power"
POLL=10
mkdir -p "$FLAGS"
[ -e "$OFF" ] || : > "$OFF"

bus_of() {
    local c d l
    for c in /sys/class/drm/card*-"$1"; do
        [ -e "$c" ] || continue
        for d in "$c"/i2c-*; do [ -e "$d" ] && { echo "${d##*/i2c-}"; return; }; done
        [ -e "$c/ddc" ] && { l=$(readlink "$c/ddc"); echo "${l##*/i2c-}"; return; }
    done
}

# NAME<TAB>BUS for every connected display with an EDID and a DDC bus
# (same discovery as the bar's brightness sliders).
monitors() {
    local c n b
    for c in /sys/class/drm/card*-*; do
        [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
        [ "$(head -c 8 "$c/edid" 2>/dev/null | wc -c)" = 8 ] || continue
        n=${c##*/}; n=${n#card*-}
        b=$(bus_of "$n")
        case "$b" in ''|*[!0-9]*) continue ;; esac
        printf '%s\t%s\n' "$n" "$b"
    done
}

# Power mode as two hex digits ("01" = on), or nothing if it doesn't answer.
read_d6() {
    timeout 5 ddcutil getvcp D6 --bus "$1" --brief 2>/dev/null \
        | awk '$1 == "VCP" && $2 == "D6" { v = $NF; sub(/^x/, "", v); print v }'
}

read_brightness() {
    timeout 5 ddcutil getvcp 10 --bus "$1" --brief 2>/dev/null \
        | awk '$1 == "VCP" && $2 == "10" && $3 == "C" { print $4 }'
}

# Rewrite the off list under a lock (the daemon and a click can race).
set_off() {   # NAME 1|0
    (
        flock 9
        local cur
        cur=$(grep -vx -- "$1" "$OFF" 2>/dev/null)
        [ "$2" = 1 ] && cur=$(printf '%s\n%s' "$cur" "$1")
        cur=$(printf '%s\n' "$cur" | sed '/^$/d' | sort -u)
        [ "$cur" = "$(cat "$OFF" 2>/dev/null)" ] || printf '%s\n' "$cur" | sed '/^$/d' > "$OFF"
    ) 9>"$OFF.lock"
}

is_off() { grep -qx -- "$1" "$OFF" 2>/dev/null; }

# After a cold power-on, put the saved slider value back once the
# display's controller has finished booting and reset itself.
restore_brightness() {   # NAME BUS
    local f="$HOME/.config/hypr/.ddc-brightness-$1" i saved cur
    for i in $(seq 1 22); do
        sleep 2
        saved=$(cat "$f" 2>/dev/null) || return
        case "$saved" in ''|*[!0-9]*) return ;; esac
        cur=$(read_brightness "$2")
        [ -n "$cur" ] && [ "$cur" != "$saved" ] && ddcutil setvcp 10 "$saved" --bus "$2" >/dev/null 2>&1
    done
}

power_off() {   # NAME BUS
    # Flag first: a poll landing mid-switch must already see "off" (the MSI
    # reads 01 no matter what, so the flag is the only thing that says so).
    echo pending > "$FLAGS/$1"
    set_off "$1" 1
    ddcutil setvcp D6 04 --bus "$2" --noverify >/dev/null 2>&1
    sleep 1.5
    if [ "$(read_d6 "$2")" = 01 ]; then echo lies > "$FLAGS/$1"; else echo truthful > "$FLAGS/$1"; fi
}

power_on() {   # NAME BUS
    # Fully off (power button): nothing to talk to, it stays off.
    [ -n "$(read_d6 "$2")" ] || return 1
    local kind
    kind=$(cat "$FLAGS/$1" 2>/dev/null)
    ddcutil setvcp D6 01 --bus "$2" --noverify >/dev/null 2>&1
    if [ "$kind" = lies ]; then
        hyprctl dispatch "hl.dsp.dpms({mode=\"off\", monitor=\"$1\"})" >/dev/null
        sleep 1
        hyprctl dispatch "hl.dsp.dpms({mode=\"on\", monitor=\"$1\"})" >/dev/null
    fi
    rm -f "$FLAGS/$1"
    set_off "$1" 0
    # Background, and without the per-display click lock, so the display can
    # be switched off again right away.
    restore_brightness "$1" "$2" 7>&- &
}

watch() {
    exec 8>"$RUN/tc-monitor-power.lock"
    flock -n 8 || exit 0

    # Kernel log: a power-button press (or our own dpms wake) logs
    # "EDID err: 2, on connector: NAME". Read through an fd so killing this
    # PID also ends journalctl.
    exec 3< <(journalctl -k -f -n 0 --no-pager 2>/dev/null)
    local jpid=$!
    trap 'kill "$jpid" 2>/dev/null' EXIT
    trap 'exit 0' TERM INT HUP

    declare -A reach=()
    local line name bus d6 off rc seen
    while :; do
        seen=""
        while IFS=$'\t' read -r name bus; do
            seen+="$name"$'\n'
            d6=$(read_d6 "$bus")
            if [ -z "$d6" ]; then
                # Fully off. Whatever turned it off, the flag no longer
                # describes it: the next answer means it was powered on.
                off=1; rm -f "$FLAGS/$name"; reach[$name]=0
            else
                if [ "${reach[$name]:-}" = 0 ]; then
                    restore_brightness "$name" "$bus" &
                fi
                reach[$name]=1
                if [ "$d6" != 01 ] || [ -e "$FLAGS/$name" ]; then off=1; else off=0; fi
            fi
            set_off "$name" "$off"
        done < <(monitors)
        # Forget displays that are gone (unplugged), or they'd stay "off".
        for name in $(cat "$OFF" 2>/dev/null); do
            grep -qx -- "$name" <<< "$seen" || set_off "$name" 0
        done

        IFS= read -r -t "$POLL" -u 3 line
        rc=$?
        if [ "$rc" -eq 0 ]; then
            if [[ "$line" =~ EDID\ err:.*on\ connector:\ ([^[:space:]]+) ]]; then
                rm -f "$FLAGS/${BASH_REMATCH[1]}"
            fi
        elif [ "$rc" -le 128 ]; then
            sleep "$POLL"     # no kernel log to wait on: plain timer
        fi
    done
}

case "${1:-}" in
    watch) watch ;;
    off|on|toggle)
        name="${2:?usage: monitor-power.sh off|on|toggle NAME}"
        bus=$(bus_of "$name")
        [ -n "$bus" ] || exit 1
        exec 7>"$RUN/tc-monitor-power-$name.lock"
        flock -n 7 || exit 0          # a click while the last one is still running
        action=$1
        if [ "$action" = toggle ]; then
            if is_off "$name"; then action=on; else action=off; fi
        fi
        if [ "$action" = off ]; then power_off "$name" "$bus"; else power_on "$name" "$bus"; fi
        ;;
    *)
        echo "usage: monitor-power.sh off|on|toggle NAME | watch" >&2
        exit 2 ;;
esac
