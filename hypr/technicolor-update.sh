#!/usr/bin/env bash
# Pull the latest Technicolor from GitHub and copy the configs into ~/.config.
# Per-machine + tuning files (colors/glass/font/pins/monitors-in-local.conf) are
# gitignored — they're not in the repo, so the copy leaves them untouched and
# your tweaks survive. Restarts quickshell (QML is only read at launch — a file
# copy alone would leave the bar running the OLD code) and reloads Hyprland.
#
# Everything lives inside main() on purpose: the copy below overwrites THIS
# script mid-run, and bash reads scripts incrementally — a parsed function is
# immune to the file changing under it.
set -u

main() {
    REPO="https://github.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo "Fetching latest from GitHub…"
    if ! git clone --depth 1 "$REPO" "$TMP" >/dev/null 2>&1; then
        echo "FAILED — couldn't reach GitHub"; exit 1
    fi
    new="$(git -C "$TMP" rev-parse --short HEAD 2>/dev/null)"

    echo "Copying configs…"
    cp -r "$TMP"/hypr "$TMP"/quickshell "$TMP"/mako ~/.config/ 2>/dev/null
    # Spicetify is OPT-IN at install time (it patches the Spotify client — against
    # their ToS, so the installer asks first and warns). Updating must not quietly
    # opt you in: only refresh the theme if you already have Spicetify or its config.
    # Without this, anyone who declined Spotify theming got ~/.config/spicetify
    # created behind their back on the first "Check for updates".
    if command -v spicetify >/dev/null 2>&1 || [ -d ~/.config/spicetify ]; then
        cp -r "$TMP"/spicetify ~/.config/ 2>/dev/null
    fi
    mkdir -p ~/.local/share/applications
    cp "$TMP"/applications/*.desktop ~/.local/share/applications/ 2>/dev/null
    # Files with safe defaults that are gitignored (so the copy above doesn't
    # touch the user's): create from the .example ONLY if missing — never clobber.
    cp -n ~/.config/hypr/hyprglass-tuning.conf.example ~/.config/hypr/hyprglass-tuning.conf 2>/dev/null
    cp -n ~/.config/mako/config.example ~/.config/mako/config 2>/dev/null
    cp -n ~/.config/hypr/terminal.conf.example ~/.config/hypr/terminal.conf 2>/dev/null
    cp -n ~/.config/hypr/wallpaper-timer.conf.example ~/.config/hypr/wallpaper-timer.conf 2>/dev/null
    cp -n ~/.config/hypr/keybinds.conf.example ~/.config/hypr/keybinds.conf 2>/dev/null
    cp -n ~/.config/hypr/transition.conf.example ~/.config/hypr/transition.conf 2>/dev/null
    cp -n ~/.config/hypr/local.conf.example ~/.config/hypr/local.conf 2>/dev/null
    # record the pulled commit so "Check for updates" can list what's new next time
    git -C "$TMP" rev-parse HEAD > "$HOME/.config/hypr/.technicolor-version" 2>/dev/null

    echo "Reloading Hyprland…"
    hyprctl reload >/dev/null 2>&1

    # Restart the bar so the new QML actually runs (quickshell reads its config
    # only at launch). Detached (setsid) because on the Settings-button path THIS
    # script is a child of the very quickshell it's about to kill. Kills ONLY the
    # plain `quickshell` instance — cmdline-matched, so any `-p <path>` instances
    # (e.g. a nested/secondary shell) are left alone. Skipped when no bar runs.
    echo "Restarting the bar…"
    setsid -f bash -c '
        sleep 0.5
        killed=""
        for p in $(pgrep -x quickshell); do
            if [ "$(tr "\0" " " < /proc/$p/cmdline)" = "quickshell " ]; then
                kill "$p" 2>/dev/null && killed=1
            fi
        done
        if [ -n "$killed" ]; then
            sleep 0.8
            setsid -f quickshell >/dev/null 2>&1 </dev/null
            sleep 3
            notify-send "Technicolor" "Updated to '"${new:-latest}"' — bar restarted." 2>/dev/null
        fi
    ' >/dev/null 2>&1 </dev/null

    echo "Done — updated to ${new:-latest}"
}

main "$@"
exit 0
