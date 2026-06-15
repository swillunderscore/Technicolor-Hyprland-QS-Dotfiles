#!/usr/bin/env python3
"""
Extract colors from wallpaper for quickshell bar.
Uses ImageMagick for palette extraction (k-means quantization).

Outputs to ~/.config/quickshell/colors.env:
  FOCUSED, VISIBLE, OCCUPIED  — workspace dot colors
  GRADIENT_START, GRADIENT_END — two harmonious colors for bar-wide gradient
"""
import sys
import subprocess
import tempfile
import os
import re
from PIL import Image

def extract_frame(path):
    ext = os.path.splitext(path)[1].lower()
    tmp = tempfile.mktemp(suffix='.png')
    if ext in ('.mp4', '.webm'):
        subprocess.run(['ffmpeg', '-y', '-i', path, '-vframes', '1', '-f', 'image2', tmp], capture_output=True)
    elif ext in ('.gif', '.webp'):
        subprocess.run(['magick', f'{path}[0]', tmp], capture_output=True)
    else:
        subprocess.run(['magick', path, tmp], capture_output=True)
    return tmp

def rgb_to_hsl(r, g, b):
    r, g, b = r/255.0, g/255.0, b/255.0
    mx, mn = max(r,g,b), min(r,g,b)
    l = (mx+mn)/2.0
    if mx == mn:
        return 0.0, 0.0, l
    d = mx - mn
    s = d/(2.0-mx-mn) if l > 0.5 else d/(mx+mn)
    if mx == r:   h = (g-b)/d + (6 if g < b else 0)
    elif mx == g: h = (b-r)/d + 2
    else:         h = (r-g)/d + 4
    return h/6.0, s, l

def hsl_to_rgb(h, s, l):
    if s == 0:
        v = int(l*255)
        return v, v, v
    def hue2rgb(p, q, t):
        if t < 0: t += 1
        if t > 1: t -= 1
        if t < 1/6: return p + (q-p)*6*t
        if t < 1/2: return q
        if t < 2/3: return p + (q-p)*(2/3-t)*6
        return p
    q = l*(1+s) if l < 0.5 else l+s-l*s
    p = 2*l - q
    return (int(hue2rgb(p,q,h+1/3)*255),
            int(hue2rgb(p,q,h)*255),
            int(hue2rgb(p,q,h-1/3)*255))

def to_hex(rgb):
    return '#{:02X}{:02X}{:02X}'.format(*rgb)


def load_saturation():
    """SATURATION knob from Settings → Colors (default 1.0 = as-extracted).
    Applied to the final 5 colors here at the source, so EVERY app that reads
    colors.env (bar, Discord, Spotify, Telegram, Brave, GTK, KDE, mako) is muted
    together — no per-app wiring needed."""
    try:
        for line in open(os.path.expanduser('~/.config/hypr/color-tuning.conf')):
            line = line.strip()
            if line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            if k.strip() == 'SATURATION':
                return max(0.0, float(v.strip()))
    except Exception:
        pass
    return 1.0


def apply_saturation(rgb, factor):
    if abs(factor - 1.0) < 1e-3:
        return rgb
    h, s, l = rgb_to_hsl(*rgb)
    s = max(0.0, min(1.0, s * factor))
    return hsl_to_rgb(h, s, l)

def get_palette(img_path, n_colors=16):
    result = subprocess.run(
        ['magick', img_path, '-resize', '200x200!', '-colors', str(n_colors),
         '-unique-colors', '-format', '%c', 'histogram:info:'],
        capture_output=True, text=True
    )
    colors = []
    for line in result.stdout.strip().split('\n'):
        match = re.search(r'(\d+):\s.*#([0-9A-Fa-f]{6,8})', line)
        if match:
            count = int(match.group(1))
            hexval = match.group(2)
            r = int(hexval[0:2], 16)
            g = int(hexval[2:4], 16)
            b = int(hexval[4:6], 16)
            colors.append((r, g, b, count))
    return colors

def perceived_brightness(r, g, b):
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0

def striking_score(r, g, b, count, total):
    h, s, l = rgb_to_hsl(r, g, b)
    v = perceived_brightness(r, g, b)
    if v < 0.20 or s < 0.15:
        return 0
    freq = count / total
    return (s ** 1.2) * (v ** 1.5) * (0.1 + freq ** 0.3)

def pick_three_colors(palette):
    total = sum(c[3] for c in palette)
    enhanced = []
    for r, g, b, count in palette:
        h, s, l = rgb_to_hsl(r, g, b)
        v = perceived_brightness(r, g, b)
        strike = striking_score(r, g, b, count, total)
        enhanced.append({'rgb': (r, g, b), 'h': h, 's': s, 'l': l, 'v': v, 'count': count, 'strike': strike})

    enhanced.sort(key=lambda x: x['strike'], reverse=True)
    if enhanced[0]['strike'] == 0:
        enhanced.sort(key=lambda x: x['v'], reverse=True)
    focused = enhanced[0]

    def cdist(c1, c2):
        return sum((c1[i] - c2[i]) ** 2 for i in range(3))

    cands = [c for c in enhanced if cdist(c['rgb'], focused['rgb']) > 2500]
    if not cands:
        fh, fs, fl = focused['h'], focused['s'], focused['l']
        return focused['rgb'], hsl_to_rgb(fh, fs, max(0.1, fl - 0.4)), hsl_to_rgb(fh, fs, max(0.2, fl - 0.2))

    cands.sort(key=lambda x: x['v'])
    occupied = None
    for c in cands:
        if c['v'] >= 0.40:
            occupied = c
            break
    if not occupied:
        base = cands[-1] if cands else focused
        fh, fs, fl = base['h'], base['s'], base['l']
        boosted = hsl_to_rgb(fh, fs, max(0.55, fl + 0.3))
        occupied = {'rgb': boosted, 'v': perceived_brightness(*boosted)}

    target_v = (focused['v'] + occupied['v']) / 2.0
    remaining = [c for c in cands if cdist(c['rgb'], occupied['rgb']) > 1500]
    if not remaining:
        vis = tuple(int((focused['rgb'][i] + occupied['rgb'][i]) / 2) for i in range(3))
        return focused['rgb'], occupied['rgb'], vis

    remaining.sort(key=lambda x: abs(x['v'] - target_v))
    return focused['rgb'], occupied['rgb'], remaining[0]['rgb']


def pick_gradient_pair(palette):
    """
    Pick two vibrant, visually distinct colors for a gradient across the bar.
    Minimum 90° hue separation. Both boosted for visibility on dark backgrounds.
    """
    total = sum(c[3] for c in palette)

    viable = []
    for r, g, b, cnt in palette:
        h, s, l = rgb_to_hsl(r, g, b)
        v = perceived_brightness(r, g, b)
        if s < 0.12 or v < 0.15:
            continue
        # Boost dark/desaturated colors
        if v < 0.40:
            l = max(l, 0.50)
        if s < 0.30:
            s = min(s * 1.5, 1.0)
        r2, g2, b2 = hsl_to_rgb(h, s, l)
        v2 = perceived_brightness(r2, g2, b2)
        score = s * v2
        viable.append({'rgb': (r2, g2, b2), 'h': h, 's': s, 'l': l, 'v': v2, 'score': score})

    if len(viable) < 2:
        if viable:
            c = viable[0]
            h2 = (c['h'] + 0.33) % 1.0
            return c['rgb'], hsl_to_rgb(h2, c['s'], c['l'])
        return (200, 150, 100), (100, 150, 200)

    viable.sort(key=lambda x: x['score'], reverse=True)
    start = viable[0]

    best = None
    best_score = -1

    for c in viable[1:]:
        hue_diff = abs(c['h'] - start['h'])
        if hue_diff > 0.5:
            hue_diff = 1.0 - hue_diff
        deg = hue_diff * 360

        # Require at least 90° separation for distinctness
        if deg < 90:
            harmony = 0.1 * (deg / 90)  # Heavily penalize close hues
        elif deg <= 180:
            harmony = 1.0  # Great range
        else:
            harmony = 0.6

        combined = c['score'] * harmony
        if combined > best_score:
            best_score = combined
            best = c

    if not best:
        # Fallback: synthesize a complementary color
        h2 = (start['h'] + 0.33) % 1.0
        return start['rgb'], hsl_to_rgb(h2, start['s'], start['l'])

    return start['rgb'], best['rgb']


def main():
    if len(sys.argv) < 2:
        print("Usage: wallpaper-colors.py <image_path>", file=sys.stderr)
        sys.exit(1)

    img_path = sys.argv[1]
    frame = extract_frame(img_path)

    try:
        palette = get_palette(frame, n_colors=16)
        if not palette:
            print("No colors extracted", file=sys.stderr)
            sys.exit(1)

        focused, occupied, visible = pick_three_colors(palette)
        grad_start, grad_end = pick_gradient_pair(palette)

        # User saturation/muting (Settings → Colors), applied at the source so
        # it flows to every app through colors.env.
        sat = load_saturation()
        focused    = apply_saturation(focused, sat)
        occupied   = apply_saturation(occupied, sat)
        visible    = apply_saturation(visible, sat)
        grad_start = apply_saturation(grad_start, sat)
        grad_end   = apply_saturation(grad_end, sat)

        env_path = os.path.expanduser('~/.config/quickshell/colors.env')
        with open(env_path, 'w') as f:
            f.write(f'FOCUSED={to_hex(focused)}\n')
            f.write(f'VISIBLE={to_hex(visible)}\n')
            f.write(f'OCCUPIED={to_hex(occupied)}\n')
            f.write(f'GRADIENT_START={to_hex(grad_start)}\n')
            f.write(f'GRADIENT_END={to_hex(grad_end)}\n')

        # Drive Hyprland's focused-window border from the primary (FOCUSED)
        # accent. Written to a sourced conf for persistence across reloads, and
        # applied live so it changes the instant the wallpaper does.
        border = "rgb({:02X}{:02X}{:02X})".format(*focused)
        try:
            conf_path = os.path.expanduser('~/.config/hypr/colors.conf')
            with open(conf_path, 'w') as cf:
                cf.write("# Auto-generated by wallpaper-colors.py — focused-window border\n"
                         "# = the wallpaper's primary accent. Sourced by hyprland.conf.\n"
                         "general {\n    col.active_border = " + border + "\n}\n")
            subprocess.run(['hyprctl', 'keyword', 'general:col.active_border', border],
                           capture_output=True)
        except Exception:
            pass

        # Regenerate the Discord (Vesktop) "Technicolor" theme from this palette,
        # so it re-tints with the wallpaper just like the bar.
        try:
            subprocess.run(['python3', os.path.expanduser('~/.config/hypr/gen-discord-theme.py')],
                           capture_output=True)
        except Exception:
            pass

        # KDE/Qt apps (Dolphin): rewrite kdeglobals color sections; KF6 apps
        # watch the file and live-recolor.
        try:
            subprocess.run(['python3', os.path.expanduser('~/.config/hypr/gen-kde-colors.py')],
                           capture_output=True)
        except Exception:
            pass

        # Brave: regenerate the unpacked theme files, then hot-apply them by
        # driving the brave://extensions reload over the DevTools protocol
        # (no-op unless Brave runs with --remote-debugging-port=9222; see
        # brave-theme-reload.py).
        try:
            subprocess.run(['python3', os.path.expanduser('~/.config/hypr/gen-brave-theme.py')],
                           capture_output=True)
            subprocess.run(['python3', os.path.expanduser('~/.config/hypr/brave-theme-reload.py')],
                           capture_output=True, timeout=15)
        except Exception:
            pass

        # GTK apps: regenerate the Technicolor GTK theme + flip A/B so GTK
        # consumers re-read and recolor immediately (Brave uses its own
        # extension theme, not GTK mode — this is for general GTK apps).
        try:
            subprocess.run(['python3', os.path.expanduser('~/.config/hypr/gen-gtk-theme.py')],
                           capture_output=True)
        except Exception:
            pass

        print(f"Focused:        {to_hex(focused)}")
        print(f"Occupied:       {to_hex(occupied)}")
        print(f"Visible:        {to_hex(visible)}")
        print(f"Gradient Start: {to_hex(grad_start)}")
        print(f"Gradient End:   {to_hex(grad_end)}")

    finally:
        if os.path.exists(frame):
            os.remove(frame)

if __name__ == '__main__':
    main()
