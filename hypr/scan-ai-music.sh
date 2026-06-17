#!/usr/bin/env bash
# Scan Spotify Liked Songs against the soul-over-ai known-AI-artist list.
exec python3 "$HOME/.config/hypr/spotify-liked.py" scan "$@"
