#!/usr/bin/env bash
# wlogout-launch.sh — launch wlogout as a compact single-row glass strip in the
# BOTTOM-RIGHT corner of the focused monitor, just above the quickshell bar and
# right-aligned under the bar's power button (which opens it). Margins are computed
# from the focused monitor's real geometry. Styling lives in style.css
# (gen-wlogout-style.py). Toggles closed if already open (no stacking).
set -u

# Single-instance: if wlogout is already open, a second invocation TOGGLES it
# closed (so pressing Super+M or the bar button again dismisses it instead of
# stacking another overlay).
if pgrep -x wlogout >/dev/null 2>&1; then
    pkill -x wlogout
    exit 0
fi

# focused monitor geometry
read -r MW MH MSCALE < <(hyprctl monitors -j | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    if m.get('focused'):
        print(m['width'], m['height'], m.get('scale',1)); break
" 2>/dev/null)
MW="${MW:-2560}"; MH="${MH:-1440}"

# logical size (wlogout margins are in logical px; divide by scale)
SC="${MSCALE:-1}"
LW=$(python3 -c "print(int($MW/$SC))" 2>/dev/null || echo "$MW")
LH=$(python3 -c "print(int($MH/$SC))" 2>/dev/null || echo "$MH")

# compact corner strip: 6 buttons (92px) + spacing(16*5) + padding(22*2) ≈ 696w, ~136h.
STRIP_W=700
STRIP_H=136

# Read the bar height on the focused monitor (gap above it so no overlap).
BAR_H=$(hyprctl layers -j 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
h=50
for mon,info in d.items():
    for lvl in info.get('levels',{}).values():
        for l in lvl:
            if l.get('namespace')=='quickshell:bar':
                h=l.get('h',50)
print(int(h))
" 2>/dev/null)
BAR_H="${BAR_H:-50}"
GAP=12

# Bottom-RIGHT corner: small right margin, large left margin (right-aligned);
# bottom margin clears the bar, large top margin pins it low.
EDGE=12                                   # gap from the right screen edge
RIGHT=$EDGE
LEFT=$(( LW - STRIP_W - EDGE )); [ "$LEFT" -lt 0 ] && LEFT=0
BOT=$(( BAR_H + GAP ))
TOP=$(( LH - STRIP_H - BOT )); [ "$TOP" -lt 0 ] && TOP=0

exec wlogout -b 6 -c 16 -r 16 -L "$LEFT" -R "$RIGHT" -T "$TOP" -B "$BOT" -n \
    -C "$HOME/.config/wlogout/style.css" \
    -l "$HOME/.config/wlogout/layout"
