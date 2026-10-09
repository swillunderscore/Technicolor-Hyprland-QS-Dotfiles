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

Per-app (by class), per KIND of window within the app (by title family — see
family()). First time an app is seen it uses its default; once you
tile/float/move/size it, that's remembered. Dialogs never inherit it (see
matcher()).
"""
import fcntl
import json
import os
import re
import subprocess
import time

STATE = os.path.expanduser("~/.local/state/hypr/window-geometry.json")
CONF = os.path.expanduser("~/.config/hypr/window-geometry.conf")
POLL = 0.4   # was 2.5 — drag a window then IMMEDIATELY spawn another and the
             # spawn raced the poll, mapping under the PRE-drag rules every
             # time. Sub-second polling closes the window a human can hit.
MIN_SIZE = 50  # ignore tiny/transient surfaces
# "Steam" (capital) is Steam's popup/dialog/toast class (the main client is the
# lowercase "steam"); recording it let a 700x330 popup poison the geometry and
# force real Steam windows tiny in the corner. Never record/reposition it.
EXCLUDE = {"com.dec05eba.gpu_screen_recorder", "gsr-ui", "hyprland-run", "wofi",
           "Steam", "aquamarine",
           # gamescope games (ELDEN RING): fullscreen is owned by gamescope, same as
           # the steam_app_ skip below. A recorded float+size+move (captured the one
           # time the window got knocked out of fullscreen) made it spawn "right
           # size, wrong corner" and gamescope ran composited at ~33 fps. 2026-09-01.
           "gamescope"}

# Some XWayland apps (e.g. Godot) give their popups/tooltips the SAME class as
# the main window, so a class-only geometry rule force-sizes the popup to the
# main window's saved geometry. They differ by initial_title: the real window
# has a stable one, popups open with an empty title. For such classes this
# initial_title regex REPLACES the learned title family: rules hit only the real
# window, and only the real window is ever recorded. class -> title regex.
MATCH_REFINE = {"Godot": "^(Godot)$"}

# What apps put between the document and their own name in a window title:
# "Week2 — Dolphin" (Qt/KDE), "New Tab - Brave" (Chromium/Electron), "a – b",
# "a | b". Spaced on both sides, so "arch-update" is not split.
SEPS = (" — ", " – ", " - ", " | ")
_SEP_SPLIT = re.compile("|".join(re.escape(s) for s in SEPS))

_max_mons = 0  # most monitors ever seen; used to pause recording when one is off


def _rx(s):
    """re.escape, plus the two characters the conf round trip can't carry: the
    fragment loader in hyprland.lua splits a rule on ',' and strips everything
    from '#' to the end of the line. \\x2c / \\x23 mean the same to RE2."""
    return "".join("\\x2c" if ch == "," else "\\x23" if ch == "#" else re.escape(ch)
                   for ch in s)


def family(title):
    """initial_title regex for every window of the same kind as one titled
    `title`: the exact title, or the same app name with any document in front
    ("<anything> - Brave") or behind ("DaVinci Resolve - <anything>").

    Rules used to require the EXACT initial title of the last window adjusted.
    Apps put the document in that title — folder, page, file, startup tab — so
    the next window rarely had the same one: Brave was tiled as "Untitled -
    Brave", its next window opened as "New Tab - Brave", matched nothing and
    floated. A title with nothing to split on still matches itself exactly."""
    if not title:
        return "^$"
    parts = _SEP_SPLIT.split(title)
    first, last = parts[0], parts[-1]
    sep = "(?:" + "|".join(_rx(s) for s in SEPS) + ")"
    alts = [_rx(title)]
    if last:   # "(<anything> - )Brave"
        alts.append("(?:.*" + sep + ")?" + _rx(last))
    if first:  # "DaVinci Resolve( - <anything>)"
        alts.append(_rx(first) + "(?:" + sep + ".*)?")
    return "^(?:" + "|".join(alts) + ")$"


def title_pat(cls, rec):
    """The initial_title regex a record's rules carry; None = any title."""
    return MATCH_REFINE.get(cls) or rec.get("pat")


def find_rec(cls, title):
    """The record a window with this initial title belongs to. The LAST match,
    because that's the one Hyprland applies (later rules win)."""
    hit = None
    for rec in geo.get(cls, []):
        pat = title_pat(cls, rec)
        if pat is None or re.fullmatch(pat, title):
            hit = rec
    return hit


def _migrate(v):
    """One saved record from an older state file -> the current record shape."""
    if isinstance(v, list) and len(v) == 5:  # oldest: floating-only [mon,x,y,w,h]
        return {"floating": True, "mon": v[0], "x": v[1], "y": v[2], "w": v[3], "h": v[4]}
    if isinstance(v, dict):
        rec = dict(v)
        # One record per class keyed to the exact title it was learned from
        # ("it") -> that title's family. No "it" = saved before titles were
        # recorded at all = whole class, as it always matched.
        if "pat" not in rec and "it" in rec:
            rec["pat"] = family(rec["it"])
        return rec
    return None


def offscreen_monitors():
    """Names of monitors that are off and not being streamed (see
    monitor-power.sh, stream-screens.sh, offscreen-guard.sh)."""
    run = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    try:
        with open(os.path.join(run, "tc-monitors-off")) as f:
            off = {l.strip() for l in f if l.strip()}
    except OSError:
        return set()
    try:
        with open(os.path.join(run, "tc-stream-output")) as f:
            off.discard(f.read().strip())
    except OSError:
        pass
    return off


def load():
    try:
        with open(STATE) as f:
            raw = json.load(f)
    except Exception:
        return {}
    out = {}
    for cls, v in raw.items():
        if isinstance(v, list) and v and all(isinstance(e, dict) for e in v):
            recs = [r for r in (_migrate(e) for e in v) if r]
        else:
            recs = [r for r in [_migrate(v)] if r]
        if recs:
            out[cls] = recs
    return out


# class -> [record, ...], one record per kind of window (title family) the user
# has adjusted. Record: {"pat": initial_title regex or absent, "floating": bool,
# "maximized": bool, "mon", "x", "y", "w", "h" (when known), "it": the initial
# title it was last learned from}. Separate records so moving a popup or a
# picture-in-picture window can't overwrite the main window's state — with ONE
# record per class, dragging any same-class window replaced it wholesale.
geo = load()


def hyprctl_json(what):
    try:
        r = subprocess.run(["hyprctl", "-j", what],
                           capture_output=True, text=True, timeout=2)
        return json.loads(r.stdout)
    except Exception:
        return None


def matcher(cls, rec):
    """Rule matcher for one record: class + not-a-dialog + its title family.

    Many apps (Steam, Godot, KDE apps, ...) give popups, toasts, and dialogs the
    SAME class as their main window, so a class-only rule force-sizes a
    "Launching game..." popup to the store page's saved geometry, or tiles a
    Save dialog.

    `float false` is Hyprland's OWN dialog test: by the time rules are read it
    has already floated anything with a parent window, a fixed size, or an X11
    dialog/transient/modal type — before `floatall` or any rule here lands. So
    on these rules it reads "not a dialog", and dialogs keep Hyprland's own
    placement. Verified: one `tile on` rule with it tiled a GTK main window and
    left its child dialog floating.

    The title family keeps apart same-class windows that AREN'T dialogs to
    Hyprland: "Picture in picture" vs "<page> - Brave", "Launching..." vs
    "Steam".
    """
    m = "match:class ^(" + _rx(cls) + ")$, match:float false"
    pat = title_pat(cls, rec)
    if pat:
        m += ", match:initial_title " + pat
    return m


def rules_for(cls, v):
    """Window-rule bodies (without the leading 'windowrule = ') for one record."""
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
            for rec in geo[cls]:
                for r in rules_for(cls, rec):
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


def apply_live(cls):
    """Apply the current rules live so a reopen THIS session uses the latest state.
    Under the Lua config `hyprctl keyword` is REJECTED, AND the raw-string
    hl.window_rule form silently no-ops for size/move/tile — so emit the STRUCTURED
    hl.window_rule table via `hyprctl eval`. No unset needed: rules accumulate and
    the LATEST matching one wins (verified).

    ALL of the class's records, in file order, not just the one that changed:
    where two families both match a title, the later record must win live
    exactly as it does in window-geometry.conf (and as find_rec assumes)."""
    # One batched eval, not one subprocess per rule: five sequential hyprctl
    # round-trips added most of a second to the drag->spawn race.
    stmts = "; ".join(_body_to_lua(r) for rec in geo.get(cls, [])
                      for r in rules_for(cls, rec))
    subprocess.run(["hyprctl", "eval", stmts + " return 1"],
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
    # Windows our rules demonstrably skipped, so never learned from: a window
    # whose record says TILED that still came up floating is one Hyprland
    # classed as a dialog (see matcher). Recording it — a Save dialog dragged
    # aside — would turn the app's next main window floating at dialog size.
    # Only checkable for tiled records: floating is everyone's default here.
    skipped = set()
    known = set()      # every address seen so far: the check runs at FIRST sight only
    first_poll = True  # windows already open at startup weren't seen mapping
    while True:
        time.sleep(POLL)
        mons = hyprctl_json("monitors")
        cls_list = hyprctl_json("clients")
        if mons is None or cls_list is None:
            continue
        # First-sight check (see `skipped`) — ahead of the missing-monitor pause
        # below, so a window is judged as it mapped, not whenever recording resumes.
        for c in cls_list:
            addr = c.get("address")
            if addr and addr not in known and not first_poll:
                rec = find_rec(c.get("class") or "", c.get("initialTitle") or "")
                if rec is not None and not rec.get("floating") and c.get("floating"):
                    skipped.add(addr)
        known = {c.get("address") for c in cls_list}
        skipped &= known
        first_poll = False
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
        # Same for a monitor that's still connected but OFFSCREEN (powered off
        # and not being streamed): offscreen-guard.sh moves windows off it, and
        # a remote one-screen session must not rewrite where apps open at home.
        if offscreen_monitors():
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
            title = c.get("initialTitle") or ""
            if not cls or cls in EXCLUDE or not addr:
                continue
            if cls in MATCH_REFINE and not re.fullmatch(MATCH_REFINE[cls], title):
                continue  # the refined class's popups: never recorded
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

        changed = set()
        for cls, lst in per_class.items():
            # The window the user actively moved/resized is the one whose shape
            # changed since the last poll. Recording THAT one — not just the biggest
            # window sharing the class — is what makes "remember the last one I
            # changed" work (a huge stale sibling no longer wins). If nothing of this
            # class changed, keep what we already remember; only fall back to
            # "largest" to SEED a class we've never recorded before.
            edited = [(a, c) for (a, c) in lst
                      if a in prev_shape and prev_shape[a] != cur_shape[a]
                      and a not in skipped]
            if edited:
                # One pick per RECORD, not per class: a popup and the main window
                # changing in the same poll are two separate facts to remember.
                groups = {}
                for a, c in edited:
                    t = c.get("initialTitle") or ""
                    rec = find_rec(cls, t)
                    groups.setdefault(id(rec) if rec is not None else family(t),
                                      []).append((a, c))
                picks = [next((c for a, c in g if a == focused_addr), None)
                         or max((c for _, c in g), key=area) for g in groups.values()]
            elif cls not in geo:
                stable = [c for (a, c) in lst if a in prev_addrs]
                if not stable:
                    continue
                picks = [max(stable, key=area)]
            else:
                continue
            for c in picks:
                if record(cls, c, prev_fs, moff):
                    changed.add(cls)
        for cls in changed:
            apply_live(cls)
        if changed:
            write_state()
            write_conf()
        prev_addrs = cur_addrs
        prev_shape = cur_shape
        prev_fs = cur_fs


def record(cls, c, prev_fs, moff):
    """Fold one window's current state into the record for its kind of window
    (creating that record if it's a new kind). True if anything changed."""
    title = c.get("initialTitle") or ""
    rec = find_rec(cls, title)
    base = dict(rec) if rec is not None else {"pat": family(title)}

    fs = c.get("fullscreen") or 0   # 0=none 1=maximize(SUPER+V) 2=fullscreen
    if fs == 2:
        # Real fullscreen (games / video) is transient — never record it.
        return False
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
            return False
        val = base
        val.setdefault("floating", True)
        val["maximized"] = True
        val["it"] = title
    elif c.get("floating"):
        at, sz, mid = c.get("at"), c.get("size"), c.get("monitor")
        if not at or not sz or sz[0] < MIN_SIZE or sz[1] < MIN_SIZE:
            return False
        if mid not in moff:
            return False
        mon, mx, my, mw, mh = moff[mid]
        rx, ry = at[0] - mx, at[1] - my
        # Sanity: don't remember a window that's mostly off its monitor or
        # bigger than it. That's exactly how an old headless/hotplug layout
        # poisoned the geometry (e.g. the 742x2079 kitty at y=-876).
        if rx < -100 or ry < -100 or rx > mw or ry > mh \
                or sz[0] > mw + 200 or sz[1] > mh + 200:
            return False
        val = {"floating": True, "maximized": False, "mon": mon,
               "x": rx, "y": ry, "w": sz[0], "h": sz[1], "it": title}
        if "pat" in base:   # absent = a class-wide record from before titles were kept
            val["pat"] = base["pat"]
    else:
        # Tiled: flip the flag, remember which monitor it's on (so it can be
        # pinned there via rules_for), keep any prior floating geometry.
        val = base
        val["floating"] = False
        val["maximized"] = False
        val["it"] = title
        mid = c.get("monitor")
        if mid in moff:
            val["mon"] = moff[mid][0]

    recs = geo.setdefault(cls, [])
    if rec is None:
        recs.append(val)
        return True
    if val == rec:
        return False
    recs[next(i for i, r in enumerate(recs) if r is rec)] = val
    return True


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
    # Rewrite both files once in the current shape, so a state file from an older
    # version doesn't keep its old rules until some window happens to change.
    # Only when something loaded: load() returns {} on a read error, and writing
    # that back would erase every saved window.
    if geo:
        write_state()
        write_conf()
    poll_loop()
