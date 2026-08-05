#!/usr/bin/env bash
# spicetify-guard.sh — re-apply the Spotify theme after a Spotify update.
#
# THE FAILURE THIS PREVENTS
# Spotify ships its UI as packed archives: /opt/spotify/Apps/xpui.spa and
# login.spa. Applying spicetify UNPACKS those into xpui/ and login/ directories
# and deletes the .spa files. A Spotify package upgrade reinstalls the .spa
# files — the patch is gone, and nothing tells you.
#
# On stock Spotify that would just look untethered. Here it looks BROKEN,
# because the Spotify window is chromakeyed whole-window (hyprland.conf, SPOTIFY
# block) with a SELF-CALIBRATING keyer: it samples the window to learn the key.
# Themed, that sample is the theme's mauve #7A6E85 and only the background keys
# out. Unthemed, it samples stock Spotify's near-black #121212 and proceeds to
# key EVERY dark pixel in the window — album art punches holes, the player bar
# goes invisible, chrome turns into wallpaper. It looks like a GPU failure. It
# is one stale patch.
#
# DETECTION
# The packaged .spa existing is proof the package manager reinstalled over the
# patch — spicetify removes it when applied. That is a direct check on the thing
# that actually broke, not a version-string comparison that drifts between
# distro packaging and Spotify's internal versioning.
#
# Safe to run on every login: one stat() when nothing is wrong.
set -uo pipefail

SPOTIFY_DIR="/opt/spotify"
PACKED="$SPOTIFY_DIR/Apps/xpui.spa"

note() {
    printf 'spicetify-guard: %s\n' "$1"
    command -v notify-send >/dev/null 2>&1 && notify-send -a "Technicolor" "Spotify theme" "$1"
}

# Not our problem if either half is absent — this is opt-in theming.
command -v spicetify >/dev/null 2>&1 || exit 0
[ -d "$SPOTIFY_DIR" ] || exit 0

# No packed .spa == spicetify's unpacked directories are still in place.
[ -e "$PACKED" ] || exit 0

# Spicetify writes into the Spotify install. Arch ships it root-owned, so a
# fresh machine needs the chmod once. Say so instead of failing opaquely --
# the symptom (keyed-out album art) points nowhere near a permissions problem.
if [ ! -w "$SPOTIFY_DIR/Apps" ]; then
    note "Spotify updated and the theme was lost, but $SPOTIFY_DIR/Apps is not writable. Run: sudo chmod a+wr $SPOTIFY_DIR && sudo chmod a+wr -R $SPOTIFY_DIR/Apps"
    exit 1
fi

note "Spotify updated — reapplying theme"

# `backup apply` re-backs-up the NEW Spotify and reapplies. Plain `apply` would
# patch against the previous version's stale backup.
if spicetify backup apply >/dev/null 2>&1; then
    note "Theme reapplied. Restart Spotify if it is open."
else
    note "Reapply FAILED — run 'spicetify backup apply' by hand to see why."
    exit 1
fi
