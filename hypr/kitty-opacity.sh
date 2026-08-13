#!/usr/bin/env bash
# Set kitty's background transparency and apply it to every window that's already
# open. Called by Technicolor Settings > System > Terminal transparency.
#
# kitty re-reads its config when it gets SIGUSR1, and `dynamic_background_opacity
# yes` is what lets background_opacity actually change on that reload — without it
# kitty locks the opacity at whatever it started with. So there's no remote-control
# socket to enable and no window to restart: write the file, signal, done.
#
# `pkill -x` matches the process NAME exactly. Never use `pkill -f kitty` here — it
# matches this script's own command line (and any shell that spawned it) too.
set -euo pipefail

val="${1:?usage: kitty-opacity.sh <0.0-1.0>}"
conf="$HOME/.config/kitty/kitty.conf"

mkdir -p "$(dirname "$conf")"
touch "$conf"

# Serialize: the settings slider fires a live write on drag and a final one on
# release, so two of these can overlap.
exec 9>"$conf.lock"
flock 9

# dynamic_background_opacity must be on, or the reload below is a no-op.
if grep -qE '^[[:space:]]*dynamic_background_opacity[[:space:]]' "$conf"; then
    sed -i -E 's/^[[:space:]]*dynamic_background_opacity[[:space:]].*/dynamic_background_opacity yes/' "$conf"
else
    printf 'dynamic_background_opacity yes\n%s' "$(cat "$conf")" > "$conf.tmp" && mv "$conf.tmp" "$conf"
fi

if grep -qE '^[[:space:]]*background_opacity[[:space:]]' "$conf"; then
    sed -i -E "s/^[[:space:]]*background_opacity[[:space:]].*/background_opacity $val/" "$conf"
else
    printf 'background_opacity %s\n' "$val" >> "$conf"
fi

pkill -USR1 -x kitty 2>/dev/null || true
