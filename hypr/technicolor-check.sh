#!/usr/bin/env bash
# List the Technicolor commits NOT yet pulled, for the Settings → Update preview.
# Uses the GitHub API (no clone). technicolor-update.sh records the pulled commit
# in ~/.config/hypr/.technicolor-version; we diff that against the latest.
#
# Output: line 1 = a count ("0", a number, or "?" when the base is unknown);
# then one "shortsha  subject" per new commit, newest first.
set -u
OWNER="swillunderscore"; REPO="Technicolor-Hyprland-QS-Dotfiles"
API="https://api.github.com/repos/$OWNER/$REPO"
base="$(cat "$HOME/.config/hypr/.technicolor-version" 2>/dev/null)"

if [ -n "$base" ]; then
    json="$(curl -fsSL "$API/compare/$base...main" 2>/dev/null)" || { echo "?"; echo "couldn't reach GitHub"; exit 0; }
    echo "$json" | jq -r '.ahead_by // 0' 2>/dev/null || echo "?"
    echo "$json" | jq -r '.commits | reverse | .[] | "\(.sha[0:7])  \(.commit.message | split("\n")[0])"' 2>/dev/null
else
    # No recorded version (e.g. fresh, or the author who never runs the updater) —
    # just show the latest commits so there's still something to preview.
    json="$(curl -fsSL "$API/commits?per_page=15&sha=main" 2>/dev/null)" || { echo "?"; echo "couldn't reach GitHub"; exit 0; }
    echo "?"
    echo "$json" | jq -r '.[] | "\(.sha[0:7])  \(.commit.message | split("\n")[0])"' 2>/dev/null
fi
