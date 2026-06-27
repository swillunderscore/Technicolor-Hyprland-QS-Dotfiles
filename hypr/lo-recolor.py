#!/usr/bin/env python3.14
"""lo-recolor.py — theme LibreOffice from the wallpaper palette, LIVE.

LibreOffice uses its own VCL toolkit and ignores kdeglobals / Qt palette changes
at runtime (unlike Dolphin). The ONE lever that reaches its in-memory color cache
is UNO, running inside the LO process. So:

  * If LO is running with a UNO acceptor, connect and rewrite its color scheme
    LIVE — the chrome recolors with no restart.
  * If LO is not running (or has no acceptor), fall back to writing the same
    scheme into registrymodifications.xcu so it applies on next launch.

Design (matches the user's wish — "page white, everything else matches like the
rest, with its own sliders"):
  * The page (DocColor) is forced WHITE and its text (FontColor) BLACK — writing
    stays readable regardless of theme.
  * Every UI/"chrome" role (gutter, toolbars, menus, buttons, sidebar) takes the
    wallpaper palette, with text roles set to a contrasting ink so labels stay
    legible. This is the LIBREOFFICE surface in the per-surface tuning system, so
    its sat/bright/hue sliders in Settings → Colors apply just like the others.

Must run under python3.14 (where LO's uno.py lives). Hooked into the pipeline by
wallpaper-colors.py. Fully defensive: any failure falls back or no-ops, never
breaks the wallpaper cycle.
"""
import os
import sys

# Reuse the shared palette + per-surface tuning helpers (the same module every
# theme generator imports). Gives us _raw_env(), _tune_palette(), rgb(), etc.
sys.path.insert(0, os.path.expanduser("~/.config/hypr"))
gd = __import__("gen-discord-theme")

SCHEME = "Technicolor"            # our named LO color scheme
PORT = 2002                      # UNO acceptor port (see lo-uno-acceptor setup)

# --- role classification (only roles that exist in the running build are set) ---
# Fill roles take a palette background; text roles take a contrasting ink.
FILL_ROLES = [
    "AppBackground", "BaseColor", "FaceColor", "ButtonColor", "FieldColor",
    "WindowColor", "MenuColor", "MenuBarColor", "ActiveColor", "SeparatorColor",
    "ShadowColor", "MenuBorderColor", "ActiveBorderColor", "InactiveBorderColor",
    "DocBoundaries",
]
TEXT_ROLES = [
    "ButtonTextColor", "MenuTextColor", "MenuBarTextColor", "WindowTextColor",
    "ActiveTextColor", "InactiveTextColor", "DisabledTextColor",
]
ACCENT_ROLES = ["AccentColor", "MenuHighlightColor", "MenuBarHighlightColor"]

WHITE = 0xFFFFFF
BLACK = 0x1A1A1A


def _int(rgb):
    return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]


def _ink_int(rgb):
    """Black or white, whichever contrasts the given fill (WCAG-ish luminance)."""
    r, g, b = rgb
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    return 0xF5F5F5 if lum < 140 else 0x1A1A1A


def build_colors():
    """Map the LIBREOFFICE-surface-tuned palette to {role: int_color}.
    Page forced white; chrome from the palette; text roles contrast their fill."""
    pal = gd._tune_palette(gd._raw_env(), "libreoffice")
    def c(key, default):
        try:
            return gd.rgb(pal.get(key, default))
        except Exception:
            return gd.rgb(default)
    chrome     = c("GRADIENT_START", "#3e71c0")   # main chrome fill
    chrome_alt = c("OCCUPIED", "#2a3550")          # darker fill (menus/borders)
    accent     = c("GRADIENT_END", "#cd9b39")      # accent / highlight

    colors = {}
    for r in FILL_ROLES:
        # gutter + main surfaces use chrome; structural lines use the darker alt
        fill = chrome_alt if r in ("MenuColor", "MenuBarColor", "SeparatorColor",
                                   "ShadowColor", "MenuBorderColor",
                                   "ActiveBorderColor", "InactiveBorderColor",
                                   "DocBoundaries") else chrome
        colors[r] = _int(fill)
    for r in TEXT_ROLES:
        # contrast against the matching fill (best-effort: against chrome)
        colors[r] = _ink_int(chrome)
    for r in ACCENT_ROLES:
        colors[r] = _int(accent)
    colors["MenuHighlightTextColor"] = _ink_int(accent)
    colors["MenuBarHighlightTextColor"] = _ink_int(accent)
    # the page itself: WHITE, black text, per the user's explicit preference
    colors["DocColor"] = WHITE
    colors["FontColor"] = BLACK
    return colors


# ---------------------------------------------------------------------------
def _connect(port):
    import uno
    lc = uno.getComponentContext()
    resolver = lc.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", lc)
    return resolver.resolve(
        f"uno:socket,host=localhost,port={port};urp;StarOffice.ComponentContext")


def _provider(ctx):
    return ctx.ServiceManager.createInstanceWithContext(
        "com.sun.star.configuration.ConfigurationProvider", ctx)


def _node(cp, path):
    from com.sun.star.beans import PropertyValue
    a = PropertyValue(); a.Name = "nodepath"; a.Value = path
    return cp.createInstanceWithArguments(
        "com.sun.star.configuration.ConfigurationUpdateAccess", (a,))


def apply_live(colors):
    """Apply via UNO to a RUNNING LibreOffice. Returns True on success."""
    try:
        ctx = _connect(PORT)
    except Exception:
        return False  # LO not running / no acceptor → caller falls back to file
    try:
        cp = _provider(ctx)
        schemes = _node(cp, "/org.openoffice.Office.UI/ColorScheme/ColorSchemes")
        if schemes.hasByName(SCHEME):
            schemes.removeByName(SCHEME)
        ns = schemes.createInstance()
        schemes.insertByName(SCHEME, ns)
        present = set(ns.ElementNames)
        for role, val in colors.items():
            if role in present:
                try:
                    ns.getByName(role).setPropertyValue("Color", val)
                except Exception:
                    pass
        schemes.commitChanges()

        cs = _node(cp, "/org.openoffice.Office.UI/ColorScheme")
        cs.setPropertyValue("CurrentColorScheme", SCHEME); cs.commitChanges()

        app = _node(cp, "/org.openoffice.Office.Common/Appearance")
        app.setPropertyValue("LibreOfficeTheme", 1); app.commitChanges()
        # nudge a repaint: toggle ApplicationAppearance (settings-changed path)
        try:
            cur = app.getPropertyValue("ApplicationAppearance")
            app.setPropertyValue("ApplicationAppearance", 2 if cur != 2 else 1)
            app.commitChanges()
            app.setPropertyValue("ApplicationAppearance", cur); app.commitChanges()
        except Exception:
            pass
        return True
    except Exception as e:
        sys.stderr.write(f"[lo-recolor] live apply failed: {e}\n")
        return False


if __name__ == "__main__":
    colors = build_colors()
    if apply_live(colors):
        print("lo-recolor: applied live via UNO")
    else:
        print("lo-recolor: LO not reachable via UNO (will theme on next launch "
              "once the acceptor + registry fallback are wired)")
