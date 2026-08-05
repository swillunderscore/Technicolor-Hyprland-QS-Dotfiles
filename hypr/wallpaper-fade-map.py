#!/usr/bin/env python3
"""
wallpaper-fade-map.py NEW MODE OUT.png [--aspect W:H]

Generates the per-pixel reveal-ORDER map for the GPU wallpaper transition
(quickshell WallpaperFade). Gray value = when that pixel starts fading in
(0 = first, 255 = last). The reveal itself runs on the GPU; this only ranks
pixels, once per transition.

The map is computed on NEW's first frame COVER-CROPPED to the screen aspect
(default 16:9) — the same crop awww and the overlay's PreserveAspectCrop use —
so luminance/geometry modes line up with what's actually on screen. Ranks are
spread linearly (argsort), matching wallpaper-transition.py's pacing exactly:
equal pixel-count per unit time, regardless of the image's histogram.

Prints JSON meta for the QML side: {"frames": N, "avgMs": per-frame ms}.
"""

import sys
import json
import argparse

import numpy as np
from PIL import Image

MAP_W, MAP_H = 960, 540


def cover_crop(img: Image.Image, aw: float, ah: float) -> Image.Image:
    w, h = img.size
    ia, sa = w / h, aw / ah
    if ia > sa:                      # wider than screen: crop sides
        nw = max(1, round(h * sa))
        x = (w - nw) // 2
        return img.crop((x, 0, x + nw, h))
    nh = max(1, round(w / sa))       # taller than screen: crop top/bottom
    y = (h - nh) // 2
    return img.crop((0, y, w, y + nh))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("new")
    ap.add_argument("mode")
    ap.add_argument("out")
    ap.add_argument("--aspect", default="16:9")
    args = ap.parse_args()

    aw, ah = (float(x) for x in args.aspect.split(":"))

    img = Image.open(args.new)

    # Animation meta (frame count + average duration) for the QML handoff sync.
    frames, total_ms = 1, 0.0
    try:
        n = getattr(img, "n_frames", 1)
        if n > 1:
            for i in range(n):
                img.seek(i)
                total_ms += img.info.get("duration", 100) or 100
            frames = n
            img.seek(0)
    except Exception:
        frames, total_ms = 1, 0.0

    first = cover_crop(img.convert("RGB"), aw, ah).resize(
        (MAP_W, MAP_H), Image.NEAREST)
    a = np.asarray(first, dtype=np.float32)

    luma = 0.2126 * a[:, :, 0] + 0.7152 * a[:, :, 1] + 0.0722 * a[:, :, 2]
    H, W = MAP_H, MAP_W
    total = H * W
    rng = np.random.default_rng()
    noise = rng.random(total, dtype=np.float32)
    lflat = luma.flatten()

    mode = args.mode
    if mode == "random":
        mode = str(rng.choice(["luminance", "shadow", "radial", "iris", "wipe",
                               "curtain", "diagonal", "clock", "blinds",
                               "dissolve"]))

    yy, xx = np.mgrid[0:H, 0:W]
    cy, cx = (H - 1) / 2.0, (W - 1) / 2.0
    xf = xx.astype(np.float32).flatten()
    yf = yy.astype(np.float32).flatten()

    # Same sort keys as wallpaper-transition.py — highest key reveals first.
    if mode == "shadow":
        sort_key = -lflat + noise * 0.99
    elif mode in ("radial", "iris"):
        dist = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2).astype(np.float32).flatten()
        sgn = -1.0 if mode == "radial" else 1.0
        sort_key = sgn * dist + noise * (float(dist.max()) * 0.04 + 1e-3)
    elif mode == "wipe":
        sort_key = -xf + noise * (W * 0.04 + 1e-3)
    elif mode == "curtain":
        sort_key = -yf + noise * (H * 0.04 + 1e-3)
    elif mode == "diagonal":
        sort_key = -(xf + yf) + noise * ((W + H) * 0.04 + 1e-3)
    elif mode == "clock":
        ang = np.arctan2(yy - cy, xx - cx).astype(np.float32).flatten()
        sort_key = -ang + noise * 0.05
    elif mode == "blinds":
        bw = max(1.0, W / 8.0)
        sort_key = -(xf % bw) + noise * (bw * 0.04 + 1e-3)
    elif mode == "dissolve":
        sort_key = noise
    else:  # luminance
        sort_key = lflat + noise * 0.99

    order = np.argsort(-sort_key, kind="stable")
    rank = np.empty(total, dtype=np.float32)
    rank[order] = np.linspace(0.0, 1.0, total, dtype=np.float32)
    Image.fromarray((rank.reshape(H, W) * 255.0).astype(np.uint8), "L").save(args.out)

    avg_ms = (total_ms / frames) if frames > 1 else 0.0
    print(json.dumps({"frames": frames, "avgMs": round(avg_ms, 3)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
