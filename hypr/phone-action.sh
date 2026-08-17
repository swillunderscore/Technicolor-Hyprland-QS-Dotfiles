#!/usr/bin/env bash
# Actions for the phone remote deck. The deck runs inside the NESTED phone
# Hyprland, so playerctl/wpctl (session-global via dbus/pipewire) work directly,
# but the wallpaper action must re-target the MAIN session (its awww is on
# wayland-1, and we keep the phone wallpaper in sync afterward).
set -u
case "${1:-}" in
    wallpaper)
        # main session = the Hyprland instance NOT running the phone config
        MAIN=$(hyprctl instances -j 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    try:
        if 'phone.conf' not in open('/proc/%d/cmdline'%i['pid']).read():
            print(i['instance']); break
    except: pass")
        HYPRLAND_INSTANCE_SIGNATURE="$MAIN" WAYLAND_DISPLAY=wayland-1 \
            "$HOME/.config/hypr/wallpaper-cycle.sh" shuffle
        # re-sync the deck wallpaper to the desktop's new one (this script runs in
        # the nested env, so awww here targets the nested daemon = the deck).
        sleep 2
        NEW=$(WAYLAND_DISPLAY=wayland-1 awww query 2>/dev/null | grep -oP 'image: \K.*' | head -1)
        if [ -n "$NEW" ]; then
            echo "$NEW" > /tmp/phone-wallpaper
            awww img --transition-type none "$NEW"
        fi
        ;;
    playpause) playerctl play-pause ;;
    next)      playerctl next ;;
    prev)      playerctl previous ;;
    volup)     wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;;
    voldown)   wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
    *) echo "usage: phone-action.sh <wallpaper|playpause|next|prev|volup|voldown>" >&2; exit 1 ;;
esac
