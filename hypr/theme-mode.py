#!/usr/bin/env python3
"""theme-mode.py — Technicolor's light/dark mode (Settings → Colors → Appearance).

AUTO follows Android's Dark theme "sunset to sunrise" schedule. The sun math
below is a line-for-line port of what Android itself runs (AOSP
TwilightService.calculateTwilightState and the ICU 74 CalendarAstronomer copy
system_server links), quirks included: it can be ~5 min off the true sunset,
and so is the phone. Same location + same time zone = the desktop switches at
the moment the phone's schedule does. (Android then holds the change until the
phone's screen next turns off; the desktop doesn't wait.) Fully offline.

  theme-mode.py now             light|dark, right now
  theme-mode.py status          JSON for Settings: mode, next switch, location
  theme-mode.py set K=V ...     update theme-mode.conf, print status, apply
  theme-mode.py apply           push the current mode to the system
  theme-mode.py daemon          keep the system in the current mode (login)
  theme-mode.py cities QUERY    offline city search (theme-mode-cities.tsv)
  theme-mode.py tuning [MODE]   the color-tuning file a mode reads
  theme-mode.py tune MODE K=V   set color-tuning keys for a mode (K= removes)

Config: ~/.config/hypr/theme-mode.conf, written by Settings (see the .example).
"""
import fcntl
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

HYPR = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
CONF = os.path.join(HYPR, "theme-mode.conf")
CITIES = os.path.join(HYPR, "theme-mode-cities.tsv")
RUN = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE = os.path.join(RUN, "technicolor-mode")        # the mode last pushed to the system
LOCK = os.path.join(RUN, "technicolor-mode.lock")
DAEMON_LOCK = os.path.join(RUN, "technicolor-mode-daemon.lock")

# Settings → Colors sliders, one set per mode. Dark keeps the file that existed
# before light/dark mode; light gets its own on its first edit and reads dark's
# until then — so it starts as a copy.
TUNING = os.path.join(HYPR, "color-tuning.conf")
TUNING_LIGHT = os.path.join(HYPR, "color-tuning-light.conf")

# MODE defaults to dark: Technicolor ran dark before this existed, so an update
# changes nothing until Auto/Custom/Light is picked in Settings.
DEFAULTS = {"MODE": "dark", "CITY": "", "LAT": "", "LON": "",
            "LIGHT_AT": "06:00", "DARK_AT": "22:00"}   # Android's custom-schedule defaults


# ── Android's sunrise/sunset ────────────────────────────────────────────────
# Port of external/icu android_icu4j/src/icu74/.../CalendarAstronomer.java
# (getSunRiseSet, riseOrSet, lstToUT, getSiderealOffset, getSunLongitude,
# trueAnomaly, eclipticObliquity, eclipticToEquatorial) with Java's long/double
# semantics, and TwilightService.calculateTwilightState. Don't "fix" anything
# here: matching the phone means matching its quirks.
_LMAX = (1 << 63) - 1
_LMIN = -(1 << 63)


def _jlong(x):
    """Java (long) cast of a double: truncate toward zero, NaN -> 0, saturate."""
    if x != x:
        return 0
    if x >= 9.223372036854776e18:
        return _LMAX
    if x <= -9.223372036854776e18:
        return _LMIN
    return int(x)


def _jdiv(a, b):
    """Java long division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def _jacos(x):
    return math.acos(x) if -1.0 <= x <= 1.0 else float("nan")


def _jasin(x):
    return math.asin(x) if -1.0 <= x <= 1.0 else float("nan")


PI = 3.14159265358979323846
PI2 = PI * 2.0
DEG_RAD = PI / 180
RAD_DEG = 180 / PI
TROPICAL_YEAR = 365.242191
SECOND_MS = 1000
MINUTE_MS = 60 * SECOND_MS
HOUR_MS = 60 * MINUTE_MS
DAY_MS = 24 * HOUR_MS
JULIAN_EPOCH_MS = -210866760000000
JD_EPOCH = 2447891.5                      # Jan 0.0 1990
SUN_ETA_G = 279.403303 * PI / 180         # ecliptic longitude at epoch
SUN_OMEGA_G = 282.768422 * PI / 180       # ecliptic longitude of perigee
SUN_E = 0.016713                          # eccentricity
SUN_DIAMETER = .533 * DEG_RAD             # getSunRiseSet: "Angular Diameter"
SUN_REFRACTION = 34 / 60.0 * DEG_RAD      # getSunRiseSet: "Refraction correction"
RISESET_EPSILON = MINUTE_MS // 12         # 5000 ms, max 5 iterations


def _normalize(value, rng):
    if value != value:  # Java Math.floor(NaN) == NaN (polar day/night path)
        return value
    return value - rng * math.floor(value / rng)


def _norm2pi(a):
    return _normalize(a, PI2)


def _normpi(a):
    return _normalize(a + PI, PI2) - PI


def _true_anomaly(mean_anomaly, e):
    E = mean_anomaly
    while True:
        delta = E - e * math.sin(E) - mean_anomaly
        E = E - delta / (1 - e * math.cos(E))
        if not abs(delta) > 1e-5:
            break
    return 2.0 * math.atan(math.tan(E / 2) * math.sqrt((1 + e) / (1 - e)))


class _CalendarAstronomer:
    def __init__(self, longitude, latitude):
        self.time = 0
        self.lon = _normpi(longitude * DEG_RAD)
        self.lat = _normpi(latitude * DEG_RAD)
        self.gmt_offset = _jlong(self.lon * 24 * HOUR_MS / PI2)

    def _julian_day(self):
        return float(self.time - JULIAN_EPOCH_MS) / float(DAY_MS)

    def _sidereal_offset(self):
        JD = math.floor(self._julian_day() - 0.5) + 0.5
        S = JD - 2451545.0
        T = S / 36525.0
        return _normalize(6.697374558 + 2400.051336 * T + 0.000025862 * T * T, 24)

    def _obliquity(self):
        T = (self._julian_day() - 2451545.0) / 36525
        o = (23.439292
             - 46.815 / 3600 * T
             - 0.0006 / 3600 * T * T
             + 0.00181 / 3600 * T * T * T)
        return o * DEG_RAD

    def _sun_longitude(self):
        day = self._julian_day() - JD_EPOCH
        epoch_angle = _norm2pi(PI2 / TROPICAL_YEAR * day)
        mean_anomaly = _norm2pi(epoch_angle + SUN_ETA_G - SUN_OMEGA_G)
        return _norm2pi(_true_anomaly(mean_anomaly, SUN_E) + SUN_OMEGA_G)

    def _sun_position(self):
        """eclipticToEquatorial(getSunLongitude(), 0) -> (ascension, declination)."""
        L = self._sun_longitude()
        obliq = self._obliquity()
        sinE, cosE = math.sin(obliq), math.cos(obliq)
        sinL, cosL = math.sin(L), math.cos(L)
        sinB, cosB, tanB = 0.0, 1.0, 0.0
        return (math.atan2(sinL * cosE - tanB * sinE, cosL),
                _jasin(sinB * cosE + cosB * sinE * sinL))

    def _lst_to_ut(self, lst):
        lt = _normalize((lst - self._sidereal_offset()) * 0.9972695663, 24)
        base = DAY_MS * _jdiv(self.time + self.gmt_offset, DAY_MS) - self.gmt_offset
        return base + _jlong(lt * HOUR_MS)

    def _rise_or_set(self, rise, diameter, refraction, epsilon):
        tanL = math.tan(self.lat)
        count = 0
        while True:
            asc, dec = self._sun_position()
            angle = _jacos(-tanL * math.tan(dec))
            lst = ((PI2 - angle if rise else angle) + asc) * 24 / PI2
            new_time = self._lst_to_ut(lst)
            delta_t = new_time - self.time
            self.time = new_time
            count += 1
            if not (count < 5 and abs(delta_t) > epsilon):
                break
        cosD = math.cos(dec)
        psi = _jacos(math.sin(self.lat) / cosD)
        x = diameter / 2 + refraction
        y = _jasin(math.sin(x) / math.sin(psi))
        delta = _jlong((240 * y * RAD_DEG / cosD) * SECOND_MS)
        return self.time + (-delta if rise else delta)

    def get_sun_rise_set(self, rise):
        t0 = self.time
        noon = _jdiv(self.time + self.gmt_offset, DAY_MS) * DAY_MS - self.gmt_offset + 12 * HOUR_MS
        self.time = noon + (-6 if rise else 6) * HOUR_MS
        t = self._rise_or_set(rise, SUN_DIAMETER, SUN_REFRACTION, RISESET_EPSILON)
        self.time = t0
        return t


def _local_noon_ms(now_ms, tz, add_days=0):
    d = datetime.fromtimestamp(now_ms / 1000, tz).date() + timedelta(days=add_days)
    return int(datetime(d.year, d.month, d.day, 12, 0, 0, tzinfo=tz).timestamp()) * 1000


def calculate_twilight_state(lat, lon, now_ms, tz):
    """(sunrise_ms, sunset_ms) exactly as TwilightService computes them; it is
    night when sunset <= now < sunrise. tz picks local noon (the phone's zone)."""
    ca = _CalendarAstronomer(lon, lat)
    ca.time = _local_noon_ms(now_ms, tz)
    sunrise = ca.get_sun_rise_set(True)
    sunset = ca.get_sun_rise_set(False)
    if sunset < now_ms:
        ca.time = _local_noon_ms(now_ms, tz, +1)
        sunrise = ca.get_sun_rise_set(True)
    elif sunrise > now_ms:
        ca.time = _local_noon_ms(now_ms, tz, -1)
        sunset = ca.get_sun_rise_set(False)
    return sunrise, sunset


# ── time zone, location, config ─────────────────────────────────────────────
def local_tz():
    """(zone, IANA name) of the system clock — DST-aware, name "" if unknown."""
    name = os.environ.get("TZ", "").lstrip(":")
    if not name:
        try:
            link = os.readlink("/etc/localtime")
            name = link.split("zoneinfo/", 1)[1] if "zoneinfo/" in link else ""
        except OSError:
            name = ""
    if name:
        try:
            return ZoneInfo(name), name
        except Exception:
            pass
    try:
        with open("/etc/localtime", "rb") as f:
            return ZoneInfo.from_file(f), ""
    except OSError:
        return timezone.utc, ""


def _dms(s, deg_digits):
    sign = -1 if s[0] == "-" else 1
    s = s[1:]
    d, m, sec = int(s[:deg_digits]), int(s[deg_digits:deg_digits + 2]), int(s[deg_digits + 2:] or 0)
    return sign * (d + m / 60 + sec / 3600)


def zone_location(name, tabs=("/usr/share/zoneinfo/zone.tab", "/usr/share/zoneinfo/zone1970.tab")):
    """(lat, lon, city) of a time zone's own city, from tzdata's tables, or None."""
    for tab in tabs:
        try:
            with open(tab, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#"):
                        continue
                    p = line.rstrip("\n").split("\t")
                    if len(p) >= 3 and p[2] == name:
                        m = re.match(r"([+-]\d+)([+-]\d+)$", p[1])
                        if m:
                            return (_dms(m.group(1), 2), _dms(m.group(2), 3),
                                    name.rsplit("/", 1)[-1].replace("_", " "))
        except OSError:
            continue
    return None


def load_conf(path=CONF):
    conf = dict(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#") and "=" in s:
                    k, v = s.split("=", 1)
                    if k.strip() in conf:
                        conf[k.strip()] = v.strip()
    except OSError:
        pass
    if conf["MODE"] not in ("auto", "custom", "light", "dark"):
        conf["MODE"] = DEFAULTS["MODE"]
    return conf


def set_conf(pairs, path=CONF):
    """Update some keys, keep the rest (the file is rewritten whole)."""
    present = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#") and "=" in s:
                    k, v = s.split("=", 1)
                    present[k.strip()] = v.strip()
    except OSError:
        pass
    for k, v in pairs.items():
        if k not in DEFAULTS:
            raise ValueError("unknown key: %s" % k)
        present[k] = v.replace("\n", " ").strip()
    body = "# Written by Settings → Colors → Appearance (theme-mode.py).\n"
    body += "".join("%s=%s\n" % (k, present[k]) for k in DEFAULTS if k in present)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, path)


def location(conf, tzname):
    """(lat, lon, label, source): the picked city, else the time zone's city
    (source "timezone"), else None."""
    try:
        lat, lon = float(conf["LAT"]), float(conf["LON"])
        return lat, lon, conf["CITY"] or "%.4f, %.4f" % (lat, lon), "city"
    except ValueError:
        pass
    z = zone_location(tzname) if tzname else None
    return (z[0], z[1], z[2], "timezone") if z else None


def _minutes(hhmm, fallback):
    m = re.match(r"^\s*(\d{1,2}):(\d{2})\s*$", hhmm or "")
    if m and int(m.group(1)) < 24 and int(m.group(2)) < 60:
        return int(m.group(1)) * 60 + int(m.group(2))
    return fallback


def schedule(now, conf, tz, tzname):
    """(mode now, next mode, next switch in epoch seconds); the next two are
    None for the fixed modes."""
    mode = conf["MODE"]
    if mode in ("light", "dark"):
        return mode, None, None
    loc = location(conf, tzname) if mode == "auto" else None
    if loc:
        rise, set_ = calculate_twilight_state(loc[0], loc[1], int(now * 1000), tz)
        if set_ <= now * 1000 < rise:
            return "dark", "light", rise / 1000
        return "light", "dark", set_ / 1000
    # Custom times — also AUTO's fallback when no location is known at all.
    dark_m, light_m = _minutes(conf["DARK_AT"], 22 * 60), _minutes(conf["LIGHT_AT"], 6 * 60)
    if dark_m == light_m:
        return "light", None, None
    local = datetime.fromtimestamp(now, tz)
    cur = local.hour * 60 + local.minute
    dark = (cur >= dark_m or cur < light_m) if dark_m > light_m else (dark_m <= cur < light_m)
    target = light_m if dark else dark_m
    for add in (0, 1, 2):
        d = local.date() + timedelta(days=add)
        t = datetime(d.year, d.month, d.day, target // 60, target % 60, tzinfo=tz).timestamp()
        if t > now:
            return ("dark" if dark else "light"), ("light" if dark else "dark"), t
    return ("dark" if dark else "light"), None, None


def _fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold())
                   if not unicodedata.combining(c))


def cities(query, limit=8, path=CITIES):
    """Biggest cities whose name starts with the query; "name, region" narrows
    by region or country."""
    parts = [_fold(p.strip()) for p in query.split(",")]
    q, rest = parts[0], [p for p in parts[1:] if p]
    if not q:
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                continue
            name, ascii_, region, country = p[0], p[1], p[2], p[3]
            if not (_fold(name).startswith(q) or (ascii_ and _fold(ascii_).startswith(q))):
                continue
            if rest and not all(_fold(region).startswith(r) or _fold(country).startswith(r) for r in rest):
                continue
            out.append({"name": name, "region": region, "country": country,
                        "lat": float(p[4]), "lon": float(p[5])})
            if len(out) >= limit:
                break
    return out


def mode_now():
    tz, tzname = local_tz()
    return schedule(time.time(), load_conf(), tz, tzname)[0]


# ── per-mode color tuning (Settings → Colors) ──────────────────────────────
def tuning_path(mode=None, tuning=TUNING, tuning_light=TUNING_LIGHT):
    """The color-tuning file a mode reads (None = right now)."""
    mode = mode or os.environ.get("TECHNICOLOR_MODE") or mode_now()
    return tuning_light if mode == "light" and os.path.exists(tuning_light) else tuning


_TUNE_KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
_TUNE_VAL = re.compile(r"^-?[0-9]*\.?[0-9]*$")


def tune(mode, pairs, tuning=TUNING, tuning_light=TUNING_LIGHT):
    """Set some color-tuning keys for one mode and keep every other line (the
    old Settings writer rewrote the file with just the four globals and lost
    the per-surface ones). An empty value removes the key."""
    if mode not in ("light", "dark"):
        raise ValueError("mode must be light or dark: %r" % mode)
    for k, v in pairs.items():
        if not _TUNE_KEY.match(k) or not _TUNE_VAL.match(v):
            raise ValueError("bad tuning value: %s=%s" % (k, v))
    path = tuning_light if mode == "light" else tuning
    if mode == "light" and not os.path.exists(path):
        try:
            shutil.copyfile(tuning, path)
        except OSError:
            pass
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    out, done = [], set()
    for line in lines:
        s = line.strip()
        k = s.split("=", 1)[0].strip() if "=" in s and not s.startswith("#") else None
        if k in pairs:
            if k not in done and pairs[k] != "":
                out.append("%s=%s" % (k, pairs[k]))
            done.add(k)
            continue
        out.append(line)
    out += ["%s=%s" % (k, v) for k, v in pairs.items() if k not in done and v != ""]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("".join(l + "\n" for l in out))
    os.replace(tmp, path)


def recolor():
    """Rebuild the palette + every app theme for the wallpaper on screen."""
    try:
        with open("/tmp/wallpaper-current-path", encoding="utf-8") as f:
            wp = f.read().strip()
    except OSError:
        wp = ""
    cmds = [[sys.executable, os.path.join(HYPR, "wallpaper-colors.py"), wp]] if wp else []
    cmds.append([os.path.join(HOME, ".config/quickshell/notif-theme-mako.sh")])
    for c in cmds:
        try:
            subprocess.run(c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            pass


# ── the system's light/dark signal ──────────────────────────────────────────
def icon_installed(name):
    dirs = [os.path.join(HOME, ".local/share/icons"), os.path.join(HOME, ".icons")]
    dirs += [os.path.join(d, "icons")
             for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")]
    return any(os.path.isfile(os.path.join(d, name, "index.theme")) for d in dirs)


def icon_for(name, mode, installed=icon_installed):
    """The icon theme's light or dark sibling (Papirus-Dark <-> Papirus-Light,
    Fluent-dark <-> Fluent-light) when it's installed, else the same theme."""
    for dark, light in (("-dark", "-light"), ("-Dark", "-Light")):
        frm, to = (dark, light) if mode == "light" else (light, dark)
        if name.endswith(frm):
            cand = name[:-len(frm)] + to
            return cand if installed(cand) else name
    return name


def _key_re(key):
    return re.compile(r"\s*%s\s*=" % re.escape(key))


def get_key(text, key, section=None):
    cur = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
        elif (section is None or cur == section) and _key_re(key).match(line):
            return line.split("=", 1)[1].strip()
    return ""


def set_key(text, key, value, section=None):
    """Replace `key=...` (inside [section] if given); text unchanged if absent."""
    out, cur = [], None
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
        elif (section is None or cur == section) and _key_re(key).match(line):
            line = "%s=%s%s" % (key, value, "\n" if line.endswith("\n") else "")
        out.append(line)
    return "".join(out)


def _swap_icon(text, key, mode, section=None):
    v = get_key(text, key, section)
    return set_key(text, key, icon_for(v, mode), section) if v else text


def _rewrite(path, fn):
    """Edit a file in place through fn, only if that changes it; keeps its mode."""
    path = os.path.realpath(path)
    try:
        with open(path, encoding="utf-8") as f:
            old = f.read()
        st = os.stat(path)
    except OSError:
        return
    new = fn(old)
    if new == old:
        return
    tmp = path + ".theme-mode-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)


def _gsettings(*args):
    try:
        r = subprocess.run(["gsettings", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip().strip("'") if r.returncode == 0 else None


def scheme_for(mode):
    return "prefer-dark" if mode == "dark" else "prefer-light"


def apply_signals(mode):
    """Tell apps: gsettings color-scheme is what the settings portal reports
    (GTK4, Qt 6, Brave, Electron). Icon themes swap to their light/dark sibling,
    each file keeping its own pick. nwg-look's saved copy is updated too —
    `nwg-look -a` re-applies it at every login and would undo all of this."""
    scheme = scheme_for(mode)
    _gsettings("set", "org.gnome.desktop.interface", "color-scheme", scheme)
    icon = _gsettings("get", "org.gnome.desktop.interface", "icon-theme")
    if icon and icon_for(icon, mode) != icon:
        _gsettings("set", "org.gnome.desktop.interface", "icon-theme", icon_for(icon, mode))
    for ini in ("gtk-3.0/settings.ini", "gtk-4.0/settings.ini"):
        _rewrite(os.path.join(HOME, ".config", ini),
                 lambda t: _swap_icon(t, "gtk-icon-theme-name", mode, "Settings"))
    _rewrite(os.path.join(HOME, ".config/kdeglobals"), lambda t: _swap_icon(t, "Theme", mode, "Icons"))
    _rewrite(os.path.join(HOME, ".local/share/nwg-look/gsettings"),
             lambda t: set_key(_swap_icon(t, "icon-theme", mode), "color-scheme", scheme))


def nudge_wallpaper():
    """Wake wallpaper-timer.sh, which owns what a switch does to the wallpaper
    and the colors (it knows about pause and fullscreen), so it acts now
    instead of on its next 15 s tick."""
    try:
        with open(os.path.join(RUN, "wallpaper-timer.pid"), encoding="utf-8") as f:
            pid = int(f.read().strip())
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            if b"wallpaper-timer.sh" in f.read():
                os.kill(pid, signal.SIGUSR1)
    except (OSError, ValueError):
        pass


def read_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def apply(mode):
    """Push the mode to the system, then hand the wallpaper + palette side to
    wallpaper-timer.sh."""
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        prev = read_state()
        apply_signals(mode)
        with open(STATE, "w", encoding="utf-8") as f:
            f.write(mode + "\n")
    if prev != mode:
        nudge_wallpaper()


def status():
    tz, tzname = local_tz()
    conf = load_conf()
    mode, next_mode, nxt = schedule(time.time(), conf, tz, tzname)
    loc = location(conf, tzname)
    return {"setting": conf["MODE"], "mode": mode, "next_mode": next_mode,
            "next": int(nxt) if nxt else None,
            "location": loc[2] if loc else "", "location_source": loc[3] if loc else "none",
            "light_at": conf["LIGHT_AT"], "dark_at": conf["DARK_AT"]}


def daemon():
    lk = open(DAEMON_LOCK, "w")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # already running: hyprland.lua re-runs its exec lines on every reload
    while True:
        wait = 30.0
        try:
            # Never set up in Settings: leave the system's own light/dark
            # setting and icon theme exactly as they are.
            if not os.path.exists(CONF):
                time.sleep(wait)
                continue
            tz, tzname = local_tz()
            mode, _, nxt = schedule(time.time(), load_conf(), tz, tzname)
            prev = read_state()
            scheme = _gsettings("get", "org.gnome.desktop.interface", "color-scheme")
            if mode != prev or (scheme is not None and scheme != scheme_for(mode)):
                apply(mode)
            # Wake right after the next switch; the 30 s cap re-checks the clock
            # anyway, so suspend, time zone changes and conf edits need nothing else.
            if nxt is not None:
                wait = min(30.0, max(1.0, nxt - time.time() + 0.5))
        except Exception as e:  # keep running; a bad tick must not end the schedule
            print("theme-mode: %s" % e, file=sys.stderr, flush=True)
        time.sleep(wait)


def main(argv):
    cmd = argv[0] if argv else "now"
    if cmd == "now":
        tz, tzname = local_tz()
        print(schedule(time.time(), load_conf(), tz, tzname)[0])
    elif cmd == "status":
        print(json.dumps(status()))
    elif cmd in ("apply", "set"):
        if cmd == "set":
            set_conf(dict(a.split("=", 1) for a in argv[1:] if "=" in a))
            print(json.dumps(status()), flush=True)  # Settings reads this line
        tz, tzname = local_tz()
        apply(schedule(time.time(), load_conf(), tz, tzname)[0])
    elif cmd == "daemon":
        return daemon()
    elif cmd == "cities":
        print(json.dumps(cities(" ".join(argv[1:]))))
    elif cmd == "tuning":
        print(tuning_path(argv[1] if len(argv) > 1 else None))
    elif cmd == "tune":
        mode = argv[1] if len(argv) > 1 else ""
        tune(mode, dict(a.split("=", 1) for a in argv[2:] if "=" in a))
        if mode == mode_now():
            recolor()   # the set on screen changed; the other mode's shows at its switch
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
