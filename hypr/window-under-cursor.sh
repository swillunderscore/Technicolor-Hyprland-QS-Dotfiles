#!/usr/bin/env bash
# Print the address of the window UNDER THE CURSOR (the "raycast"). Prints
# NOTHING when the cursor isn't over any window — callers must treat empty as
# "do nothing". There is deliberately NO fallback to the focused window: these
# actions must only ever hit what the mouse is pointing at.
#
# Shared by window-action.sh (Super+Space/V/C float/maximize/close) and
# minimize.sh (Super+scroll) so the ranking lives in exactly one place. Needed
# because input:follow_mouse=2 detaches pointer focus from keyboard focus — the
# built-in dispatchers act on the KEYBOARD-focused window, not the hovered one.
#
#   --at X Y   rank at the given point instead of the live cursor (tests).
#
# Ranking = what is VISUALLY on top at that point. Every rule below was
# verified against rendered pixels (grim hit-tests), not guessed:
#   filter: mapped, visible==true, workspace CURRENTLY DISPLAYED on some
#       monitor (active or active-special), rect contains point.
#       `visible` is load-bearing: Hyprland flips visible=false on windows
#       COVERED by a maximized/fullscreen window, so occluded floats drop out
#       by themselves. But visible stays true for windows on workspaces that
#       are NOT currently shown (other ws of the same monitor, hidden special)
#       — verified: without the displayed-workspace check the raycast picked a
#       kitty from a hidden ws and a steam game from another ws. Hence the
#       active-workspace-set filter; it also means special windows are only
#       targetable while their overlay is actually open.
#   rank:
#       0  pinned                  always drawn above everything
#       1  overFullscreen==true    raised over / opened on top of a maximized
#                                  or fullscreen window -> renders above it
#       2  fullscreen field > 0    maximize (1) or fullscreen (2)
#       3  floating                floats always render above tiled windows,
#                                  no matter the click/focus order
#       4  tiled
#   tie-break within a rank: highest clients-array index. (Clicks, drags and
#   opens move a window to the array end. Focus alone ALSO reorders the array
#   WITHOUT visually raising — the layer ranks make that harmless across
#   layers; it only matters float-vs-float, where real pointer interaction
#   dominates in practice.)

if [ "${1:-}" = "--at" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
    cx=$2 cy=$3
else
    cursor=$(hyprctl cursorpos -j 2>/dev/null)
    cx=$(echo "$cursor" | jq -r '.x // empty')
    cy=$(echo "$cursor" | jq -r '.y // empty')
fi
if [ -z "$cx" ] || [ -z "$cy" ]; then exit 0; fi

# Monitor table: geometry (logical size) + which workspaces are actually on
# screen (active ws + open special ws; 0 = none). Used for two filters:
#   1. candidates must live on a DISPLAYED workspace (anything else is not
#      rendered and must never be a target),
#   2. XWayland PHANTOM exclusion: an xwayland, floating, fullscreen==0 window
#      whose rect EXACTLY equals a full monitor is a lying iconified game
#      window (verified live: "Bloons TD Battles 2" claimed [0,0] 2560x1440
#      over the whole left monitor while not rendered — pixel-tested — and ate
#      every raycast on that monitor). Real steam games are force-fullscreened
#      by windowrule (fs=2) and real windowed games are smaller, so this shape
#      only matches phantoms. Worst case a raycast on such a window does
#      nothing — the safe direction.
mons=$(hyprctl monitors -j | jq -c '[.[] | {
    mx: .x, my: .y,
    mw: ((.width  / .scale) | round),
    mh: ((.height / .scale) | round),
    ws: .activeWorkspace.id,
    sp: (.specialWorkspace.id // 0) }]')

hyprctl clients -j | jq -r --argjson cx "$cx" --argjson cy "$cy" --argjson mons "$mons" '
    [to_entries[] | {i: .key, w: .value} | select(
        .w.mapped == true and .w.visible == true and
        (.w.workspace.id as $wid | any($mons[]; .ws == $wid or .sp == $wid)) and
        (.w.at[0] // 0) <= $cx and $cx < ((.w.at[0] // 0) + (.w.size[0] // 0)) and
        (.w.at[1] // 0) <= $cy and $cy < ((.w.at[1] // 0) + (.w.size[1] // 0)) and
        ((.w as $win |
            $win.xwayland and $win.floating and (($win.fullscreen // 0) == 0) and
            any($mons[]; .mx == $win.at[0] and .my == $win.at[1] and
                         .mw == $win.size[0] and .mh == $win.size[1])
         ) | not)
    )] | sort_by(
        (if .w.pinned then 0
         elif (.w.overFullscreen // false) then 1
         elif (.w.fullscreen // 0) == 2 then 3
         elif (.w.floating or ((.w.fullscreen // 0) == 1)) then 2
         else 4 end),
        (-.i)
    ) | .[0].w.address // empty'
