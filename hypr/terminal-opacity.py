#!/usr/bin/env python3
"""Read and write the background transparency of whichever terminal you use.

Technicolor Settings > System > Terminal transparency talks to this. Every
terminal spells transparency differently and reloads differently, so each one
gets an adapter below: where its config lives, what the key is called, and how
to make an already-open window pick the change up.

    terminal-opacity.py get [--term kitty]     -> term/name/opacity/support/note
    terminal-opacity.py set 0.65 [--term ...]

`support` is what the UI promises the user:
    live     - open windows change as you drag
    restart  - written now, applies to windows you open from here on
    none     - this terminal has no transparency we can drive

With no --term it follows the desktop's default terminal (terminal.conf, which
Settings writes), so the slider always tunes the terminal Super+Q opens.

Why the background and not a compositor rule: a Hyprland `opacity` windowrule
fades the TEXT along with the background. Every adapter here sets the
terminal's own background alpha instead, so glyphs stay fully solid.
"""

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CONF_DIR = HOME / ".config"
LOCK = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "technicolor-terminal-opacity.lock"


# ─────────────────────────── config file plumbing ───────────────────────────
# Hand-rolled rather than configparser/tomlkit: those rewrite the whole file and
# throw away the user's comments and ordering. These only touch the one line.

def _read(path: Path) -> list[str]:
    try:
        return path.read_text().splitlines()
    except OSError:
        return []


def _write(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tc-tmp")
    tmp.write_text("\n".join(lines).rstrip("\n") + "\n")
    tmp.replace(path)


def _is_section(line: str) -> str | None:
    m = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
    return m.group(1) if m else None


def get_key(path: Path, key: str, section: str | None = None,
            sep: str = "=") -> str | None:
    """First value of `key` (inside `[section]` if given). None if absent."""
    pat = re.compile(rf"^\s*{re.escape(key)}\s*{re.escape(sep.strip()) or ''}\s*(.+?)\s*$"
                     if sep.strip() else rf"^\s*{re.escape(key)}\s+(.+?)\s*$")
    cur = None
    for line in _read(path):
        sec = _is_section(line)
        if sec is not None:
            cur = sec
            continue
        if section is not None and cur != section:
            continue
        m = pat.match(line)
        if m:
            return m.group(1).strip()
    return None


def put_key(path: Path, key: str, value: str, section: str | None = None,
            sep: str = " = ") -> None:
    """Set `key` (inside `[section]` if given), preserving the rest of the file.

    Replaces the existing line where there is one; otherwise inserts directly
    under the section header, creating the section if the file doesn't have it.
    """
    lines = _read(path)
    new = f"{key}{sep}{value}"
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*(=|\s)")

    cur, sec_at = None, None
    for i, line in enumerate(lines):
        s = _is_section(line)
        if s is not None:
            cur = s
            if s == section and sec_at is None:
                sec_at = i
            continue
        if section is not None and cur != section:
            continue
        if key_re.match(line):
            lines[i] = new
            _write(path, lines)
            return

    if section is None:
        lines.append(new)
    elif sec_at is not None:
        lines.insert(sec_at + 1, new)
    else:
        if lines and lines[-1].strip():
            lines.append("")
        lines += [f"[{section}]", new]
    _write(path, lines)


def num(text: str | None, default: float = 1.0) -> float:
    """First float in `text` — copes with `0.65`, `"0.65"`, `0.65  # comment`."""
    if not text:
        return default
    m = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(m.group(0)) if m else default


def signal(name: str, sig: str = "-USR1") -> None:
    # -x matches the process NAME exactly. Never -f here: that matches this
    # script's own command line (and the shell that launched it) too.
    subprocess.run(["pkill", sig, "-x", name],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def version_at_least(cmd: str, want: tuple[int, ...]) -> bool:
    try:
        out = subprocess.run([cmd, "--version"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", out)
    if not m:
        return False
    got = tuple(int(g) for g in m.groups() if g is not None)
    return got >= want[:len(got)]


# ────────────────────────────── the adapters ────────────────────────────────
# Each returns (opacity, support, note) for get, and applies for set.

def kitty_get():
    conf = CONF_DIR / "kitty/kitty.conf"
    # Opacity is only changeable at runtime if dynamic_background_opacity was on
    # when the window opened. We set it on every write, so it's on from the first
    # drag onwards — but windows opened before that still ignore reloads.
    dyn = (get_key(conf, "dynamic_background_opacity", sep=" ") or "").lower() in ("yes", "y", "true", "1")
    return (num(get_key(conf, "background_opacity", sep=" ")),
            "live" if dyn else "restart",
            "" if dyn else "terminals already open keep their current transparency")


def kitty_set(v):
    conf = CONF_DIR / "kitty/kitty.conf"
    put_key(conf, "dynamic_background_opacity", "yes", sep=" ")
    put_key(conf, "background_opacity", f"{v:.2f}", sep=" ")
    signal("kitty")            # kitty re-reads its whole config on SIGUSR1


def alacritty_conf():
    for name in ("alacritty.toml", "alacritty.yml"):
        p = CONF_DIR / "alacritty" / name
        if p.exists():
            return p
    return CONF_DIR / "alacritty/alacritty.toml"


def alacritty_get():
    conf = alacritty_conf()
    # Alacritty watches its own config; only an explicit opt-out stops that.
    off = (get_key(conf, "live_config_reload", "general") or
           get_key(conf, "live_config_reload") or "").lower().startswith("false")
    return (num(get_key(conf, "opacity", "window")),
            "restart" if off else "live",
            "live_config_reload is off in alacritty.toml" if off else "")


def alacritty_set(v):
    put_key(alacritty_conf(), "opacity", f"{v:.2f}", "window")


def foot_get():
    return num(get_key(CONF_DIR / "foot/foot.ini", "alpha", "colors")), "live", ""


def foot_set(v):
    put_key(CONF_DIR / "foot/foot.ini", "alpha", f"{v:.2f}", "colors", sep="=")
    signal("foot")             # foot reloads its config on SIGUSR1


def ghostty_get():
    conf = CONF_DIR / "ghostty/config"
    live = version_at_least("ghostty", (1, 1))
    return (num(get_key(conf, "background-opacity")), "live" if live else "restart",
            "" if live else "ghostty < 1.1 can't reload its config in place")


def ghostty_set(v):
    put_key(CONF_DIR / "ghostty/config", "background-opacity", f"{v:.2f}")
    # Only signal versions known to HANDLE SIGUSR1 — the default disposition for
    # an unhandled SIGUSR1 is to kill the process, and killing someone's terminal
    # to make it slightly more see-through is not a trade worth making.
    if version_at_least("ghostty", (1, 1)):
        signal("ghostty")


# The two shapes a wezterm.lua ends in. Anchored to a whole line so a `return`
# inside some helper function of theirs can't be mistaken for the config's.
WEZ_RETURN_VAR = re.compile(r"^([ \t]*)return[ \t]+(\w+)[ \t]*$", re.M)
WEZ_RETURN_TBL = re.compile(r"^([ \t]*)return[ \t]*\{[ \t]*$", re.M)


def wezterm_conf():
    for p in (CONF_DIR / "wezterm/wezterm.lua", HOME / ".wezterm.lua"):
        if p.exists():
            return p
    return CONF_DIR / "wezterm/wezterm.lua"


def wezterm_get():
    conf = wezterm_conf()
    text = conf.read_text() if conf.exists() else ""
    m = re.search(r"window_background_opacity\s*=\s*([\d.]+)", text)
    if m:
        return float(m.group(1)), "live", ""
    # No key yet — but we can still add one to either shape a wezterm.lua comes
    # in (`return config` after config_builder, or a bare `return { ... }`), and
    # to a config that doesn't exist at all.
    if not text.strip() or WEZ_RETURN_VAR.search(text) or WEZ_RETURN_TBL.search(text):
        return 1.0, "live", ""
    return 1.0, "none", "your wezterm.lua doesn't end in a return this can edit"


def wezterm_set(v):
    conf = wezterm_conf()
    text = conf.read_text() if conf.exists() else ""
    val = f"{v:.2f}"
    if re.search(r"window_background_opacity\s*=\s*[\d.]+", text):
        text = re.sub(r"(window_background_opacity\s*=\s*)[\d.]+", rf"\g<1>{val}", text, count=1)
    elif not text.strip():
        text = ("local wezterm = require 'wezterm'\n"
                "local config = wezterm.config_builder()\n"
                f"config.window_background_opacity = {val}\n"
                "return config\n")
    else:
        # Insert into whichever return the file ends with: an assignment above
        # `return config` (the config_builder shape), or a field just inside a
        # bare `return { ... }` table.
        m = list(WEZ_RETURN_VAR.finditer(text))
        if m:
            last = m[-1]
            text = (text[:last.start()]
                    + f"{last.group(1)}{last.group(2)}.window_background_opacity = {val}\n"
                    + text[last.start():])
        else:
            m = list(WEZ_RETURN_TBL.finditer(text))
            if not m:
                return
            last = m[-1]
            text = (text[:last.end()]
                    + f"\n{last.group(1)}  window_background_opacity = {val},"
                    + text[last.end():])
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_text(text)      # wezterm reloads on file change by default


def konsole_builtin(name: str) -> str | None:
    """Konsole's stock colour schemes have no files — since KDE 22 they're baked
    into the library as Qt resources. They're stored uncompressed though, so we
    can lift the exact one out and hand it back as text."""
    libs = []
    for base in ("/usr/lib", "/usr/lib64", "/usr/local/lib", "/usr/lib/x86_64-linux-gnu"):
        libs += sorted(Path(base).glob("libkonsoleprivate.so*")) if Path(base).is_dir() else []
    printable = set(range(0x20, 0x7F)) | {0x0A}
    for lib in libs:
        try:
            data = lib.read_bytes().decode("latin-1")
        except OSError:
            continue
        at = data.find(f"\nDescription={name}\n")
        if at < 0:
            continue
        # Each embedded file is its own run of printable bytes — walk out to the
        # NULs on either side, then trim to the one scheme we asked for.
        lo = at
        while lo > 0 and ord(data[lo - 1]) in printable:
            lo -= 1
        hi = at
        while hi < len(data) and ord(data[hi]) in printable:
            hi += 1
        run = data[lo:hi]
        rel = at - lo
        start = run.rfind("[Background]", 0, rel)
        nxt = run.find("[Background]", rel)
        return run[max(start, 0):nxt if nxt > 0 else len(run)]
    return None


def konsole_target() -> tuple[Path, str]:
    """(colour scheme file for the default profile, its name). The file may not
    exist yet — stock schemes don't have one until we make it."""
    profile = get_key(CONF_DIR / "konsolerc", "DefaultProfile", "Desktop Entry") or "Profile 1.profile"
    user_dir = HOME / ".local/share/konsole"
    scheme = get_key(user_dir / profile, "ColorScheme", "Appearance") or "Breeze"
    return user_dir / f"{scheme}.colorscheme", scheme


def konsole_scheme() -> Path | None:
    """Konsole keeps opacity in the colour scheme, not the profile. A stock
    scheme has no file to edit, so materialise it into ~/.local/share (which
    Konsole prefers) before touching it — same name, same colours, now with an
    Opacity we own. Only called on WRITE; reading never creates files."""
    dest, scheme = konsole_target()
    if dest.exists():
        return dest

    body = None
    for src in (Path("/usr/share/konsole") / f"{scheme}.colorscheme",
                Path("/usr/local/share/konsole") / f"{scheme}.colorscheme"):
        if src.exists():
            body = src.read_text()
            break
    if body is None:
        body = konsole_builtin(scheme)
    if body is None:
        # Nothing to copy. A scheme that only sets Opacity still works — Konsole
        # fills every colour it doesn't find from its own default table (verified,
        # text and the 16 ANSI colours all render normally) — so transparency
        # still gets to work rather than the slider going dead.
        body = f"[General]\nDescription={scheme}\nOpacity=1\n"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body if body.endswith("\n") else body + "\n")
    return dest


def konsole_get():
    dest, scheme = konsole_target()
    if dest.exists():
        return num(get_key(dest, "Opacity", "General")), "restart", ""
    # Not materialised yet: the stock scheme's own Opacity is the current value,
    # and stock schemes are all fully opaque.
    body = konsole_builtin(scheme) or ""
    m = re.search(r"^Opacity\s*=\s*([\d.]+)", body, re.M)
    return (float(m.group(1)) if m else 1.0), "restart", ""


def konsole_set(v):
    scheme = konsole_scheme()
    if scheme is not None:
        put_key(scheme, "Opacity", f"{v:.2f}", "General", sep="=")


def gnome_profile() -> str | None:
    try:
        out = subprocess.run(["gsettings", "get", "org.gnome.Terminal.ProfilesList", "default"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"'([^']+)'", out)
    return m.group(1) if m else None


def gnome_path(uuid: str) -> str:
    return f"org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:{uuid}/"


def gnome_get():
    uuid = gnome_profile()
    if not uuid:
        return 1.0, "none", "no gnome-terminal profile found"
    out = subprocess.run(["gsettings", "get", gnome_path(uuid), "background-transparency-percent"],
                         capture_output=True, text=True, check=False).stdout
    # gnome-terminal counts TRANSPARENCY, not opacity.
    return 1.0 - num(out, 0.0) / 100.0, "live", ""


def gnome_set(v):
    uuid = gnome_profile()
    if not uuid:
        return
    p = gnome_path(uuid)
    pct = round((1.0 - v) * 100)
    subprocess.run(["gsettings", "set", p, "use-transparent-background",
                    "true" if pct > 0 else "false"], check=False)
    subprocess.run(["gsettings", "set", p, "background-transparency-percent", str(pct)], check=False)


def xfce_conf():
    return CONF_DIR / "xfce4/terminal/terminalrc"


def xfce_get():
    # BackgroundDarkness is the opacity, but only honoured in TRANSPARENT mode.
    return num(get_key(xfce_conf(), "BackgroundDarkness", "Configuration")), "restart", ""


def xfce_set(v):
    conf = xfce_conf()
    put_key(conf, "BackgroundMode",
            "TERMINAL_BACKGROUND_TRANSPARENT" if v < 1.0 else "TERMINAL_BACKGROUND_SOLID",
            "Configuration", sep="=")
    put_key(conf, "BackgroundDarkness", f"{v:.2f}", "Configuration", sep="=")


# name shown in the UI, plus its get/set pair. Anything not in here reports
# support=none, which greys the slider out rather than lying about it.
ADAPTERS = {
    "kitty":          ("kitty",           kitty_get,     kitty_set),
    "alacritty":      ("Alacritty",       alacritty_get, alacritty_set),
    "foot":           ("foot",            foot_get,      foot_set),
    "footclient":     ("foot",            foot_get,      foot_set),
    "ghostty":        ("Ghostty",         ghostty_get,   ghostty_set),
    "wezterm":        ("WezTerm",         wezterm_get,   wezterm_set),
    "wezterm-gui":    ("WezTerm",         wezterm_get,   wezterm_set),
    "konsole":        ("Konsole",         konsole_get,   konsole_set),
    "gnome-terminal": ("GNOME Terminal",  gnome_get,     gnome_set),
    "xfce4-terminal": ("Xfce Terminal",   xfce_get,      xfce_set),
}


# ───────────────────── wallpaper-aware transparency ─────────────────────────
# The slider alone can't win on every wallpaper: the setting that looks best over
# a dark photo leaves white terminal text unreadable over a bright one. So the
# slider is a FLOOR — the most see-through you ever want, which is what you get
# on a dark wallpaper — and a bright wallpaper lifts opacity off it. Auto only
# ever makes the terminal MORE opaque, never more transparent than you asked.
STATE = CONF_DIR / "hypr/terminal-opacity.conf"

# Luminance either side of which nothing more happens: at or below DARK you get
# the floor exactly, at or above BRIGHT you get the full lift.
#
# All three are overridable from terminal-opacity.conf (LUMA_DARK / LUMA_BRIGHT
# / MAX_LIFT) so the response can be tuned without editing code.
LUMA_DARK   = 0.20
# Where the lift maxes out. Everything above this gets identical treatment, so
# set too low it flattens: a merely-bright wallpaper and a blinding one both
# land on the ceiling and the terminal looks arbitrarily dark on the first one.
LUMA_BRIGHT = 0.85
# How far toward fully opaque the brightest wallpaper is allowed to push. Not
# 1.0 — a terminal that goes solid isn't the look anyone set transparency for.
MAX_LIFT    = 0.70


def read_state() -> dict:
    out = {}
    try:
        for line in STATE.read_text().splitlines():
            k, _, v = line.partition("=")
            if _:
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


# What the background BEHIND the text should read at. White text needs roughly
# this or darker to stay comfortably legible (about a 4.5:1 contrast ratio).
TARGET_LUMA = 0.18
DEADBAND    = 0.02   # ignore smaller errors, or it never stops nudging
GAIN        = 1.2    # correction per unit of error; >1 converges in a step or two


def terminal_backdrop() -> float | None:
    """How bright the terminal actually LOOKS on screen right now, 0..1.

    Measures the composited result rather than the wallpaper file, because the
    wallpaper is only sometimes what's behind the window. A white browser page
    under a see-through terminal makes the text unreadable no matter how dark
    the wallpaper is, and reading the wallpaper can't see that. This can.

    Uses the 25th percentile, not the mean: the terminal's own text is bright and
    would drag a mean upward, but the lower quartile of a text screen is the gaps
    BETWEEN the glyphs, which is exactly the background we're trying to judge.

    Takes the brightest window when several are open — opacity is one setting for
    all of them, so the worst case is the one that has to stay readable."""
    try:
        cl = json.loads(subprocess.run(["hyprctl", "clients", "-j"],
                                       capture_output=True, text=True, timeout=5).stdout)
        ws = json.loads(subprocess.run(["hyprctl", "activeworkspace", "-j"],
                                       capture_output=True, text=True, timeout=5).stdout)["id"]
    except Exception:
        return None

    term = Path(default_term()).name
    worst = None
    for c in cl:
        if c.get("workspace", {}).get("id") != ws or c.get("hidden") or not c.get("mapped"):
            continue
        if c.get("class", "").lower() != term.lower():
            continue
        x, y = c["at"]; w, h = c["size"]
        if w < 80 or h < 80:
            continue
        # Inset so the glass rim and border don't skew it.
        geo = f"{x + 20},{y + 20} {w - 40}x{h - 40}"
        try:
            from PIL import Image
            tmp = "/tmp/.tc-termshot.png"
            subprocess.run(["grim", "-g", geo, "-t", "png", tmp],
                           capture_output=True, timeout=5, check=True)
            with Image.open(tmp) as im:
                im = im.convert("L")
                im.thumbnail((200, 200))
                px = sorted(im.getdata())
        except Exception:
            continue
        if not px:
            continue
        p25 = px[len(px) // 4] / 255.0
        if worst is None or p25 > worst:
            worst = p25
    return worst


def wallpaper_luma() -> float | None:
    """Mean perceived brightness of the current wallpaper, 0..1.

    The MEAN rather than a peak on purpose: what sits behind the text is the
    blurred backdrop, and blurring is averaging. A small bright highlight that a
    peak statistic would panic about is smeared into its surroundings before you
    ever read text over it."""
    try:
        path = Path("/tmp/wallpaper-current-path").read_text().strip()
    except OSError:
        return None
    if not path or not Path(path).exists():
        return None
    try:
        from PIL import Image
        with Image.open(path) as im:
            im = im.convert("RGB")
            im.thumbnail((160, 160))          # plenty for a mean, and fast
            px = list(im.getdata())
    except Exception:
        return None
    if not px:
        return None
    # Same coefficients as wallpaper-colors.py's perceived_brightness, so the
    # two agree about what "bright" means.
    return sum(0.299 * r + 0.587 * g + 0.114 * b for r, g, b in px) / (255.0 * len(px))


def effective_opacity(floor: float, auto: bool, luma: float | None) -> float:
    if not auto or luma is None:
        return floor
    st = read_state()
    def tune(key, default):
        try:
            return float(st.get(key, default))
        except (TypeError, ValueError):
            return default
    dark, bright, lift_max = tune("LUMA_DARK", LUMA_DARK), tune("LUMA_BRIGHT", LUMA_BRIGHT), tune("MAX_LIFT", MAX_LIFT)
    if bright <= dark:
        return floor
    lift = (luma - dark) / (bright - dark)
    lift = max(0.0, min(1.0, lift))
    # Ease it. A straight ramp puts most of the movement in the middle of the
    # range, which is where most wallpapers actually sit — so near-identical
    # wallpapers came out visibly different. Smoothstep flattens the middle and
    # pushes the change out to the extremes, where it belongs.
    lift = lift * lift * (3.0 - 2.0 * lift)
    return min(1.0, floor + (1.0 - floor) * lift * lift_max)


# A wallpaper switch takes ~1.5s end to end, so ramp the terminal across most of
# it instead of snapping. Steps are deliberately few: for kitty each one rewrites
# the config and signals a reload, and sixty of those in a second is a stutter,
# not a fade.
RAMP_MS    = 1200
RAMP_STEPS = 16


def ramp_to(term_entry, start: float, target: float, support: str, ms: int) -> None:
    """Walk the terminal from start to target on a smoothstep curve. Single step
    for terminals that can't change live, or when there's nothing to cover."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if support != "live" or abs(target - start) <= 0.01 or ms <= 0:
            term_entry[2](target)
            return
        for i in range(1, RAMP_STEPS + 1):
            t = i / RAMP_STEPS
            t = t * t * (3.0 - 2.0 * t)              # no abrupt start/stop
            term_entry[2](start + (target - start) * t)
            if i < RAMP_STEPS:
                time.sleep(ms / 1000.0 / RAMP_STEPS)


def publish(applied: float, floor: float, auto: bool, luma: float | None) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".conf.tc-tmp")
    # Carry the hand-tuned curve keys through. This file is rewritten on every
    # apply, so anything not copied here is silently lost the next time you move
    # the slider — which would make them look like they don't work.
    prev = read_state()
    extra = "".join(f"{k}={prev[k]}\n"
                    for k in ("LUMA_DARK", "LUMA_BRIGHT", "MAX_LIFT", "TARGET") if k in prev)
    tmp.write_text(f"OPACITY={applied:.2f}\nFLOOR={floor:.2f}\nAUTO={1 if auto else 0}\n"
                   f"LUMA={-1 if luma is None else luma:.3f}\n" + extra)
    tmp.replace(STATE)


def apply_and_publish(term_entry, floor: float, auto: bool, ramp: bool = False) -> float:
    """Work out the opacity this wallpaper needs, push it to the terminal, and
    publish it for the bar. Returns what was applied."""
    luma = wallpaper_luma()
    applied = effective_opacity(floor, auto, luma)
    if term_entry is not None:
        start, support, _ = term_entry[1]()
        ramp_to(term_entry, start, applied, support, RAMP_MS if ramp else 0)
    # OPACITY is the applied value — that's what the bar's pills match. FLOOR and
    # AUTO are the intent, so a wallpaper change can recompute without the UI.
    publish(applied, floor, auto, luma)
    return applied


def default_term() -> str:
    conf = CONF_DIR / "hypr/terminal.conf"
    m = re.search(r"^\s*\$terminal\s*=\s*(\S+)", conf.read_text(), re.M) if conf.exists() else None
    return (m.group(1) if m else "kitty").strip()


def main() -> int:
    args = sys.argv[1:]
    term = None
    if "--term" in args:
        i = args.index("--term")
        term = args[i + 1] if i + 1 < len(args) else None
        del args[i:i + 2]
    if not args:
        print("usage: terminal-opacity.py get|set <0.0-1.0> [--term NAME]", file=sys.stderr)
        return 2

    term = (term or default_term()).strip()
    key = Path(term).name          # the picker stores a bare command, but be safe
    entry = ADAPTERS.get(key)

    if args[0] == "get":
        if entry is None:
            # No note: the UI already says "<name> has no transparency setting
            # Technicolor can drive". A note is for the cases where there IS a
            # specific reason worth naming.
            print(f"term={key}\nname={key}\nopacity=1.00\nsupport=none\nnote=")
            return 0
        name, get, _ = entry
        opacity, support, note = get()
        print(f"term={key}\nname={name}\nopacity={opacity:.2f}\nsupport={support}\nnote={note}")
        return 0

    if args[0] == "set":
        if len(args) < 2:
            print("set needs a value", file=sys.stderr)
            return 2
        if entry is None:
            return 0
        v = max(0.0, min(1.0, float(args[1])))
        st = read_state()
        apply_and_publish(entry, v, st.get("AUTO", "0") == "1")
        return 0

    if args[0] == "auto":
        # Turn wallpaper-adaptive opacity on or off, keeping the floor.
        on = len(args) > 1 and args[1] in ("1", "on", "true", "yes")
        st = read_state()
        floor = float(st.get("FLOOR", st.get("OPACITY", "1.0")))
        apply_and_publish(entry, floor, on)
        return 0

    if args[0] == "autotune":
        # One correction step from what the terminal actually looks like. Called
        # on a timer by the bar and after a wallpaper change.
        st = read_state()
        if st.get("AUTO", "0") != "1" or entry is None:
            return 0
        floor = float(st.get("FLOOR", st.get("OPACITY", "1.0")))
        try:
            target = float(st.get("TARGET", TARGET_LUMA))
            max_lift = float(st.get("MAX_LIFT", MAX_LIFT))
        except ValueError:
            target, max_lift = TARGET_LUMA, MAX_LIFT

        measured = terminal_backdrop()
        if measured is None:
            # Nothing on screen to measure — fall back to judging the wallpaper.
            apply_and_publish(entry, floor, True, ramp=True)
            return 0

        current, support, _ = entry[1]()
        err = measured - target
        if abs(err) < DEADBAND:
            return 0
        ceiling = min(1.0, floor + (1.0 - floor) * max_lift)
        want = max(floor, min(ceiling, current + GAIN * err))
        if abs(want - current) < 0.01:
            return 0
        ramp_to(entry, current, want, support,
                RAMP_MS if len(args) > 1 and args[1] == "--slow" else 400)
        publish(want, floor, True, measured)
        return 0

    if args[0] == "refresh":
        # Called after a wallpaper change: same floor, new wallpaper, new answer.
        st = read_state()
        if st.get("AUTO", "0") != "1":
            return 0
        floor = float(st.get("FLOOR", st.get("OPACITY", "1.0")))
        apply_and_publish(entry, floor, True, ramp=True)
        return 0

    if args[0] == "state":
        st = read_state()
        luma = wallpaper_luma()
        floor = float(st.get("FLOOR", st.get("OPACITY", "1.0")))
        auto = st.get("AUTO", "0") == "1"
        print(f"floor={floor:.2f}\nauto={1 if auto else 0}\n"
              f"luma={-1 if luma is None else luma:.3f}\n"
              f"applied={effective_opacity(floor, auto, luma):.2f}")
        return 0

    print(f"unknown command: {args[0]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
