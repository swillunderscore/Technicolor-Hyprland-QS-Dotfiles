#!/usr/bin/env python3
"""
tg-badge-listener.py — bridge Telegram's Unity LauncherEntry badge count to the
quickshell bar (the same signal KDE's task manager reads to show the badge).

Telegram broadcasts com.canonical.Unity.LauncherEntry "Update" whenever its
unread count CHANGES (and on launch). With "Include muted chats in unread
count" on, that count is the total incl muted. This must run persistently (like
Plasma does) to catch those emissions — if it starts late it misses the last
one, since there's no way to query the current value.

Writes Telegram's count to $XDG_RUNTIME_DIR/quickshell-tg-count.json:
    {"count": 7, "visible": true, "urgent": false, "ts": ...}
and logs EVERY LauncherEntry event (any app) to /tmp/tg-launcher.log for
debugging — so we can tell "Telegram isn't emitting" apart from "nothing
emitted at all".
"""
import json
import os
import re
import subprocess
import time

XDG = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
OUT = os.path.join(XDG, "quickshell-tg-count.json")
LOG = "/tmp/tg-launcher.log"
DBUS_MON = "/usr/bin/dbus-monitor" if os.path.exists("/usr/bin/dbus-monitor") else "dbus-monitor"
VARIANT = re.compile(r"variant\s+(int64|int32|uint32|boolean)\s+(\S+)")


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except Exception:
        pass


def write_out(props):
    rec = {"count": int(props.get("count", 0) or 0),
           "visible": bool(props.get("count-visible", False)),
           "urgent": bool(props.get("urgent", False)),
           "ts": int(time.time())}
    try:
        tmp = OUT + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, OUT)
    except Exception:
        pass
    return rec


def main():
    log(f"listener started (using {DBUS_MON})")
    p = subprocess.Popen(
        [DBUS_MON, "interface='com.canonical.Unity.LauncherEntry'"],
        stdout=subprocess.PIPE, text=True)
    appuri = None
    cur_key = None
    expect_appuri = False
    props = {}
    for raw in p.stdout:
        line = raw.strip()
        if "member=Update" in line:
            appuri, cur_key, expect_appuri, props = None, None, True, {}
        elif line.startswith('string "'):
            val = line[len('string "'):]
            if val.endswith('"'):
                val = val[:-1]
            if expect_appuri:
                appuri, expect_appuri = val, False
            else:
                cur_key = val
        elif line.startswith("variant") and cur_key is not None:
            m = VARIANT.match(line)
            if m:
                t, v = m.group(1), m.group(2)
                props[cur_key] = (v == "true") if t == "boolean" else int(v)
                cur_key = None
        elif line == "]":  # end of the a{sv} dict
            if appuri:
                log(f"LauncherEntry from {appuri}: {props}")
                if "telegram" in appuri.lower():
                    write_out(props)
            appuri, props, cur_key = None, {}, None
    log("dbus-monitor stream ended (exited)")


if __name__ == "__main__":
    main()
