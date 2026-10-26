#!/usr/bin/env python3
"""window-buttons.py — close/minimize/maximize buttons (Settings → System).

  window-buttons.py get       1 = shown, 0 = hidden (no window-buttons.conf = 0)
  window-buttons.py set 0|1   save it and apply it

What follows it:
  Discord (Vesktop)   gen-discord-theme.py hides Discord's own buttons when off
  Settings            draws its buttons when on (reads window-buttons.conf)
  GTK apps            gsettings button-layout + gtk-3.0/gtk-4.0 settings.ini.
                      KDE's kded6 (gtkconfig) rewrites those from kwinrc's
                      ButtonsOnLeft/ButtonsOnRight whenever it starts, so
                      kwinrc is set too, or the layout would come back.
GTK is left alone until the setting is first changed. Whatever GTK and KWin had
before turning buttons off is saved here and put back when they go on again.
"""
import os
import re
import shutil
import subprocess
import sys

HYPR = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
CONF = os.path.join(HYPR, "window-buttons.conf")
KWINRC = os.path.join(HOME, ".config/kwinrc")
GTK_INIS = [os.path.join(HOME, ".config", d, "settings.ini") for d in ("gtk-3.0", "gtk-4.0")]
NO_BUTTONS = ":"
FALLBACK_LAYOUT = "appmenu:minimize,maximize,close"


def load():
    conf = {}
    try:
        with open(CONF, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#") and "=" in s:
                    k, v = s.split("=", 1)
                    conf[k.strip()] = v.strip()
    except OSError:
        pass
    return conf


def save(conf):
    body = "# Written by Settings → System → Window buttons (window-buttons.py).\n"
    body += "".join("%s=%s\n" % kv for kv in conf.items())
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, CONF)


def gsettings(*args):
    try:
        r = subprocess.run(["gsettings", *args], capture_output=True, text=True, timeout=10)
        return r.stdout.strip().strip("'") if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def kwin_buttons():
    """{key: value} for the ButtonsOnLeft/Right lines kwinrc has (absent = KDE's default)."""
    out, section = {}, None
    try:
        with open(KWINRC, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith("[") and s.endswith("]"):
                    section = s[1:-1]
                elif section == "org.kde.kdecoration2" and "=" in s:
                    k, v = s.split("=", 1)
                    if k in ("ButtonsOnLeft", "ButtonsOnRight"):
                        out[k] = v
    except OSError:
        pass
    return out


def kwin_set(key, value):
    """value None = delete (back to KDE's default). --notify tells kded6 now."""
    if not shutil.which("kwriteconfig6"):
        return
    cmd = ["kwriteconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2", "--key", key, "--notify"]
    cmd += ["--delete"] if value is None else [value]
    subprocess.run(cmd, capture_output=True, timeout=10)


def gtk_set(layout):
    gsettings("set", "org.gnome.desktop.wm.preferences", "button-layout", layout)
    for ini in GTK_INIS:
        try:
            with open(ini, encoding="utf-8") as f:
                old = f.read()
        except OSError:
            continue
        new = re.sub(r"(?m)^gtk-decoration-layout=.*$", "gtk-decoration-layout=" + layout, old)
        if new != old:
            with open(ini, "w", encoding="utf-8") as f:
                f.write(new)


def apply(on, conf):
    if not on:
        if conf.get("WINDOW_BUTTONS") != "0":   # remember what to go back to
            layout = gsettings("get", "org.gnome.desktop.wm.preferences", "button-layout")
            if layout and layout != NO_BUTTONS:
                conf["SAVED_GTK_LAYOUT"] = layout
            for k in ("SAVED_KWIN_LEFT", "SAVED_KWIN_RIGHT"):
                conf.pop(k, None)
            kb = kwin_buttons()
            if "ButtonsOnLeft" in kb:
                conf["SAVED_KWIN_LEFT"] = kb["ButtonsOnLeft"]
            if "ButtonsOnRight" in kb:
                conf["SAVED_KWIN_RIGHT"] = kb["ButtonsOnRight"]
        kwin_set("ButtonsOnLeft", "")
        kwin_set("ButtonsOnRight", "")
        gtk_set(NO_BUTTONS)
    else:
        kwin_set("ButtonsOnLeft", conf.pop("SAVED_KWIN_LEFT", None))
        kwin_set("ButtonsOnRight", conf.pop("SAVED_KWIN_RIGHT", None))
        gtk_set(conf.pop("SAVED_GTK_LAYOUT", FALLBACK_LAYOUT))
    conf["WINDOW_BUTTONS"] = "1" if on else "0"
    save(conf)
    # Discord's structure themes carry the hide rule (rewritten only if it changed)
    subprocess.run(["python3", os.path.join(HYPR, "gen-discord-theme.py")], capture_output=True, timeout=60)


def main(argv):
    cmd = argv[0] if argv else "get"
    if cmd == "get":
        print("1" if load().get("WINDOW_BUTTONS") == "1" else "0")
        return 0
    if cmd == "set" and len(argv) > 1 and argv[1] in ("0", "1"):
        apply(argv[1] == "1", load())
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
