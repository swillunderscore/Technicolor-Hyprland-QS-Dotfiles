#!/usr/bin/env bash
# Shared ABI guard for the vendored Hyprland plugins (hyprglass, Hypr-DarkWindow).
#
# WHY THIS EXISTS: a plugin .so built against one Hyprland is not loadable by
# another. Hyprland 0.56.0 did not *reject* the 0.55.4-built Hypr-DarkWindow —
# it SEGFAULTED inside dlopen() while loading it, which killed the compositor,
# and the watchdog then relaunched the session in --safe-mode (no user config,
# one emergency keybind). The old "load it, and if that didn't take, rebuild
# and retry" fallback could never run: the process was already dead.
#
# So: NEVER dlopen a .so that wasn't built against the CURRENT Hyprland. Stamp
# each build with an ABI fingerprint, and before loading:
#   stamp == current  -> load it
#   stamp != current  -> rebuild first; load only if the rebuild succeeded
#   build fails       -> DO NOT LOAD, notify, exit clean
# A plugin that can't be built for this Hyprland now costs you that plugin's
# effect (glass / chromakey) and nothing else — the session always comes up.
#
# Sourced by each plugin's load.sh; if this file is missing they fall back to
# building unconditionally, which is slower but still never loads a stale .so.

# Fingerprint everything that determines plugin ABI: the exact Hyprland source
# commit + tag (from the installed headers) and the versions of every hypr*
# library a plugin links against. Catches same-version package rebuilds against
# a newer hyprutils/aquamarine, which are equally fatal.
tc_abi_key() {
    {
        grep -oE '"[^"]+"' /usr/include/hyprland/src/version.h 2>/dev/null | tr -d '"'
        for p in hyprland hyprutils hyprlang hyprgraphics hyprcursor aquamarine pixman-1; do
            printf '%s=%s\n' "$p" "$(pkg-config --modversion "$p" 2>/dev/null)"
        done
    } | md5sum | cut -c1-16
}

# tc_plugin_guard <plugin-dir> <so-path> <stamp-path> <pretty-name>
# Ensures <so-path> is built against the running Hyprland. Returns 0 when the
# .so is safe to load, non-zero when it must NOT be loaded.
tc_plugin_guard() {
    local dir="$1" so="$2" stamp="$3" name="$4"
    local want have
    want="$(tc_abi_key)"
    have="$(cat "$stamp" 2>/dev/null || echo none)"

    if [ -f "$so" ] && [ "$have" = "$want" ] && [ -n "$want" ]; then
        return 0                      # already built for this Hyprland
    fi

    # Stale, unstamped or missing -> rebuild from scratch before any load.
    # (-B: a stale .so is newer than the sources, so plain make would skip it.)
    rm -f "$stamp"
    if make -s -B -C "$dir" >/tmp/tc-plugin-build-$$.log 2>&1 && [ -f "$so" ]; then
        printf '%s' "$want" > "$stamp"
        rm -f /tmp/tc-plugin-build-$$.log
        return 0
    fi

    # Build failed: the plugin source needs porting to this Hyprland. Keep the
    # log, tell the user, and REFUSE to load — a stale .so would crash the
    # session into safe mode.
    mv -f "/tmp/tc-plugin-build-$$.log" "$dir/build-failed.log" 2>/dev/null
    notify-send -a Hyprland -u critical \
        "$name disabled" \
        "Not built for this Hyprland ($(pkg-config --modversion hyprland 2>/dev/null)).
Session is fine; that effect is off.
Build log: $dir/build-failed.log" 2>/dev/null || true
    return 1
}
