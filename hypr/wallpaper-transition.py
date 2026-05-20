#!/usr/bin/env python3
"""
wallpaper-transition.py OLD NEW [--at-start CMD]

Pixel-by-pixel reveal transition from OLD to NEW, ordered by perceived
brightness (Rec.709 luma) of NEW. Brightest pixels appear first.

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
from PIL import Image

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
         "--transition-type", "none"],
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

    if old.shape != new.shape:
        target = (new.shape[1], new.shape[0])
        old_frames = [
            np.array(Image.fromarray(f).resize(target, Image.NEAREST))
            for f in old_frames
        ]
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

    luma = (0.2126 * new[:, :, 0]
            + 0.7152 * new[:, :, 1]
            + 0.0722 * new[:, :, 2])

    # Break ties spatially so flat-luma regions (skies, walls) don't reveal
    # in one burst at whatever value their pixels share.
    # Noise < 1 luma unit, so it never reorders pixels across brightness levels.
    H, W = luma.shape
    total = H * W
    rng = np.random.default_rng()
    sort_key = luma.flatten().astype(np.float32) + rng.random(total, dtype=np.float32) * 0.99
    # Descending: brightest pixels of NEW pop in first, shadows fill last.
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
        # from where it was when the transition started; NEW starts from 0.
        wall_t = (i + 1) * FRAME_INTERVAL

        new_t = wall_t % new_total if new_total > 0 else 0.0
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

        now = time.monotonic()
        if now < target:
            time.sleep(target - now)

    if in_flight is not None:
        in_flight.result()
    executor.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
