#!/usr/bin/env bash
# Seed each monitor (sorted left-to-right by x position) with consecutive workspaces:
# leftmost monitor → ws1, next → ws2, etc. Refocus the leftmost when done.
#
# Uses focusworkspaceoncurrentmonitor (not `workspace`) so workspaces actually
# get moved between monitors rather than just shifting focus.
sleep 0.3

mapfile -t slot_ids < <(hyprctl monitors -j | jq -r 'sort_by(.x) | .[] | .id')
n=${#slot_ids[@]}

# Build a single batch — leftmost-first, so each monitor's target ws is
# unoccupied (or about-to-be-vacated) when it claims it.
batch=""
for i in "${!slot_ids[@]}"; do
    batch+="dispatch hl.dsp.focus({monitor=\"${slot_ids[$i]}\"}) ; "
    batch+="dispatch hl.dsp.focus({workspace=\"$((i + 1))\", on_current_monitor=true}) ; "
done
batch+="dispatch hl.dsp.focus({monitor=\"${slot_ids[0]}\"})"

hyprctl --batch "$batch"
