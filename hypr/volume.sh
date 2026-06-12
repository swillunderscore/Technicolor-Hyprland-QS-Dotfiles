#!/bin/bash
# Adjust volume / mute on the sink the Quickshell bar currently drives.
# The bar publishes that sink's PipeWire id to $XDG_RUNTIME_DIR/quickshell-bar-sink
# (see Bar.qml: publishSink). If the file is missing (bar not up yet) we fall
# back to the system default sink. This only changes the chosen sink's VOLUME —
# it never touches the default sink or any routing.
f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/quickshell-bar-sink"
sink="@DEFAULT_AUDIO_SINK@"
if [ -r "$f" ]; then
    id="$(cat "$f")"
    [ -n "$id" ] && sink="$id"
fi

case "$1" in
    up)   exec wpctl set-volume -l 1 "$sink" 5%+ ;;
    down) exec wpctl set-volume "$sink" 5%- ;;
    mute) exec wpctl set-mute "$sink" toggle ;;
    *)    echo "usage: volume.sh {up|down|mute}" >&2; exit 1 ;;
esac
