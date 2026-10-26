#!/usr/bin/env python3
"""kwin-screenshot-shim.py — lets KDE's Spectacle take screenshots on Hyprland.

Spectacle only captures through KWin's org.kde.KWin.ScreenShot2 D-Bus service:
it checks that this bus name exists and reads its Version, then asks for
screens, windows or areas. This owns that name and answers the same calls with
grim (pixels) and hyprctl (where things are). It never claims org.kde.KWin
itself, so nothing else mistakes Hyprland for KWin.

Protocol (kwin src/plugins/screenshot/org.kde.KWin.ScreenShot2.xml): every
Capture* call carries an a{sv} of options and a pipe fd, and returns
{type: "raw", width, height, stride, format (a QImage::Format), scale, screen}.
The raw pixels go into the pipe AFTER the reply: Spectacle starts reading only
once it has the reply, so writing first would block on a full pipe forever.

Started at login (hyprland.lua). Spectacle can't wake it on demand: it checks
whether the name is registered before calling anything.
"""
import json
import os
import subprocess
import sys
import threading

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "org.kde.KWin.ScreenShot2"
PATH = "/org/kde/KWin/ScreenShot2"
VERSION = 4                 # KWin 6's; Spectacle only checks >= 2 (active window/screen)
FORMAT_RGB888 = 13          # QImage::Format_RGB888, what grim's PPM already is
ERR = "org.kde.KWin.ScreenShot2.Error."
UNDER_CURSOR = os.path.expanduser("~/.config/hypr/window-under-cursor.sh")

XML = """
<node>
  <interface name="org.kde.KWin.ScreenShot2">
    <property name="Version" type="u" access="read"/>
    <method name="CaptureWindow">
      <arg name="handle" type="s" direction="in"/><arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureActiveWindow">
      <arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureArea">
      <arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/>
      <arg name="width" type="u" direction="in"/><arg name="height" type="u" direction="in"/>
      <arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureScreen">
      <arg name="name" type="s" direction="in"/><arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureActiveScreen">
      <arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureInteractive">
      <arg name="kind" type="u" direction="in"/><arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
    <method name="CaptureWorkspace">
      <arg name="options" type="a{sv}" direction="in"/>
      <arg name="pipe" type="h" direction="in"/><arg name="results" type="a{sv}" direction="out"/>
    </method>
  </interface>
</node>
"""


class CaptureError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def hypr(*args):
    r = subprocess.run(["hyprctl", *args, "-j"], capture_output=True, text=True, timeout=5)
    return json.loads(r.stdout)


def monitors():
    return [m for m in hypr("monitors") if not m.get("disabled")]


def grim(target, cursor):
    """(width, height, rgb bytes, scale) for a monitor name or a region."""
    cmd = ["grim", "-t", "ppm"] + (["-c"] if cursor else [])
    if isinstance(target, str):
        cmd += ["-o", target]
    else:
        x, y, w, h = target
        cmd += ["-g", "%d,%d %dx%d" % (x, y, w, h)]
    r = subprocess.run(cmd + ["-"], capture_output=True, timeout=15)
    if r.returncode != 0:
        raise CaptureError("InternalError", "grim failed: " + r.stderr.decode(errors="replace").strip())
    data = r.stdout
    # PPM: "P6" <ws> width <ws> height <ws> maxval <one ws> pixels
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6" or fields[3] != b"255":
        raise CaptureError("InternalError", "unexpected grim output")
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos + 1:pos + 1 + w * h * 3]


def rows_for_qimage(w, h, rgb):
    """QImage pads each RGB888 line to 4 bytes; Spectacle reads sizeInBytes()."""
    line = w * 3
    stride = (line + 3) & ~3
    if stride == line:
        return stride, rgb
    pad = b"\0" * (stride - line)
    return stride, b"".join(rgb[i:i + line] + pad for i in range(0, line * h, line))


def scale_for_rect(x, y, w, h):
    best = 1.0
    for m in monitors():
        mw, mh = m["width"] / m["scale"], m["height"] / m["scale"]
        if x < m["x"] + mw and m["x"] < x + w and y < m["y"] + mh and m["y"] < y + h:
            best = max(best, m["scale"])
    return best


def window_rect(c):
    return (c["at"][0], c["at"][1], c["size"][0], c["size"][1])


def window_under_cursor():
    addr = ""
    if os.access(UNDER_CURSOR, os.X_OK):
        addr = subprocess.run([UNDER_CURSOR], capture_output=True, text=True, timeout=5).stdout.strip()
    clients = hypr("clients")
    if addr:
        for c in clients:
            if c["address"] == addr:
                return c
    cx, cy = (float(v) for v in subprocess.run(["hyprctl", "cursorpos"], capture_output=True,
                                               text=True, timeout=5).stdout.split(","))
    active_ws = {m["activeWorkspace"]["id"] for m in monitors()}
    for c in sorted(clients, key=lambda c: c.get("focusHistoryID", 99)):
        x, y, w, h = window_rect(c)
        if c["workspace"]["id"] in active_ws and x <= cx < x + w and y <= cy < y + h:
            return c
    return None


def capture(method, args, options):
    cursor = bool(options.get("include-cursor", False))
    if method == "CaptureScreen":
        name = args[0]
        mon = next((m for m in monitors() if m["name"] == name), None)
        if mon is None:
            raise CaptureError("InvalidScreen", "no screen named " + name)
        return grim(name, cursor), mon["scale"], name
    if method in ("CaptureActiveScreen", "CaptureInteractive") and (method == "CaptureActiveScreen" or args[0] == 1):
        if method == "CaptureActiveScreen":
            mon = next((m for m in monitors() if m.get("focused")), None)
        else:
            cx, cy = (float(v) for v in subprocess.run(["hyprctl", "cursorpos"], capture_output=True,
                                                       text=True, timeout=5).stdout.split(","))
            mon = next((m for m in monitors() if m["x"] <= cx < m["x"] + m["width"] / m["scale"]
                        and m["y"] <= cy < m["y"] + m["height"] / m["scale"]), None)
        if mon is None:
            raise CaptureError("InvalidScreen", "no active screen")
        return grim(mon["name"], cursor), mon["scale"], mon["name"]
    if method in ("CaptureActiveWindow", "CaptureInteractive", "CaptureWindow"):
        if method == "CaptureActiveWindow":
            c = hypr("activewindow") or None
        elif method == "CaptureInteractive":
            c = window_under_cursor()
        else:
            c = next((c for c in hypr("clients") if c["address"] == args[0]), None)
        if not c or not c.get("address"):
            raise CaptureError("InvalidWindow", "no window to capture")
        rect = window_rect(c)
        return grim(rect, cursor), scale_for_rect(*rect), ""
    if method == "CaptureArea":
        rect = (args[0], args[1], args[2], args[3])
        return grim(rect, cursor), scale_for_rect(*rect), ""
    if method == "CaptureWorkspace":
        mons = monitors()
        x0 = min(m["x"] for m in mons)
        y0 = min(m["y"] for m in mons)
        x1 = max(m["x"] + m["width"] / m["scale"] for m in mons)
        y1 = max(m["y"] + m["height"] / m["scale"] for m in mons)
        rect = (x0, y0, int(x1 - x0), int(y1 - y0))
        return grim(rect, cursor), max(m["scale"] for m in mons), ""
    raise CaptureError("InternalError", "unknown method " + method)


def write_pixels(fd, data):
    try:
        with os.fdopen(fd, "wb", closefd=True) as f:
            f.write(data)
    except OSError:
        pass        # Spectacle gave up (closed its end); nothing to tell it


def on_method_call(conn, sender, path, iface, method, params, invocation):
    args = params.unpack()
    options, handle = args[-2], args[-1]
    fds = invocation.get_message().get_unix_fd_list()
    fd = fds.get(handle) if fds is not None else -1

    def work():
        try:
            (w, h, rgb), scale, screen = capture(method, args[:-2], options)
            stride, data = rows_for_qimage(w, h, rgb)
        except CaptureError as e:
            if fd >= 0:
                os.close(fd)
            invocation.return_dbus_error(ERR + e.kind, str(e))
            return
        except Exception as e:  # never leave Spectacle waiting on a dead call
            if fd >= 0:
                os.close(fd)
            invocation.return_dbus_error(ERR + "InternalError", repr(e))
            return
        results = {"type": GLib.Variant("s", "raw"), "width": GLib.Variant("u", w),
                   "height": GLib.Variant("u", h), "stride": GLib.Variant("u", stride),
                   "format": GLib.Variant("u", FORMAT_RGB888), "scale": GLib.Variant("d", float(scale))}
        if screen:
            results["screen"] = GLib.Variant("s", screen)
        invocation.return_value(GLib.Variant("(a{sv})", (results,)))
        if fd >= 0:
            write_pixels(fd, data)

    threading.Thread(target=work, daemon=True).start()


def on_get_property(conn, sender, path, iface, prop):
    return GLib.Variant("u", VERSION) if prop == "Version" else None


def main():
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    loop = GLib.MainLoop()

    def on_bus(conn, name):
        conn.register_object(PATH, node.interfaces[0], on_method_call, on_get_property, None)

    def on_lost(conn, name):
        print("kwin-screenshot-shim: %s is taken (KWin running?), exiting" % NAME, file=sys.stderr)
        loop.quit()

    Gio.bus_own_name(Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
                     on_bus, None, on_lost)
    loop.run()


if __name__ == "__main__":
    main()
