#!/usr/bin/env bash
# Rebuild the QS_THEME block in ~/.config/mako/config from the bar's current
# palette (~/.config/quickshell/colors.env). Run automatically after
# wallpaper-colors.py from wallpaper-cycle.sh.
#
# Layout of mako/config (markers managed by scripts, manual edits stay outside):
#
#   # QS_THEME_BEGIN ... # QS_THEME_END     ← this script
#   [urgency=low]   ...
#   [urgency=high]  ...
#   # QS_SILENCE_BEGIN ... # QS_SILENCE_END  ← notif-silence.sh

set -eu

colors_file="$HOME/.config/quickshell/colors.env"
mako_config="$HOME/.config/mako/config"

[ -f "$mako_config" ] || exit 0

GRADIENT_START="#89B4FA"
GRADIENT_END="#F38BA8"
# Source the NOTIFICATIONS-surface-tuned palette (Settings → Colors →
# Per-surface) — surface-tune.py applies that surface's sat/bright/hue on top
# of colors.env (identity if none set), emitting KEY=value lines to eval.
[ -s "$colors_file" ] && eval "$(python3 "$HOME/.config/hypr/surface-tune.py" notifications 2>/dev/null)" || . "$colors_file"

# strip leading #
gs="${GRADIENT_START#\#}"
ge="${GRADIENT_END#\#}"

# Compute luminance of GRADIENT_END so the urgency=low/normal border picks
# whichever palette color is the more accent-y one; if GRADIENT_END is the
# darker of the two, swap roles.
contrast=$(python3 - "$gs" "$ge" <<'PY'
import sys, os
gs, ge = sys.argv[1], sys.argv[2]
def parse(h):  return int(h[0:2],16), int(h[2:4],16), int(h[4:6],16)
def hex_(rgb): return '{:02X}{:02X}{:02X}'.format(*[max(0,min(255,int(c))) for c in rgb])
def lerp(a, b, t): return tuple(a[i] + (b[i]-a[i])*t for i in range(3))
# Match the bar's contrastText() exactly: luminance 0..1, threshold from the
# CONTRAST_BIAS slider (0.5 -> 0.55, the original default).
def lum01(rgb): return (0.299*rgb[0] + 0.587*rgb[1] + 0.114*rgb[2]) / 255.0
def bias():
    try:
        for ln in open(os.path.expanduser('~/.config/hypr/color-tuning.conf')):
            ln = ln.strip()
            if ln.startswith('#') or '=' not in ln: continue
            k, v = ln.split('=', 1)
            if k.strip() == 'CONTRAST_BIAS': return float(v.strip())
    except Exception: pass
    return 0.5
b = bias()
thr = (b/0.5)*0.55 if b <= 0.5 else 0.55 + ((b-0.5)/0.5)*0.45
s, e = parse(gs), parse(ge)
# Match the bar's notification-tray pill exactly: lerpColor(0.86).
# Keep in sync with `borderNotif` in Bar.qml.
accent = lerp(s, e, 0.86)
text = 'FFFFFF' if lum01(accent) <= thr else '000000'
print(f"{hex_(accent)} {text}")
PY
)
accent_hex=$(echo "$contrast" | awk '{print $1}')
text_hex=$(echo "$contrast" | awk '{print $2}')

# Solid palette accent fill (matches bar pill "filled"); no visible border.
bg_color="#${accent_hex}F0"
border_color="#${accent_hex}F0"
text_color="#${text_hex}"

theme_block=$(cat <<EOF
# QS_THEME_BEGIN
# (managed by ~/.config/quickshell/notif-theme-mako.sh — regenerated on wallpaper change)
default-timeout=7000
on-notify=exec ~/.config/quickshell/notif-bump.sh "\$id"
font=JetBrainsMono Nerd Font 11
background-color=${bg_color}
text-color=${text_color}
border-color=${border_color}
border-size=2
border-radius=12
padding=14
margin=12
width=380
max-visible=3
layer=overlay
anchor=top-right
# QS_THEME_END
EOF
)

tmp=$(mktemp)
awk '
    /^# QS_THEME_BEGIN$/ { skip=1; next }
    /^# QS_THEME_END$/   { skip=0; next }
    skip != 1
' "$mako_config" > "$tmp"

# Strip leading blank lines (the theme block goes at the top)
while [ -s "$tmp" ] && [ -z "$(head -n1 "$tmp")" ]; do
    sed -i '1d' "$tmp"
done

{
    printf '%s\n\n' "$theme_block"
    cat "$tmp"
} > "${tmp}.new"
mv "${tmp}.new" "$mako_config"
rm -f "$tmp"

makoctl reload 2>/dev/null || true
