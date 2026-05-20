#!/usr/bin/env bash
# workspace-watcher.sh — keep the carousel invariant true even when external
# events shift monitor/workspace state. External triggers we've seen: mouse
# crossing a monitor edge (Hyprland re-focuses the new monitor), an app
# opening on the wrong workspace, Hyprland GC'ing an empty workspace and
# something else re-creating it on the focused monitor instead of where it
# belongs.
#
# Invariant: monitor at slot i (sorted left-to-right by x) shows ws (base+i)
# for some base >= 1. When that breaks, realign — anchored on the focused
# monitor so what the user is looking at does NOT move.
#
# Coordination: BUSY marker file is touched by us AND by workspace-move.sh
# whenever they dispatch carousel changes; the heal handler ignores events
# for a brief window after that to avoid fighting its own dispatches.

LOG="/tmp/carousel.log"
BUSY="/tmp/carousel-busy"
HEAL_LOCK="/tmp/carousel-heal.lock"
log() { echo "[$(date +%H:%M:%S.%3N)] watcher: $*" >> "$LOG"; }

# Touch BUSY to suppress event handling for ~BUSY_MS after our own dispatches
busy()    { date +%s%3N > "$BUSY"; }
is_busy() {
    local deadline_ms=$1
    [ -f "$BUSY" ] || return 1
    local then now
    then=$(cat "$BUSY" 2>/dev/null || echo 0)
    now=$(date +%s%3N)
    [ $((now - then)) -lt "$deadline_ms" ]
}

# Compute and apply realignment so that slot i shows (base + i) where base is
# anchored on the focused monitor's current ws. Idempotent — bails if already
# consistent.
realign_anchored() {
    sleep 0.15  # let Hyprland settle after the event burst

    is_busy 500 && { log "skip realign (busy)"; return; }

    local state focused_id sorted mon_count focused_slot=-1 focused_ws
    state=$(hyprctl monitors -j 2>/dev/null) || return
    focused_id=$(echo "$state" | jq '.[] | select(.focused == true) | .id // empty')
    mapfile -t sorted < <(echo "$state" | jq -r 'sort_by(.x) | .[] | "\(.id):\(.activeWorkspace.id)"')
    mon_count=${#sorted[@]}
    [ "$mon_count" -lt 1 ] && return

    local -a slot_ids=() slot_wss=()
    local i id ws
    for i in "${!sorted[@]}"; do
        IFS=: read -r id ws <<< "${sorted[$i]}"
        slot_ids[$i]=$id
        slot_wss[$i]=$ws
        [ "$id" = "$focused_id" ] && focused_slot=$i
    done
    [ "$focused_slot" -lt 0 ] && focused_slot=0
    focused_ws=${slot_wss[$focused_slot]}

    # Anchor: focused monitor stays on its current ws; everyone else shifts.
    local base=$((focused_ws - focused_slot))
    [ "$base" -lt 1 ] && base=1

    local consistent=true
    for i in "${!slot_wss[@]}"; do
        if [ "${slot_wss[$i]}" -ne "$((base + i))" ]; then
            consistent=false; break
        fi
    done
    if [ "$consistent" = true ]; then
        return
    fi

    # Process focused slot LAST so its ws doesn't get yanked.
    # For non-focused slots: pick an order such that each move's "victim"
    # (the source monitor losing its active ws) is a slot we'll overwrite
    # later in the iteration.
    local -a order=()
    if [ "$focused_slot" -gt 0 ]; then
        for ((i=0; i<focused_slot; i++)); do order+=("$i"); done
    fi
    if [ "$focused_slot" -lt $((mon_count - 1)) ]; then
        for ((i=mon_count - 1; i>focused_slot; i--)); do order+=("$i"); done
    fi
    order+=("$focused_slot")

    busy
    local batch=""
    for i in "${order[@]}"; do
        local target=$((base + i))
        [ "$target" -lt 1 ] && continue
        # Skip if already correct (cheap; saves a no-op dispatch)
        if [ "${slot_wss[$i]}" = "$target" ]; then continue; fi
        batch+="dispatch focusmonitor ${slot_ids[$i]} ; "
        batch+="dispatch focusworkspaceoncurrentmonitor $target ; "
    done
    [ -n "$focused_id" ] && batch+="dispatch focusmonitor $focused_id"

    if [ -z "$batch" ]; then
        return
    fi

    log "realign: base=$base N=$mon_count focused_slot=$focused_slot curr=[${slot_wss[*]}] → $batch"
    hyprctl --batch "$batch" > /dev/null 2>&1
    busy
}

# Singleton: only ever ONE heal pending at a time. Rapid events all try to
# schedule; only the first wins. After it runs, if state is still off, the
# next event will schedule again.
schedule_heal() {
    (
        exec 9>"$HEAL_LOCK"
        flock -n 9 || exit 0
        realign_anchored
    ) &
}

# Recreate a destroyed workspace IF its slot in the carousel is still in
# view, or if there is occupied content to the right of it. Recreate it on
# the CORRECT monitor (the slot it belongs to), not the focused one.
handle_destroy() {
    local destroyed_id=$1
    [ "$destroyed_id" -le 0 ] 2>/dev/null && return

    local state sorted mon_count focused_id
    state=$(hyprctl monitors -j 2>/dev/null) || return
    focused_id=$(echo "$state" | jq '.[] | select(.focused == true) | .id // empty')
    mapfile -t sorted < <(echo "$state" | jq -r 'sort_by(.x) | .[] | "\(.id):\(.activeWorkspace.id)"')
    mon_count=${#sorted[@]}
    [ "$mon_count" -lt 1 ] && return

    local -a slot_ids=() slot_wss=()
    local i id ws focused_slot=-1
    for i in "${!sorted[@]}"; do
        IFS=: read -r id ws <<< "${sorted[$i]}"
        slot_ids[$i]=$id
        slot_wss[$i]=$ws
        [ "$id" = "$focused_id" ] && focused_slot=$i
    done
    [ "$focused_slot" -lt 0 ] && focused_slot=0

    # Where SHOULD the destroyed ws live in the carousel?
    # Derive base from the focused slot (same anchor as realign).
    local base=$((slot_wss[focused_slot] - focused_slot))
    [ "$base" -lt 1 ] && base=1
    local target_slot=$((destroyed_id - base))

    # Case 1: destroyed ws's carousel slot is currently in view.
    # Recreate immediately on the correct monitor so the slot doesn't go blank.
    if [ "$target_slot" -ge 0 ] && [ "$target_slot" -lt "$mon_count" ]; then
        busy
        log "destroy>>ws$destroyed_id was carousel slot $target_slot — recreating on mon${slot_ids[$target_slot]}"
        hyprctl --batch \
            "dispatch focusmonitor ${slot_ids[$target_slot]} ; \
             dispatch workspace $destroyed_id ; \
             dispatch focusmonitor $focused_id" > /dev/null 2>&1
        busy
        return
    fi

    # Case 2: destroyed ws is OUTSIDE the carousel view but content exists
    # further right — preserve the gap so navigating back finds it.
    local max_ws
    max_ws=$(hyprctl workspaces -j | jq '[.[] | select(.id > 0 and .windows > 0)] | if length > 0 then max_by(.id).id else 0 end')
    if [ "$destroyed_id" -lt "$max_ws" ]; then
        # Recreate on FOCUSED monitor briefly, then return — no slot to honor
        local cur=${slot_wss[$focused_slot]}
        busy
        log "destroy>>ws$destroyed_id (out of view; max content=ws$max_ws) — gap-preserve on focused"
        hyprctl --batch "dispatch workspace $destroyed_id ; dispatch workspace $cur" > /dev/null 2>&1
        busy
    fi
}

SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
log "started (pid $$)"

socat -U - "UNIX-CONNECT:$SOCK" 2>/dev/null | while read -r line; do
    case "$line" in
        monitoraddedv2*|monitorremovedv2*)
            log "event: ${line%%>>*}"
            schedule_heal
            ;;
        # NOT listening to: destroyworkspacev2 (move.sh creates wss it needs;
        # auto-recreate fires on the wrong monitor and poisons move.sh's view
        # of bindings), workspacev2 / focusedmonv2 (fire constantly during
        # alt-tab pie, mouse-cross, app launches — auto-healing fought user
        # intent). Move.sh self-heals on the next slide if state desynced.
    esac
done
