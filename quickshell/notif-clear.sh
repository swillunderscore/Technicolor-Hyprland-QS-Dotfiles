#!/usr/bin/env bash
# Clear notification counts AND log entries.
#
# Usage:
#   notif-clear.sh <window-class>   # fuzzy substring (focus-watcher)
#   notif-clear.sh --key <key>      # exact key (silence script)
#   notif-clear.sh --id <id>        # single mako id (tray left-click)

set -eu

mode="fuzzy"
case "${1:-}" in
    --key)        mode="exact"; shift ;;
    --id)         mode="id"; shift ;;
    --all)        mode="all" ;;
    --suppressed) mode="suppressed" ;;
esac

counts_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-counts.json"
log_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-log.json"
lock_file="${counts_file}.lock"

if [ "$mode" = "all" ]; then
    supp_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-suppressed.json"
    (
        flock 9
        echo '{}' > "$counts_file"
        echo '[]' > "$log_file"
        echo '{}' > "$supp_file"
    ) 9>"$lock_file"
    makoctl dismiss --all 2>/dev/null || true
    exit 0
fi

if [ "$mode" = "suppressed" ]; then
    supp_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-suppressed.json"
    (
        flock 9
        echo '{}' > "$supp_file"
    ) 9>"$lock_file"
    exit 0
fi

arg="${1:-}"
[ -z "$arg" ] && exit 0

(
    flock 9

    if [ "$mode" = "id" ]; then
        removed_key=""
        if [ -s "$log_file" ]; then
            removed_key=$(jq -r --argjson id "$arg" \
                'map(select(.id == $id)) | .[0].key // ""' \
                "$log_file" 2>/dev/null || true)
            jq -c --argjson id "$arg" 'map(select(.id != $id))' \
                "$log_file" > "${log_file}.new" 2>/dev/null \
                || cp "$log_file" "${log_file}.new"
            mv "${log_file}.new" "$log_file"
        fi
        if [ -n "$removed_key" ] && [ -s "$counts_file" ]; then
            jq -c --arg k "$removed_key" '
                .[$k] = (.[$k] // 0) - 1
                | with_entries(select(.value > 0))
            ' "$counts_file" > "${counts_file}.new" 2>/dev/null \
                || cp "$counts_file" "${counts_file}.new"
            mv "${counts_file}.new" "$counts_file"
        fi
        exit 0
    fi

    needle=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')

    if [ "$mode" = "exact" ]; then
        keep='select(.key != $needle)'
    else
        # Capture .key as $k before piping, otherwise `.key` inside contains()
        # resolves against the piped-in string and errors.
        keep='
            .key as $k
            | select(
                ( (($k|length) >= 3 and ($needle|contains($k)))
                  or
                  (($needle|length) >= 3 and ($k|contains($needle)))
                ) | not
              )
        '
    fi

    if [ -s "$counts_file" ]; then
        jq -c --arg needle "$needle" \
            "to_entries | map($keep) | from_entries" \
            "$counts_file" > "${counts_file}.new" 2>/dev/null \
            || cp "$counts_file" "${counts_file}.new"
        mv "${counts_file}.new" "$counts_file"
    fi
    if [ -s "$log_file" ]; then
        jq -c --arg needle "$needle" "map($keep)" \
            "$log_file" > "${log_file}.new" 2>/dev/null \
            || cp "$log_file" "${log_file}.new"
        mv "${log_file}.new" "$log_file"
    fi
) 9>"$lock_file"
