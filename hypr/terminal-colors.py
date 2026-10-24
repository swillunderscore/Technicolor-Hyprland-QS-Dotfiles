#!/usr/bin/env python3
"""terminal-colors.py — dark text for white terminal glass (Settings → Glass).

  terminal-colors.py light     black text + colors readable on white glass
  terminal-colors.py default   the terminal's own colors again
  terminal-colors.py status    light | default

kitty only: it is the terminal whose colors change live, through the same
per-window socket terminal-opacity.py sets up (allow_remote_control +
listen_on unix:/tmp/kitty-{kitty_pid}). The colors also go in a file kitty.conf
includes, so new windows match. Every color here is at least 4.5:1 (WCAG AA)
against both pure white and the glass's default white target.
"""
import glob
import os
import subprocess
import sys
from pathlib import Path

KITTY = Path.home() / ".config/kitty"
CONF = KITTY / "kitty.conf"
COLORS = KITTY / "technicolor-colors.conf"
INCLUDE = "include technicolor-colors.conf"

LIGHT = {
    "foreground": "#000000", "background": "#ffffff",
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
# kitty's built-in defaults, to put running windows back. New windows get them
# anyway once the include file is empty.
DEFAULT = {
    "foreground": "#dddddd", "background": "#000000",
    "cursor": "#cccccc", "cursor_text_color": "#111111",
    "selection_foreground": "#000000", "selection_background": "#fffacd",
    "url_color": "#0087bd",
    "color0": "#000000", "color8": "#767676",
    "color1": "#cc0403", "color9": "#f2201f",
    "color2": "#19cb00", "color10": "#23fd00",
    "color3": "#cecb00", "color11": "#fffd00",
    "color4": "#0d73cc", "color12": "#1a8fff",
    "color5": "#cb1ed1", "color13": "#fd28ff",
    "color6": "#0dcdcd", "color14": "#14ffff",
    "color7": "#dddddd", "color15": "#ffffff",
}


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


def apply_live(colors):
    """Recolor every open kitty window; returns how many processes took it."""
    tmp = KITTY / ".technicolor-colors.live"
    tmp.write_text(body(colors))
    ok = 0
    for sock in live_sockets():
        try:
            r = subprocess.run(["kitten", "@", "--to", "unix:" + sock, "set-colors",
                                "--all", "--configured", str(tmp)],
                               capture_output=True, timeout=5)
            ok += r.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            pass
    tmp.unlink(missing_ok=True)
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
    COLORS.write_text(body(LIGHT) if cmd == "light" else "")
    n = apply_live(LIGHT if cmd == "light" else DEFAULT)
    print("%s: %d kitty process%s recolored" % (cmd, n, "" if n == 1 else "es"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
