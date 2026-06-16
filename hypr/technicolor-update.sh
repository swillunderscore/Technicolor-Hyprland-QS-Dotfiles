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

echo "Reloading Hyprland…"
hyprctl reload >/dev/null 2>&1
echo "Done — updated to ${new:-latest}"
