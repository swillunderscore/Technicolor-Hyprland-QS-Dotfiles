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

# Under the Lua config manager `hyprctl keyword` is rejected; apply live via
# `hyprctl eval hl.config({...})`. Colon-namespaced keys (e.g. dark:brightness,
# layers:enabled) must become NESTED tables — build the nested form from KEY.
_hg_eval() {
    local key="$1" val="$2" inner part i
    local IFS=':'; local -a parts=($key); unset IFS
    for ((i=${#parts[@]}-1; i>=0; i--)); do
        part="${parts[$i]}"
        if [ "$i" -eq "$((${#parts[@]}-1))" ]; then
            inner="$part=$val"
        else
            inner="$part={$inner}"
        fi
    done
    hyprctl eval "hl.config({plugin={hyprglass={$inner}}}) return 1" >/dev/null 2>&1
}
_hg_eval "$KEY" "$VAL"

touch "$CONF"
# Replace any existing override for this key, then append the new one.
grep -v "^plugin:hyprglass:$KEY = " "$CONF" > "$CONF.tmp" 2>/dev/null || true
printf 'plugin:hyprglass:%s = %s\n' "$KEY" "$VAL" >> "$CONF.tmp"
mv "$CONF.tmp" "$CONF"
