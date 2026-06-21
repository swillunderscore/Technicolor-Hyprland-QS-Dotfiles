#!/usr/bin/env bash
# Load Technicolor's patched hyprglass.
#
# Upstream hyprglass caches a glass LAYER surface's sampled backdrop and only
# refreshes it when a window behind moves / focus / workspace changes, or the
# layer itself animates — never on a wallpaper frame. So the alt-tab pie's
# liquid glass froze the (animated) wallpaper it captured when it mapped. The
# one-line patch (src/GlassLayerSurface.cpp, kForceLiveLayer) forces glass
# layers to re-sample every frame.
#
# The BSD-3 source is vendored next to this script (see ./LICENSE) and built
# locally — no hyprpm, no fork. Called from hyprland.conf right after
# `hyprpm reload`, so it can replace any hyprpm-loaded copy.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SO="$DIR/hyprglass.so"

build()  { make -s -C "$DIR"; }
loaded() { hyprctl plugins list 2>/dev/null | grep -qi hyprglass; }

[ -f "$SO" ] || build

# Drop any OTHER hyprglass already loaded (e.g. an hyprpm-managed copy in either
# the user or the system store) so ours is the one in effect.
for p in \
    "$HOME"/.local/share/hyprpm/*/hyprglass.so \
    "$HOME"/.local/share/hyprpm/*/*/hyprglass.so \
    /var/cache/hyprpm/*/*/hyprglass.so; do
    [ -f "$p" ] && [ "$p" != "$SO" ] && hyprctl plugin unload "$p" >/dev/null 2>&1
done
hyprctl plugin unload "$SO" >/dev/null 2>&1   # idempotent on re-run
hyprctl plugin load   "$SO" >/dev/null 2>&1

# Didn't take? The binary is ABI-stale after a Hyprland update -> FORCE a
# rebuild (-B; plain `make` sees the .so newer than sources and skips it), reload.
loaded || { make -s -B -C "$DIR"; hyprctl plugin load "$SO" >/dev/null 2>&1; }
