# Technicolor

🚨 This is basically entirely vibe coded (including most of the below lol)
   But 100% designed by me aside from the bugs :) 🚨

Uses [Hyprland](https://hyprland.org/), [Quickshell](https://quickshell.org/), and [mako](https://github.com/emersion/mako).

The bar is custom Quickshell, and its colors are pulled live from the current wallpaper. Workspaces are one long carousel that slides across every monitor together. It has an app launcher, live system monitors, a notification tray, per-monitor brightness, and an alt-tab pie menu.

The same wallpaper palette can also theme your actual apps — Discord (Vesktop), Spotify, Dolphin and Brave get full-strength color blocks with auto-contrasting text, re-tinted on every wallpaper change, with optional per-pixel "glass" transparency between the blocks via a compositor chromakey shader. See [App theming](#app-theming-discord--spotify--dolphin--brave).


## Demo

clickable video
[![Demo](https://img.youtube.com/vi/fFTZ00qKpcg/maxresdefault.jpg)](https://youtu.be/fFTZ00qKpcg)

![screenshot](screenshot.png)

## Install

Follow these top to bottom and you'll have a working setup.

### 1. Dependencies

Everything needed: `hyprland`, `quickshell`, `mako`, `xdg-desktop-portal-hyprland`, `pipewire` + `wireplumber`, `ddcutil`, `nethogs`, `jq`, `gawk`, `kitty`, `wofi`, `swww`, `imagemagick`, `python-pillow`, `grim`, `slurp`, `satty`, `wl-clipboard`, `playerctl`, `brightnessctl`, plus a Nerd Font (JetBrainsMono Nerd Font). Optional: `nwg-look`, `nwg-displays`, `dex`, `wlogout`, `gnome-keyring`.

Most share the same package name across distros. The newer ones to watch are `quickshell`, `swww`, and `satty`, plus Hyprland itself on older distros. Quickshell's per-distro install page: <https://quickshell.org/docs/master/guide/install-setup/>


  What each piece is for:

  - `hyprland` — the Wayland compositor everything runs on
  - `quickshell` — the framework the bar is built in
  - `mako` — notification daemon; the bar's tray is a frontend for it
  - `xdg-desktop-portal-hyprland` — screen-share and file-picker support for apps
  - `pipewire` + `wireplumber` — audio, and the volume controls
  - `ddcutil` — external-monitor brightness over the cable (the brightness sliders)
  - `nethogs` — per-app network usage (the network widget)
  - `jq` — JSON parsing in the scripts
  - `gawk` — number crunching in the system-monitor script
  - `kitty` — terminal
  - `wofi` — app launcher / run menu
  - `swww` — animated wallpaper daemon
  - `imagemagick` + `python-pillow` — pull the color palette out of the wallpaper
  - `grim` + `slurp` + `satty` + `wl-clipboard` — screenshots: capture, region-select, annotate, copy
  - `playerctl` — media keys (play/pause/next)
  - `brightnessctl` — laptop backlight keys
  - a Nerd Font (I use JetBrainsMono Nerd Font) — every icon and glyph in the UI
  - optional: `nwg-look` (GTK theme GUI), `nwg-displays` (monitor-layout GUI that writes
  monitors.conf), `dex` (runs XDG autostart entries), `wlogout` (power menu), `gnome-keyring`
  (secrets)
  - optional, for app theming (see the App theming section): `vesktop` (Discord),
  `spicetify-cli` (Spotify), `qt6ct-kde` + `gcc` (Dolphin/Qt), and the Hyprland plugins
  `Hypr-DarkWindow` + `hyprglass` via `hyprpm` (the glass transparency)

**Arch** (my distro; a few are AUR, so use `paru`/`yay`):
```
paru -S hyprland quickshell mako xdg-desktop-portal-hyprland pipewire wireplumber \
  ddcutil nethogs jq gawk kitty wofi swww imagemagick python-pillow \
  grim slurp satty wl-clipboard playerctl brightnessctl ttf-jetbrains-mono-nerd
```

**Fedora:** most via `dnf` under the same names (Hyprland is packaged on F39+). quickshell is a COPR:
```
sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell
```
`swww` and `satty` may need a COPR or building from source.

**Debian / Ubuntu:** `apt` has most of these, but Hyprland and quickshell are usually too old or missing, so build those two from source.

**NixOS:** add the packages to `environment.systemPackages` (or home-manager). Hyprland and quickshell both ship flakes; see the Hyprland wiki's Nix page and quickshell's install docs.

### 2. Copy the configs
```
cp -r hypr quickshell mako ~/.config/
```
(If you're doing the Spotify theming below, also `cp -r spicetify ~/.config/` — it only contains the live-color extension.)

### 3. Set up the two per-machine files
`hyprland.conf` sources these, so they need to exist:
```
cp ~/.config/hypr/monitors.conf.example ~/.config/hypr/monitors.conf
cp ~/.config/hypr/local.conf.example    ~/.config/hypr/local.conf
```
- Edit `monitors.conf` for your displays. Run `hyprctl monitors` for names and modes, or use `nwg-displays`. The `preferred, auto` fallback works for a single screen as-is.
- `local.conf` is for machine-specific Hyprland bits (GPU driver, input quirks). It can stay empty.

### 4. Add wallpapers
Put animated wallpapers in `~/Wallpapers/animated/` (see the Wallpapers section). The bar regenerates its color palette from the current wallpaper automatically.

### 5. Enable monitor brightness
`ddcutil` needs you in the `i2c` group:
```
sudo usermod -aG i2c $USER
```
Log out and back in for it to take effect.

### 6. Log into Hyprland
Select Hyprland at your display manager (or start it from a TTY).

## Wallpapers

The animated wallpapers I use are pixel-art scenes by **Anas Abdin**: <https://www.tumblr.com/anasabdin>. The color extraction, nearest-neighbor upscaling, and wallpaper transition are tuned for that pixel-art style, so photos and other kinds of images may not look as good.

## Fonts

A Nerd Font is required or the icons render as boxes; I use JetBrainsMono Nerd Font (installed in step 1). The UI text is SF Pro, which is Apple's font, so I can't include it. Without it, set `QS_FONT` to a font you have (before Hyprland starts, e.g. in your shell profile):
```
export QS_FONT="Inter"
```

## App theming (Discord / Spotify / Dolphin / Brave)

All optional — everything below is driven by `hypr/gen-*.py`, which `wallpaper-colors.py` already calls on every wallpaper change (failures are silently skipped, so nothing breaks if you skip an app). The shared engine lives in `gen-discord-theme.py`: it picks the bar's gradient pair as primary/secondary, computes WCAG black-or-white ink per surface, and feeds every other generator.

**Discord (Vesktop + Vencord):** generated themes land in `~/.config/vesktop/themes/` — enable exactly ONE (`technicolor-glass.css` is the good one: solid color blocks on a liquid-glass gradient). Live colors go through Vencord's QuickCSS (enable "Use QuickCSS"), which is how wallpaper changes apply with zero flash and a 1.4s cross-fade. Built on [midnight-discord](https://github.com/refact0r/midnight-discord) (inlined).

**Spotify (spicetify):** `gen-spotify-theme.py` writes a full Technicolor theme (`spicetify config current_theme Technicolor`, then `spicetify backup apply`). Live colors poll a tiny local HTTP server (`technicolor-color-server.py`, already in `hyprland.conf`'s exec-once) via the `spicetify/Extensions/technicolor-sync.js` extension (`spicetify config extensions technicolor-sync.js`). For real per-pixel transparency behind the blocks, add the chromakey shader (below).

**Dolphin / Qt apps:** `gen-kde-colors.py` rewrites `kdeglobals`, a named KDE color scheme, and a qt6ct palette. You need `qt6ct-kde` (AUR) with `QT_QPA_PLATFORMTHEME=qt6ct` in your environment, and — this is the one non-obvious step — point `~/.config/qt6ct/qt6ct.conf`'s `color_scheme_path` at `~/.local/share/color-schemes/Technicolor.colors`, NOT at a qt6ct palette file (otherwise KDE apps silently fall back to stock Breeze for everything KColorScheme-driven — white file views that no palette setting can fix). Launch Dolphin through `hypr/dolphin-tc.sh`: it applies the rounded-blocks stylesheet and auto-compiles a tiny `LD_PRELOAD` shim (`tc-styledbg.cpp`, needs `gcc` + Qt6 headers) that lets the side panels paint rounded QSS blocks.

**Brave:** `gen-brave-theme.py` writes an unpacked Chromium theme to `~/.config/brave-technicolor-theme` — load it once via `brave://extensions` (developer mode → Load unpacked), then hit reload there after wallpaper changes (Chromium can't live-update themes). Colors only — never chromakey a browser, it eats matching pixels inside page content.

**The glass (chromakey) layer:** the gaps between color blocks in Spotify/Dolphin can be made actually transparent — real windows/wallpaper visible behind — using [Hypr-DarkWindow](https://github.com/micha4w/Hypr-DarkWindow) custom shaders (`hyprpm add micha4w/Hypr-DarkWindow`), plus optionally [hyprglass](https://github.com/hyprnux/hyprglass) for a refraction/liquid-glass look on those areas. Uncomment the shader blocks in `local.conf` (they need absolute paths) and use `hypr/tckey-reload.sh` after changing shader args (the plugin caches them across reloads). Two gotchas already handled in the configs: `decoration:blur:size` doubles as Hyprland's re-render margin for these effects even with blur disabled (keep it at 40 or stacked glass glitters on focus changes), and Dolphin uses a fixed-key shader variant so its dialogs don't get keyed transparent.

## What's where

- `hypr/` — Hyprland config and its scripts: the workspace carousel, wallpaper cycling and theming, taskbar, minimize, alt-tab, plus the app-theming engine (`gen-*.py`), the chromakey shaders (`technicolor-chromakey*.glsl`), the color server, and the Dolphin launcher/shim.
- `quickshell/` — the bar (`Bar.qml`), the alt-tab pie, notification scripts, system-monitor helpers, shaders.
- `mako/` — notification styling. The bar's tray reads from mako.
- `spicetify/` — the Spotify live-color extension (`Extensions/technicolor-sync.js`).

## Swapping mako

mako is fairly baked in, so this isn't a one-liner. The tray shells out to `makoctl` and reads mako's JSON, and the theming and silencing rewrite mako's config file. To use something else (dunst, swaync, etc.), port these:

- `quickshell/notif-bump.sh` — `makoctl list -j` and the on-notify hook
- `quickshell/notif-clear.sh` — `makoctl dismiss`
- `quickshell/notif-activate.sh` — `makoctl invoke`
- `quickshell/notif-silence.sh` — rewrites mako's per-app silence rules
- `quickshell/notif-theme-mako.sh` — regenerates mako's colors from the wallpaper
- `mako/config` — the config format
- `quickshell/Bar.qml` — assumes mako's record fields (`app_icon`, `desktop_entry`, …)

## Notes

- mako is required for the notification tray; it's the actual daemon and the bar is the frontend.
- `nethogs` runs under sudo for the network widget; without a sudoers rule it stays blank.
- GPU, temperature sensors, and monitor brightness all auto-detect, so there's nothing to hardcode.
