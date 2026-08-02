#!/usr/bin/env bash
# Rebuild and reload without ever writing over a mapped plugin.
# Linking straight onto hyprglass.so while Hyprland has it dlopen'd is a way to
# lose the session: the compositor is executing from that file. Unload first,
# build second, load third.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SO="$DIR/hyprglass.so"
hyprctl plugin unload "$SO" >/dev/null 2>&1
make -C "$DIR" "$@" || exit 1
hyprctl plugin load "$SO"
