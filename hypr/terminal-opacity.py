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
import os
import re
import subprocess
import sys
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
        # The slider writes live while you drag AND once more on release, so two
        # of these can overlap. Serialise them or they interleave mid-rewrite.
        LOCK.parent.mkdir(parents=True, exist_ok=True)
        with open(LOCK, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            entry[2](v)
        return 0

    print(f"unknown command: {args[0]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
