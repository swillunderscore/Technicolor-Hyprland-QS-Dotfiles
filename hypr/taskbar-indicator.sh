#!/usr/bin/env python3
import subprocess, json, sys

slot = int(sys.argv[1]) - 1

clients = json.loads(subprocess.check_output(
    ["hyprctl", "clients", "-j"], text=True
))
clients = sorted(
    [c for c in clients if c.get("workspace", {}).get("id", 0) > 0],
    key=lambda c: c["workspace"]["id"]
)

if slot >= len(clients):
    print('{"text":""}')
    sys.exit(0)

c = clients[slot]
cls = c.get("class", "").lower()
ws = c["workspace"]["id"]
addr = c.get("address", "")
title = c.get("title", "")[:50].replace('"', '\\"')

# Check if focused
try:
    active = json.loads(subprocess.check_output(
        ["hyprctl", "activewindow", "-j"], text=True
    ))
    state = "focused" if active.get("address") == addr else "normal"
except:
    state = "normal"

# Icon map: key prefix -> nerd font codepoint
ICONS = {
    # Browsers
    "brave":           "\U000f02af",  # chrome-like (same as waybar)
    "chromium":        "\U000f02af",
    "google-chrome":   "\U000f02af",
    "firefox":         "\uf269",
    "zen":             "\uf269",

    # Terminals
    "kitty":           "\uf489",
    "alacritty":       "\uf489",
    "wezterm":         "\uf489",
    "konsole":         "\uf489",
    "foot":            "\uf489",

    # Communication
    "vesktop":         "\U000f066f",  # discord (same as waybar)
    "discord":         "\U000f066f",
    "telegram":        "\uf2c6",
    "org.telegram":    "\uf2c6",
    "signal":          "\U000f0592",
    "slack":           "\U000f0372",
    "element":         "\U000f0838",
    "thunderbird":     "\U000f012a",

    # Gaming
    "steam":           "\U000f04d3",  # steam logo (same as waybar)
    "slippi":          "\uedf8",      # frog (same as waybar)
    "lutris":          "\U000f0baf",
    "heroic":          "\U000f0baf",
    "prismlauncher":   "\U000f0baf",
    "gamescope":       "\U000f0baf",
    "minecraft":       "\U000f0baf",

    # Media
    "spotify":         "\uf1bc",      # spotify (same as waybar)
    "com.spotify":     "\uf1bc",
    "mpv":             "\U000f040a",
    "vlc":             "\U000f057c",
    "obs":             "\U000f0580",
    "com.obsproject":  "\U000f0580",
    "audacity":        "\U000f075a",

    # Editors / Dev
    "code":            "\U000f0a1e",
    "kate":            "\U000f0377",
    "neovim":          "\uf36f",
    "nvim":            "\uf36f",
    "emacs":           "\ue632",
    "sublime":         "\ue7aa",
    "jetbrains":       "\ue6b5",
    "unityhub":        "\ue721",
    "unity":           "\ue721",
    "github-desktop":  "\U000f02a4",

    # Graphics
    "gimp":            "\uf1fc",
    "inkscape":        "\uf6ec",
    "blender":         "\U000f00ab",
    "org.blender":     "\U000f00ab",
    "krita":           "\uf1fc",

    # File managers
    "dolphin":         "\U000f024b",  # folder (same as waybar)
    "org.kde.dolphin": "\U000f024b",
    "nautilus":        "\U000f024b",
    "thunar":          "\U000f024b",
    "pcmanfm":         "\U000f024b",
    "nemo":            "\U000f024b",

    # System / Utils
    "missioncenter":   "\U000f04c5",  # speedometer (same as waybar)
    "systemsettings":  "\U000f0493",
    "pavucontrol":     "\U000f057e",
    "blueman":         "\U000f00af",

    # Office / Docs
    "libreoffice":     "\U000f021f",
    "okular":          "\U000f0226",
    "evince":          "\U000f0226",
    "zathura":         "\U000f0226",

    # Downloads
    "transmission":    "\U000f0214",
    "qbittorrent":     "\U000f0214",
}

GENERIC = "\U000f0560"

icon = GENERIC
for prefix, ic in ICONS.items():
    if cls.startswith(prefix):
        icon = ic
        break

print(f'{{"text":"{icon}", "tooltip":"{title}", "class":"{state}"}}')
