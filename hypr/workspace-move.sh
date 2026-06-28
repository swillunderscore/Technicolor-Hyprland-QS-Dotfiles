#!/usr/bin/env bash
# Carousel workspace navigation across N monitors.
# Monitors are ordered left-to-right by their x position. Each monitor shows
# one workspace; they slide together when you go past the edge.
#
# Args:
#   $1 = "left" | "right"
#   $2 = "--move" (optional) — move active window instead of navigating

direction="$1"
move_flag="${2:-}"

LOG="/tmp/carousel.log"
BUSY="/tmp/carousel-busy"
log()  { echo "[$(date +%H:%M:%S.%3N)] move:    $*" >> "$LOG"; }
busy() { date +%s%3N > "$BUSY"; }
busy   # mark immediately so the watcher won't react to the events we're about to fire

state=$(hyprctl monitors -j)
ws_state=$(hyprctl workspaces -j)

focused_mon_id=$(echo "$state" | jq '.[] | select(.focused == true) | .id')

# Sort monitors by x position, build parallel arrays slot_id[i] and slot_ws[i]
mapfile -t sorted < <(echo "$state" | jq -r 'sort_by(.x) | .[] | "\(.id):\(.activeWorkspace.id)"')
mon_count=${#sorted[@]}
declare -a slot_id slot_ws
focused_slot=-1
for i in "${!sorted[@]}"; do
    IFS=: read -r id ws <<< "${sorted[$i]}"
    slot_id[$i]=$id
    slot_ws[$i]=$ws
    [ "$id" = "$focused_mon_id" ] && focused_slot=$i
done

# Fallback if focused monitor wasn't found (shouldn't happen)
[ "$focused_slot" -lt 0 ] && focused_slot=0

slot_summary=""
for i in $(seq 0 $((mon_count - 1))); do
    slot_summary+="slot$i=mon${slot_id[$i]}/ws${slot_ws[$i]} "
done
log "=== $direction $move_flag | N=$mon_count focused=slot$focused_slot(mon$focused_mon_id) | $slot_summary==="

# ─── MOVE WINDOW ──────────────────────────────────────
if [ "$move_flag" = "--move" ]; then
    cur_ws=${slot_ws[$focused_slot]}
    if [ "$direction" = "right" ]; then
        target=$((cur_ws + 1))
    else
        target=$((cur_ws - 1))
        [ "$target" -lt 1 ] && exit 0
    fi
    log "Move active window ws$cur_ws -> ws$target"
    hyprctl dispatch "hl.dsp.window.move({workspace=\"$target\", follow=false})"
    busy
    # workspace-watcher.sh handles preserving the now-empty source workspace
    # if it sits between occupied ones, so no extra dance needed here.
    exit 0
fi

# ─── NAVIGATE ─────────────────────────────────────────
#
# Self-healing model: every slide re-derives slot ws from a single base
# (slot i → base + i). If the current slots are already consecutive,
# advance by ±1; if they're out of order (from monitor hotplug or a prior
# race), the first slide heals in place without advancing, so the user's
# next key press does what they expect.

leftmost_ws=${slot_ws[0]}

# Is slot_ws[i] == leftmost_ws + i for all i?
consistent=true
for i in "${!slot_ws[@]}"; do
    if [ "${slot_ws[$i]}" -ne "$((leftmost_ws + i))" ]; then
        consistent=false
        break
    fi
done

if [ "$direction" = "right" ]; then
    # Not at the rightmost monitor — just shift focus (no realign needed)
    if [ "$focused_slot" -lt $((mon_count - 1)) ] && [ "$consistent" = true ]; then
        next_id=${slot_id[$((focused_slot + 1))]}
        log "Focus slot$focused_slot -> slot$((focused_slot + 1)) (mon$next_id)"
        hyprctl dispatch "hl.dsp.focus({monitor=\"$next_id\"})"
        busy; exit 0
    fi

    if [ "$consistent" = true ]; then
        new_base=$((leftmost_ws + 1))
        mode="advance"
    else
        new_base=$leftmost_ws
        mode="heal"
    fi

elif [ "$direction" = "left" ]; then
    if [ "$focused_slot" -gt 0 ] && [ "$consistent" = true ]; then
        prev_id=${slot_id[$((focused_slot - 1))]}
        log "Focus slot$focused_slot -> slot$((focused_slot - 1)) (mon$prev_id)"
        hyprctl dispatch "hl.dsp.focus({monitor=\"$prev_id\"})"
        busy; exit 0
    fi

    if [ "$consistent" = true ]; then
        new_base=$((leftmost_ws - 1))
        mode="advance"
    else
        new_base=$leftmost_ws
        mode="heal"
    fi
    [ "$new_base" -lt 1 ] && { log "At ws1, can't go left"; exit 0; }
fi

# ── Slide pattern ─────────────────────────────────────
#
# Why this is non-obvious: `focusworkspaceoncurrentmonitor N` when ws N is
# bound to another monitor first NAVIGATES to ws N on that other monitor
# (briefly making it active there) and THEN moves it. The source monitor
# is forced to fall back to some prior workspace from its history, which
# is the random-fallback chaos / mid-slide flicker we kept hitting.
#
# `moveworkspacetomonitor` doesn't have that detour — it rebinds directly.
# Pattern:
#   1. On the "new" slot (the one that will show the ws entering from the
#      slide direction), focus + `dispatch workspace N`. Creates the ws on
#      that slot if it doesn't exist; just focuses it if it already does.
#      Whatever was active on that slot becomes hidden on it.
#   2. Cascade `moveworkspacetomonitor` for the remaining slots, from the
#      slot nearest the new edge toward the far edge. Each step moves a ws
#      whose old occupant just got hidden by the previous step — so no
#      monitor ever has its active ws yanked, no fallback ever happens.
#
# Right slide (slot 0..N-1 → ws base..base+N-1):
#   - new slot = N-1, new ws = base+N-1
#   - cascade i = N-2, N-3, ..., 0
# Left slide:
#   - new slot = 0, new ws = base
#   - cascade i = 1, 2, ..., N-1

if [ "$direction" = "right" ]; then
    new_slot=$((mon_count - 1))
    cascade=$(seq $((mon_count - 2)) -1 0)
else
    new_slot=0
    cascade=$(seq 1 $((mon_count - 1)))
fi

# Iteration: NEW slot first, then cascade outward (toward the opposite edge).
#
# Why this order matters: focusworkspaceoncurrentmonitor on a hidden-but-bound
# workspace on another monitor yanks that ws (and its source mon's active falls
# back to some random history entry — that was the ws3 fallback chaos).
#
# By processing new_slot FIRST, we set the "entering" edge's monitor to its
# brand-new target ws. The OLD ws on that slot is now hidden there. Then each
# cascade step yanks a hidden ws from the slot we just processed — but since
# we're about to OVERWRITE that previous slot's active anyway with its own
# target in the next iteration, the fallback is invisible (overwritten before
# the user sees it). Each monitor ends up doing exactly one transition: its
# current ws → its target ws, in the direction the user actually intended.
#
# Right slide (ws_a, ws_b) → (ws_b, ws_c):
#   1. focus mon1, focusws ws_c → creates ws_c. Mon1: ws_b → ws_c (slides right).
#                                  ws_b is now hidden on mon1.
#   2. focus mon0, focusws ws_b → yanks hidden ws_b from mon1 to mon0.
#                                  Mon1 active stays ws_c. Mon0: ws_a → ws_b.
#
# Left slide (ws_b, ws_c) → (ws_a, ws_b):
#   1. focus mon0, focusws ws_a → creates ws_a. Mon0: ws_b → ws_a (slides left).
#   2. focus mon1, focusws ws_b → yanks hidden ws_b from mon0 to mon1.
#                                  Mon1: ws_c → ws_b (slides left).

order=("$new_slot" $cascade)
batch=""
for i in "${order[@]}"; do
    target_ws=$((new_base + i))
    target_mon=${slot_id[$i]}
    batch+="dispatch hl.dsp.focus({monitor=\"$target_mon\"}) ; dispatch hl.dsp.focus({workspace=\"$target_ws\", on_current_monitor=true}) ; "
done
batch+="dispatch hl.dsp.focus({monitor=\"$focused_mon_id\"})"

log "Slide $direction ($mode, base=$new_base, new_slot=$new_slot): $batch"
hyprctl --batch "$batch"
busy
