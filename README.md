# Technicolor

🚨 This is basically entirely vibe coded (including most of the below lol)
   But 100% designed by me aside from the bugs :) 🚨

Uses [Hyprland](https://hyprland.org/), [Quickshell](https://quickshell.org/), and [mako](https://github.com/emersion/mako).

The bar is custom Quickshell, and its colors are pulled live from the current wallpaper. Workspaces are one long carousel that slides across every monitor together. It has an app launcher, live system monitors, a notification tray, per-monitor brightness, an alt-tab pie menu, and a [Settings app](#settings-app) — a real window with a cover-flow wallpaper picker and live color/glass tuning.

The same wallpaper palette can also theme your actual apps — Discord (Vesktop), Spotify, Dolphin and Brave get full-strength color blocks with auto-contrasting text, re-tinted on every wallpaper change, with optional per-pixel "glass" transparency between the blocks via a compositor chromakey shader. See [App theming](#app-theming-discord--spotify--dolphin--brave).


## Demo

clickable video
[![Demo](https://img.youtube.com/vi/WGOLzbLe-U8/maxresdefault.jpg)](https://youtu.be/WGOLzbLe-U8)

![screenshot](screenshot.png)

## Install

Follow these top to bottom and you'll have a working setup.

### 1. Dependencies

Everything needed: `hyprland`, `quickshell`, `mako`, `xdg-desktop-portal-hyprland`, `pipewire` + `wireplumber`, `ddcutil`, `nethogs`, `jq`, `gawk`, `kitty`, `wofi`, `awww`, `imagemagick`, `python-pillow`, `grim`, `slurp`, `satty`, `wl-clipboard`, `playerctl`, `brightnessctl`, plus a Nerd Font (JetBrainsMono Nerd Font). Optional: `nwg-look`, `nwg-displays`, `dex`, `wlogout`, `gnome-keyring`.

Most share the same package name across distros. The newer ones to watch are `quickshell`, `awww` (the wallpaper daemon — it's the current name of the project formerly called `swww`, so don't also install `swww`), and `satty`, plus Hyprland itself on older distros. Quickshell's per-distro install page: <https://quickshell.org/docs/master/guide/install-setup/>


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
  - `awww` — animated wallpaper daemon (the successor to `swww`; the package provides both the `awww` client and the `awww-daemon` the scripts start)
  - `imagemagick` + `python-pillow` — pull the color palette out of the wallpaper
  - `grim` + `slurp` + `satty` + `wl-clipboard` — screenshots: capture, region-select, annotate, copy
  - `playerctl` — media keys (play/pause/next)
  - `brightnessctl` — laptop backlight keys
  - a Nerd Font (I use JetBrainsMono Nerd Font) — every icon and glyph in the UI
  - optional: `nwg-look` (GTK theme GUI), `nwg-displays` (monitor-layout GUI — it
  produces `monitor =` lines you can paste into `local.conf`), `dex` (runs XDG autostart entries), `wlogout` (power menu), `gnome-keyring`
  (secrets)
  - optional, for app theming (see the App theming section) — install whichever
  apps you actually use, each alongside its theming helper:
    - `vesktop` — Discord client (Vencord is built in)
    - `spotify` + `spicetify-cli` — the native Spotify client and its theming CLI
    - `dolphin` + `qt6ct-kde` + `gcc` — the file manager, the Qt color theming, and
      the compiler for the rounded-blocks shim
    - `brave-bin` — the browser
    - glass transparency: `Hypr-DarkWindow` + `hyprglass` — both ship vendored
      (`hypr/Hypr-DarkWindow/`, `hypr/hyprglass/`) and build themselves at startup

**Arch** — the entire core install is in the official repos, so plain `pacman`, no AUR helper needed:
```
sudo pacman -S hyprland quickshell mako xdg-desktop-portal-hyprland pipewire wireplumber \
  ddcutil nethogs jq gawk kitty wofi awww imagemagick python-pillow \
  grim slurp satty wl-clipboard playerctl brightnessctl ttf-jetbrains-mono-nerd
```

Optional — the apps the wallpaper palette can theme, plus their helpers. Install only the ones you use (each still needs the one-time hook-up in [App theming](#app-theming-discord--spotify--dolphin--brave--gtk); the generators no-op for anything missing). **These are the only AUR packages in the whole setup** — vet the PKGBUILDs / use a helper you trust; nothing in the core above touches the AUR:
```
sudo pacman -S dolphin gcc                                 # official repos
paru -S vesktop spotify spicetify-cli qt6ct-kde brave-bin  # AUR — the only part that needs a helper
```
(The glass transparency uses two Hyprland plugins — `Hypr-DarkWindow` and `hyprglass` — both vendored in this repo (`hypr/Hypr-DarkWindow/`, `hypr/hyprglass/`) and compiled by their own `load.sh` on first launch; no `hyprpm`, no extra packages. See App theming.)

**Fedora:** most via `dnf` under the same names (Hyprland is packaged on F39+). quickshell is a COPR:
```
sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell
```
`awww` (Rust; the `swww` successor) and `satty` aren't in the Fedora repos — build them from source (`awww`: <https://codeberg.org/LGFae/awww>).

**Debian / Ubuntu:** `apt` has most of these, but Hyprland and quickshell are usually too old or missing, so build those two from source.

**NixOS:** add the packages to `environment.systemPackages` (or home-manager). Hyprland and quickshell both ship flakes; see the Hyprland wiki's Nix page and quickshell's install docs.

### 2. Copy the configs
```
cp -r hypr quickshell mako ~/.config/
mkdir -p ~/.local/share/applications && cp applications/*.desktop ~/.local/share/applications/
```
(The `.desktop` makes the Settings app show up in your launcher / app list. If you're doing the Spotify theming below, also `cp -r spicetify ~/.config/` — it only contains the live-color extension.)

### 3. Set up the per-machine files
The main config is **`hyprland.lua`** — recent Hyprland (0.55+) loads it automatically, and `hyprland.conf` ships beside it only as a fallback for older versions (Hyprland uses the `.lua` when present, otherwise the `.conf`). It pulls in a few *optional* per-machine fragments; they're gitignored, so copy the examples once and your edits stick across updates:
```
cp ~/.config/hypr/local.conf.example            ~/.config/hypr/local.conf
cp ~/.config/hypr/hyprglass-tuning.conf.example ~/.config/hypr/hyprglass-tuning.conf
cp ~/.config/hypr/terminal.conf.example         ~/.config/hypr/terminal.conf
cp ~/.config/mako/config.example                ~/.config/mako/config
```
- **Monitors** — one screen works as-is (the shipped `hl.monitor{ output = "", mode = "preferred", … }` line in `hyprland.lua` auto-detects it). For multi-monitor or a specific mode/refresh, the update-safe way is to add `monitor = ` lines to **`local.conf`** (gitignored, and read by `hyprland.lua`), e.g. `monitor = DP-1, 2560x1440@165, 0x0, 1` — run `hyprctl monitors` for names/modes, or use `nwg-displays`. You *can* instead edit the `hl.monitor` block in `hyprland.lua`, but that file is tracked, so an update re-copy overwrites it; `local.conf` is never touched.
- `local.conf` — machine-specific Hyprland bits: GPU/driver env (a ready-to-uncomment Nvidia block is included), input quirks, and any extra `monitor =` lines. It can otherwise stay empty.
- `hyprglass-tuning.conf` starts empty (just defaults); the Settings app's Glass tab writes to it. Everything else per-machine (`color-tuning.conf`, `wallpaper-dir.conf`, `launcher-apps.json`, `keybinds.conf`, …) is created by the Settings app on demand — sensible defaults apply when they're absent.

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

## Updating

Pull the latest and re-copy:
```
cd /path/to/this/repo && git pull
cp -r hypr quickshell mako ~/.config/
```
**Your personal settings are NOT touched.** Everything you tune at runtime —
the [Settings app](#settings-app)'s colors (`color-tuning.conf`), liquid-glass
sliders (`hyprglass-tuning.conf`), wallpaper folder (`wallpaper-dir.conf`),
auto-cycle prefs (`wallpaper-timer.conf`), pinned apps (`launcher-apps.json`) —
plus your `local.conf` —
are **gitignored**, so they live only in `~/.config` and aren't in the repo. A
`git pull` + copy overwrites the shipped code but leaves those files alone, so
your glass/color/launcher tweaks survive updates. (New tunables added in an
update just fall back to their defaults until you touch them.)

The only files the copy overwrites are the tracked ones — if you hand-edited a
tracked file (e.g. the monitor block in `hyprland.lua`), back it up first or —
better — keep machine-specific changes in `local.conf` (gitignored, read by
`hyprland.lua`, and never overwritten).

## Wallpapers

The animated wallpapers I use are pixel-art scenes by **Anas Abdin**: <https://www.tumblr.com/anasabdin>. The color extraction, nearest-neighbor upscaling, and wallpaper transition are tuned for that pixel-art style, so photos and other kinds of images may not look as good.

## Fonts

A Nerd Font is required or the icons render as boxes (JetBrainsMono Nerd Font, installed in step 1). The UI text needs **nothing extra** — it defaults to your system's sans-serif, so it renders instantly on any machine. Prefer a specific font? Pick any installed family in **Settings → System → Font** (applies live), or set `QS_FONT` before Hyprland starts:
```
export QS_FONT="Inter"          # bash / zsh
# fish:  set -Ux QS_FONT Inter
```
(I use SF Pro on my own machine — Apple's font, not redistributable — but the shipped default no longer depends on it.)

## Settings app

A real app window (`quickshell/Settings.qml`) — it appears in your app list as **Technicolor Settings**, and opens from the gear on the bar's launcher popup or with `qs ipc call settings open`. It's styled like the themed windows: solid rounded blocks with live liquid glass in the gaps. Tabs:

- **Apps** — edit the launcher's pinned apps (reorder, swap icons, add/remove). Pins are stored in `quickshell/launcher-apps.json`; a built-in default set is used until you customize.
- **Wallpaper** — set the wallpapers folder, and browse a **cover-flow** of every wallpaper in it: scroll or drag to spin it (a vertical mouse wheel scrolls it horizontally), click the centered cover to set it. Plus shuffle, open-folder, a **transition** picker (the switch animation — a per-pixel reveal ordered by Brightness, Shadows, Radial, Wipe, Dissolve, or Random), and **auto-cycle** controls: how often it rotates the wallpaper, a pause toggle, and pause-while-a-fullscreen-app-is-open — so a game or fullscreen video never gets a transition (or the CPU spike of one) mid-frame.
- **Colors** — four sliders that retint **every** themed app at once, with live previews and reset buttons: a text **contrast** threshold (where text flips light↔dark — center is the default, full-left forces dark text, full-right forces light), plus **saturation** and **brightness** *ceilings* (full-right = the wallpaper's own colors untouched; lower them to cap how vivid/bright the palette can get, which reins in over-saturated wallpapers while leaving already-muted/dark ones alone) and **hue** rotation. A slider release re-runs the whole palette pipeline, so the bar and all themed apps follow.
- **Glass** — live sliders for the hyprglass liquid-glass effect (refraction, fresnel, specular, blur, lens distortion, chromatic aberration, brightness/contrast/saturation/vibrancy), each with a reset, plus a write-in box for any value past a slider's range or any option without a slider. Applies instantly via `hyprctl keyword` and persists to `hypr/hyprglass-tuning.conf`.
- **Hotkeys** — a searchable, **editable** list of every keybind, grouped by purpose (apps, windows, focus, workspaces, media…) with the combo shown as keycaps. It's read live from `hyprctl binds`, so it always matches your real config — including anything in `local.conf`. **Click a shortcut's keys to rebind it**: hold your modifiers (they're detected as the "hold" part) and press a key; conflicts are caught and named so you don't clobber an existing bind, and `↺` resets one to its shipped default. Rebinds apply immediately and are saved to `keybinds.conf` (gitignored). Media/volume/mouse binds are shown but fixed.
- **System** — GUI pickers for the **UI font** (any installed family, previewed in itself), **default file manager**, and **default terminal** (sets Hyprland's Super+Q *and* the file manager's "Open Terminal"); an editor for `local.conf` with Save & reload; and an **Update** section that checks GitHub for new commits, lists them, and pulls + re-copies on a two-click confirm (leaving all your gitignored settings untouched); and **Spotify Liked Songs** tools — *Scan for AI music* (cross-references your likes against the community [soul-over-ai](https://github.com/xoundbyte/soul-over-ai) known-AI-artist list by exact artist ID) and *Back up to CSV* (a full export of your library so you never lose it). Both run **read-only through your open Spotify via the Spicetify session** — no developer app, no extra login — using `spotify-liked.py` (`scan-ai-music.sh` / `export-liked-songs.sh`).

Everything it writes (`color-tuning.conf`, `hyprglass-tuning.conf`, `wallpaper-dir.conf`, `launcher-apps.json`) is per-machine and gitignored; defaults apply when the files are absent.

## App theming (Discord / Spotify / Dolphin / Brave / GTK)

All optional — everything below is driven by `hypr/gen-*.py`, which `wallpaper-colors.py` already calls on every wallpaper change (failures are silently skipped, so nothing breaks if you skip an app). The shared engine lives in `gen-discord-theme.py`: it picks the bar's gradient pair as primary/secondary, computes WCAG black-or-white ink per surface, and feeds every other generator. The ink crossover and the overall color saturation are tunable live for every app at once from [Settings → Colors](#settings-app).

The themed apps aren't part of the core install — install whichever you use (this is the same optional line as in [step 1](#1-dependencies); the generators just no-op for anything you don't have):
```
sudo pacman -S dolphin gcc                                 # official repos
paru -S vesktop spotify spicetify-cli qt6ct-kde brave-bin  # AUR — the only part that needs a helper
```
Each app still needs its one-time hook-up described below (Vencord QuickCSS, `spicetify` apply, the qt6ct `color_scheme_path`, the Brave flags).

**Discord (Vesktop + Vencord):** generated themes land in `~/.config/vesktop/themes/`. In Vesktop → Settings → Themes, enable **Technicolor**, then **Technicolor Blocks** (in that order — base then the block layout on top). Live colors go through Vencord's QuickCSS (enable "Use QuickCSS"), which is how wallpaper changes apply with zero flash and a 1.4s cross-fade. Built on [midnight-discord](https://github.com/refact0r/midnight-discord) (inlined).

**Spotify (spicetify):** `gen-spotify-theme.py` writes a full Technicolor theme (`spicetify config current_theme Technicolor`, then `spicetify backup apply`). Live colors poll a tiny local HTTP server (`technicolor-color-server.py`, already launched at login by your Hyprland config) via the `spicetify/Extensions/technicolor-sync.js` extension (`spicetify config extensions technicolor-sync.js`). For real per-pixel transparency behind the blocks, add the chromakey shader (below).

**Dolphin / Qt apps:** `gen-kde-colors.py` rewrites `kdeglobals`, a named KDE color scheme, and a qt6ct palette. You need `qt6ct-kde` (AUR) with `QT_QPA_PLATFORMTHEME=qt6ct` in your environment, and — this is the one non-obvious step — point `~/.config/qt6ct/qt6ct.conf`'s `color_scheme_path` at `~/.local/share/color-schemes/Technicolor.colors`, NOT at a qt6ct palette file (otherwise KDE apps silently fall back to stock Breeze for everything KColorScheme-driven — white file views that no palette setting can fix). Launch Dolphin through `hypr/dolphin-tc.sh`: it applies the rounded-blocks stylesheet and auto-compiles a tiny `LD_PRELOAD` shim (`tc-styledbg.cpp`, needs `gcc` + Qt6 headers) that lets the side panels paint rounded QSS blocks. The shim also watches the stylesheet and re-applies it live, so a running Dolphin recolors with the wallpaper instead of only at launch (Qt reads `-stylesheet` once otherwise).

**Brave:** `gen-brave-theme.py` writes an unpacked Chromium theme to `~/.config/brave-technicolor-theme`. Auto-load and auto-recolor it with two flags in `~/.config/brave-flags.conf` — use an **absolute path** (the brave launcher reads this file line-by-line and does *not* expand `~`, so a tilde silently fails to load the theme):
```
--load-extension=/home/YOU/.config/brave-technicolor-theme
--remote-debugging-port=9222
```
The first loads — and **re-reads** — the theme on every launch, which is what makes a wallpaper change you made while Brave was closed show up on the next launch (paired with the per-palette extension version, so Chromium re-bakes instead of serving its cache, rather than just keeping the last theme it baked while running). No `brave://extensions` clicking — Brave just flashes a dismissable "developer-mode extensions" bubble. The second lets `brave-theme-reload.py` apply new colors *live* while Brave is open: Chromium caches the theme in the profile, so rewriting the files does nothing on its own — the script forces a re-read + re-apply with the browser-level CDP command `Extensions.loadUnpacked` (no tab, no window). **Security cost:** that debug port lets any process on your machine drive the browser (it's localhost-only, but still real) — it's a big part of why this repo is opt-in. The frame and tab-strip are painted in the chromakey colour so the band-limited shader (below) glasses them to the wallpaper; web content is never touched.

**GTK apps:** `gen-gtk-theme.py` writes a Technicolor GTK theme and flips between two copies (`Technicolor-A`/`-B`) on each wallpaper change so GTK apps re-read and recolor immediately (GTK caches by theme *name*, so the rename is what forces the reload). This sets your global GTK theme, so GTK file dialogs etc. follow the wallpaper too; revert any time with `gsettings set org.gnome.desktop.interface gtk-theme Adwaita` (or your previous theme).

**The glass (chromakey) layer:** the gaps between color blocks in Spotify/Dolphin — and Brave's tab-strip — can be made actually transparent (real windows/wallpaper visible behind) using [Hypr-DarkWindow](https://github.com/micha4w/Hypr-DarkWindow) custom shaders, plus [hyprglass](https://github.com/hyprnux/hyprglass) for a refraction/liquid-glass look on those areas. Both plugins are vendored in this repo — Hypr-DarkWindow (MIT) under `hypr/Hypr-DarkWindow/` and a one-line-patched hyprglass (BSD-3) under `hypr/hyprglass/` — and each one's `load.sh` builds + loads it against your system Hyprland headers at startup (force-rebuilding itself when a Hyprland update leaves the binary ABI-stale), so there's no `hyprpm add` for either. (The patch makes glass *layers* re-sample the backdrop every frame: upstream caches it, so the alt-tab pie's liquid glass froze the animated wallpaper it captured when it opened.) The shaders register automatically once the Hypr-DarkWindow plugin is loaded — `hyprland.lua` adds `tckey` / `tckeydolph` / `tckeybrave` with their paths resolved from `$HOME`, so there's nothing to uncomment or hardcode; just run `hypr/tckey-reload.sh` after changing shader args (the plugin caches them across reloads). Browsers were long considered un-keyable — a whole-window key eats matching pixels inside pages (e.g. a teal Twitch stream) — so the Brave variant is **band-limited**: it only keys the top tab-strip band and refuses to touch anything below it, leaving web content alone. Two more gotchas already handled: `decoration:blur:size` doubles as Hyprland's re-render margin for these effects even with blur disabled (keep it at 40 or stacked glass glitters on focus changes), and Dolphin uses a fixed-key shader variant so its dialogs don't get keyed transparent.

## What's where

- `hypr/` — Hyprland config and its scripts: the workspace carousel, wallpaper cycling/colors/thumbnails (`wallpaper-*.sh/.py`), taskbar, minimize, alt-tab, the Dolphin-reusing folder opener (`open-folder.sh`), the hyprglass tuning helpers (`hyprglass-get.sh`/`hyprglass-set.sh`), plus the app-theming engine (`gen-*.py`), the chromakey shaders (`technicolor-chromakey*.glsl`), the color server, and the Dolphin launcher/shim.
- `quickshell/` — the bar (`Bar.qml`), the Settings app (`Settings.qml`), the alt-tab pie, notification scripts, system-monitor helpers, shaders.
- `applications/` — the `.desktop` entry so the Settings app appears in your launcher.
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

## Portability

- **Distros:** the bar/compositor side is distro-agnostic — if you can install the step-1 packages, it runs. The app-theming extras are Arch-friendliest: `qt6ct-kde` is an AUR package (elsewhere you'd build it), and both vendored plugins (`Hypr-DarkWindow`, `hyprglass`) compile against your exact Hyprland version via their own `load.sh` — so you just need base-devel/cmake plus the Hyprland headers (the `hyprland` package).
- **Resolutions & scale:** nothing is hardcoded to a resolution. The bar and themes are pixel-based, so on a 4K display you'll want a Hyprland monitor scale like any px-based UI; the Qt theming and chromakey shaders are scale-aware.
- **Hardware:** GPU-agnostic. The bar's GPU usage/VRAM/temp auto-detect: amdgpu sysfs first, then `nvidia-smi` (proprietary/open Nvidia), with graceful zeros otherwise; CPU temp covers AMD/Intel/ARM hwmon names. Nvidia setup (env vars, cursor quirk, driver notes) is a ready-to-uncomment block in `local.conf.example`. The swap widget reads all swap devices and labels itself ZRAM or SWAP automatically. Monitor brightness needs `ddcutil`-compatible displays.
- **Laptops:** works out of the box — the touchpad drives the 3-finger workspace swipe, and the brightness/volume/media **function keys are bound** (`brightnessctl` for the built-in backlight, `wpctl`/`playerctl` for the rest). Two caveats: the bar's brightness *sliders* drive external DDC/CI monitors via `ddcutil`, not the built-in panel (use the brightness keys for that), and there's **no battery indicator on the bar yet**. GPU auto-detect covers Intel/AMD/Nvidia laptops (for Nvidia, uncomment the block in `local.conf`).
- **Spotify:** the theming assumes the native client (spicetify paths + window class `Spotify`); flatpak Spotify needs spicetify's flatpak setup.

## One-block install (for the impatient and/or stupid)

> ⚠️
> Hello it is me swillunderscore again
> Unless you know me why would you trust me with a giant install command like this
> It is a very bad idea to run things from people you dont know
> but yea like mr claude wrote all this and i run it and i trust it
> There was some big AUR malware thing today (06/12/2026) and i checked to make sure nothing on my system was affected and nothing was
> Therefore nothing here was affected
> ⚠️

The Install section above, as one script — **save it to `install.sh` and run `bash install.sh`** (this runs in bash no matter your login shell, so **fish/zsh users included**). Do NOT paste it line-by-line into your shell: the `for … do … done` loop isn't valid in fish, and the `set -e` would close the shell on the first hiccup — either way it looks like "nothing happened." It prints each step as it runs, and existing configs are moved to `*.bak.<time>`, never deleted. Arch-family; the core uses plain `pacman`, so on other distros just swap the package line for your package manager's equivalent.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. packages
sudo pacman -S --needed hyprland quickshell mako xdg-desktop-portal-hyprland pipewire wireplumber \
  ddcutil nethogs jq gawk kitty wofi awww imagemagick python-pillow \
  grim slurp satty wl-clipboard playerctl brightnessctl ttf-jetbrains-mono-nerd

# 2. configs (backs up anything already there)
echo "==> Cloning Technicolor to /tmp/technicolor ..."
rm -rf /tmp/technicolor
git clone --depth 1 https://github.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles /tmp/technicolor
echo "==> Backing up any existing configs to *.bak.<timestamp> ..."
for d in hypr quickshell mako spicetify; do
  [ -e ~/.config/$d ] && mv ~/.config/$d ~/.config/$d.bak.$(date +%s) && echo "    moved ~/.config/$d aside"
done
echo "==> Copying configs into ~/.config ..."
cp -r /tmp/technicolor/hypr /tmp/technicolor/quickshell /tmp/technicolor/mako /tmp/technicolor/spicetify ~/.config/
mkdir -p ~/.local/share/applications && cp /tmp/technicolor/applications/*.desktop ~/.local/share/applications/
echo "==> Configs installed."

# 3. per-machine files + wallpaper dir
cp ~/.config/hypr/local.conf.example            ~/.config/hypr/local.conf
cp ~/.config/hypr/hyprglass-tuning.conf.example ~/.config/hypr/hyprglass-tuning.conf
cp ~/.config/hypr/terminal.conf.example         ~/.config/hypr/terminal.conf
cp ~/.config/mako/config.example                ~/.config/mako/config
mkdir -p ~/Wallpapers/animated

# 4. monitor brightness (takes effect after re-login)
sudo usermod -aG i2c "$USER"

cat <<'DONE'
Done. Before logging into Hyprland:
  1. put animated wallpapers in ~/Wallpapers/animated/   (see Wallpapers section)
  2. multi-monitor? add 'monitor =' lines to ~/.config/hypr/local.conf  (one screen auto-detects; hyprctl monitors for names)
  3. want a specific UI font? pick one in Settings → System → Font (it defaults to your system sans)
App theming (Discord/Spotify/Dolphin/Brave/GTK) is NOT installed above — those
apps and their one-time hook-up live in the App theming section of the README.
DONE
```
