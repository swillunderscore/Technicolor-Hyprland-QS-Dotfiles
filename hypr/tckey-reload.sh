#!/usr/bin/env bash
# tckey-reload.sh — reload the Spotify chromakey shader after editing
# technicolor-chromakey.glsl or its args in hyprland.conf.
#
# Needed because the plugin caches shader args across plain `hyprctl reload`s:
# the only reliable flush is a full plugin unload/load cycle, then a config
# reload, then a Spotify relaunch (the windowrule applies at window open).
set -e
SO="$HOME/.config/hypr/Hypr-DarkWindow/out/hypr-darkwindow.so"

hyprctl plugin unload "$SO" >/dev/null || true
sleep 0.3
hyprctl plugin load "$SO" >/dev/null
sleep 0.3
hyprctl reload >/dev/null
sleep 0.7
# second reload settles the shader<->windowrule registration race
hyprctl reload >/dev/null
sleep 0.5

addr=$(hyprctl clients -j | python3 -c "
import json,sys
[print(c['address']) for c in json.load(sys.stdin) if c['class']=='Spotify']" | head -1)
if [ -n "$addr" ]; then
    hyprctl dispatch closewindow "address:$addr" >/dev/null
    sleep 2
fi
setsid -f spotify >/dev/null 2>&1 9>&-
echo "tckey reloaded; spotify relaunching"
