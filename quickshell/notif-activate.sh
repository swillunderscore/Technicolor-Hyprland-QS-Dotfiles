#!/usr/bin/env bash
# Triggered by left-clicking a notification card in the bar's tray.
#
#   1. Try `makoctl invoke <id>` — if the notification is still in mako's
#      queue AND has a default action bound, this fires it. Many apps
#      (Vesktop/Discord, Telegram, Thunderbird…) implement the default
#      action to raise their window AND jump to the specific chat/email.
#
#   2. Locate the matching Hyprland window by fuzzy-matching the key (the
#      lowercased desktop_entry / app_name we stored when the notif arrived)
#      against window classes. If found:
#         • on the special:minimized workspace → run minimize-restore.sh so
#           it pops back onto the current workspace and gets focus
#         • elsewhere → focuswindow it (Hyprland switches workspaces if needed)
#      The default-action invoke above may have already done this; doing it
#      again is a safe no-op.
#
#   3. Drop the entry from the tray so left-click always feels responsive.
#
# Args: $1 = mako id, $2 = lowercase key

set -eu

notif_id="${1:-}"
key="${2:-}"

if [ -n "$notif_id" ]; then
    makoctl invoke "$notif_id" 2>/dev/null || true
fi

if [ -n "$key" ]; then
    # Fuzzy match: case-insensitive substring either direction with a
    # length-≥3 guard on both sides (same rule the focus-watcher uses).
    match=$(hyprctl clients -j 2>/dev/null | jq -r --arg k "$key" '
        [ .[]
          | select(.mapped == true and (.class // "") != "")
          | . as $w
          | ($w.class | ascii_downcase) as $c
          | select(
              ($k|length) >= 3 and ($c|length) >= 3
              and (($k|contains($c)) or ($c|contains($k)))
            )
          | { address: $w.address, ws: ($w.workspace.name // ""), fh: ($w.focusHistoryID // 999999) }
        ]
        | sort_by(.fh)
        | .[0]
        | (if . == null then "" else "\(.address) \(.ws)" end)
    ' 2>/dev/null || true)

    addr=$(printf '%s' "$match" | awk '{print $1}')
    ws=$(printf '%s' "$match"  | awk '{print $2}')

    if [ -n "$addr" ] && [ "$addr" != "null" ]; then
        if [ "$ws" = "special:minimized" ]; then
            ~/.config/hypr/minimize-restore.sh "$addr" 2>/dev/null || true
        else
            hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1 || true
        fi
    fi
fi

if [ -n "$notif_id" ]; then
    ~/.config/quickshell/notif-clear.sh --id "$notif_id" 2>/dev/null || true
fi
