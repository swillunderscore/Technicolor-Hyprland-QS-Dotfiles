#!/usr/bin/env bash
# Called by mako's on-notify hook. Two side effects:
#   1) per-app unread count in $XDG_RUNTIME_DIR/quickshell-notif-counts.json
#      → drives the workspace-dot and minimized-icon badges
#   2) full notification record appended to $XDG_RUNTIME_DIR/quickshell-notif-log.json
#      → drives the bar's notification tray panel
#
# Args: $1 = notification id (mako exposes $id; we pass it explicitly)
# The mako rule [desktop-entry=X] invisible=1 already kills popups for silenced
# apps before this script runs — we double-check anyway and skip logging.

set -eu

notif_id="${1:-}"
[ -z "$notif_id" ] && exit 0

counts_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-counts.json"
log_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-log.json"
supp_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-notif-suppressed.json"
silenced_file="$HOME/.config/quickshell/silenced-apps.json"
lock_file="${counts_file}.lock"
mkdir -p "$(dirname "$counts_file")"

# Pull the full notification record from mako (one entry).
entry=$(makoctl list -j 2>/dev/null \
    | jq -c --arg id "$notif_id" '
        .[] | select(.id == ($id|tonumber))
      ' 2>/dev/null | head -1)
[ -z "$entry" ] && exit 0

app_name=$(printf '%s' "$entry" | jq -r '.app_name // ""')
desktop_entry=$(printf '%s' "$entry" | jq -r '.desktop_entry // ""')
app_icon=$(printf '%s' "$entry" | jq -r '.app_icon // ""')
summary=$(printf '%s' "$entry" | jq -r '.summary // ""')
body=$(printf '%s' "$entry" | jq -r '.body // ""')
urgency=$(printf '%s' "$entry" | jq -r '.urgency // "normal"')

# Lowercase key prefers desktop_entry, falls back to app_name.
raw_key="${desktop_entry:-$app_name}"
key=$(printf '%s' "$raw_key" | tr '[:upper:]' '[:lower:]')
[ -z "$key" ] && exit 0

# notify-send default app_name; not worth tracking as its own bucket.
[ "$key" = "notify-send" ] && exit 0

ts=$(date +%s)

# If the app is silenced, mako's [app-name=…] / [desktop-entry=…] rule with
# invisible=1 already killed the popup — but we still log the notification
# (capped per-app at 20) so the user can audit what they're missing via the
# silenced-tab expand. Match against both desktop_entry and app_name forms so
# that silencing through the bar catches notifications regardless of which
# identifier the sending app populates.
if [ -s "$silenced_file" ]; then
    an_lc=$(printf '%s' "$app_name" | tr '[:upper:]' '[:lower:]')
    de_lc=$(printf '%s' "$desktop_entry" | tr '[:upper:]' '[:lower:]')
    matched_key=$(jq -r \
        --arg de "$de_lc" --arg an "$an_lc" --arg k "$key" '
        [ to_entries[] | select(
            .key == $k
            or ($de != "" and ((.value.desktop_entry // "") | ascii_downcase) == $de)
            or ($an != "" and ((.value.app_name      // "") | ascii_downcase) == $an)
          ) ][0].key // ""
    ' "$silenced_file" 2>/dev/null)
    if [ -n "$matched_key" ]; then
        (
            flock 9
            curr="{}"
            [ -s "$supp_file" ] && curr=$(cat "$supp_file")
            printf '%s' "$curr" | jq -c \
                --arg k "$matched_key" --argjson id "$notif_id" --argjson ts "$ts" \
                --arg sum "$summary" --arg body "$body" --arg urg "$urgency" \
                '.[$k] = (([{id:$id, ts:$ts, summary:$sum, body:$body, urgency:$urg}] + (.[$k] // []))[0:20])' \
                > "${supp_file}.new"
            mv "${supp_file}.new" "$supp_file"
        ) 9>"$lock_file"
        exit 0
    fi
fi

# Display name: prefer human app_name; otherwise the desktop_entry slug.
display="${app_name:-$desktop_entry}"
[ -z "$display" ] && display="$key"

# Suppress if the matching app's window is already focused.
focused=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""' | tr '[:upper:]' '[:lower:]')
suppress=0
if [ -n "$focused" ] && [ "${#key}" -ge 3 ]; then
    case "$focused" in
        *"$key"*) suppress=1 ;;
    esac
    if [ "$suppress" = 0 ] && [ "${#focused}" -ge 3 ]; then
        case "$key" in
            *"$focused"*) suppress=1 ;;
        esac
    fi
fi
[ "$suppress" = 1 ] && exit 0

(
    flock 9
    # --- counts ---
    current="{}"
    [ -s "$counts_file" ] && current=$(cat "$counts_file")
    printf '%s' "$current" \
        | jq -c --arg k "$key" '. as $c | .[$k] = (($c[$k] // 0) + 1)' \
        > "${counts_file}.new"
    mv "${counts_file}.new" "$counts_file"

    # --- log (cap at 50, newest first) ---
    log_current="[]"
    [ -s "$log_file" ] && log_current=$(cat "$log_file")
    printf '%s' "$log_current" \
        | jq -c \
            --argjson id "$notif_id" \
            --argjson ts "$ts" \
            --arg k "$key" \
            --arg disp "$display" \
            --arg an "$app_name" \
            --arg de "$desktop_entry" \
            --arg ai "$app_icon" \
            --arg sum "$summary" \
            --arg body "$body" \
            --arg urg "$urgency" \
            '[{id: $id, ts: $ts, key: $k, display: $disp, app_name: $an, desktop_entry: $de, app_icon: $ai, summary: $sum, body: $body, urgency: $urg}] + . | .[0:50]' \
        > "${log_file}.new"
    mv "${log_file}.new" "$log_file"
) 9>"$lock_file"
