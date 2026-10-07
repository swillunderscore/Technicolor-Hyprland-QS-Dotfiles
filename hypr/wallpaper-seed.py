#!/usr/bin/env python3
"""
The wallpaper sequence, as a pure function of (seed, step).

    wallpaper-seed.py index  <count> <step>   -> index for that step
    wallpaper-seed.py step                    -> which step "now" is
    wallpaper-seed.py reseed [count] [want]   -> new sequence; optionally one
                                                 whose step 0 IS `want`

Why a function rather than a roll: the rotation used bare $RANDOM, which is
unmirrorable — there is nothing to hand another device that would let it
compute the same sequence. Deriving it means the whole protocol is two
numbers, seed and epoch, sent once.

Still truly random in the sense that matters: every step is an independent
draw, it never cycles through the list and starts over, and a wallpaper can
recur whenever chance says so. Only immediate repeats are re-rolled, by
salting — picking a neighbour instead would be a pattern, and the point is
that a client reproduces this exactly without being told anything.

MANUAL PICKS reseed by SEARCHING for a seed whose step 0 is the chosen
wallpaper. It costs a few hundred hashes and keeps the protocol at two
numbers — the alternative was carrying a third "and the first one is
actually this" field forever.
"""
import hashlib
import re
import os
import secrets
import sys
import time

HOME = os.path.expanduser("~")
SEED_FILE = os.path.join(HOME, ".config/hypr/wallpaper-seed")
EPOCH_FILE = os.path.join(HOME, ".config/hypr/wallpaper-epoch")
TIMER_CONF = os.path.join(HOME, ".config/hypr/wallpaper-timer.conf")


def period() -> int:
    """How long one wallpaper lasts, in seconds.

    ONE number, read from the timer's own config, because the desktop and the
    a mirror must agree on it. It used to be a constant here AND an INTERVAL_MIN
    in wallpaper-timer.conf, which is two numbers that only looked like one:
    the timer fired on its own elapsed counter while the sequence advanced on
    the clock, so the desktop changed wallpaper at an arbitrary offset from
    the step boundary a mirror was using.
    """
    try:
        with open(TIMER_CONF) as f:
            for line in f:
                k, _, v = line.partition("=")
                if k.strip() == "INTERVAL_MIN":
                    m = int(float(v.strip()))
                    return max(60, m * 60)
    except Exception:
        pass
    return 3600


def _h(seed: int, step: int, salt: int) -> int:
    raw = "%d:%d:%d" % (seed, step, salt)
    return int(hashlib.sha256(raw.encode()).hexdigest()[:8], 16)


def index_for(seed: int, count: int, step: int) -> int:
    """THE shared function. Any client must match this exactly."""
    if count <= 1:
        return 0
    prev = _h(seed, step - 1, 0) % count if step > 0 else -1
    for salt in range(9):
        idx = _h(seed, step, salt) % count
        if idx != prev:
            return idx
    return _h(seed, step, 0) % count


def reveal_ms() -> int:
    """How long the desktop's transition takes, in milliseconds.

    Read from wallpaper-transition.py rather than duplicated, and shipped to
    a mirror with the seed. A separate number on a mirror is a number that
    drifts from this one and then has to be explained.
    """
    try:
        src = open(os.path.join(HOME, ".config/hypr/wallpaper-transition.py")).read()
        n = re.search(r"^NFRAMES\s*=\s*([0-9]+)", src, re.M)
        iv = re.search(r"^FRAME_INTERVAL\s*=\s*([0-9.]+)", src, re.M)
        if n and iv:
            return max(100, int(float(n.group(1)) * float(iv.group(1)) * 1000))
    except Exception:
        pass
    return 1540


def fade_ms() -> int:
    """The desktop's per-pixel cross-fade length, in milliseconds.

    Each pixel fades over this rather than switching, which is most of why the
    desktop's transition looks soft. Shipped with the seed for the same reason
    the duration is: one fact, one place.
    """
    try:
        src = open(os.path.join(HOME, ".config/hypr/wallpaper-transition.py")).read()
        m = re.search(r"^FADE_DURATION\s*=\s*([0-9.]+)", src, re.M)
        if m:
            return max(10, int(float(m.group(1)) * 1000))
    except Exception:
        pass
    return 300


def read(path, default):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except Exception:
        return default


def seed() -> int:
    s = read(SEED_FILE, -1)
    if s < 0:
        s = secrets.randbits(63)
        open(SEED_FILE, "w").write(str(s))
    return s


def epoch() -> int:
    e = read(EPOCH_FILE, -1)
    if e < 0:
        e = int(time.time())
        open(EPOCH_FILE, "w").write(str(e))
    return e


def step_at(now: int, epoch_: int, p: int) -> int:
    """Which step `now` is, counted in ALIGNED periods.

    Boundaries come from absolute time — `now // period` — not from the epoch,
    so a change always lands on a round time: on the hour at the default, on
    the half hour at 30 minutes. The epoch only says which period is step 0.

    Deriving boundaries from the epoch instead put every future change at
    whatever minute the last shuffle happened, and FLOORING the epoch to fix
    that broke the merge rule the other way: a sequence created at 13:59 and
    floored to 13:00 looks older than one created at 13:20, so the wrong one
    wins. Two jobs, two numbers — the epoch stays a true timestamp.
    """
    return max(0, now // p - epoch_ // p)


def boundary_at(now: int, p: int) -> int:
    """The instant the current step ends. A mirror computes this identically."""
    return (now // p + 1) * p


def reseed(count=None, want=None) -> int:
    """New sequence starting now. With `want`, one that starts on it.

    The epoch is the TRUE time, unrounded, because it is what resolves a
    conflict between two devices that both shuffled while disconnected. Step
    boundaries do not come from it — see step_at.
    """
    s = secrets.randbits(63)
    if count and want is not None and count > 1:
        for _ in range(20000):
            if index_for(s, count, 0) == want:
                break
            s = secrets.randbits(63)
    open(SEED_FILE, "w").write(str(s))
    open(EPOCH_FILE, "w").write(str(int(time.time())))
    return s


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "index"
    if cmd == "reveal":
        print(reveal_ms())
        raise SystemExit(0)
    if cmd == "fade":
        print(fade_ms())
        raise SystemExit(0)
    if cmd == "period":
        print(period())
        raise SystemExit(0)
    if cmd == "boundary":
        # When the current step ends — what the timer sleeps until, and what
        # a mirror independently computes, so both flip at the same instant.
        print(boundary_at(int(time.time()), period()))
        raise SystemExit(0)
    if cmd == "step":
        print(step_at(int(time.time()), epoch(), period()))
    elif cmd == "reseed":
        cnt = int(sys.argv[2]) if len(sys.argv) > 2 else None
        want = int(sys.argv[3]) if len(sys.argv) > 3 else None
        reseed(cnt, want)
        print(index_for(seed(), cnt or 1, 0) if cnt else 0)
    else:
        count, step = int(sys.argv[2]), int(sys.argv[3])
        print(index_for(seed(), count, step))
