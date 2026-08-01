#!/usr/bin/env bash
# ============================================================================
# Technicolor — interactive installer (Arch-based distros)
#
#   curl -fsSL https://raw.githubusercontent.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles/main/install.sh -o /tmp/technicolor-install.sh
#   bash /tmp/technicolor-install.sh
#
# Installs the lean CORE from the official repos (no AUR), copies the configs,
# then asks — one app at a time — which things you actually want themed and
# installs ONLY those. Nothing proprietary is installed unless you say yes.
# Re-runnable; any existing configs are backed up to *.bak.<timestamp>.
# ============================================================================
set -euo pipefail

REPO="https://github.com/swillunderscore/Technicolor-Hyprland-QS-Dotfiles"
SRC="/tmp/technicolor-src"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
info() { printf '     %s\n' "$*"; }
ask()  { local r; printf '   \033[1;35m?\033[0m %s [y/N] ' "$1"; read -r r </dev/tty || true; [[ "${r:-}" =~ ^[Yy] ]]; }

trap 'echo; warn "Install stopped early (see the error above). Anything already applied is kept — re-run to continue."' ERR

# ── prerequisites ───────────────────────────────────────────────────────────
command -v pacman >/dev/null 2>&1 || { echo "This installer is for Arch-based distros (needs pacman)."; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not root — it will sudo when it needs to."; exit 1; }

say "Technicolor installer"
info "Installs the core, then asks which apps to theme. Ctrl-C to bail at any prompt."

# ── git + fetch the repo ────────────────────────────────────────────────────
say "Making sure git is present, then fetching Technicolor…"
sudo pacman -S --needed --noconfirm git
rm -rf "$SRC"
git clone --depth 1 "$REPO" "$SRC"
ok "cloned to $SRC"

# ── core packages (official repos only — no AUR) ────────────────────────────
say "Installing the core (official repos only)…"
sudo pacman -S --needed --noconfirm \
  hyprland quickshell mako xdg-desktop-portal-hyprland pipewire wireplumber \
  ddcutil nethogs jq gawk kitty wofi awww imagemagick python-pillow \
  grim slurp satty wl-clipboard playerctl brightnessctl base-devel ttf-jetbrains-mono-nerd
ok "core installed"

# ── copy configs (back up anything already there; cp merges, never nests) ───
say "Copying configs into ~/.config (backing up any existing ones)…"
for d in hypr quickshell mako; do
  if [ -e "$HOME/.config/$d" ]; then
    mv "$HOME/.config/$d" "$HOME/.config/$d.bak.$(date +%s)"
    info "backed up ~/.config/$d"
  fi
done
cp -r "$SRC/hypr" "$SRC/quickshell" "$SRC/mako" "$HOME/.config/"
mkdir -p "$HOME/.local/share/applications"
cp "$SRC"/applications/*.desktop "$HOME/.local/share/applications/"
# Record the installed commit so Settings → System → "Check for updates" lists
# only commits newer than this install.
git -C "$SRC" rev-parse HEAD > "$HOME/.config/hypr/.technicolor-version" 2>/dev/null || true
ok "configs copied"

# ── per-machine files + wallpapers dir (cp -n keeps your edits on re-run) ───
say "Setting up per-machine files…"
cp -n "$HOME/.config/hypr/local.conf.example"            "$HOME/.config/hypr/local.conf"            2>/dev/null || true
cp -n "$HOME/.config/hypr/hyprglass-tuning.conf.example" "$HOME/.config/hypr/hyprglass-tuning.conf" 2>/dev/null || true
cp -n "$HOME/.config/hypr/terminal.conf.example"         "$HOME/.config/hypr/terminal.conf"         2>/dev/null || true
cp -n "$HOME/.config/mako/config.example"                "$HOME/.config/mako/config"                2>/dev/null || true
mkdir -p "$HOME/Wallpapers/animated"
ok "per-machine files ready (you only need to touch local.conf for Nvidia or multi-monitor)"

# ── external-monitor brightness group ───────────────────────────────────────
if sudo usermod -aG i2c "$USER" >/dev/null 2>&1; then
  ok "added you to the 'i2c' group (external-monitor brightness; takes effect after re-login)"
fi

# ── AUR helper (only touched if you pick an app that needs it) ──────────────
AUR=""
for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { AUR="$h"; break; }; done
ensure_aur() {
  [ -n "$AUR" ] && return 0
  warn "that one lives in the AUR and you have no AUR helper installed"
  if ask "install 'paru' now (prebuilt, from the AUR)"; then
    local d; d="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$d/paru-bin"
    ( cd "$d/paru-bin" && makepkg -si )
    AUR="paru"; return 0
  fi
  warn "skipping — install paru or yay later, then re-run to add this one"
  return 1
}
aur_install() { "$AUR" -S --needed "$@"; }

# ── optional per-app theming ────────────────────────────────────────────────
say "Optional app theming — press Enter to skip any of these."
info "Nothing below is installed unless you say yes. Each app recolors on every wallpaper change."

warn "Discord theming installs Vesktop — a THIRD-PARTY, unofficial Discord client (open-source)."
info "It's popular and FOSS, but it's a modded client: technically against Discord's ToS, and it"
info "handles your account through third-party code. Only opt in if you're comfortable with that."
if ask "Theme Discord?  (installs Vesktop)"; then
  if ensure_aur && aur_install vesktop; then
    ok "Vesktop installed"
    info "one-time: Vesktop → Settings → Themes → enable 'Technicolor', then 'Technicolor Blocks'"
  else warn "skipped Discord theming"; fi
fi

warn "Spotify theming installs Spicetify — it PATCHES the official Spotify client with third-party code."
info "Widely used and FOSS, but it's a client mod: against Spotify's ToS, and it injects into the app."
info "Only opt in if you're comfortable with that."
if ask "Theme Spotify?  (installs spotify + spicetify-cli)"; then
  if ensure_aur && aur_install spotify spicetify-cli; then
    ok "Spotify + Spicetify installed"
    info "one-time: launch Spotify once so Spicetify can patch it; colors follow your first wallpaper"
  else warn "skipped Spotify theming"; fi
fi

if ask "Theme Brave?"; then
  if ensure_aur && aur_install brave-bin; then
    ok "Brave installed"
    ff="$HOME/.config/brave-flags.conf"
    mkdir -p "$HOME/.config"
    if ! grep -q 'brave-technicolor-theme' "$ff" 2>/dev/null; then
      printf -- '--load-extension=%s/.config/brave-technicolor-theme\n--remote-debugging-port=9222\n' "$HOME" >> "$ff"
      ok "wrote $ff (absolute path — theme auto-loads on next Brave launch)"
    fi
    info "heads-up: that debug port lets local processes drive Brave — it's how live recolor works"
  else warn "skipped Brave theming"; fi
fi

if ask "Theme your file manager + Qt apps?  (installs Dolphin + qt6ct-kde)"; then
  sudo pacman -S --needed --noconfirm dolphin || warn "dolphin install failed"
  if ensure_aur && aur_install qt6ct-kde; then ok "Dolphin + qt6ct installed"; else warn "qt6ct (AUR) skipped"; fi
  info "one-time: put QT_QPA_PLATFORMTHEME=qt6ct in your environment, and point qt6ct's"
  info "  color_scheme_path at ~/.local/share/color-schemes/Technicolor.colors"
  info "  (full details: README → App theming → Dolphin / Qt apps)"
fi

# LibreOffice only maps XDG_CURRENT_DESKTOP=KDE -> kf6 and GNOME -> gtk3. Under
# Hyprland it matches neither and silently falls back to its ancient built-in "gen"
# widget set: crammed menubar, boxy outlined toolbar buttons, ignores your colours.
# Gated on soffice actually existing, so this is a no-op if you don't use LibreOffice.
# Not a prompt: with LibreOffice installed this is strictly a bug fix, and asking
# "do you want your toolbar to not be broken?" is noise. No-op without LibreOffice.
if command -v soffice >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/environment.d"
  printf '%s\n' \
    '# Hyprland is not a desktop LibreOffice recognises, so it falls back to the old' \
    '# "gen" widget set. Pin the Qt6/KDE one so it matches the rest of Technicolor.' \
    'SAL_USE_VCLPLUGIN=kf6' > "$HOME/.config/environment.d/libreoffice.conf"
  ok "LibreOffice pinned to the kf6 widget backend (fixes its cramped toolbar)"
  info "takes effect after your next log out + log in"
fi

if ask "Theme GTK apps?  (no install — sets your global GTK theme)"; then
  ok "enabled — the wallpaper cycle writes + selects a Technicolor GTK theme"
  info "this makes GTK apps + file dialogs follow the wallpaper"
  info "revert anytime: gsettings set org.gnome.desktop.interface gtk-theme Adwaita"
fi

# ── done ────────────────────────────────────────────────────────────────────
say "Done! 🎨"
info "1. Log out and pick Hyprland at your login screen (or start it from a TTY)."
info "2. Drop some animated wallpapers into  ~/Wallpapers/animated/"
info "3. Nvidia GPU? uncomment the block in  ~/.config/hypr/local.conf"
info "4. Multi-monitor? add  'monitor = …'  lines to  ~/.config/hypr/local.conf"
info "Everything else auto-detects. Enjoy."
