#!/bin/bash
# Main script lock to prevent shortcut stacking
exec 9>/tmp/wallpaper.lock
if ! flock -n 9; then
    exit 0
fi

# Source folder — set in Settings (writes wallpaper-dir.conf). Re-read every run,
# so changing it takes effect on the next cycle without restarting anything.
WALLPAPER_DIR="$(cat "$HOME/.config/hypr/wallpaper-dir.conf" 2>/dev/null)"
[ -z "$WALLPAPER_DIR" ] && WALLPAPER_DIR="$HOME/Wallpapers/animated"
STATE_FILE="/tmp/wallpaper-current-index"
CURRENT_PATH_FILE="/tmp/wallpaper-current-path"
CACHE_DIR="$HOME/.cache/wallpapers-upscaled"
TRIGGER_FILE="/tmp/wallpaper-sync-trigger"
TIMER_PID_FILE="/tmp/wallpaper-timer.pid"
MODE="${1:-random}"

mkdir -p "$CACHE_DIR"

mapfile -t WALLPAPERS < <(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.webp' -o -name '*.webm' -o -name '*.mp4' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -size +0c | sort)
COUNT=${#WALLPAPERS[@]}
[ "$COUNT" -eq 0 ] && exit 0

if [ "$MODE" = "random" ]; then
    INDEX=$((RANDOM % COUNT))
elif [ "$MODE" = "restore" ]; then
    INDEX=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
elif [ -f "$MODE" ]; then
    # Explicit file (Settings cover-flow picks one): find its index in the
    # sorted list so STATE_FILE / colors / hourly rotation stay aligned.
    INDEX=-1
    for i in "${!WALLPAPERS[@]}"; do
        if [ "${WALLPAPERS[$i]}" = "$MODE" ]; then INDEX=$i; break; fi
    done
    [ "$INDEX" -lt 0 ] && exit 0
else
    CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "-1")
    INDEX=$(( (CURRENT + 1) % COUNT ))
fi

PREV_PATH=$(cat "$CURRENT_PATH_FILE" 2>/dev/null || echo "")

echo "$INDEX" > "$STATE_FILE"
CHOSEN="${WALLPAPERS[$INDEX]}"

if [[ "$XDG_CURRENT_DESKTOP" == *"KDE"* ]]; then
    python3 "$HOME/.config/hypr/wallpaper-colors.py" "$CHOSEN"
    ~/.config/quickshell/notif-theme-mako.sh 2>/dev/null || true

    pkill -x awww-daemon

    BASENAME=$(basename "$CHOSEN")
    FINAL_WALLPAPER="$CACHE_DIR/$BASENAME"

    # 1. Instantly apply the wallpaper.
    if [ -s "$FINAL_WALLPAPER" ]; then
        plasma-apply-wallpaperimage "$FINAL_WALLPAPER"
        rm -f "$TRIGGER_FILE"
    else
        plasma-apply-wallpaperimage "$CHOSEN"
        echo "$BASENAME" > "$TRIGGER_FILE"
    fi

    # 2. Check if a sync/upscale is needed.
    SRC_COUNT=$(find "$WALLPAPER_DIR" -maxdepth 1 -type f | wc -l)
    CACHE_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -type f | wc -l)

    if [ "$SRC_COUNT" -ne "$CACHE_COUNT" ]; then
        CACHE_WAS_EMPTY=0
        [ "$CACHE_COUNT" -eq 0 ] && CACHE_WAS_EMPTY=1

        (
            exec 8>/tmp/wallpaper-sync.lock
            if ! flock -n 8; then exit 0; fi

            # Cleanup deleted files from cache
            for CACHED_FILE in "$CACHE_DIR"/*; do
                [ -e "$CACHED_FILE" ] || continue
                B_NAME=$(basename "$CACHED_FILE")
                if [ ! -f "$WALLPAPER_DIR/$B_NAME" ]; then
                    rm -f "$CACHED_FILE"
                fi
            done

            FIRST_CACHED=""

            # Upscale missing files
            for FILE in "$WALLPAPER_DIR"/*; do
                [ -e "$FILE" ] || continue
                B_NAME=$(basename "$FILE")
                C_FILE="$CACHE_DIR/$B_NAME"
                EXT="${B_NAME##*.}"
                EXT="${EXT,,}"

                if [ ! -s "$C_FILE" ]; then
                    rm -f "$C_FILE" 2>/dev/null
                    if [[ "$EXT" == "gif" ]] || [[ "$EXT" == "webp" ]]; then
                        magick "$FILE" -coalesce -scale 800% -layers optimize "$C_FILE"
                    elif [[ "$EXT" == "mp4" ]] || [[ "$EXT" == "webm" ]]; then
                        ffmpeg -hide_banner -loglevel error -y -i "$FILE" -vf "scale=iw*8:ih*8:flags=neighbor" -c:v libx264 -preset ultrafast -crf 12 -pix_fmt yuv444p "$C_FILE"
                    else
                        magick "$FILE" -scale 800% "$C_FILE"
                    fi

                    if [ -s "$C_FILE" ]; then
                        # If cache was empty, apply the very first finished file immediately
                        # and kick off the hourly rotation timer
                        if [ "$CACHE_WAS_EMPTY" -eq 1 ] && [ -z "$FIRST_CACHED" ]; then
                            FIRST_CACHED="$C_FILE"
                            plasma-apply-wallpaperimage "$C_FILE"
                            rm -f "$TRIGGER_FILE"

                            # Kill any existing timer before starting a new one
                            if [ -f "$TIMER_PID_FILE" ]; then
                                kill "$(cat "$TIMER_PID_FILE")" 2>/dev/null
                                rm -f "$TIMER_PID_FILE"
                            fi

                            # Start hourly rotation loop through cache as it fills
                            (
                                echo $$ > "$TIMER_PID_FILE"
                                while true; do
                                    sleep 3600

                                    # Collect whatever is cached so far
                                    mapfile -t CACHED_NOW < <(find "$CACHE_DIR" -maxdepth 1 -type f -size +0c | sort)
                                    CACHED_COUNT="${#CACHED_NOW[@]}"

                                    if [ "$CACHED_COUNT" -eq 0 ]; then continue; fi

                                    # Check if full batch is done; if so, switch to random and exit loop
                                    SRC_NOW=$(find "$WALLPAPER_DIR" -maxdepth 1 -type f | wc -l)
                                    if [ "$CACHED_COUNT" -ge "$SRC_NOW" ]; then
                                        RAND_IDX=$(( RANDOM % CACHED_COUNT ))
                                        plasma-apply-wallpaperimage "${CACHED_NOW[$RAND_IDX]}"
                                        rm -f "$TIMER_PID_FILE"
                                        exit 0
                                    fi

                                    # Still batching — pick next cached file in rotation
                                    LAST_APPLIED=$(cat /tmp/wallpaper-last-cached 2>/dev/null || echo "")
                                    NEXT_IDX=0
                                    for i in "${!CACHED_NOW[@]}"; do
                                        if [ "${CACHED_NOW[$i]}" = "$LAST_APPLIED" ]; then
                                            NEXT_IDX=$(( (i + 1) % CACHED_COUNT ))
                                            break
                                        fi
                                    done

                                    NEXT_FILE="${CACHED_NOW[$NEXT_IDX]}"
                                    plasma-apply-wallpaperimage "$NEXT_FILE"
                                    echo "$NEXT_FILE" > /tmp/wallpaper-last-cached
                                done
                            ) & disown
                            echo $! > "$TIMER_PID_FILE"
                        fi

                        # Handle the trigger file for partial-cache case (original behaviour)
                        if [ -f "$TRIGGER_FILE" ]; then
                            TRIGGERED_FILE=$(cat "$TRIGGER_FILE")
                            if [ "$B_NAME" == "$TRIGGERED_FILE" ]; then
                                plasma-apply-wallpaperimage "$C_FILE"
                                rm -f "$TRIGGER_FILE"
                            fi
                        fi
                    fi
                fi
            done
        ) & disown
    fi

elif [[ "$XDG_CURRENT_DESKTOP" == *"Hyprland"* ]]; then
    if ! pgrep -x awww-daemon >/dev/null; then
        awww-daemon &
        sleep 0.5
    fi

    COLORS_CMD="python3 $HOME/.config/hypr/wallpaper-colors.py '$CHOSEN' && ~/.config/quickshell/notif-theme-mako.sh 2>/dev/null"

    if [ -n "$PREV_PATH" ] && [ -f "$PREV_PATH" ] && [ "$PREV_PATH" != "$CHOSEN" ]; then
        # transition.py runs the reveal AND does the final animated apply itself
        # (a seamless on-cadence handoff). Applying again here would restart the
        # gif from frame 0 right after — a visible hitch — so we don't.
        python3 "$HOME/.config/hypr/wallpaper-transition.py" \
            "$PREV_PATH" "$CHOSEN" --at-start "$COLORS_CMD"
    else
        eval "$COLORS_CMD"
        # No transition (first wallpaper / same image): apply directly here.
        # --transition-fps works around the awww 0.12.1 regression where the
        # default frame timer otherwise makes every apply take ~430ms.
        awww img "$CHOSEN" --fill-color 000000 --resize crop --filter Nearest --transition-type none --transition-fps 255
    fi
    echo "$CHOSEN" > "$CURRENT_PATH_FILE"

    # Keep awww's cache small — its per-apply latency grows with the file count,
    # which would make the reveal laggy. Run detached (so it never contends with
    # the animation the final apply just started — that was a small
    # post-transition hitch) and after a brief delay. The 9>&- closes the
    # inherited flock fd so the prune's delay doesn't keep the stacking-lock held
    # and block the next wallpaper change. See prune-awww-cache.sh.
    setsid -f "$HOME/.config/hypr/prune-awww-cache.sh" "$CHOSEN" >/dev/null 2>&1 9>&-
else
    echo "Desktop environment not recognized. Wallpaper not set."
    exit 1
fi
