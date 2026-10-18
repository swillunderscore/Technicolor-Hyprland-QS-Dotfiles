#!/usr/bin/env python3
"""Let go of any key a finished Moonlight stream left held down.

Sunshine types through a virtual keyboard and mice of its own. When a stream
ends, Sunshine is meant to release whatever the remote side was still holding,
but sometimes it doesn't, and the key stays down on that virtual keyboard. While
ANY keyboard holds a key, Hyprland drops that key from every other keyboard, so
it goes dead everywhere, voice typing included, until something releases it.

stream-screens.sh runs this a couple of seconds after every stream ends. It
reads which keys/buttons the kernel still has down on Sunshine's keyboard and
mice and writes a release for each to the device's event node (writing to
/dev/input/eventN injects into that device, so it needn't be ours). Needs
read/write on those nodes: membership of the `input` group.

Gamepads, touch and pen are left alone: Sunshine resets those per session, and
another stream may still be using them.

Every release is logged (one line per device), so it's visible how often
Sunshine leaves keys stuck:
    ~/.local/state/hypr/stream-stuck-keys.log

Env overrides, for tests:
    TC_STREAM_KEYS_NAMES  regex of device names to clear
    TC_STREAM_KEYS_LOG    log path
"""

import fcntl
import glob
import os
import re
import struct
import sys
import time

# Sunshine 2026.1013 (libvirtualhid backend) names its devices
# "libvirtualhid Keyboard", "libvirtualhid Mouse", "libvirtualhid Mouse (Absolute)".
NAMES = re.compile(os.environ.get("TC_STREAM_KEYS_NAMES", r"^libvirtualhid (Keyboard|Mouse)"))
LOG = os.environ.get("TC_STREAM_KEYS_LOG") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "hypr", "stream-stuck-keys.log")

EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
KEY_MAX = 0x2FF
KEY_BYTES = (KEY_MAX + 8) // 8
EVIOCGKEY = (2 << 30) | (KEY_BYTES << 16) | (ord("E") << 8) | 0x18   # _IOR('E', 0x18, len)
EVENT = struct.Struct("llHHi")   # struct input_event: timeval, type, code, value


def log(msg):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def key_names():
    """evdev code -> "KEY_F" from the kernel header, if it's installed."""
    names = {}
    try:
        with open("/usr/include/linux/input-event-codes.h") as f:
            for m in re.finditer(r"#define\s+((?:KEY|BTN)_\w+)\s+(0x[0-9a-fA-F]+|\d+)\b", f.read()):
                names[int(m.group(2), 0)] = m.group(1)   # last wins: BTN_LEFT over BTN_MOUSE
    except OSError:
        pass
    return names


def held(fd):
    buf = bytearray(KEY_BYTES)
    fcntl.ioctl(fd, EVIOCGKEY, buf)
    return [code for code in range(KEY_MAX + 1) if buf[code // 8] >> (code % 8) & 1]


def main():
    devices = []
    for node in sorted(glob.glob("/sys/class/input/event*")):
        try:
            with open(node + "/device/name") as f:
                name = f.read().strip()
        except OSError:
            continue
        if NAMES.search(name):
            devices.append(("/dev/input/" + os.path.basename(node), name))

    # The keyboard is the one that matters; finding only mice means it was renamed.
    found = devices if "TC_STREAM_KEYS_NAMES" in os.environ else [d for d in devices if "Keyboard" in d[1]]
    if not found:
        log(f"WARNING: no Sunshine keyboard found (looked for /{NAMES.pattern}/); "
            "a Sunshine update may have renamed it, so stuck keys are NOT being released")
        return 1

    names = key_names()
    rc = 0
    for path, name in devices:
        try:
            fd = os.open(path, os.O_RDWR)
        except OSError as e:
            log(f"ERROR: {name} ({path}): {e.strerror}; can't release its keys")
            rc = 1
            continue
        try:
            down = held(fd)
            if not down:
                continue
            for code in down:
                os.write(fd, EVENT.pack(0, 0, EV_KEY, code, 0))
            os.write(fd, EVENT.pack(0, 0, EV_SYN, SYN_REPORT, 0))
            still = held(fd)
            label = ", ".join(names.get(c, str(c)) for c in down)
            if still:
                log(f"ERROR: {name} ({path}): released {label}, but still held: "
                    + ", ".join(names.get(c, str(c)) for c in still))
                rc = 1
            else:
                log(f"released {label} on {name} ({path})")
        finally:
            os.close(fd)
    return rc


if __name__ == "__main__":
    sys.exit(main())
