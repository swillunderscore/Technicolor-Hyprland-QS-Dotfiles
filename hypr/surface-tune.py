#!/usr/bin/env python3
"""surface-tune.py <surface> — read colors.env, apply <surface>'s per-surface
sat/bright/hue (from color-tuning.conf), print key=value. Used by:
  * wallpaper-colors.py → writes colors-bar.env for the quickshell bar
  * notif-theme-mako.sh → sources this for notification colors
Reuses the HSL math + tuning loader from gen-discord-theme (the same logic the
six theme generators apply in-process via gd.load()'s _surface_tune hook), so
every surface uses identical tuning math.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.config/hypr"))
gd = __import__("gen-discord-theme")  # _surface_apply, _surface_tuning_for, rgb, hexs

surface = sys.argv[1].strip() if len(sys.argv) > 1 else ""
sat, bright, hue = gd._surface_tuning_for(surface)

d = {}
try:
    for line in open(gd.ENV):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            d[k] = v
except Exception:
    pass

identity = abs(sat - 1) < 1e-3 and abs(bright - 1) < 1e-3 and abs(hue) < 1e-3
for k, v in d.items():
    if not identity and isinstance(v, str) and v.startswith("#") and len(v) == 7:
        try:
            v = gd.hexs(gd._surface_apply(gd.rgb(v), sat, bright, hue))
        except Exception:
            pass
    print(f"{k}={v}")
