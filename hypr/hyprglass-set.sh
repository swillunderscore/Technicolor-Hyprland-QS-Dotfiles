#!/usr/bin/env bash
# Set a hyprglass option live AND persist it (Settings → Glass tab).
#   hyprglass-set.sh <key> <value>
# Live: hyprctl keyword. Persist: an override line in hyprglass-tuning.conf,
# which hyprland.conf sources AFTER the defaults, so it survives reloads/restarts.
# <key> may be any plugin:hyprglass key (e.g. refraction_strength, dark:brightness),
# letting the UI's write-in box set anything, including out-of-slider-range values.
set -u

KEY="${1:-}"; VAL="${2:-}"
[ -z "$KEY" ] && exit 1
CONF="$HOME/.config/hypr/hyprglass-tuning.conf"

hyprctl keyword "plugin:hyprglass:$KEY" "$VAL" >/dev/null 2>&1

touch "$CONF"
# Replace any existing override for this key, then append the new one.
grep -v "^plugin:hyprglass:$KEY = " "$CONF" > "$CONF.tmp" 2>/dev/null || true
printf 'plugin:hyprglass:%s = %s\n' "$KEY" "$VAL" >> "$CONF.tmp"
mv "$CONF.tmp" "$CONF"
