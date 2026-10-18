#!/usr/bin/env bash
# Which monitor a Moonlight client is looking at right now, if any.
#
# A one-screen client (a laptop, a phone) streaming over Sunshine sees ONE
# output. This follows sunshine.log and keeps the answer in a one-line state
# file:
#
#   $XDG_RUNTIME_DIR/tc-stream-output   "DP-1" while streaming a real monitor,
#                                       empty otherwise
#
# Readers: the bar and workspace-move.sh. A monitor that is powered off
# (monitor-power.sh) is offscreen -- diamond dot, Super+[ / ] won't hand it
# focus -- UNLESS it is the one being streamed: Hyprland keeps drawing it, so
# the remote viewer can see it.
#
# When a stream ends it also runs stream-release-keys.py: Sunshine sometimes
# leaves a key the remote side was holding stuck down on its virtual keyboard,
# and while it's held that key is dead on every keyboard.
#
# A stream of a virtual headless output (e.g. one created for a TV with
# `hyprctl output create headless`) logs as "Selected monitor []" (headless
# outputs have no description), so it never names a real monitor.
#
# Log lines it keys on (Sunshine 2026.1004):
#   Info: Sunshine version: ...                          fresh start, reset
#   Info: New streaming session started [active sessions: N]
#   Info: CLIENT DISCONNECTED
#   Info: <address>: Ping Timeout     stream lost; no CLIENT DISCONNECTED follows
#   Error: Initial Ping Timeout       session never got going (video/audio)
#   Info: [wlgrab] Selected monitor [<description> (DP-1)] for streaming
# "Selected monitor" also appears while Sunshine probes encoders at startup;
# it only matters while a session is up.

LOG="${TC_STREAM_LOG:-$HOME/.config/sunshine/sunshine.log}"   # env overrides: tests
RUN="${TC_STREAM_RUN:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"
STATE="$RUN/tc-stream-output"
RELEASE="${TC_STREAM_RELEASE:-$(dirname "$(readlink -f "$0")")/stream-release-keys.py}"

exec 8>"$RUN/tc-stream-output.lock"
flock -n 8 || exit 0          # one watcher per session

: > "$STATE"

sessions=0
selected=""

publish() {
    # Sunshine can segfault mid-stream and never log the disconnect.
    if [ "$sessions" -gt 0 ] && ! pgrep -x sunshine >/dev/null; then
        sessions=0
        selected=""
    fi
    local out=""
    if [ "$sessions" -gt 0 ] && [ -n "$selected" ] && [[ "$selected" != HEADLESS-* ]]; then
        out="$selected"
    fi
    [ "$out" = "$(cat "$STATE" 2>/dev/null)" ] && return
    printf '%s\n' "$out" > "$STATE"
}

# Sunshine's own key reset runs as the session winds down, so give it a moment,
# then clear whatever is still held. Only for a line that is happening NOW --
# the startup replay of old sessions must not touch a stream that's up.
release_soon() {
    local t
    t=$(date -d "${1:1:19}" +%s 2>/dev/null) || return
    [ $((EPOCHSECONDS - t)) -le 15 ] || return
    ( sleep 2; exec "$RELEASE" ) 3<&- 8>&- &
}

# -n +1 replays the current log first (a stream may already be up when this
# starts); -F follows Sunshine's restart, which rotates sunshine.log to .1 and
# starts a fresh file. Replayed lines arrive in one burst, so state is only
# published once input goes quiet -- no flicker through old sessions.
# Read through an fd, not a pipe: the loop stays in this shell, so killing
# this PID takes tail down with it instead of orphaning it (an orphan would
# also keep holding the instance lock).
exec 3< <(tail -F -n +1 "$LOG" 2>/dev/null)
tail_pid=$!
trap 'kill "$tail_pid" 2>/dev/null' EXIT
trap 'exit 0' TERM INT HUP
while :; do
    IFS= read -r -t 30 -u 3 line
    rc=$?
    if [ "$rc" -gt 128 ]; then        # quiet for 30 s: re-check Sunshine is alive
        publish
        continue
    fi
    [ "$rc" -ne 0 ] && exit 0         # tail went away
    case "$line" in
        *"Info: Sunshine version:"*)
            sessions=0; selected=""; dirty=1 ;;
        *"New streaming session started [active sessions: "*)
            # selected is re-logged for every session; forget the startup
            # probe's pick so a TV session never flashes as DP-1
            n=${line##*active sessions: }; n=${n%%]*}
            [[ "$n" =~ ^[0-9]+$ ]] && sessions=$n
            selected=""; dirty=1 ;;
        *"CLIENT DISCONNECTED"*|*": Ping Timeout"*)
            [ "$sessions" -gt 0 ] && sessions=$((sessions - 1))
            release_soon "$line"
            dirty=1 ;;
        *"Initial Ping Timeout"*)
            # can be logged by both the video and audio thread, so not counted;
            # the next session start re-syncs the count anyway
            release_soon "$line" ;;
        *"[wlgrab] Selected monitor ["*)
            sel=${line#*Selected monitor [}; sel=${sel%] for streaming*}
            if [[ "$sel" =~ \(([^()]+)\)$ ]]; then selected=${BASH_REMATCH[1]}; else selected=""; fi
            dirty=1 ;;
    esac
    [ "${dirty:-0}" = 1 ] || continue
    read -r -t 0 -u 3 && continue     # more lines already waiting: batch them
    publish
    dirty=0
done
