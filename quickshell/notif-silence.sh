#!/usr/bin/env bash
# Manages the per-app silence list used by the bar's notification tray.
#
# Truth lives in ~/.config/quickshell/silenced-apps.json:
#   { "<lowercase-key>": { "display": "...", "app_name": "...", "desktop_entry": "..." }, ... }
# Mako only listens to its config file, so every change rewrites the section
# between the QS_SILENCE_BEGIN / QS_SILENCE_END markers in ~/.config/mako/config
# and runs `makoctl reload`.
#
# Usage:
#   notif-silence.sh add KEY DISPLAY APP_NAME [DESKTOP_ENTRY]
#   notif-silence.sh remove KEY
#   notif-silence.sh list

set -eu

cmd="${1:-list}"
state_file="$HOME/.config/quickshell/silenced-apps.json"
lock_file="${state_file}.lock"
mako_config="$HOME/.config/mako/config"

mkdir -p "$(dirname "$state_file")"
[ -s "$state_file" ] || echo '{}' > "$state_file"

regenerate_mako() {
    local tmp
    tmp=$(mktemp)
    # Strip existing managed block (if present)
    awk '
        /^# QS_SILENCE_BEGIN$/ { skip=1; next }
        /^# QS_SILENCE_END$/   { skip=0; next }
        skip != 1
    ' "$mako_config" > "$tmp"
    # Drop trailing blank lines so we re-append cleanly
    while [ -s "$tmp" ] && [ -z "$(tail -n1 "$tmp")" ]; do
        sed -i -e '$d' "$tmp"
    done
    {
        printf '\n# QS_SILENCE_BEGIN\n'
        printf '# (managed by ~/.config/quickshell/notif-silence.sh — do not edit by hand)\n'
        jq -r '
            to_entries
            | map(
                (if (.value.desktop_entry // "") != ""
                 then "[desktop-entry=" + .value.desktop_entry + "]\ninvisible=1\n"
                 else "" end)
                +
                (if (.value.app_name // "") != ""
                 then "[app-name=\"" + .value.app_name + "\"]\ninvisible=1\n"
                 else "" end)
              )
            | join("")
        ' "$state_file"
        printf '# QS_SILENCE_END\n'
    } >> "$tmp"
    mv "$tmp" "$mako_config"
    makoctl reload 2>/dev/null || true
}

case "$cmd" in
    add)
        key="${2:?key required}"
        display="${3:-$key}"
        app_name="${4:-$display}"
        desktop_entry="${5:-}"
        (
            flock 9
            jq -c \
                --arg k "$key" --arg d "$display" \
                --arg a "$app_name" --arg e "$desktop_entry" \
                '. + {($k): {display: $d, app_name: $a, desktop_entry: $e}}' \
                "$state_file" > "${state_file}.new"
            mv "${state_file}.new" "$state_file"
            regenerate_mako
        ) 9>"$lock_file"

        # Best-effort: also drop the offending entries from the live log/counts
        # so silencing visibly clears the tray right away.
        ~/.config/quickshell/notif-clear.sh --key "$key" 2>/dev/null || true
        ;;
    remove)
        key="${2:?key required}"
        supp_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-suppressed.json"
        (
            flock 9
            jq -c --arg k "$key" 'del(.[$k])' "$state_file" > "${state_file}.new"
            mv "${state_file}.new" "$state_file"
            regenerate_mako
            if [ -s "$supp_file" ]; then
                jq -c --arg k "$key" 'del(.[$k])' "$supp_file" > "${supp_file}.new" \
                    && mv "${supp_file}.new" "$supp_file"
            fi
        ) 9>"$lock_file"
        ;;
    list)
        cat "$state_file"
        ;;
    *)
        echo "usage: $0 {add|remove|list} ..." >&2
        exit 1
        ;;
esac
