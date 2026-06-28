#!/usr/bin/env bash
# Open a folder in Dolphin, REUSING an existing window — un-minimize + raise +
# navigate it — instead of spawning a new window every time. Falls back to
# launching Dolphin if none is open. Arg: $1 = a path or a file:// URI.
#
# Dolphin spawns a new window per external open and won't un-minimize an existing
# one (Hyprland "minimize" = special:minimized workspace, which it can't see), so
# we drive it explicitly: find the window via hyprctl, restore+raise it, then use
# Dolphin's openDirectories D-Bus method (which reuses the window) to show the path.
set -u

raw="${1:-$HOME}"
path="${raw#file://}"
uri="file://$path"

read -r addr pid ws < <(hyprctl clients -j 2>/dev/null \
    | jq -r '[.[] | select(.class=="org.kde.dolphin")][0] as $d
             | if $d then "\($d.address) \($d.pid) \($d.workspace.name)" else "" end')

if [ -n "${addr:-}" ] && [ "$addr" != "null" ]; then
    # un-minimize (if stashed) + focus + raise above other floating windows
    if [ "$ws" = "special:minimized" ]; then
        cur=$(hyprctl activeworkspace -j | jq -r '.id')
        hyprctl dispatch "hl.dsp.window.move({workspace=\"$cur\", window=\"address:$addr\"})" >/dev/null 2>&1
    fi
    hyprctl --batch "dispatch hl.dsp.focus({window=\"address:$addr\"}) ; dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:$addr\"})" >/dev/null 2>&1
    # navigate that same window to the folder (reuses it — no new window)
    gdbus call --session --dest "org.kde.dolphin-$pid" --object-path /dolphin/Dolphin_1 \
        --method org.kde.dolphin.MainWindow.openDirectories "['$uri']" false >/dev/null 2>&1
else
    # No existing window: launch via the themed wrapper (LD_PRELOAD shim + QSS),
    # NOT plain `dolphin`, so the new window gets the chromakey transparency +
    # recolor like a normally-opened one.
    setsid "$HOME/.config/hypr/dolphin-tc.sh" "$path" >/dev/null 2>&1 &
fi
