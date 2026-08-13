# Technicolor

A Hyprland desktop that recolors itself from your wallpaper.

Bar, notifications, Discord, Spotify, Dolphin, Brave and GTK all follow whatever's on screen.
Everything is tunable from a settings app with sliders, so you don't have to open a config
file.

🚨 This is basically entirely vibe coded (including most of the below lol)
   But 100% designed by me aside from the bugs :) 🚨

[![Demo](https://img.youtube.com/vi/f_846Oc1UWg/maxresdefault.jpg)](https://youtu.be/f_846Oc1UWg)

![screenshot](screenshot.png)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles/main/install.sh -o /tmp/technicolor-install.sh
bash /tmp/technicolor-install.sh
```

Works in any shell. Installs the core from the official Arch repos, copies the configs, then
asks one app at a time which things you want themed.

Nothing proprietary is installed unless you say yes. Existing configs are backed up to
`*.bak.<time>`. When it's done, log out and pick Hyprland.

> ⚠️
> Hello it is me swill again
> Unless you know me why would you trust me with a giant install command like this
> It is a very bad idea to run things from people you dont know
> but yea like mr claude wrote all this and i run it and i trust it
> There was some big AUR malware thing today (06/12/2026) and i checked to make sure nothing on my system was affected and nothing was
> Therefore nothing here was affected
> ⚠️

Want to read it first? It's [`install.sh`](install.sh) — eyeball it, then run it. Or do it by
hand:

<details>
<summary><b>Manual install</b> — packages, per-distro notes, per-machine files</summary>

### 1. Dependencies

`hyprland`, `quickshell`, `mako`, `xdg-desktop-portal-hyprland`, `pipewire` + `wireplumber`,
`ddcutil`, `nethogs`, `jq`, `gawk`, `kitty`, `wofi`, `awww`, `imagemagick`, `python-pillow`,
`grim`, `slurp`, `satty`, `wl-clipboard`, `playerctl`, `brightnessctl`, `base-devel`, plus a
Nerd Font. Optional: `nwg-look`, `nwg-displays`, `dex`, `wlogout`, `gnome-keyring`.

**Arch** — the entire core is in the official repos, no AUR helper needed:
```
sudo pacman -S hyprland quickshell mako xdg-desktop-portal-hyprland pipewire wireplumber \
  ddcutil nethogs jq gawk kitty wofi awww imagemagick python-pillow \
  grim slurp satty wl-clipboard playerctl brightnessctl base-devel ttf-jetbrains-mono-nerd
```

Most names are the same across distros. The ones to watch are `quickshell`, `awww` (the
wallpaper daemon — this is the current name of the project formerly called `swww`, so don't
also install `swww`), and `satty`.

<details>
<summary>What each package is for</summary>

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
- `awww` — animated wallpaper daemon (successor to `swww`; provides both the `awww` client and the `awww-daemon` the scripts start)
- `imagemagick` + `python-pillow` — pull the color palette out of the wallpaper
- `grim` + `slurp` + `satty` + `wl-clipboard` — screenshots: capture, region-select, annotate, copy
- `playerctl` — media keys
- `brightnessctl` — laptop backlight keys
- `base-devel` — `make`/`g++`/`pkg-config` to compile the two bundled plugins at startup. Skip it and Hyprland throws ~15 `hyprwater:` config errors on login and you get no glass; everything else still works.
- a Nerd Font (I use JetBrainsMono Nerd Font) — every icon and glyph in the UI
- optional: `nwg-look` (GTK theme GUI), `nwg-displays` (monitor layout GUI — produces `monitor =` lines you can paste into `local.conf`), `dex` (XDG autostart), `wlogout` (power menu), `gnome-keyring` (secrets)
</details>

<details>
<summary>Fedora / Debian / NixOS</summary>

**Fedora:** most via `dnf` under the same names (Hyprland is packaged on F39+). quickshell is a COPR:
```
sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell
```
`awww` and `satty` aren't in the Fedora repos — build from source (`awww`: <https://codeberg.org/LGFae/awww>).

**Debian / Ubuntu:** `apt` has most of these, but Hyprland and quickshell are usually too old or missing — build those two from source.

**NixOS:** add the packages to `environment.systemPackages` (or home-manager). Hyprland and quickshell both ship flakes.
</details>

### 2. Copy the configs
```
cp -r hypr quickshell mako ~/.config/
mkdir -p ~/.local/share/applications && cp applications/*.desktop ~/.local/share/applications/
```
(The `.desktop` makes the Settings app show up in your app list. Doing the Spotify theming? Also `cp -r spicetify ~/.config/`.)

### 3. Per-machine files

The main config is **`hyprland.lua`**. Hyprland 0.55+ loads it automatically. (`hyprland.conf`
ships beside it as a fallback for older versions.)

It reads optional per-machine fragments, all gitignored. Copy the examples once and your edits
survive updates:
```
cp ~/.config/hypr/local.conf.example            ~/.config/hypr/local.conf
cp ~/.config/hypr/hyprwater-tuning.conf.example ~/.config/hypr/hyprwater-tuning.conf
cp ~/.config/hypr/terminal.conf.example         ~/.config/hypr/terminal.conf
cp ~/.config/mako/config.example                ~/.config/mako/config
```
**Monitors:** one screen works as-is. For multi-monitor, put `monitor =` lines in
**`local.conf`**, not `hyprland.lua` — `local.conf` is gitignored and never overwritten,
`hyprland.lua` is tracked and will be. `hyprctl monitors` lists names, or use `nwg-displays`.

Everything else per-machine is created by the Settings app on demand.

### 4. Wallpapers, brightness, log in

Animated wallpapers go in `~/Wallpapers/animated/`.

External-monitor brightness needs you in the `i2c` group:
```
sudo usermod -aG i2c $USER
```
Log out and back in, then pick Hyprland at your display manager.
</details>

<details>
<summary><b>Updating</b> — and why it won't eat your settings</summary>

```
cd /path/to/this/repo && git pull
cp -r hypr quickshell mako ~/.config/
```

Or use **Settings → System → Update**, which checks GitHub, lists what changed, and pulls on
a two-click confirm.

**Your settings aren't touched.** Colors, glass, water, wallpaper folder, auto-cycle, pinned
apps and rebound keys are all gitignored. They live only in `~/.config`. The copy overwrites
tracked files and leaves those alone.

The one thing that does get overwritten is a tracked file you hand-edited — the monitor block
in `hyprland.lua`, say. Keep machine-specific changes in `local.conf`.
</details>

## Before you install

- **Every window floats by default.** This is not a tiling config. The `floatall` rule is one
  line in `hyprland.lua` if you want tiling back.
- **Arch is the tested path.** Other distros work, but you'll be building a couple of packages
  yourself.
- **The theming is opt-in, app by app.** Two of the options are client mods against their
  app's ToS, and one opens a browser debug port. Each is called out where it appears.

## The pieces

<details>
<summary><b>The bar</b> — carousel workspaces, monitors, tray, alt-tab pie</summary>

Custom Quickshell, colors pulled live from the current wallpaper. Workspaces are one long
carousel that slides across every monitor together. Includes an app launcher, live system
monitors (CPU/GPU/VRAM/RAM/swap/net/disk with per-app breakdowns), a notification tray,
per-monitor brightness, and an alt-tab pie menu.

Hardware is auto-detected: amdgpu sysfs first, then `nvidia-smi`, with graceful zeros
otherwise. CPU temp covers AMD/Intel/ARM hwmon names. The swap widget labels itself ZRAM or
SWAP automatically.
</details>

<details>
<summary><b>Settings app</b> — the tabs and what each one does</summary>

A real app window (`quickshell/Settings.qml`), listed as **Technicolor Settings**. Opens from
the gear on the launcher popup or `qs ipc call settings open`.

| Tab | What's in it |
|---|---|
| **Apps** | Pinned launcher apps — reorder, swap icons, add/remove. |
| **Wallpaper** | Cover-flow picker (scroll or drag to spin, click the middle one). Shuffle, transition style, auto-cycle timer, pause-while-fullscreen so a game never eats a transition. |
| **Colors** | Four sliders that retint every themed app at once: text contrast threshold, saturation ceiling, brightness ceiling, hue. The ceilings rein in over-saturated wallpapers without touching muted ones. |
| **Glass** | Refraction, fresnel, specular, blur, lens distortion, chromatic aberration, brightness/contrast/saturation/vibrancy. Write-in box for anything past a slider's range. |
| **Water** | Speed, scale, depth, viscosity, activity, warping. |
| **Effects** | The GPU governor and its thresholds. |
| **Hotkeys** | Every keybind, searchable and editable. Read live from `hyprctl binds`, so it matches your real config. Click the keys to rebind; conflicts are caught and named. |
| **System** | UI font, default file manager, default terminal, terminal transparency, a `local.conf` editor, the update checker, and Spotify library tools. |

**Terminal transparency** (System tab) follows whichever terminal you've set as
the default and drives *that* terminal's own background alpha, so the text stays
fully solid — a compositor opacity rule would fade the glyphs with it. kitty,
Alacritty, foot, Ghostty, WezTerm and GNOME Terminal change as you drag; Konsole
and Xfce Terminal are saved to config and come up transparent in new windows.
Anything else says so instead of pretending. Adapters live in
`hypr/terminal-opacity.py` — one entry per terminal, easy to extend.

**Spotify library tools** (System tab): *Scan for AI music* checks your likes against the
community [soul-over-ai](https://github.com/xoundbyte/soul-over-ai) list by artist ID. *Back up
to CSV* exports your library. Both read-only, through your open Spotify via Spicetify — no
developer app, no extra login.

</details>

<details>
<summary><b>Water</b> — a real wave simulation on the glass</summary>

The glass surface can run an actual fluid simulation rather than an animated texture. A
height field is integrated on the GPU (`∂²h/∂t² = c²∇²h`) on ping-ponged half-float
framebuffers, so disturbances propagate at finite speed, reflect off the edges, interfere with
their own reflections, and decay. Short waves die faster than long ones (`ν∇²(∂h/∂t)`), which
is why a disturbed surface relaxes into smooth swells instead of staying grainy.

Both of the visible effects come from that one field:

- **Refraction** displaces what's behind the window by the surface gradient.
- **Caustics** are the singularity of that same displacement: `1/|det(I + k·H)|`. The zero set
  of a determinant is a *curve*, which is why caustics are thin filaments and not blobs.

They redistribute light rather than adding it, so every bright vein is paid for by the water
around it going dim. They also disperse — blue converges at a shorter distance than red, so the
veins carry color at their edges.

Depth is the one physical length and drives both effects. Deeper water bends further and
focuses harder, because those are the same thing.

Costs about 5% GPU at 1440p.

Everything is on **Settings → Water**, and it's off by default.
</details>

<details>
<summary><b>Effects governor</b> — steps effects down when the GPU is busy</summary>

Effects at idle are fine. Effects competing with a game are not.

The governor watches GPU load and steps effects down in tiers — water, then layer glass, then
window glass, then animations — and back up when load drops. Hysteresis keeps it from
oscillating.

Configurable in **Settings → Effects**, including an optional low-battery tier for laptops.
</details>

<details>
<summary><b>App theming</b> — Discord, Spotify, Dolphin, Brave, GTK</summary>

All optional. Driven by `hypr/gen-*.py`, which `wallpaper-colors.py` calls on every wallpaper
change; failures are silently skipped, so nothing breaks if you skip an app. The shared engine
is `gen-discord-theme.py`: it picks the bar's gradient pair as primary/secondary, computes WCAG
black-or-white ink per surface, and feeds every other generator. Ink crossover and saturation
are tunable live for every app at once from Settings → Colors.

```
sudo pacman -S dolphin gcc                                 # official repos
paru -S vesktop spotify spicetify-cli qt6ct-kde brave-bin  # AUR — the only part needing a helper
```

**Discord (Vesktop + Vencord)** — ⚠️ Vesktop is a third-party, unofficial Discord client.
Open-source and popular, but a modded client, so it's against Discord's ToS and runs
third-party code on your account. Opt in only if you're fine with that.

Themes land in `~/.config/vesktop/themes/`. Enable **Technicolor**, then **Technicolor
Blocks**, in that order. Live colors go through Vencord's QuickCSS, which is what makes
wallpaper changes cross-fade in 1.4s with no flash.

Built on [midnight-discord](https://github.com/refact0r/midnight-discord).

**Spotify (spicetify)** — ⚠️ Spicetify patches the official client with third-party code.
Open-source and widely used, but a client mod, so it's against Spotify's ToS. `spicetify config
current_theme Technicolor`, then `spicetify backup apply`. Live colors poll a small local HTTP
server via the `technicolor-sync.js` extension.

Every Spotify **update** silently reverts that patch, and because the window is chromakeyed
whole-window with a self-calibrating keyer, losing the theme doesn't just look untethered — the
keyer re-calibrates onto stock Spotify's near-black and keys out album art and the player bar.
`spicetify-guard.sh` runs at login, detects it (the packaged `xpui.spa` reappearing is the tell),
and reapplies. No-op when nothing is wrong.

**Dolphin / Qt** — `gen-kde-colors.py` rewrites `kdeglobals`, a KDE color scheme and a qt6ct
palette. Needs `qt6ct-kde` with `QT_QPA_PLATFORMTHEME=qt6ct`.

The non-obvious step: point `color_scheme_path` in `~/.config/qt6ct/qt6ct.conf` at
`~/.local/share/color-schemes/Technicolor.colors`, **not** at a qt6ct palette file. Otherwise
KDE apps fall back to stock Breeze for everything KColorScheme-driven and you get white file
views that no palette setting fixes.

Launch via `hypr/dolphin-tc.sh`. It applies the stylesheet and compiles a small `LD_PRELOAD`
shim so the side panels paint rounded blocks and recolor live.

**Brave** — `gen-brave-theme.py` writes an unpacked Chromium theme. Add two flags to
`~/.config/brave-flags.conf`. Use an **absolute path** — the launcher reads this file
line-by-line and does not expand `~`:
```
--load-extension=/home/YOU/.config/brave-technicolor-theme
--remote-debugging-port=9222
```
⚠️ **Security cost:** that debug port lets any process on your machine drive the browser.
Localhost-only, but real. Skip the second flag if you don't want it — you just lose live
recoloring while Brave is open.

Only the frame and tab strip are painted. Web content is never touched.

**GTK** — `gen-gtk-theme.py` writes a theme and flips between two copies (`-A`/`-B`) on each
wallpaper change, because GTK caches by theme *name* and the rename is what forces a reload.
This sets your global GTK theme; revert with `gsettings set org.gnome.desktop.interface
gtk-theme Adwaita`.

**The glass (chromakey) layer** — the gaps between color blocks, and Brave's tab strip, can be
made genuinely transparent. Real windows and wallpaper show through.

Uses [Hypr-DarkWindow](https://github.com/micha4w/Hypr-DarkWindow) shaders plus `hyprwater` for
the refraction. Both are vendored here and build themselves at startup against your exact
Hyprland version, rebuilding when an update leaves the binary ABI-stale. No `hyprpm`.

Browsers were long considered un-keyable: a whole-window key eats matching pixels inside pages,
like a teal Twitch stream. The Brave variant is **band-limited** — it keys only the tab-strip
band and refuses to touch anything below it.

Two gotchas already handled. `decoration:blur:size` doubles as Hyprland's re-render margin for
these effects even with blur off, so keep it at 40 or stacked glass glitters on focus changes.
Dolphin uses a fixed-key variant so its dialogs don't go transparent.
</details>

<details>
<summary><b>Reference</b> — layout, portability, swapping mako, notes</summary>

### What's where
- `hypr/` — Hyprland config and scripts: workspace carousel, wallpaper cycling/colors, taskbar, minimize, alt-tab, the app-theming engine (`gen-*.py`), chromakey shaders, the color server, the Dolphin launcher/shim, and the `hyprwater` plugin.
- `quickshell/` — the bar (`Bar.qml`), the Settings app (`Settings.qml`), the alt-tab pie, notification scripts, system-monitor helpers, shaders.
- `applications/` — the `.desktop` entry for the Settings app.
- `mako/` — notification styling.
- `spicetify/` — the Spotify live-color extension.

### Portability
- **Distros** — the bar/compositor side is distro-agnostic. The theming extras are Arch-friendliest: `qt6ct-kde` is AUR (elsewhere you'd build it), and both vendored plugins compile against your Hyprland via their own `load.sh`, so you need `base-devel` plus the headers in the `hyprland` package — no cmake.
- **Resolution & scale** — nothing is hardcoded to a resolution. The bar and themes are pixel-based, so on 4K you'll want a monitor scale like any px-based UI; the Qt theming and shaders are scale-aware.
- **Hardware** — GPU-agnostic; see the bar section. Nvidia setup is a ready-to-uncomment block in `local.conf.example`. Monitor brightness needs DDC/CI-capable displays.
- **Laptops** — works out of the box; the touchpad drives the 3-finger workspace swipe and the function keys are bound. Two caveats: the bar's brightness *sliders* drive external DDC/CI monitors, not the built-in panel (use the keys), and there's no battery indicator on the bar yet.
- **Spotify** — theming assumes the native client; flatpak needs spicetify's flatpak setup.

### Swapping mako
mako is fairly baked in. The tray shells out to `makoctl` and reads its JSON, and the theming
rewrites its config. To use dunst/swaync/etc., port: `notif-bump.sh` (`makoctl list -j` + the
on-notify hook), `notif-clear.sh` (`dismiss`), `notif-activate.sh` (`invoke`),
`notif-silence.sh` (per-app rules), `notif-theme-mako.sh` (colors), `mako/config` (format), and
`Bar.qml` (assumes mako's record fields).

### Notes
- mako is required for the notification tray — it's the daemon, the bar is the frontend.
- `nethogs` runs under sudo for the network widget; without a sudoers rule it stays blank.
- GPU, temperature sensors and monitor brightness all auto-detect.
- The animated wallpapers I use are pixel-art scenes by **Anas Abdin**: <https://www.tumblr.com/anasabdin>. Color extraction, upscaling and transitions are tuned for that style, so photos may not look as good.
- A Nerd Font is required or icons render as boxes. UI text uses your system sans-serif by default; pick another in Settings → System → Font, or set `QS_FONT`.
</details>

## License & credits

BSD 3-Clause ([`LICENSE`](LICENSE)) — take it, change it, ship it. The one thing it withholds
is using my name to endorse whatever you make out of it.

The two vendored plugins keep their own licenses:
[Hypr-DarkWindow](https://github.com/micha4w/Hypr-DarkWindow) (MIT) and `hyprwater` (BSD-3).

> **`hyprwater` is a fork of [hyprglass](https://github.com/Hyprnux/hyprglass)** by Jeremy
> Trufier, used under the BSD 3-Clause License (`hypr/hyprwater/LICENSE`). It has diverged
> enough to warrant its own name: on top of hyprglass's thick-glass refraction it adds the GPU
> wave simulation described above, and derives both the surface's refraction and its caustics
> from that field. The upstream project is not responsible for this fork and does not endorse
> it.
