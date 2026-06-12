#!/usr/bin/env python3
"""
gen-discord-theme.py — "Technicolor" Vesktop/Discord themes.

NO-FLASH ARCHITECTURE: Vencord tears down a theme's <style> and rebuilds it on
every file change (that's the default-theme flash, regardless of atomic writes or
inlining). So we split:

  * STRUCTURE themes (technicolor[-blocks|-glass].css): inline midnight + all the
    layout/CSS, referencing colors as var(--tc-*) with built-in DEFAULTS. These
    are palette-INDEPENDENT, so they're written only-if-changed -> never rewritten
    on a wallpaper change -> Vencord never reloads them -> never flash.
  * A tiny COLORS file (technicolor-vars.css): just `html:root { --tc-*: ... }`
    from the current wallpaper palette. THIS is the only thing rewritten per
    wallpaper change. It's tiny, and the structure stays loaded, so at worst the
    colors blip to the structure's defaults for a frame — never default Discord.

Enable the COLORS theme + ONE structure (order doesn't matter: the colors file
uses html:root (higher specificity) so it always wins, and --tc-* is a private
namespace that doesn't fight midnight).

Palette from ~/.config/quickshell/colors.env, via wallpaper-colors.py.
"""
import os
import tempfile
import colorsys

ENV = os.path.expanduser("~/.config/quickshell/colors.env")
TH = os.path.expanduser("~/.config/vesktop/themes")
OUT_VARS = os.path.join(TH, "technicolor-vars.css")
OUT_BLOCKS = os.path.join(TH, "technicolor-blocks.css")
OUT_GRAD = os.path.join(TH, "technicolor.css")
OUT_GLASS = os.path.join(TH, "technicolor-glass.css")
# Colors go to QuickCSS (Vencord updates it live, in place, WITHOUT rebuilding
# themes — so no default-theme flash, unlike any file in the themes folder).
QUICKCSS = os.path.expanduser("~/.config/vesktop/settings/quickCss.css")
QC_START = "/* >>> technicolor colors (auto-generated) >>> */"
QC_END = "/* <<< technicolor colors <<< */"

DARK = (21, 21, 26)
LIGHT = (245, 245, 248)


def _load_midnight():
    try:
        lines = open(os.path.expanduser("~/.config/hypr/midnight-build.css")).read().splitlines()
        return "\n".join(l for l in lines if not l.lstrip().startswith("@import"))
    except Exception:
        return "@import url('https://refact0r.github.io/midnight-discord/build/midnight.css');"


MIDNIGHT = _load_midnight()


def load():
    d = {}
    try:
        for line in open(ENV):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                d[k] = v
    except Exception:
        pass
    return d


def rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def _lin(v):
    v /= 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def rel_lum(c):
    return 0.2126 * _lin(c[0]) + 0.7152 * _lin(c[1]) + 0.0722 * _lin(c[2])


def ink_rgb(c):
    L = rel_lum(c)
    return DARK if (L + 0.05) / 0.05 >= 1.05 / (L + 0.05) else LIGHT


def role_filter(surface):
    return "brightness(0.5) saturate(1.55)" if ink_rgb(surface) == DARK else "brightness(1.7) saturate(1.2)"


def hexs(c):
    return "#{:02x}{:02x}{:02x}".format(*c)


def hsl(c):
    r, g, b = [x / 255.0 for x in c]
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h * 360.0, s * 100.0, l * 100.0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def pb(c):
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255.0


def _shades(t):
    return ["rgba({},{},{},{:.2f})".format(t[0], t[1], t[2], a) for a in (1.0, 0.94, 0.88, 0.62, 0.46)]


def compute_vars(primary, secondary, third, accent):
    P, S, T, A = hexs(primary), hexs(secondary), hexs(third), hexs(accent)
    Ai = hexs(ink_rgb(accent))
    ts = _shades(ink_rgb(secondary))
    tc = _shades(ink_rgb(primary))
    ah, as_, al = hsl(accent)
    ACS = clamp(as_, 52, 95)
    avg = (pb(primary) + pb(secondary)) / 2.0
    glight = avg > 0.52
    frost = (250, 250, 253) if glight else (8, 8, 13)
    st = _shades(DARK if glight else LIGHT)
    rf = "brightness(0.5) saturate(1.55)" if glight else "brightness(1.7) saturate(1.2)"
    ph, ps_, _pl = hsl(primary)
    tl = 0.32 if glight else 0.80
    tsat = clamp(ps_ * 1.15, 45, 100) / 100.0
    _r, _g, _b = colorsys.hls_to_rgb(ph / 360.0, tl, tsat)
    TP = "#{:02x}{:02x}{:02x}".format(int(_r * 255), int(_g * 255), int(_b * 255))

    def fr(a):
        return "rgba({},{},{},{:.2f})".format(frost[0], frost[1], frost[2], a)

    def hv(l):
        return "hsl({:.0f}, {:.0f}%, {}%)".format(ah, ACS, l)

    def hva(l, a):
        return "hsla({:.0f}, {:.0f}%, {}%, {})".format(ah, ACS, l, a)

    return {
        "p": P, "s": S, "t": T, "a": A, "ai": Ai,
        "ts0": ts[0], "ts1": ts[1], "ts2": ts[2], "ts3": ts[3], "ts4": ts[4],
        "tc0": tc[0], "tc1": tc[1], "tc2": tc[2], "tc3": tc[3], "tc4": tc[4],
        "acc1": hv(72), "acc2": hv(65), "acc3": hv(58), "acc4": hv(51), "acc5": hv(45), "accnew": hv(58),
        "hover": hva(60, 0.12), "active": hva(60, 0.20), "active2": hva(60, 0.28),
        "rfp": role_filter(primary), "rfs": role_filter(secondary),
        "tp": TP, "rf": rf,
        "st0": st[0], "st1": st[1], "st2": st[2], "st3": st[3], "st4": st[4],
        "fr04": fr(0.04), "fr07": fr(0.07), "fr10": fr(0.10), "fr12": fr(0.12), "fr14": fr(0.14), "fr18": fr(0.18),
    }


def vars_block(V, selector):
    return selector + " {\n" + "\n".join("  --tc-{}: {};".format(k, v) for k, v in V.items()) + "\n}\n"


DEFAULTS = compute_vars(rgb("#cd9b39"), rgb("#3e71c0"), rgb("#546c8a"), rgb("#758994"))

# filter-string vars can't be registered as <color> (they animate via
# `transition: filter` on the elements instead)
FILTER_KEYS = ("rfp", "rfs", "rf")
FADE = "1.4s ease"


def props_block():
    """Register every color var as a typed <color> property — this is what makes
    them INTERPOLABLE, so palette changes cross-fade instead of snapping."""
    return "\n".join(
        "@property --tc-{} {{ syntax: '<color>'; inherits: true; initial-value: {}; }}".format(k, v)
        for k, v in DEFAULTS.items() if k not in FILTER_KEYS)


def transition_rule():
    keys = [k for k in DEFAULTS if k not in FILTER_KEYS]
    return ("/* elegant palette cross-fade: registered vars interpolate on change */\n"
            "html:root { transition: "
            + ", ".join("--tc-{} {}".format(k, FADE) for k in keys) + "; }")


BLOCKS_LAYER = """
body {
  --font: 'SF Pro'; --code-font: ''; --gap: 12px; --border-thickness: 0px; --custom-dms-icon: off;
}
:root {
  --colors: on;
  /* derived from the ANIMATING color vars -> gradients/highlights morph per-frame */
  --tc-grad: linear-gradient(135deg, var(--tc-p), var(--tc-s));
  --tc-men: linear-gradient(to right, color-mix(in hsl, var(--tc-t), transparent 84%) 40%, transparent);
  --tc-menh: linear-gradient(to right, color-mix(in hsl, var(--tc-t), transparent 90%) 40%, transparent);
  --tc-msgh: color-mix(in hsl, var(--tc-t), transparent 82%);
  --bg-3: var(--tc-p); --bg-4: var(--tc-s); --bg-2: var(--tc-s); --bg-1: var(--tc-s);
  --hover: var(--tc-hover); --active: var(--tc-active); --active-2: var(--tc-active2);
  --channeltextarea-background: var(--tc-s);
  --text-0: var(--tc-ai); --text-1: var(--tc-ts0); --text-2: var(--tc-ts1); --text-3: var(--tc-ts2); --text-4: var(--tc-ts3); --text-5: var(--tc-ts4);
  --text-default: var(--tc-ts2); --text-strong: var(--tc-ts1); --header-primary: var(--tc-ts0); --header-secondary: var(--tc-ts2);
  --text-muted: var(--tc-ts4); --chat-text-muted: var(--tc-ts4); --interactive-normal: var(--tc-ts3); --interactive-text-default: var(--tc-ts3);
  --white-500: var(--tc-ts0); --white: var(--tc-ts0);
  --accent-1: var(--tc-acc1); --accent-2: var(--tc-acc2); --accent-3: var(--tc-acc3); --accent-4: var(--tc-acc4); --accent-5: var(--tc-acc5); --accent-new: var(--tc-accnew);
}
body, .theme-dark:not(.custom-user-profile-theme), .theme-light:not(.custom-user-profile-theme) {
  --text-link: var(--tc-s); --mention-foreground: var(--tc-s);
  --input-background-default: var(--tc-p); --input-text-default: var(--tc-tc2); --input-placeholder-text-default: var(--tc-tc4);
  --background-code: var(--tc-s);
  --mention: var(--tc-men); --mention-hover: var(--tc-menh);
  --message-mentioned-background-default: var(--tc-men); --message-mentioned-background-hover: var(--tc-menh);
  --background-message-highlight: var(--tc-msgh);
}
[class*="chatContent"] {
  --bg-4: var(--tc-p); --bg-2: var(--tc-p); --bg-1: var(--tc-p);
  --background-base-low: var(--tc-p); --background-base-lower: var(--tc-p); --background-base-lowest: var(--tc-p);
  --background-primary: var(--tc-p); --chat-background-default: var(--tc-p);
  background-color: var(--tc-p) !important;
  --text-0: var(--tc-ai); --text-1: var(--tc-tc0); --text-2: var(--tc-tc1); --text-3: var(--tc-tc2); --text-4: var(--tc-tc3); --text-5: var(--tc-tc4);
  --text-default: var(--tc-tc2); --text-strong: var(--tc-tc1); --header-primary: var(--tc-tc0); --header-secondary: var(--tc-tc2);
  --text-muted: var(--tc-tc4); --chat-text-muted: var(--tc-tc4); --interactive-normal: var(--tc-tc3); --interactive-text-default: var(--tc-tc3);
  --white-500: var(--tc-tc0); --white: var(--tc-tc0);
}
[class*="chatContent"] [class*="scroller_"], [class*="chatContent"] [class*="messagesWrapper"] { background-color: var(--tc-p) !important; }
[class*="messagesWrapper"]::before { background: var(--tc-p) !important; }
[class*="chatContent"] [class*="form_"] {
  --bg-4: var(--tc-s); --background-base-lower: var(--tc-s); --background-base-low: var(--tc-s);
  --text-0: var(--tc-ai); --text-1: var(--tc-ts0); --text-2: var(--tc-ts1); --text-3: var(--tc-ts2); --text-4: var(--tc-ts3); --text-5: var(--tc-ts4);
  --text-default: var(--tc-ts2); --text-strong: var(--tc-ts1); --header-primary: var(--tc-ts0); --header-secondary: var(--tc-ts2);
  --text-muted: var(--tc-ts4); --chat-text-muted: var(--tc-ts4); --interactive-normal: var(--tc-ts3); --interactive-text-default: var(--tc-ts3);
  --white-500: var(--tc-ts0); --white: var(--tc-ts0);
  /* links/@mentions are SECONDARY-colored app-wide (contrast vs the primary
     chat) — inside this SECONDARY input box flip them to PRIMARY */
  --text-link: var(--tc-p);
  --mention-foreground: var(--tc-p);
  --mention-background: color-mix(in srgb, var(--tc-p), transparent 82%);
}
[class*="form_"] a, [class*="form_"] [class*="anchor"] { color: var(--tc-p) !important; }
[class*="form_"] [class*="mention"] {
  color: var(--tc-p) !important;
  background-color: color-mix(in srgb, var(--tc-p), transparent 82%) !important;
}
[class*="channelTextArea"] { background-color: var(--tc-s) !important; }
[class*="username"], [class*="nickname"], [class*="roleColor"] { filter: var(--tc-rfp); transition: filter 1.4s ease; }
[class*="membersWrap"] [class*="username"], [class*="members_"] [class*="username"], [class*="membersWrap"] [class*="nickname"], [class*="members_"] [class*="nickname"] { filter: var(--tc-rfs); }
a, [class*="anchor"] { color: var(--tc-s) !important; }
code, [class*="codeBlock"] { color: var(--tc-ts2) !important; }
"""


GRADIENT_LAYER = """
body {
  --font: 'SF Pro'; --code-font: ''; --gap: 12px; --border-thickness: 0px; --custom-dms-icon: off;
  --background-image: on; --background-image-url: var(--tc-grad);
  --panel-blur: on; --blur-amount: 30px; --transparency-tweaks: on;
}
:root {
  --colors: on;
  /* derived from the ANIMATING color vars -> gradients/highlights morph per-frame */
  --tc-grad: linear-gradient(135deg, var(--tc-p), var(--tc-s));
  --tc-men: linear-gradient(to right, color-mix(in hsl, var(--tc-t), transparent 84%) 40%, transparent);
  --tc-menh: linear-gradient(to right, color-mix(in hsl, var(--tc-t), transparent 90%) 40%, transparent);
  --tc-msgh: color-mix(in hsl, var(--tc-t), transparent 82%);
  --bg-4: var(--tc-fr07); --bg-3: var(--tc-fr04); --bg-2: var(--tc-fr12); --bg-1: var(--tc-fr18);
  --hover: var(--tc-hover); --active: var(--tc-active); --active-2: var(--tc-active2);
  --channeltextarea-background: var(--tc-fr10);
  --text-0: var(--tc-ai); --text-1: var(--tc-st0); --text-2: var(--tc-st1); --text-3: var(--tc-st2); --text-4: var(--tc-st3); --text-5: var(--tc-st4);
  --accent-1: var(--tc-acc1); --accent-2: var(--tc-acc2); --accent-3: var(--tc-acc3); --accent-4: var(--tc-acc4); --accent-5: var(--tc-acc5); --accent-new: var(--tc-accnew);
}
body, .theme-dark:not(.custom-user-profile-theme), .theme-light:not(.custom-user-profile-theme) {
  --app-frame-background: transparent;
  --border-subtle: transparent; --border-faint: transparent; --border-normal: transparent; --border-strong: transparent; --border-hover: transparent; --border: transparent; --border-light: transparent;
  --background-code: var(--tc-fr14); --input-background-default: var(--tc-fr12);
  --input-text-default: var(--tc-st2); --input-placeholder-text-default: var(--tc-st4);
  --text-default: var(--tc-st2); --text-strong: var(--tc-st1); --header-primary: var(--tc-st0); --header-secondary: var(--tc-st2);
  --text-muted: var(--tc-st4); --chat-text-muted: var(--tc-st4); --interactive-normal: var(--tc-st3); --interactive-text-default: var(--tc-st3);
  --white-500: var(--tc-st0); --white: var(--tc-st0);
  --text-link: var(--tc-tp); --mention-foreground: var(--tc-tp);
  --mention: var(--tc-men); --mention-hover: var(--tc-menh);
  --message-mentioned-background-default: var(--tc-men); --message-mentioned-background-hover: var(--tc-menh);
  --background-message-highlight: var(--tc-msgh);
}
[class*="chatContent"] [class*="scroller_"], [class*="chatContent"] [class*="messagesWrapper"] { background: transparent !important; }
[class*="messagesWrapper"]::before { background: transparent !important; }
[class*="username"], [class*="nickname"], [class*="roleColor"] { filter: var(--tc-rf); transition: filter 1.4s ease; }
a, [class*="anchor"] { color: var(--tc-tp) !important; }
code, [class*="codeBlock"] { color: var(--tc-st2) !important; }
"""


def header(name, desc):
    return "/**\n * @name {}\n * @description {}\n */\n".format(name, desc)


def struct(name, *layers):
    return (header(name, "Technicolor structure (static). Live colors come from QuickCSS.")
            + MIDNIGHT + "\n"
            + props_block() + "\n"
            + vars_block(DEFAULTS, ":root") + "\n"
            + transition_rule() + "\n"
            + "\n/* @@TC-LAYER@@ */\n" + "\n".join(layers))


def write_atomic(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def write_quickcss(block):
    """Inject the color vars into QuickCSS between markers (preserving any other
    QuickCSS the user has). Vencord applies QuickCSS live with no theme rebuild."""
    section = QC_START + "\n" + block + QC_END + "\n"
    try:
        cur = open(QUICKCSS).read()
    except Exception:
        cur = ""
    if QC_START in cur and QC_END in cur:
        pre = cur.split(QC_START)[0].rstrip("\n")
        post = cur.split(QC_END, 1)[1].lstrip("\n")
        out = (pre + "\n\n" if pre.strip() else "") + section + (post if post.strip() else "")
    else:
        out = (cur.rstrip("\n") + "\n\n" if cur.strip() else "") + section
    # IN-PLACE write, NOT atomic-replace: Vesktop's fs.watch follows the inode,
    # and os.replace swaps in a new inode -> watcher dies -> live updates stop.
    # Same-inode truncate+write keeps the watcher alive. (Safe: tiny file, and
    # the structure themes carry baked default colors as a fallback.)
    with open(QUICKCSS, "w") as f:
        f.write(out)


def write_if_changed(path, data):
    """Only write when content differs — so static structure files are NOT
    touched on a wallpaper change, so Vencord never reloads (never flashes) them."""
    try:
        if open(path).read() == data:
            return
    except Exception:
        pass
    write_atomic(path, data)


def main():
    p = load()
    # primary/secondary = THE BAR'S gradient pair (the only two colors the
    # extractor guarantees distinct — FOCUSED can converge with GRADIENT_END
    # and made themes monochrome). primary = gradient END per user preference.
    primary = rgb(p.get("GRADIENT_END", "#cd9b39"))
    secondary = rgb(p.get("GRADIENT_START", "#3e71c0"))
    third = rgb(p.get("OCCUPIED", "#546c8a"))
    accent = rgb(p.get("VISIBLE", "#758994"))

    # Colors -> QuickCSS (live, no theme rebuild -> no flash). html:root wins over
    # the structures' baked :root defaults regardless of order.
    V = compute_vars(primary, secondary, third, accent)
    write_quickcss(vars_block(V, "html:root"))

    # Same palette as JSON for Spotify (served by technicolor-color-server.py,
    # polled by the technicolor-sync Spicetify extension). Tiny in-place write.
    try:
        import json
        # _wallv = wallpaper version (path+mtime) -> tells the Spotify extension
        # to refresh its wallpaper-background layer (served via /wall)
        try:
            wp = open("/tmp/wallpaper-current-path").read().strip()
            V["_wallv"] = "{}-{}".format(abs(hash(wp)) % 10**8, int(os.path.getmtime(wp)))
        except Exception:
            pass
        rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/{}".format(os.getuid()))
        with open(os.path.join(rt, "technicolor-colors.json"), "w") as f:
            json.dump(V, f)
    except Exception:
        pass

    # static structures — written only-if-changed -> never reloaded on wallpaper change
    write_if_changed(OUT_BLOCKS, struct("Technicolor Blocks", BLOCKS_LAYER))
    write_if_changed(OUT_GRAD, struct("Technicolor", GRADIENT_LAYER))
    write_if_changed(OUT_GLASS, struct("Technicolor Glass", GRADIENT_LAYER, BLOCKS_LAYER))


if __name__ == "__main__":
    main()
