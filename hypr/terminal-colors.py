#!/usr/bin/env python3
"""terminal-colors.py — dark text for white terminal glass (Settings → Glass).

  terminal-colors.py light     black text + colors readable on white glass
  terminal-colors.py default   the terminal's own colors again
  terminal-colors.py status    light | default

kitty only: it is the terminal whose colors change live, through the same
per-window socket terminal-opacity.py sets up (allow_remote_control +
listen_on unix:/tmp/kitty-{kitty_pid}). Everything goes in a file kitty.conf
includes, and open windows reload their config. Readability is kitty's own
text_fg_override_threshold: every text color (this palette, 24-bit colors apps
pick, the 256-color cube, text on colored backgrounds) has its lightness moved
just enough for 4.5:1 (WCAG AA) against the cell behind it, hue kept. The
default background is the glass's gray, so that is what plain text is
measured against.
"""
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

KITTY = Path.home() / ".config/kitty"
CONF = KITTY / "kitty.conf"
COLORS = KITTY / "technicolor-colors.conf"
INCLUDE = "include technicolor-colors.conf"

LIGHT = {
    "foreground": "#000000",
    "cursor": "#000000", "cursor_text_color": "#ffffff",
    "selection_foreground": "#000000", "selection_background": "#b4cdfa",
    "url_color": "#0b41c2",
    "color0": "#000000", "color8": "#444444",
    "color1": "#b3001b", "color9": "#c4001f",
    "color2": "#00701a", "color10": "#006b1b",
    "color3": "#7a5b00", "color11": "#7f5f00",
    "color4": "#0b41c2", "color12": "#1a4fd6",
    "color5": "#8a00a8", "color13": "#9400b5",
    "color6": "#00707a", "color14": "#006a74",
    "color7": "#555555", "color15": "#222222",
}
LIGHT_OPTIONS = {
    "text_fg_override_threshold": "4.5 ratio",
    # Faint text (SGR 2) is the foreground at this opacity: kitty's 0.4 left it
    # near 2.3:1 on the glass, 0.6 is about 4.8:1.
    "dim_opacity": "0.6",
}
GLASS_TUNING = Path.home() / ".config/hypr/hyprwater-tuning.conf"


def glass_background():
    """The gray the white glass settles on (hyprwater adaptive_white_target,
    0.78 by default). It is what the text contrast is measured against; with
    the terminal's background see-through it is never drawn as such."""
    target = 0.78
    try:
        m = re.search(r"(?m)^plugin:hyprwater:adaptive_white_target\s*=\s*([0-9.]+)\s*$",
                      GLASS_TUNING.read_text())
        if m:
            target = min(1.0, max(0.0, float(m.group(1))))
    except (OSError, ValueError):
        pass
    return "#%02x%02x%02x" % ((round(target * 255),) * 3)


def body(colors):
    return "".join("%s %s\n" % kv for kv in colors.items())


def ensure_include():
    try:
        text = CONF.read_text()
    except OSError:
        text = ""
    if not any(line.strip() == INCLUDE for line in text.splitlines()):
        sep = "" if text == "" or text.endswith("\n") else "\n"
        CONF.parent.mkdir(parents=True, exist_ok=True)
        with open(CONF, "a") as f:
            f.write(sep + "# Settings → Glass → White glass (terminal-colors.py)\n" + INCLUDE + "\n")


def live_sockets():
    """One remote-control socket per running kitty process."""
    out = []
    for sock in glob.glob("/tmp/kitty-*"):
        pid = sock.rsplit("-", 1)[-1]
        if pid.isdigit() and os.path.exists("/proc/%s" % pid):
            out.append(sock)
    return out


def apply_live():
    """Reload every open kitty's config, include file and all; returns how many
    processes took it. A reload, not set-colors: the contrast options aren't
    colors. It also sets each window back to the config's font size, and
    going back restores whatever kitty.conf itself says."""
    ok = 0
    for sock in live_sockets():
        try:
            r = subprocess.run(["kitten", "@", "--to", "unix:" + sock, "load-config"],
                               capture_output=True, timeout=5)
            ok += r.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            pass
    return ok


def main(argv):
    cmd = argv[0] if argv else "status"
    if cmd == "status":
        try:
            print("light" if COLORS.read_text().strip() else "default")
        except OSError:
            print("default")
        return 0
    if cmd not in ("light", "default"):
        print(__doc__)
        return 2
    ensure_include()
    COLORS.write_text(body(dict(LIGHT, background=glass_background(), **LIGHT_OPTIONS))
                      if cmd == "light" else "")
    n = apply_live()
    print("%s: %d kitty process%s recolored" % (cmd, n, "" if n == 1 else "es"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
