#!/usr/bin/env bash
# ============================================================================
#  Technicolor effects governor — step desktop effects down under load.
#
#  ⚠️ THIS CONFIG USES THE LUA PARSER. `hyprctl keyword` DOES NOT WORK:
#       $ hyprctl keyword plugin:hyprglass:enabled 0
#       keyword can't work with non-legacy parsers. Use eval.
#     It fails SILENTLY from a script's point of view (exit 0, message on
#     stdout), so a governor built on `keyword` looks like it works, changes
#     nothing, and any measurement you take of it is just noise. Everything
#     here goes through `hyprctl eval hl.config({...})` instead, the same path
#     Settings → Glass uses (see hyprglass-set.sh).
#
#  TYPES MATTER in hl.config: the hyprglass keys are INTs (0/1) and Hyprland's
#  own animations/shadow keys are BOOLs (true/false). Passing 0 where a bool is
#  expected does not throw — it just does nothing.
#
#  WHY TWO MECHANISMS AND NOT ONE:
#    GPU TIME and VRAM behave differently, and only one can be reclaimed
#    reactively.
#      GPU time — a continuous budget. Stop spending it and whatever else is
#                 running gets it back on the next frame. Polling works.
#      VRAM     — allocated up front. llama.cpp/ComfyUI size their allocation
#                 when the model LOADS; handing memory back afterwards gives
#                 them nothing. Polling CANNOT fix this: by the time
#                 utilisation rises, the allocation already happened.
#    So `daemon` covers games and surprises, and an explicit `tier`/`off`
#    call before a model loads covers VRAM.
#
#  WHY RUNTIME-ONLY:
#    Everything here evaporates on `hyprctl reload`. That is deliberate — the
#    governor can never corrupt hyprland.lua or your Glass tuning, and a
#    reload is always a clean escape hatch.
# ============================================================================
set -u

CONF="${HOME}/.config/hypr/effects-governor.conf"
STATE="${XDG_RUNTIME_DIR:-/tmp}/technicolor-governor.tier"

# ── defaults (overridden by $CONF) ──────────────────────────────────────────
ENABLED=1
GPU_HIGH=70
GPU_LOW=45
POLL_SECONDS=2
MAX_TIER=3
BATTERY_ENABLED=1
BATTERY_LOW=25
BATTERY_TIER=2
[ -f "$CONF" ] && . "$CONF"

# ── tiers ───────────────────────────────────────────────────────────────────
#   0  everything on
#   1  shimmer off              (animated glass; key absent until that ships)
#   2  + layer glass off        (bar/popups plain; windows keep glass)
#   3  + hyprglass off entirely (per-window shader + blur — the big one)
#   4  + animations and shadows off (manual only; governor stops at MAX_TIER)

has_key() { hyprctl getoption "$1" -j >/dev/null 2>&1; }

# Read an option regardless of whether it reports as bool/int/str. Returns
# 1/0 for booleans so callers can compare uniformly.
get_key() {
    hyprctl getoption "$1" -j 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
v = d.get("bool", d.get("int", d.get("str", "?")))
print(1 if v is True else 0 if v is False else v)' 2>/dev/null
}

apply_tier() {
    local t="$1" gl lay sh anim
    gl=$([ "$t" -ge 3 ] && echo 0 || echo 1)      # int
    lay=$([ "$t" -ge 2 ] && echo 0 || echo 1)     # int
    sh=$([ "$t" -ge 1 ] && echo 0 || echo 1)      # int
    anim=$([ "$t" -ge 4 ] && echo false || echo true)  # BOOL, not 0/1

    # The shimmer key does not exist until animated glass ships, and hyprglass
    # may not be installed at all. Including an unknown key would make the
    # whole eval fail, taking the tier that actually matters down with it.
    local hg="enabled=${gl},layers={enabled=${lay}}"
    has_key plugin:hyprglass:shimmer:enabled && hg="${hg},shimmer={enabled=${sh}}"

    local lua="{"
    has_key plugin:hyprglass:enabled && lua="${lua}plugin={hyprglass={${hg}}},"
    lua="${lua}animations={enabled=${anim}},decoration={shadow={enabled=${anim}}}}"

    hyprctl eval "hl.config(${lua}) return 1" >/dev/null 2>&1
    echo "$t" > "$STATE"
}

current_tier() { [ -f "$STATE" ] && cat "$STATE" 2>/dev/null || echo 0; }

# ── sensors ─────────────────────────────────────────────────────────────────
# Absent on some drivers → -1 means "unknown", NOT "idle", so a missing sensor
# can never silently strip the user's effects.
gpu_busy() {
    local f
    for f in /sys/class/drm/card*/device/gpu_busy_percent; do
        [ -r "$f" ] && { cat "$f" 2>/dev/null || echo -1; return; }
    done
    echo -1
}

# A LAPTOP battery, not a peripheral. Wireless mice enumerate as type=Battery
# with scope=Device — testing only `type` puts battery sliders on a desktop
# because the MOUSE has a battery. scope is the discriminator.
battery_path() {
    local d
    for d in /sys/class/power_supply/*/; do
        [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
        [ "$(cat "$d/scope" 2>/dev/null)" = "Device" ] && continue
        echo "$d"; return
    done
}
# Is a real fullscreen app (a game, usually) on screen?
#
# WHY THIS EXISTS ALONGSIDE THE GPU CHECK: gpu_busy_percent only trips the
# governor if a game actually pushes past GPU_HIGH. A frame-capped or CPU-bound
# game can sit at 40-60% and never trigger it, which is the exact case people
# most want handled. Fullscreen is deterministic — a game going fullscreen is
# not a heuristic, it is the event itself.
#
# `fullscreen` is 0 none / 1 maximized / 2 real fullscreen. Only 2 counts:
# maximized is just a big window (a browser, an editor) and must NOT strip
# someone's desktop effects while they work.
fullscreen_app() {
    [ "${FULLSCREEN_ENABLED:-1}" = "1" ] || return 1
    hyprctl clients -j 2>/dev/null | python3 -c '
import sys, json
try: cs = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(c.get("fullscreen") == 2 for c in cs) else 1)' 2>/dev/null
}

on_battery()  { local d; d="$(battery_path)"; [ -n "$d" ] && [ "$(cat "$d/status" 2>/dev/null)" = "Discharging" ]; }
battery_pct() { local d; d="$(battery_path)"; [ -n "$d" ] && cat "$d/capacity" 2>/dev/null || echo 100; }

# ── the governor loop ───────────────────────────────────────────────────────
# HYSTERESIS: step down at GPU_HIGH, back up only below GPU_LOW. The gap stops
# a workload hovering near one number from flapping the desktop every 2s.
#
# DRIFT CHECK, not blind re-apply: a `hyprctl reload` (a wallpaper change does
# one) resets every runtime value to the config default — which IS tier 0. So
# while holding a reduced tier we read ONE key and only re-issue if it drifted
# back. At tier 0 there is nothing to hold, so an idle desktop sends zero IPC.
daemon() {
    local tier=0 busy bat want
    apply_tier 0
    while :; do
        [ -f "$CONF" ] && . "$CONF"
        if [ "${ENABLED:-1}" != "1" ]; then
            [ "$tier" -ne 0 ] && { tier=0; apply_tier 0; }
            sleep "${POLL_SECONDS:-2}"; continue
        fi

        # GUARD AN INVERTED CONF. If GPU_LOW >= GPU_HIGH the two branches below
        # are both true at the same load, and the tier flaps every poll — the
        # exact thrash the hysteresis exists to prevent. Settings clamps this,
        # but a hand-edited conf can still express it, so the floor lives here
        # too. (Observed for real: GPU_HIGH=3/GPU_LOW=45 oscillated 2-3-2-3.)
        if [ "$GPU_LOW" -ge "$GPU_HIGH" ]; then
            GPU_LOW=$((GPU_HIGH - 5))
            [ "$GPU_LOW" -lt 0 ] && GPU_LOW=0
        fi

        # A fullscreen app pins the tier immediately — no ramp, no waiting for a
        # threshold that a frame-capped game might never cross. Dropping straight
        # to the floor also means the effects are gone BEFORE the game finishes
        # loading, rather than stepping down over six seconds while it stutters.
        if fullscreen_app; then
            tier="$MAX_TIER"
        else
            busy="$(gpu_busy)"
            if [ "$busy" -ge 0 ] 2>/dev/null; then
                if   [ "$busy" -ge "$GPU_HIGH" ] && [ "$tier" -lt "$MAX_TIER" ]; then tier=$((tier+1))
                elif [ "$busy" -le "$GPU_LOW"  ] && [ "$tier" -gt 0 ];            then tier=$((tier-1))
                fi
            fi
        fi

        # Battery floor: while discharging and low, never sit above this tier.
        if [ "${BATTERY_ENABLED:-1}" = "1" ] && on_battery; then
            bat="$(battery_pct)"
            [ "$bat" -le "$BATTERY_LOW" ] && [ "$tier" -lt "$BATTERY_TIER" ] && tier="$BATTERY_TIER"
        fi

        if [ "$tier" -ne "$(current_tier)" ]; then
            apply_tier "$tier"
        elif [ "$tier" -gt 0 ]; then
            want=$([ "$tier" -ge 3 ] && echo 0 || echo 1)
            [ "$(get_key plugin:hyprglass:enabled)" != "$want" ] && apply_tier "$tier"
        fi
        sleep "${POLL_SECONDS:-2}"
    done
}

case "${1:-status}" in
    daemon) daemon ;;
    tier)   apply_tier "${2:-0}" ;;
    off)    apply_tier 4 ;;
    on)     apply_tier 0 ;;
    status)
        echo "tier:     $(current_tier)"
        echo "gpu_busy: $(gpu_busy)%"
        echo "enabled:  ${ENABLED}"
        b="$(battery_path)"
        if [ -n "$b" ]; then echo "battery:  $(battery_pct)% ($(cat "$b/status" 2>/dev/null))"
        else echo "battery:  none (desktop — battery settings hidden)"; fi
        for k in plugin:hyprglass:enabled plugin:hyprglass:layers:enabled animations:enabled decoration:shadow:enabled; do
            has_key "$k" && printf '  %-38s = %s\n' "$k" "$(get_key "$k")"
        done
        ;;
    has-battery) [ -n "$(battery_path)" ] && echo yes || echo no ;;
    *) echo "usage: $0 {daemon|tier N|off|on|status|has-battery}" >&2; exit 1 ;;
esac
