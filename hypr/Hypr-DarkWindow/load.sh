#!/usr/bin/env bash
# Build + load the vendored Hypr-DarkWindow (the Spotify/Brave/Dolphin chromakey
# "glass" plugin — provides the `darkwindow:shade` windowrule field + the tckey
# custom shaders). Built against the SYSTEM Hyprland headers (pkg-config
# hyprland) — no hyprpm, no sudo — so a Hyprland update can't strand it in a
# root-owned /var/cache that needs a password to rebuild. Mirrors hyprglass/load.sh.
# Source vendored from github.com/micha4w/Hypr-DarkWindow. Called from
# hyprland.conf's plugin exec-once.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SO="$DIR/out/hypr-darkwindow.so"

loaded() { hyprctl plugins list 2>/dev/null | grep -qi darkwindow; }

[ -f "$SO" ] || make -s -C "$DIR" >/dev/null 2>&1

# Drop any hyprpm-managed copy (user or system store) so ours is the one loaded.
for p in \
    /var/cache/hyprpm/*/*/Hypr-DarkWindow.so \
    "$HOME"/.local/share/hyprpm/*/*/Hypr-DarkWindow.so; do
    [ -f "$p" ] && [ "$p" != "$SO" ] && hyprctl plugin unload "$p" >/dev/null 2>&1
done
hyprctl plugin unload "$SO" >/dev/null 2>&1   # idempotent on re-run
hyprctl plugin load   "$SO" >/dev/null 2>&1

# Didn't take? The binary is ABI-stale after a Hyprland update -> FORCE a rebuild
# (-B; plain make would see the .so newer than sources and skip it), then reload.
loaded || { make -s -B -C "$DIR" >/dev/null 2>&1; hyprctl plugin load "$SO" >/dev/null 2>&1; }
