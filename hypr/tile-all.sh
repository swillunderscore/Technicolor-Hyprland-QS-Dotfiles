#!/usr/bin/env bash
# Toggle EVERY window on the active workspace between tiled and floating.
#
# hyprlang's `workspaceopt allfloat` has no Lua equivalent. Probed on 0.56.1:
# hl.dsp.workspaceopt is nil, and while hl.dsp.workspace exists as a table it has
# no opt/allfloat/all_float/float_all member. So this walks the workspace and
# flips windows individually, via the same dispatcher window-action.sh uses for
# the single-window toggle.
#
# Doing it per-window is also better behaved than allfloat was: allfloat is a
# blind toggle, so on a mixed workspace it inverts each window instead of
# unifying them. This picks a target state first (see below).
#
# hl.dsp.window.float is a TOGGLE, so firing it at every window would invert a
# mixed workspace rather than unify it. Instead: pick a target state, then only
# toggle the windows that disagree with it.

set -uo pipefail

ws=$(hyprctl activeworkspace -j 2>/dev/null \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
[ -z "${ws:-}" ] && exit 0

# NOTE: the filter below must use `python3 -c`, not `python3 - <<HEREDOC`. With a
# heredoc, Python reads its PROGRAM from stdin, which is the same stdin the
# hyprctl pipe uses - json.load(sys.stdin) then sees nothing.
#
# Windows on this workspace that are mapped and not hidden. Hidden covers the
# scratchpad and minimised windows; flipping those would yank them into view.
mapfile -t rows < <(hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
ws = int(sys.argv[1])
for c in json.load(sys.stdin):
    if c.get("workspace", {}).get("id") != ws:               continue
    if not c.get("mapped", False) or c.get("hidden", False): continue
    if c.get("fullscreen"):                                  continue
    print(c["address"], 1 if c.get("floating") else 0)
' "$ws" 2>/dev/null)

[ "${#rows[@]}" -eq 0 ] && exit 0

tiled=0
for r in "${rows[@]}"; do [ "${r##* }" = "0" ] && tiled=$((tiled + 1)); done

# Any tiled window present -> float everything. Otherwise -> tile everything.
if [ "$tiled" -gt 0 ]; then want=0; else want=1; fi

batch=""
for r in "${rows[@]}"; do
    addr="${r%% *}"; isfloat="${r##* }"
    [ "$isfloat" = "$want" ] || continue
    batch+="dispatch hl.dsp.window.float({window=\"address:$addr\"}) ; "
done

# --batch so the whole workspace flips in one pass instead of visibly cascading
[ -n "$batch" ] && hyprctl --batch "${batch% ; }" >/dev/null 2>&1
exit 0
