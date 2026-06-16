#!/usr/bin/env bash
# Pull the latest Technicolor from GitHub and copy the configs into ~/.config.
# Per-machine + tuning files (colors/glass/font/pins/monitors/local) are
# gitignored — they're not in the repo, so a copy leaves them untouched and your
# tweaks survive. Reloads quickshell (auto, on file change) and Hyprland after.
set -u
REPO="https://github.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching latest from GitHub…"
if ! git clone --depth 1 "$REPO" "$TMP" >/dev/null 2>&1; then
    echo "FAILED — couldn't reach GitHub"; exit 1
fi
new="$(git -C "$TMP" rev-parse --short HEAD 2>/dev/null)"

echo "Copying configs…"
cp -r "$TMP"/hypr "$TMP"/quickshell "$TMP"/mako "$TMP"/spicetify ~/.config/ 2>/dev/null
mkdir -p ~/.local/share/applications
cp "$TMP"/applications/*.desktop ~/.local/share/applications/ 2>/dev/null
# Files with safe defaults that are gitignored (so the copy above doesn't touch
# the user's): create them from the .example ONLY if missing — never clobber.
cp -n ~/.config/hypr/hyprglass-tuning.conf.example ~/.config/hypr/hyprglass-tuning.conf 2>/dev/null
cp -n ~/.config/mako/config.example ~/.config/mako/config 2>/dev/null
cp -n ~/.config/hypr/terminal.conf.example ~/.config/hypr/terminal.conf 2>/dev/null
cp -n ~/.config/hypr/wallpaper-timer.conf.example ~/.config/hypr/wallpaper-timer.conf 2>/dev/null
# record the pulled commit so "Check for updates" can list what's new next time
git -C "$TMP" rev-parse HEAD > "$HOME/.config/hypr/.technicolor-version" 2>/dev/null

echo "Reloading Hyprland…"
hyprctl reload >/dev/null 2>&1
echo "Done — updated to ${new:-latest}"
