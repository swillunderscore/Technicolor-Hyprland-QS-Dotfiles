#!/usr/bin/env bash
# Back up Spotify Liked Songs to a CSV (default ~/spotify-liked-DATE.csv).
exec python3 "$HOME/.config/hypr/spotify-liked.py" export "$@"
