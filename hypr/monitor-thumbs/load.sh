#!/usr/bin/env bash
# Build + load monitor-thumbs, the plugin that makes the bar's monitor pictures
# from frames Hyprland already drew (see src/main.cpp). Called from
# hyprland.lua's startup handler.
#
# ABI SAFETY: never dlopen a .so built against a different Hyprland — a stale
# plugin segfaults the compositor inside dlopen and drops the session into
# safe mode. ../plugin-abi.sh rebuilds on any Hyprland/hypr*-library change
# BEFORE loading and refuses to load if that build fails. You then lose the
# bar's monitor pictures (plain color blocks instead, and a critical
# notification says so), never the session.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SO="$DIR/monitor-thumbs.so"
STAMP="$DIR/.abi-stamp"

if [ -r "$DIR/../plugin-abi.sh" ]; then
    . "$DIR/../plugin-abi.sh"
    tc_plugin_guard "$DIR" "$SO" "$STAMP" "Bar monitor pictures (monitor-thumbs)" || exit 0
else
    make -s -B -C "$DIR" >/dev/null 2>&1 && [ -f "$SO" ] || exit 0
fi

hyprctl plugin unload "$SO" >/dev/null 2>&1   # idempotent on re-run
hyprctl plugin load   "$SO" >/dev/null 2>&1
