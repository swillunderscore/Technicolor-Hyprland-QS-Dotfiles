# Hyprland + Quickshell dotfiles

My Linux desktop: a [Hyprland](https://hyprland.org/) compositor with a custom
[Quickshell](https://quickshell.org/) bar — workspaces carousel, app launcher,
system monitors, notification tray, per-monitor brightness — themed live off the
current wallpaper.

> **Heads up:** I designed all of this but the code is vibe-coded — I'm a
> designer, not a coder. It runs great and is cleaned up for sharing, but it's
> "here's my setup to crib from," not a maintained project.

![screenshot](screenshot.png) <!-- drop a screenshot here -->

## What's in here

| Folder | What it is |
|--------|-----------|
| `hypr/` | Hyprland config + its scripts (carousel workspaces, wallpaper cycling, taskbar, minimize) |
| `quickshell/` | The bar (`Bar.qml`), alt-tab pie, notification scripts, system-monitor helpers, shaders |
| `mako/` | Notification daemon config (the bar's notification tray is a frontend for mako) |

## Setup

No install script — these are just config folders. Put them where Hyprland and
Quickshell look for them (`~/.config/`):

```sh
# from inside this repo
cp -r hypr quickshell mako ~/.config/
```

Then create the two per-machine files from their templates and edit them:

```sh
cp ~/.config/hypr/monitors.conf.example ~/.config/hypr/monitors.conf
cp ~/.config/hypr/local.conf.example    ~/.config/hypr/local.conf
```

- **`monitors.conf`** — your displays. Get names/modes with `hyprctl monitors`,
  or use `nwg-displays`. The default `monitor = , preferred, auto, 1` works for
  most single setups as-is.
- **`local.conf`** — anything machine-specific (GPU driver, primary output,
  input tweaks, app→monitor rules). It's sourced last by `hyprland.conf`.
  All examples are commented out, so an empty/unedited one is fine.

Install the dependencies below, then log into Hyprland.

## Dependencies

Arch package names (I'm on CachyOS). Other distros: same tools, translate the
names; Quickshell may need building from source.

**Core:** `hyprland` · `quickshell` (AUR) · `mako` · `xdg-desktop-portal-hyprland`
· `pipewire` · `wireplumber`

**Bar features:** `ddcutil` (monitor brightness) · `nethogs` (per-app network) ·
`jq` · `gawk`

**Used by the Hyprland config:** `kitty` · `wofi` · `swww`/`awww` (animated
wallpaper) · `imagemagick` + `python-pillow` (wallpaper palette) · `grim`
`slurp` `satty` `wl-clipboard` (screenshots) · `playerctl` `brightnessctl`
· optional: `nwg-look` `dex` `gnome-keyring` `wlogout` `nwg-displays`

**Fonts:**
- **JetBrainsMono Nerd Font — required.** Every icon/glyph comes from it; without
  a Nerd Font you get tofu boxes (□). It's free.
- **SF Pro — optional** (the UI text font; it's Apple's, can't be bundled).
  Don't have it? It still works with a substitute. To use any installed font
  without editing QML, set `QS_FONT`, e.g. `export QS_FONT="Inter"` before
  Hyprland starts.

## Auto-detects (nothing to edit)

- **GPU + temps** — finds your GPU and CPU/GPU temp sensors by scanning `/sys`,
  so it works on AMD/Intel/Nvidia with no hardcoded paths.
- **Monitor brightness** — one slider per DDC/CI monitor, built from
  `ddcutil detect`. Any monitor count; virtual/headless outputs are skipped.

## Good to know

- **mako is required** for the notification tray — the bar reads notifications
  from it; it isn't its own notification daemon.
- **`ddcutil`** needs the `i2c-dev` module and your user in the `i2c` group:
  `sudo usermod -aG i2c $USER` (then re-login). Laptop built-in screens use
  backlight, not DDC/CI, so they won't get a slider — use the brightness keys.
- **`nethogs` runs via `sudo`** for the network widget. To skip the password
  prompt, add a sudoers rule for it; otherwise that one widget stays blank.
- **Wallpapers** live in `~/Wallpapers/animated/` (or edit `wallpaper-cycle.sh`).
- **Qt theming** assumes `qt6ct` + Breeze (set via env vars in `hyprland.conf`).

## License

It's dotfiles — crib freely. No formal license; add an MIT `LICENSE` if you want
to be explicit. The vendored wofi theme in `hypr/wofi/repo/` keeps its own.
