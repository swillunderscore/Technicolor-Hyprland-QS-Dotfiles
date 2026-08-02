#!/usr/bin/env bash
# Build + load the vendored Hypr-DarkWindow (the Spotify/Brave/Dolphin chromakey
# "glass" plugin — provides the `darkwindow:shade` windowrule field + the tckey
# custom shaders). Built against the SYSTEM Hyprland headers (pkg-config
# hyprland) — no hyprpm, no sudo — so a Hyprland update can't strand it in a
# root-owned /var/cache that needs a password to rebuild. Mirrors hyprwater/load.sh.
# Source vendored from github.com/micha4w/Hypr-DarkWindow. Called from the
# hyprland.lua startup handler.
#
# ABI SAFETY: never dlopen a .so built against a different Hyprland — 0.56.0
# segfaulted on the 0.55.4-built copy and dropped the session into safe mode.
# ../plugin-abi.sh rebuilds on any Hyprland/hypr*-library change BEFORE loading
# and refuses to load if that build fails (you lose chromakey, never the session).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SO="$DIR/out/hypr-darkwindow.so"
STAMP="$DIR/out/.abi-stamp"

if [ -r "$DIR/../plugin-abi.sh" ]; then
    . "$DIR/../plugin-abi.sh"
    tc_plugin_guard "$DIR" "$SO" "$STAMP" "Chromakey glass (Hypr-DarkWindow)" || exit 0
else
    # No guard available: still never load a possibly-stale binary — rebuild it.
    make -s -B -C "$DIR" >/dev/null 2>&1 && [ -f "$SO" ] || exit 0
fi

# Drop any hyprpm-managed copy (user or system store) so ours is the one loaded.
for p in \
    /var/cache/hyprpm/*/*/Hypr-DarkWindow.so \
    "$HOME"/.local/share/hyprpm/*/*/Hypr-DarkWindow.so; do
    [ -f "$p" ] && [ "$p" != "$SO" ] && hyprctl plugin unload "$p" >/dev/null 2>&1
done
hyprctl plugin unload "$SO" >/dev/null 2>&1   # idempotent on re-run
hyprctl plugin load   "$SO" >/dev/null 2>&1
