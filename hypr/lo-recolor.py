#!/usr/bin/env python3.14
"""lo-recolor.py — theme LibreOffice from the wallpaper palette.

Empirically established (see the role-mapping tests):
  * LibreOffice's CHROME (toolbars, menubar, sidebar, statusbar, ruler) is
    painted by the kf6 VCL plugin from the Qt palette = ~/.config/kdeglobals,
    which gen-kde-colors.py already rewrites on every wallpaper change. So with
    LibreOfficeTheme=0 the chrome follows the wallpaper for free — including the
    toolbars, with the colored (sukapura) icons intact. It updates on LO
    relaunch (kf6 reads the palette at startup; lo-tc.sh re-launches/re-applies).
  * The DOCUMENT colors — the page (DocColor) and the blank gutter around it
    (AppBackground) — are read from LO's own ColorConfig, NOT the Qt palette, so
    they ARE settable live via UNO regardless of plugin.

So this script does the document half, live, via UNO:
  * DocColor  -> WHITE  (the page stays white for writing; user's explicit wish)
  * FontColor -> black
  * AppBackground -> a fixed KEY color, so the chromakey shader (Hypr-DarkWindow)
    can key JUST the gutter transparent and hyprglass refracts it = liquid glass
    in the blank area around the page. The key is unique so nothing else is hit.

LibreOfficeTheme stays 0 (off) so the Qt/kdeglobals chrome shows through; we only
touch document colors here. Runs under python3.14 (LO's uno.py). Fully defensive:
if LO isn't reachable over UNO it no-ops (chrome still themes from kdeglobals on
next launch).
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.config/hypr"))
gd = __import__("gen-discord-theme")

PORT = 2002

# The gutter key color. Picked to be visually distinct + unlikely to collide with
# real content; the Hypr-DarkWindow windowrule keys exactly this to transparent.
# Kept STATIC (not palette-derived) so the shader's fixed key never drifts — the
# glass shows the real wallpaper/refraction behind it anyway, so the gutter's own
# color doesn't need to match the palette.
GUTTER_KEY = 0x01BABC            # rgb(1,186,188) — exactly the Dolphin fixed key,
                                 # so we reuse the tckeydolph shader (it's a fixed
                                 # uniform key, safe to share across window classes)
WHITE = 0xFFFFFF
BLACK = 0x1A1A1A


def _connect(port):
    import uno
    lc = uno.getComponentContext()
    resolver = lc.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", lc)
    return resolver.resolve(
        f"uno:socket,host=localhost,port={port};urp;StarOffice.ComponentContext")


def _node(cp, path):
    from com.sun.star.beans import PropertyValue
    a = PropertyValue(); a.Name = "nodepath"; a.Value = path
    return cp.createInstanceWithArguments(
        "com.sun.star.configuration.ConfigurationUpdateAccess", (a,))


def apply_live(glass_gutter=True):
    """Set document colors (white page + keyed/plain gutter) on a running LO via
    UNO. Returns True on success, False if LO isn't reachable."""
    try:
        ctx = _connect(PORT)
    except Exception:
        return False
    try:
        cp = ctx.ServiceManager.createInstanceWithContext(
            "com.sun.star.configuration.ConfigurationProvider", ctx)
        # Document colors live in the AUTOMATIC scheme's entries (ColorConfig).
        # We write them into the current scheme so they take effect immediately.
        cs = _node(cp, "/org.openoffice.Office.UI/ColorScheme")
        scheme = cs.getPropertyValue("CurrentColorScheme")
        schemes = _node(cp, "/org.openoffice.Office.UI/ColorScheme/ColorSchemes")
        if not schemes.hasByName(scheme):
            return False
        ns = schemes.getByName(scheme)
        present = set(ns.ElementNames)
        gutter = GUTTER_KEY if glass_gutter else _palette_gutter()
        wanted = {"DocColor": WHITE, "FontColor": BLACK, "AppBackground": gutter}
        for role, val in wanted.items():
            if role in present:
                try:
                    ns.getByName(role).setPropertyValue("Color", val)
                except Exception:
                    pass
        schemes.commitChanges()
        app = _node(cp, "/org.openoffice.Office.Common/Appearance")
        # Keep LibreOfficeTheme OFF: we want the CHROME (toolbars/menubar/sidebar)
        # to come from the kf6 Qt palette = kdeglobals (so it follows the
        # wallpaper, with colored icons). Only the DOCUMENT colors above are ours,
        # and those read from ColorConfig regardless of this flag.
        try:
            app.setPropertyValue("LibreOfficeTheme", 0); app.commitChanges()
        except Exception:
            pass
        # nudge a repaint (document area re-reads ColorConfig)
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


def _palette_gutter():
    """Fallback gutter = the libreoffice-surface-tuned palette accent (used if
    glass is disabled)."""
    try:
        pal = gd._tune_palette(gd._raw_env(), "libreoffice")
        r, g, b = gd.rgb(pal.get("GRADIENT_START", "#3e71c0"))
        return (r << 16) | (g << 8) | b
    except Exception:
        return 0x2A3550


if __name__ == "__main__":
    # glass on by default; pass "solid" to fill the gutter with the palette instead
    glass = not (len(sys.argv) > 1 and sys.argv[1] == "solid")
    if apply_live(glass_gutter=glass):
        print("lo-recolor: document colors applied live via UNO "
              f"({'glass gutter key' if glass else 'solid gutter'})")
    else:
        print("lo-recolor: LO not reachable via UNO (chrome still themes from "
              "kdeglobals on next launch)")
