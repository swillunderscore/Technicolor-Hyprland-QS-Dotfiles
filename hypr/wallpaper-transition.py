#!/usr/bin/env python3
"""
wallpaper-transition.py OLD NEW [--at-start CMD] [--mode MODE]

Pixel-by-pixel reveal transition from OLD to NEW. The reveal pattern is set by
--mode (luminance|shadow|radial|wipe|dissolve|random); luminance (default)
reveals the brightest pixels of NEW first, shadows last.

Frames are paced so awww-daemon has time to render each one. The final
"100% new" frame is skipped — caller is expected to invoke
`awww img <NEW>` right after to finish the reveal AND start animation.

If --at-start is given, CMD is run just before the first frame fires.
Used to kick off the bar color cross-fade so it animates alongside.
"""

import sys
import os
import glob
import time
import subprocess
import argparse
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image, ImageOps

NFRAMES = 22
FRAME_INTERVAL = 0.070       # seconds; total ~1.54s
TOTAL_DURATION = NFRAMES * FRAME_INTERVAL
FADE_DURATION = 0.30         # per-pixel cross-fade time (seconds)
TMPDIR = "/tmp/wallpaper-transition"
CURRENT_PATH_FILE = "/tmp/wallpaper-current-path"

VIDEO_EXTS = (".mp4", ".webm")


def load_first_frame(path: str) -> np.ndarray:
    if path.lower().endswith(VIDEO_EXTS):
        out = os.path.join(TMPDIR, "_video_first.png")
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error",
             "-i", path, "-vframes", "1", out],
            check=True,
        )
        img = Image.open(out)
    else:
        img = Image.open(path)
    return np.array(img.convert("RGB"))


def load_all_frames(path: str):
    """Return (frames, durations_seconds). One-element list for stills."""
    if path.lower().endswith(VIDEO_EXTS):
        out_pattern = os.path.join(TMPDIR, "_vframe_%04d.png")
        for f in glob.glob(os.path.join(TMPDIR, "_vframe_*.png")):
            os.unlink(f)
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=r_frame_rate",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, check=True,
        )
        num, den = probe.stdout.strip().split("/")
        per_frame = float(den) / float(num)
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", path, out_pattern],
            check=True,
        )
        frames = [np.array(Image.open(f).convert("RGB"))
                  for f in sorted(glob.glob(os.path.join(TMPDIR, "_vframe_*.png")))]
        return frames, [per_frame] * len(frames)

    img = Image.open(path)
    frames, durations = [], []
    try:
        i = 0
        while True:
            img.seek(i)
            frames.append(np.array(img.convert("RGB")))
            # GIF/webp duration is in ms; fall back to 100ms.
            durations.append(img.info.get("duration", 100) / 1000.0)
            i += 1
    except EOFError:
        pass
    if not frames:
        frames = [np.array(img.convert("RGB"))]
        durations = [0.1]
    return frames, durations


def send_frame(path: str) -> None:
    subprocess.run(
        ["awww", "img", path,
         "--resize", "crop",
         "--filter", "Nearest",
         "--transition-type", "none",
         # awww 0.12.1 regression: 'none' sets transition-step=255 (instant)
         # but NOT the fps, so each apply waits on the default frame timer
         # (~430ms). The 21 frames here then take ~9s and pin the daemon,
         # stuttering animated wallpapers. An explicit high fps cuts each
         # apply to ~37ms. (0.12.0 didn't need this.)
         "--transition-fps", "255"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("old")
    parser.add_argument("new")
    parser.add_argument("--at-start", default=None,
                        help="shell command to run just before the first frame")
    parser.add_argument("--mode", default="luminance",
                        help="reveal pattern: luminance|shadow|radial|iris|wipe|"
                             "curtain|diagonal|clock|blinds|dissolve|random")
    args = parser.parse_args()

    os.makedirs(TMPDIR, exist_ok=True)

    new_frames, new_durations = load_all_frames(args.new)
    new = new_frames[0]
    try:
        old_frames, old_durations = load_all_frames(args.old)
    except Exception:
        old_frames = [np.zeros_like(new)]
        old_durations = [0.1]
    old = old_frames[0]

    # Composite on a SCREEN-aspect canvas, cover-cropping BOTH animations onto
    # it — the same centered crop awww's `--resize crop` shows of each. (This
    # used to stretch OLD onto NEW's canvas, which visibly warped a 16:9 OLD
    # for the whole reveal whenever NEW was vertical.) With the canvas at
    # screen aspect, awww's crop of each composited frame is the identity, so
    # each wallpaper appears exactly as its own full-screen crop does.
    #
    # The canvas is also capped: computing the reveal at full wallpaper res
    # (upscaled stills are 5120x3200 ≈ 410ms/frame) blows the ~70ms frame
    # budget ~6x and the transition stutters. The caller applies the crisp
    # full-res image at the end.
    def screen_aspect() -> float:
        try:
            import json
            out = subprocess.run(["hyprctl", "monitors", "-j"],
                                 capture_output=True, text=True, timeout=2)
            m = json.loads(out.stdout)[0]
            w, h = float(m["width"]), float(m["height"])
            if int(m.get("transform", 0)) in (1, 3, 5, 7):  # rotated 90/270
                w, h = h, w
            return w / h if h > 0 else 16 / 9
        except Exception:
            return 16 / 9

    MAX_DIM = 1920
    ar = screen_aspect()
    h0, w0 = new.shape[:2]
    # Canvas = NEW's own cover-crop region, capped to MAX_DIM on the long side.
    if w0 / h0 > ar:
        ch, cw = h0, max(1, round(h0 * ar))
    else:
        cw, ch = w0, max(1, round(w0 / ar))
    if max(cw, ch) > MAX_DIM:
        s = MAX_DIM / max(cw, ch)
        cw, ch = max(1, round(cw * s)), max(1, round(ch * s))

    def cover(frames):
        out = []
        for f in frames:
            im = Image.fromarray(f)
            # NEAREST for upscales keeps pixel art crisp; LANCZOS downscales.
            method = Image.NEAREST if (im.width < cw or im.height < ch) \
                else Image.LANCZOS
            out.append(np.array(ImageOps.fit(im, (cw, ch), method)))
        return out

    if (new.shape[1], new.shape[0]) != (cw, ch):
        new_frames = cover(new_frames)
        new = new_frames[0]
    if (old.shape[1], old.shape[0]) != (cw, ch):
        old_frames = cover(old_frames)
        old = old_frames[0]

    # Cumulative animation times for sampling each animation at wall-clock t.
    new_cum = np.cumsum(np.array(new_durations, dtype=np.float32))
    new_total = float(new_cum[-1])
    old_cum = np.cumsum(np.array(old_durations, dtype=np.float32))
    old_total = float(old_cum[-1])

    # Estimate where OLD is in its loop right now so it continues smoothly
    # instead of restarting from frame 0. mtime of CURRENT_PATH_FILE was set
    # the last time we applied a wallpaper, so wall_clock - mtime ≈ how long
    # OLD has been playing.
    old_offset = 0.0
    if old_total > 0:
        try:
            elapsed = time.time() - os.path.getmtime(CURRENT_PATH_FILE)
            old_offset = elapsed % old_total
        except OSError:
            pass

    # Phase NEW's animation so it arrives at frame 0 exactly when the caller's
    # `awww img NEW` takes over (awww always starts animations at frame 0).
    # Without this the reveal plays NEW forward to ~frame 15, then the apply
    # snaps it back to 0 — a visible animation "restart" when the transition
    # ends. For a still NEW (new_total == 0) the offset is irrelevant.
    new_offset = 0.0
    if new_total > 0:
        new_offset = (new_total - (TOTAL_DURATION % new_total)) % new_total

    luma = (0.2126 * new[:, :, 0]
            + 0.7152 * new[:, :, 1]
            + 0.0722 * new[:, :, 2])

    # The reveal ORDER is a per-pixel sort key — pixels with the highest key fade
    # in first. Each --mode is just a different key; the fade cadence + color
    # cross-fade machinery below is identical for all of them. A little noise
    # breaks ties so flat regions (skies, walls) don't pop in one hard burst.
    H, W = luma.shape
    total = H * W
    rng = np.random.default_rng()
    noise = rng.random(total, dtype=np.float32)
    lflat = luma.flatten().astype(np.float32)

    mode = args.mode
    if mode == "random":
        mode = str(rng.choice(["luminance", "shadow", "radial", "iris", "wipe",
                               "curtain", "diagonal", "clock", "blinds", "dissolve"]))

    yy, xx = np.mgrid[0:H, 0:W]
    cy, cx = (H - 1) / 2.0, (W - 1) / 2.0
    xf = xx.astype(np.float32).flatten()
    yf = yy.astype(np.float32).flatten()

    if mode == "shadow":                          # darkest pixels first
        sort_key = -lflat + noise * 0.99
    elif mode in ("radial", "iris"):              # center→out  /  edges→center
        dist = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2).astype(np.float32).flatten()
        sgn = -1.0 if mode == "radial" else 1.0
        sort_key = sgn * dist + noise * (float(dist.max()) * 0.04 + 1e-3)
    elif mode == "wipe":                          # left → right
        sort_key = -xf + noise * (W * 0.04 + 1e-3)
    elif mode == "curtain":                       # top → bottom
        sort_key = -yf + noise * (H * 0.04 + 1e-3)
    elif mode == "diagonal":                      # top-left → bottom-right
        sort_key = -(xf + yf) + noise * ((W + H) * 0.04 + 1e-3)
    elif mode == "clock":                         # angular sweep around center
        ang = np.arctan2(yy - cy, xx - cx).astype(np.float32).flatten()   # [-pi, pi]
        sort_key = -ang + noise * 0.05
    elif mode == "blinds":                        # 8 vertical bands wipe in unison
        bw = max(1.0, W / 8.0)
        sort_key = -(xf % bw) + noise * (bw * 0.04 + 1e-3)
    elif mode == "dissolve":                      # pure random dissolve
        sort_key = noise
    else:                                         # "luminance" (default): bright → dark
        sort_key = lflat + noise * 0.99
    # Descending: highest key reveals first.
    reveal_order = np.argsort(-sort_key, kind="stable")

    # Each pixel gets its own fade window. fade_start = when this pixel begins
    # fading in; FADE_DURATION later it's fully NEW.
    # Spread starts linearly across [0, TOTAL_DURATION - FADE_DURATION] so the
    # last (brightest) pixel finishes exactly at TOTAL_DURATION.
    reveal_span = TOTAL_DURATION - FADE_DURATION
    fade_start = np.empty(total, dtype=np.float32)
    fade_start[reveal_order] = np.linspace(0.0, reveal_span, total, dtype=np.float32)
    fade_start = fade_start.reshape(H, W)

    # Both OLD and NEW animations are sampled per-frame, so casts happen in
    # the loop. No precomputed float copy here.

    def ease_in_out(t: float) -> float:
        # Cubic Hermite smoothstep — slow start, fast middle, gentle end.
        # Applied to the "frontier time" so the wave of fades accelerates
        # then decelerates across the transition.
        return t * t * (3.0 - 2.0 * t)

    executor = ThreadPoolExecutor(max_workers=1)
    in_flight = None

    if args.at_start:
        subprocess.Popen(args.at_start, shell=True)

    # Cache-warm strategy for NEW. awww has no decode-only command, so any warm
    # is a real (briefly-displayed) apply — fire it at the wrong moment and it
    # flashes NEW mid-reveal ("wrong frame near the end").
    #   - If NEW is already cached (heavy gifs are pre-pinned, or it was shown
    #     recently), the caller's final apply is already warm — fire NO warm, so
    #     nothing displays until the clean handoff at the end.
    #   - If NEW is uncached, fire the warm late enough that its ~0.3s cold
    #     decode lands at the END of the reveal, not partway through. The decode
    #     overlaps the last few static frames (no flash) and is warm by handoff.
    new_key = args.new.replace("/", "_")
    new_cached = bool(glob.glob(
        os.path.expanduser(f"~/.cache/awww/*/{new_key}__*_crop_Argb")))
    WARM_AT = None if new_cached else (NFRAMES - 6)
    warmed = False
    warm_proc = None

    start = time.monotonic()
    # Skip the last frame: caller fires the animated wallpaper, which
    # completes the reveal AND begins animation in one swap.
    for i in range(NFRAMES - 1):
        target = start + (i + 1) * FRAME_INTERVAL

        # Eased "frontier" time for the reveal alpha.
        eased = ease_in_out((i + 1) / NFRAMES)
        current_time = eased * TOTAL_DURATION
        alpha = np.clip((current_time - fade_start) / FADE_DURATION, 0.0, 1.0)
        alpha3 = alpha[..., None]

        # Sample both animations at real wall-clock progress. OLD continues
        # from where it left off; NEW is phased (new_offset) to land on frame 0
        # at the handoff, so awww's apply continues it without a rewind.
        wall_t = (i + 1) * FRAME_INTERVAL

        new_t = (new_offset + wall_t) % new_total if new_total > 0 else 0.0
        new_idx = min(int(np.searchsorted(new_cum, new_t, side="right")),
                      len(new_frames) - 1)
        new_f = new_frames[new_idx].astype(np.float32)

        old_t = (old_offset + wall_t) % old_total if old_total > 0 else 0.0
        old_idx = min(int(np.searchsorted(old_cum, old_t, side="right")),
                      len(old_frames) - 1)
        old_f = old_frames[old_idx].astype(np.float32)

        frame = (alpha3 * new_f + (1.0 - alpha3) * old_f).astype(np.uint8)
        path = os.path.join(TMPDIR, f"frame_{i:02d}.bmp")
        Image.fromarray(frame).save(path)

        if in_flight is not None:
            in_flight.result()
        in_flight = executor.submit(send_frame, path)

        # Kick off the cache warm once (only when uncached; see WARM_AT above).
        if WARM_AT is not None and i == WARM_AT and not warmed:
            warmed = True
            warm_proc = subprocess.Popen(
                ["awww", "img", args.new,
                 "--fill-color", "000000", "--resize", "crop",
                 "--filter", "Nearest", "-t", "none", "--transition-fps", "255"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        now = time.monotonic()
        if now < target:
            time.sleep(target - now)

    if in_flight is not None:
        in_flight.result()
    executor.shutdown()

    # For an uncached NEW, wait for the pre-warm to finish so the handoff apply
    # below is fast (the warm primed awww's cache during the reveal). Capped low
    # — a huge gif can't decode in time regardless; it cold-decodes once here,
    # then awww's on-disk cache keeps it warm.
    if warm_proc is not None:
        try:
            warm_proc.wait(timeout=2)
        except Exception:
            pass

    # Single authoritative handoff: ALWAYS apply the animated gif last, so it
    # actually animates. The trailing static reveal frames repaint over any
    # earlier warm display, so without this the wallpaper would sit FROZEN on the
    # last reveal frame. Done here (not from the calling shell after python
    # exits) so the gap stays under the reveal's ~70ms cadence — the cache is
    # warm in both cases (cached, or primed by the warm above), so it's ~48ms.
    # The caller does NOT apply after a transition (see wallpaper-cycle.sh).
    subprocess.run(
        ["awww", "img", args.new,
         "--fill-color", "000000", "--resize", "crop",
         "--filter", "Nearest", "-t", "none", "--transition-fps", "255"],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
