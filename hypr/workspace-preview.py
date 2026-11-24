#!/usr/bin/env python3
"""workspace-preview.py — tiny pictures of monitors and windows for the bar.

Started by shell.qml as a Process child, so it lives and dies with the bar.
Commands, one per line on stdin:
  monitors DP-1,DP-2              monitors to picture (nothing after the space = none)
  hover <wsId> <cardW> <cardH>    capture that workspace's windows now and every second
  unhover
Events, one per line on stdout:
  mon <name> <path> <seq>
  win <address> <path> <seq>

MONITOR pictures come from the monitor-thumbs Hyprland plugin
(hypr/monitor-thumbs), which shrinks frames Hyprland already drew on the GPU
and writes a ~5 KB PPM per monitor about once a second. This helper only
watches those files and tells the bar. It used to run grim once a second, and
each grim froze Hyprland ~19 ms (it redraws the whole monitor for a new
screencopy client and waits for the copy; measured 2026-10-28). No file = no
plugin: the bar drops the picture and shows its plain color block.

HOVER pictures (windows of a hovered workspace, hidden ones too) come from the
same plugin: `hyprctl monitorthumbs window <address> <w> <h>` makes it draw the
window's own GPU image (what the app last handed Hyprland) at the size the
view shows it. grim -T used to freeze Hyprland 5-18 ms per second of hovering.
Monitor pictures stop updating while the focused window is really fullscreen
(games) or the effects governor has stepped effects down; hover pictures
always update, because someone asked for them.
"""
import json
import os
import select
import shutil
import socket
import sys
import time

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
OUT = os.path.join(RUN, "tc-previews")
GOVERNOR = os.path.join(RUN, "technicolor-governor.tier")
THUMBS = os.path.join(RUN, "hypr", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), "monitor-thumbs")
TICK = 1.0          # hover pictures: asked for again every second
MON_POLL = 0.25     # picture files: a stat() each, nothing else


def thumb_path(name):
    return os.path.join(THUMBS, "mon-%s.ppm" % name)


def thumb_mtime(name):
    try:
        return os.stat(thumb_path(name)).st_mtime_ns
    except OSError:
        return None


def win_path(stable_id):
    return os.path.join(THUMBS, "win-%s.ppm" % stable_id)


def win_mtime(stable_id):
    try:
        return os.stat(win_path(stable_id)).st_mtime_ns
    except OSError:
        return None


def window_requests(wins, k):
    """[(address, stableId, w, h)]: each window at the size the view shows it."""
    return [(c["address"], c["stableId"], max(8, round(c["size"][0] * k)), max(8, round(c["size"][1] * k)))
            for c in wins]


def request_line(reqs):
    return "monitorthumbs window " + " ; ".join("%s %d %d" % (a, w, h) for a, _, w, h in reqs)


def win_changes(pairs, seen, stat=None):
    """[(address, path)] for window pictures the plugin (re)wrote, and the new
    `seen` (stableId -> mtime announced). No file = no event: the view keeps
    the app icon (a window the plugin can't picture never gets one)."""
    stat = stat or win_mtime
    events, now = [], {}
    for addr, sid in pairs:
        m = stat(sid)
        if m is None:
            continue
        now[sid] = m
        if seen.get(sid) != m:
            events.append((addr, win_path(sid)))
    return events, now


def thumb_changes(names, seen, stat=None):
    """[(monitor, path or None)] for the bar, and the new `seen`
    (monitor -> mtime announced). A picture whose file vanished is announced
    as None, so the bar drops it instead of keeping a frozen one."""
    stat = stat or thumb_mtime
    events, now = [], {}
    for name in names:
        m = stat(name)
        if m is None:
            if name in seen:
                events.append((name, None))
            continue
        now[name] = m
        if seen.get(name) != m:
            events.append((name, thumb_path(name)))
    return events, now


def split_lines(buf):
    """Complete lines in `buf`, and what's left of an unfinished one."""
    *lines, rest = buf.split(b"\n")
    return [l.decode(errors="replace") for l in lines], rest


def parse_command(line):
    parts = line.strip().split(" ")
    if parts[0] == "monitors":
        rest = parts[1] if len(parts) > 1 else ""
        return "monitors", [m for m in rest.split(",") if m]
    if parts[0] == "hover" and len(parts) == 4:
        try:
            return "hover", (int(parts[1]), int(parts[2]), int(parts[3]))
        except ValueError:
            return None, None
    if parts[0] == "unhover":
        return "unhover", None
    return None, None


def hypr_raw(cmd):
    """A hyprctl request straight over Hyprland's socket: no process per query
    (a hyprctl spawn every second was a third of this helper's CPU)."""
    path = os.path.join(RUN, "hypr", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(path)
        sock.sendall(cmd.encode())
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    return data


def hypr(cmd):
    """hyprctl's JSON for `cmd`."""
    return json.loads(hypr_raw("j/" + cmd))


def paused():
    try:
        with open(GOVERNOR) as f:
            if int(f.read().strip() or 0) > 0:
                return True
    except (OSError, ValueError):
        pass
    try:
        return hypr("activewindow").get("fullscreen") == 2    # 1 = Super+V maximize, keep going
    except (OSError, ValueError):
        return False


class Helper:
    def __init__(self):
        self.monitors = []
        self.seen = {}             # monitor -> picture mtime the bar has
        self.mon_held = False      # a monitor picture change waiting one check
        self.hover = None          # (wsId, cardW, cardH)
        self.hover_wins = []       # [(address, stableId)] last asked for
        self.win_seen = {}         # stableId -> picture mtime the bar has
        self.seq = 0

    def emit(self, kind, key, path):
        self.seq += 1
        sys.stdout.write("%s %s %s %d\n" % (kind, key, path, self.seq))
        sys.stdout.flush()

    def check_monitors(self, now=False):
        """Tell the bars about new monitor pictures. A change is held for one
        check (0.25 s): both monitors' pictures are written ~60 ms apart and
        every bar shows both, so announcing each on its own redrew every bar
        twice a second (measured: +11 ms/s of Quickshell CPU). `now` = a
        workspace switch, which wants its picture at once."""
        events, seen = thumb_changes(self.monitors, self.seen)
        if not events:
            self.mon_held = False
            return
        if not now and not self.mon_held:
            self.mon_held = True
            return
        self.mon_held = False
        if any(path for _, path in events) and paused():
            return                 # leave them unannounced; picked up once unpaused
        self.seen = seen
        for name, path in events:
            self.emit("mon", name, path or "-")

    def request_hover(self):
        ws, card_w, card_h = self.hover
        try:
            clients = hypr("clients")
            ws_info = next((w for w in hypr("workspaces") if w.get("id") == ws), None)
            mons = hypr("monitors")
        except (OSError, ValueError):
            return
        mon = next((m for m in mons if ws_info and m["name"] == ws_info.get("monitor")), mons[0] if mons else None)
        mon_w = mon["width"] / mon["scale"] if mon else 1920
        # .get: since Hyprland 0.57 special/named workspaces (minimized windows'
        # special:minimized) have NO "id" -> c["workspace"]["id"] was a KeyError.
        wins = [c for c in clients if c["workspace"].get("id") == ws and c.get("mapped") and not c.get("hidden")]
        live = {c["stableId"] for c in clients}
        for f in os.listdir(THUMBS) if os.path.isdir(THUMBS) else ():   # pictures of windows that are gone
            if f.startswith("win-") and f.endswith(".ppm") and f[4:-4] not in live:
                try:
                    os.unlink(os.path.join(THUMBS, f))
                except OSError:
                    pass
        reqs = window_requests(wins, card_w / mon_w)
        self.hover_wins = [(a, sid) for a, sid, _, _ in reqs]
        if reqs:
            try:
                hypr_raw(request_line(reqs))
            except OSError:
                pass

    def check_windows(self):
        events, self.win_seen = win_changes(self.hover_wins, self.win_seen)
        for addr, path in events:
            self.emit("win", addr, path)

    def handle(self, line):
        cmd, arg = parse_command(line)
        if cmd == "monitors":
            self.monitors = arg
            self.check_monitors(now=True)
        elif cmd == "hover":
            self.hover = arg
            self.request_hover()
        elif cmd == "unhover":
            self.hover = None

    def run(self):
        # The grim-era picture folder (PNG copies of every picture): nothing
        # writes there any more.
        shutil.rmtree(OUT, ignore_errors=True)
        next_mon = next_hover = time.monotonic()
        buf = b""
        while True:
            wait = max(0.0, min(next_mon, next_hover) - time.monotonic())
            r, _, _ = select.select([sys.stdin], [], [], wait)
            if r:
                # Raw reads, every complete line handled: sys.stdin.readline()
                # pulled BOTH of a back-to-back pair ("unhover", "hover ...")
                # into Python's buffer and returned one, and select() then saw
                # an empty pipe — the hover sat unread and a grown view never
                # got its window pictures.
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    return 0               # the bar went away
                lines, buf = split_lines(buf + chunk)
                for line in lines:
                    self.handle(line)
                continue
            now = time.monotonic()
            if now >= next_mon:
                next_mon = now + MON_POLL
                self.check_monitors()
                if self.hover:
                    self.check_windows()
            if now >= next_hover:
                next_hover = now + TICK
                if self.hover:
                    self.request_hover()


if __name__ == "__main__":
    sys.exit(Helper().run())
