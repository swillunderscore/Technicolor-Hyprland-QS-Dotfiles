#!/usr/bin/env bash
# lo-tc.sh — launch LibreOffice with a UNO acceptor, then apply the Technicolor
# theme live once the socket is up. Used as the Exec for the LibreOffice .desktop
# overrides (~/.local/share/applications/libreoffice-*.desktop), so every launch:
#   1. opens a UNO socket on :2002 (lets lo-recolor.py poke the live color cache)
#   2. gets freshly recolored from the current wallpaper palette
#
# LibreOffice is single-instance: if an LO is already running, this `soffice`
# call just opens the requested window in it (the acceptor from the first launch
# is still up), and the recolor re-applies. Pass-through of all args ($@) keeps
# the .desktop variants (--writer, --calc, %U, …) working.
PORT=2002
ACCEPT="socket,host=localhost,port=${PORT};urp;"

# Launch LO (real binary), passing through whatever the .desktop asked for.
setsid -f soffice --accept="$ACCEPT" "$@" >/dev/null 2>&1 < /dev/null

# Fire the recolor in the background once the acceptor is listening (don't block
# the launch; give up after ~15s so a failed socket never hangs anything).
(
    for _ in $(seq 1 30); do
        if (exec 3<>"/dev/tcp/localhost/${PORT}") 2>/dev/null; then
            exec 3>&- 3<&-
            python3.14 "$HOME/.config/hypr/lo-recolor.py" >/dev/null 2>&1
            break
        fi
        sleep 0.5
    done
) &
