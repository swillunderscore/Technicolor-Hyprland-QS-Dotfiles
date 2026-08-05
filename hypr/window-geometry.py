#!/usr/bin/env python3
"""
window-geometry.py — remember & restore each app's window state across reboots:
whether it was tiled or floating, and (when floating) its monitor + position +
size. Hyprland 0.55 has no native equivalent.

  - Polls `hyprctl clients`; per window class records tiled-vs-floating, plus
    floating geometry (monitor-relative position + size). Saved to JSON
    (survives reboots).
  - Writes matching window rules into a sourced conf file AND applies them live:
      floating -> `float on` + `monitor`/`size`/`move`  (spawns at the saved spot)
      tiled    -> `tile on`                              (opens tiled)
    The rules exist BEFORE a window opens, so it spawns in the right state with
    no jump. The conf is sourced by hyprland.conf so it also works from the
    first launch after a reboot.

Per-app (by class). First time an app is seen it uses its default; once you
tile/float/move/size it, that's remembered.
"""
import fcntl
import json
import os
import re
import subprocess
import time

STATE = os.path.expanduser("~/.local/state/hypr/window-geometry.json")
CONF = os.path.expanduser("~/.config/hypr/window-geometry.conf")
POLL = 2.5
MIN_SIZE = 50  # ignore tiny/transient surfaces
# "Steam" (capital) is Steam's popup/dialog/toast class (the main client is the
# lowercase "steam"); recording it let a 700x330 popup poison the geometry and
# force real Steam windows tiny in the corner. Never record/reposition it.
EXCLUDE = {"com.dec05eba.gpu_screen_recorder", "gsr-ui", "hyprland-run", "wofi",
           "Steam", "aquamarine"}

# Some XWayland apps (e.g. Godot) give their popups/tooltips the SAME class as
# the main window, so a class-only geometry rule force-sizes the popup to the
# main window's saved geometry. They differ by initial_title: the real window
# has a stable one, popups open with an empty title. For such classes, append an
# extra matcher so geometry rules hit ONLY the real window. class -> extra match.
MATCH_REFINE = {"Godot": "match:initial_title ^(Godot)$"}

_max_mons = 0  # most monitors ever seen; used to pause recording when one is off


def load():
    try:
        with open(STATE) as f:
            raw = json.load(f)
    except Exception:
        return {}
    out = {}
    for cls, v in raw.items():
        if isinstance(v, list) and len(v) == 5:  # legacy floating-only format
            out[cls] = {"floating": True, "mon": v[0], "x": v[1],
                        "y": v[2], "w": v[3], "h": v[4]}
        elif isinstance(v, dict):
            out[cls] = v
    return out


geo = load()  # class -> {"floating": bool, "mon","x","y","w","h" (when known)}


def hyprctl_json(what):
    try:
        r = subprocess.run(["hyprctl", "-j", what],
                           capture_output=True, text=True, timeout=2)
        return json.loads(r.stdout)
    except Exception:
        return None


def matcher(cls, v=None):
    """Class matcher for window rules, plus popup-excluding refinement.

    Many apps (Steam, Godot, ...) give popups, toasts, and transient dialogs
    the SAME class as their main window, so a class-only rule force-sizes a
    "Launching game..." popup to the store page's saved geometry — and the
    reverse. The canonical window's initial_title is recorded with its
    geometry and required here, so rules only ever hit the window they were
    learned from. Self-healing: if an app's real window changes its
    initial_title, the rule stops matching until the user adjusts the window
    once, which re-records both. MATCH_REFINE stays as a manual override.
    """
    m = "match:class ^(" + re.escape(cls) + ")$"
    if cls in MATCH_REFINE:
        m += ", " + MATCH_REFINE[cls]
    elif v and v.get("it"):
        m += ", match:initial_title ^(" + re.escape(v["it"]) + ")$"
    return m


def rules_for(cls, v):
    """Window-rule bodies (without the leading 'windowrule = ') for this app."""
    m = matcher(cls, v)
    if not v.get("floating"):
        out = ["tile on, " + m]
        # Pin tiled windows to their remembered monitor too, so e.g. Brave opens
        # on the screen it lives on instead of wherever keyboard focus happens to
        # be at launch. (Floating windows already get a monitor rule below.)
        if v.get("mon"):
            out.append(f"monitor {v['mon']}, " + m)
    else:
        out = ["float on, " + m]
        if all(v.get(k) is not None for k in ("mon", "x", "y", "w", "h")):
            out += [f"monitor {v['mon']}, {m}",
                    f"size {v['w']} {v['h']}, {m}",
                    f"move {v['x']} {v['y']}, {m}"]
    # Maximized (SUPER+V = fullscreen mode 1) layers ON TOP of the float/size/move
    # above: the window opens maximized, and un-maximizing returns it to the saved
    # geometry. (Real fullscreen, mode 2, is never recorded — see poll_loop.)
    #
    # ALWAYS emitted, both states. Live rules accumulate and the LATEST matching
    # verb wins — an "on" from any SUPER+V this session would stay the latest
    # maximize rule forever if clearing it merely emitted nothing, which is why
    # kitty kept spawning maximized no matter how often the user dragged one
    # back down. "off" has to be said out loud to overwrite it.
    out.append(("maximize on, " if v.get("maximized") else "maximize off, ") + m)
    return out


def write_conf():
    try:
        os.makedirs(os.path.dirname(CONF), exist_ok=True)
        out = ["# Auto-generated by ~/.config/hypr/window-geometry.py — remembered",
               "# per-app window state (tiled/floating + floating geometry),",
               "# regenerated whenever a window changes. Do not edit by hand.", ""]
        for cls in sorted(geo):
            for r in rules_for(cls, geo[cls]):
                out.append("windowrule = " + r)
        tmp = CONF + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(out) + "\n")
        os.replace(tmp, CONF)
    except Exception:
        pass


def write_state():
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(geo, f)
        os.replace(tmp, STATE)
    except Exception:
        pass


def _lua_str(s):
    # escape a value for embedding in a lua double-quoted string literal: double
    # backslashes (re.escape gives `^(brave\-browser)$`; a bare `\-` is an invalid
    # lua escape), then escape quotes.
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _body_to_lua(body):
    """Convert a windowrule body ('size 700 400, match:class ^(X)$') into a
    STRUCTURED hl.window_rule(...) eval string. CRITICAL: under the Lua config the
    raw-string form hl.window_rule({"size .., match:.."}) is silently accepted but
    size/move/tile/monitor NEVER apply — only the table form works (verified). This
    mirrors apply_windowrule() in hyprland.lua so live + startup behave identically."""
    parts = [p.strip() for p in body.split(",")]
    match_fields = []
    for p in parts[1:]:
        if p.startswith("match:"):
            kv = p[len("match:"):].split(" ", 1)
            if len(kv) == 2:
                match_fields.append(f'{kv[0]} = "{_lua_str(kv[1])}"')
    verb, _, rest = parts[0].partition(" ")
    if verb in ("float", "tile", "fullscreen", "maximize"):
        action = f'{verb} = {"true" if rest == "on" else "false"}'
    elif verb in ("size", "move", "monitor"):
        action = f'{verb} = "{_lua_str(rest)}"'
    else:
        return 'hl.window_rule({"' + _lua_str(body) + '"})'  # unknown verb: raw fallback
    return f'hl.window_rule({{ match = {{ {", ".join(match_fields)} }}, {action} }})'


def apply_live(cls, v):
    """Apply the current rules live so a reopen THIS session uses the latest state.
    Under the Lua config `hyprctl keyword` is REJECTED, AND the raw-string
    hl.window_rule form silently no-ops for size/move/tile — so emit the STRUCTURED
    hl.window_rule table via `hyprctl eval`. No unset needed: rules accumulate and
    the LATEST matching one wins (verified)."""
    for r in rules_for(cls, v):
        subprocess.run(["hyprctl", "eval", _body_to_lua(r) + " return 1"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def poll_loop():
    global _max_mons
    # Addresses seen on the PREVIOUS poll. A window is only recorded once it has
    # persisted ≥1 interval — so a splash/loader that flashes up and vanishes
    # within a poll is never recorded (this is the "shotcut splash" problem).
    # prev_shape maps addr -> geometry tuple from last poll, to detect which window
    # the user actually moved/resized (see the per-class loop).
    prev_addrs = set()
    prev_shape = {}
    prev_fs = {}
    while True:
        time.sleep(POLL)
        mons = hyprctl_json("monitors")
        cls_list = hyprctl_json("clients")
        if mons is None or cls_list is None:
            continue
        # Pause recording while a monitor is missing (e.g. powered off overnight):
        # windows pile onto the remaining monitor, and we must NOT overwrite the
        # real saved geometry with that squished layout. Resume once all are back.
        # Count only PHYSICAL monitors for the "a monitor is missing, pause
        # recording" guard. A transient headless output (TV stream / DisplayThree)
        # otherwise bumped the max and then, once removed, paused recording for the
        # rest of the session — freezing stale geometry.
        phys = [m for m in mons if not str(m.get("name", "")).startswith("HEADLESS")]
        _max_mons = max(_max_mons, len(phys))
        if len(phys) < _max_mons:
            continue
        # id -> (name, x, y, logical_w, logical_h)
        moff = {}
        for m in mons:
            sc = m.get("scale") or 1
            moff[m["id"]] = (m["name"], m["x"], m["y"],
                             int((m["width"] or 0) / sc), int((m["height"] or 0) / sc))

        active = hyprctl_json("activewindow") or {}
        focused_addr = (active or {}).get("address")

        def shape(c):
            mid = c.get("monitor")
            at = c.get("at") or [None, None]
            sz = c.get("size") or [None, None]
            mon = moff[mid][0] if mid in moff else None
            mx, my = (moff[mid][1], moff[mid][2]) if mid in moff else (0, 0)
            rx = at[0] - mx if at[0] is not None else None
            ry = at[1] - my if at[1] is not None else None
            return (bool(c.get("floating")), c.get("fullscreen") or 0, mon, rx, ry, sz[0], sz[1])

        def area(c):
            sz = c.get("size") or [0, 0]
            return (sz[0] or 0) * (sz[1] or 0)

        # Eligible windows this poll, grouped by class. Skip excluded classes,
        # special workspaces, and anything on a headless output (its geometry is
        # meaningless once the headless is gone).
        cur_addrs = set()
        cur_shape = {}
        cur_fs = {}
        per_class = {}
        for c in cls_list:
            cls = c.get("class") or ""
            addr = c.get("address") or ""
            if not cls or cls in EXCLUDE or not addr:
                continue
            if cls.startswith("steam_app_"):
                # Steam/Proton games: monitor + fullscreen are owned by local.conf.
                # Tracking them here fought that — a recorded `float + size 2560x1440
                # + move 0 0` made a game spawn corner-anchored at full size instead
                # of fullscreen ("right size, wrong corner").
                continue
            ws = (c.get("workspace") or {}).get("name", "")
            if ws.startswith("special"):
                continue
            mid = c.get("monitor")
            if mid in moff and str(moff[mid][0]).startswith("HEADLESS"):
                continue
            cur_addrs.add(addr)
            cur_shape[addr] = shape(c)
            cur_fs[addr] = c.get("fullscreen") or 0
            per_class.setdefault(cls, []).append((addr, c))

        changed = False
        for cls, lst in per_class.items():
            # The window the user actively moved/resized is the one whose shape
            # changed since the last poll. Recording THAT one — not just the biggest
            # window sharing the class — is what makes "remember the last one I
            # changed" work (a huge stale sibling no longer wins). If nothing of this
            # class changed, keep what we already remember; only fall back to
            # "largest" to SEED a class we've never recorded before.
            edited = [(a, c) for (a, c) in lst
                      if a in prev_shape and prev_shape[a] != cur_shape[a]]
            if edited:
                c = next((c for a, c in edited if a == focused_addr), None) \
                    or max((c for _, c in edited), key=area)
            elif cls not in geo:
                stable = [c for (a, c) in lst if a in prev_addrs]
                if not stable:
                    continue
                c = max(stable, key=area)
            else:
                continue

            fs = c.get("fullscreen") or 0   # 0=none 1=maximize(SUPER+V) 2=fullscreen
            if fs == 2:
                # Real fullscreen (games / video) is transient — never record it.
                continue
            if fs == 1:
                # Maximized: at/size are the maximized bounds, not the real floating
                # geometry — keep the prior geometry, just flag maximized.
                #
                # TRANSITIONS ONLY. A window that merely SITS maximized while its
                # shape drifts (workspace slides, monitor changes, another window
                # of the class being adjusted) must not keep re-asserting the
                # flag: with one kitty parked maximized and another being dragged
                # around unmaximized, the parked one won every poll and every new
                # kitty spawned maximized no matter what the user did. Only the
                # deliberate act — a window that BECAME maximized since the last
                # poll — gets to set the flag; unmaximizing records through the
                # floating/tiled branches below as before.
                if prev_fs.get(c.get("address")) == 1:
                    continue
                val = dict(geo.get(cls, {}))
                val.setdefault("floating", True)
                val["maximized"] = True
                val["it"] = c.get("initialTitle") or ""
            elif c.get("floating"):
                at, sz, mid = c.get("at"), c.get("size"), c.get("monitor")
                if not at or not sz or sz[0] < MIN_SIZE or sz[1] < MIN_SIZE:
                    continue
                if mid not in moff:
                    continue
                mon, mx, my, mw, mh = moff[mid]
                rx, ry = at[0] - mx, at[1] - my
                # Sanity: don't remember a window that's mostly off its monitor or
                # bigger than it. That's exactly how an old headless/hotplug layout
                # poisoned the geometry (e.g. the 742x2079 kitty at y=-876).
                if rx < -100 or ry < -100 or rx > mw or ry > mh \
                        or sz[0] > mw + 200 or sz[1] > mh + 200:
                    continue
                val = {"floating": True, "maximized": False, "mon": mon,
                       "x": rx, "y": ry, "w": sz[0], "h": sz[1],
                       "it": c.get("initialTitle") or ""}
            else:
                # Tiled: flip the flag, remember which monitor it's on (so it can be
                # pinned there via rules_for), keep any prior floating geometry.
                val = dict(geo.get(cls, {}))
                val["floating"] = False
                val["maximized"] = False
                val["it"] = c.get("initialTitle") or ""
                mid = c.get("monitor")
                if mid in moff:
                    val["mon"] = moff[mid][0]
            if geo.get(cls) != val:
                geo[cls] = val
                apply_live(cls, val)
                changed = True
        if changed:
            write_state()
            write_conf()
        prev_addrs = cur_addrs
        prev_shape = cur_shape
        prev_fs = cur_fs


if __name__ == "__main__":
    # Single instance: a reload/relaunch (or a stale daemon from a prior session)
    # otherwise leaves two pollers racing on the same state + conf. Hold an
    # exclusive lock for our whole lifetime; a second copy exits immediately.
    _lock_path = os.path.expanduser("~/.local/state/hypr/window-geometry.lock")
    os.makedirs(os.path.dirname(_lock_path), exist_ok=True)
    _lock = open(_lock_path, "w")
    try:
        fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit(0)
    poll_loop()
