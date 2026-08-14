#!/usr/bin/env bash
# Set a hyprwater option live AND persist it (Settings → Glass tab).
#   hyprwater-set.sh <key> <value>
# Live: hyprctl keyword. Persist: an override line in hyprwater-tuning.conf,
# which hyprland.conf sources AFTER the defaults, so it survives reloads/restarts.
# <key> may be any plugin:hyprwater key (e.g. refraction_strength, dark:brightness),
# letting the UI's write-in box set anything, including out-of-slider-range values.
set -u

KEY="${1:-}"; VAL="${2:-}"
NEEDS_RELOAD=0
[ -z "$KEY" ] && exit 1
CONF="$HOME/.config/hypr/hyprwater-tuning.conf"

# Under the Lua config manager `hyprctl keyword` is rejected; apply live via
# `hyprctl eval hl.config({...})`. Colon-namespaced keys (e.g. dark:brightness,
# layers:enabled) must become NESTED tables — build the nested form from KEY.
_hg_eval() {
    local key="$1" val="$2" inner part i lit
    # The value is pasted into Lua source, so anything that isn't a number has to
    # be QUOTED or it's a syntax error. String-valued keys (layers:namespaces,
    # layers:namespace_mask_thresholds, presets) contain ':' and '=' and were
    # producing `namespace_mask_thresholds=quickshell:bar=0.002`, which is not
    # Lua. With stderr discarded that failed silently: the file got written, the
    # running plugin never saw it, and the setting only took effect on the next
    # `hyprctl reload`. Numbers and 0x… ints stay bare.
    if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ || "$val" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
        lit="$val"
    else
        lit="\"${val//\"/\\\"}\""
        # String keys need more than a live set. The plugin parses them into
        # cached maps (namespace -> preset, namespace -> mask threshold) and only
        # rebuilds those on the config-reloaded event, so an eval alone updates
        # the stored string and changes nothing on screen. Numbers are read
        # straight from the config pointer each frame and don't need this.
        NEEDS_RELOAD=1
    fi
    local IFS=':'; local -a parts=($key); unset IFS
    for ((i=${#parts[@]}-1; i>=0; i--)); do
        part="${parts[$i]}"
        if [ "$i" -eq "$((${#parts[@]}-1))" ]; then
            inner="$part=$lit"
        else
            inner="$part={$inner}"
        fi
    done
    # Report failures instead of swallowing them — a silent no-op here is
    # indistinguishable from a setting that simply doesn't do anything, which is
    # exactly how the unquoted-string bug above stayed hidden.
    local out
    out="$(hyprctl eval "hl.config({plugin={hyprwater={$inner}}}) return 1" 2>&1)"
    [ "$out" = "ok" ] || printf 'hyprwater-set: live apply failed for %s: %s\n' "$key" "$out" >&2
}
_hg_eval "$KEY" "$VAL"

touch "$CONF"
# Replace any existing override for this key, then append the new one.
grep -v "^plugin:hyprwater:$KEY = " "$CONF" > "$CONF.tmp" 2>/dev/null || true
printf 'plugin:hyprwater:%s = %s\n' "$KEY" "$VAL" >> "$CONF.tmp"
mv "$CONF.tmp" "$CONF"

# See _hg_eval: string-valued keys only take effect once the plugin re-parses
# them, which happens on config reload.
[ "$NEEDS_RELOAD" = 1 ] && hyprctl reload >/dev/null 2>&1
exit 0
