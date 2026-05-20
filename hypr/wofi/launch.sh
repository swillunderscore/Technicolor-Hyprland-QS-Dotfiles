#!/usr/bin/env bash

# Paths pointing to the files you just cloned
CONFIG="$HOME/.config/hypr/wofi/repo/config/config"
STYLE="$HOME/.config/hypr/wofi/repo/src/mocha/style.css"

# Check if wofi is already running; if not, launch it with the Mocha theme
if [[ ! $(pidof wofi) ]]; then
    wofi --conf "${CONFIG}" --style "${STYLE}"
else
    pkill wofi
fi
