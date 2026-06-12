#!/usr/bin/env python3
"""
gen-kde-colors.py — technicolor palette -> KDE/Qt (Dolphin etc.) colors.

Rewrites the [Colors:*] sections of ~/.config/kdeglobals IN PLACE (preserving
everything else) from the wallpaper palette, mirroring the Spotify/Discord
mapping: View (file area) = PRIMARY, Window/chrome = SECONDARY, Selection =
ACCENT, per-surface contrast inks. KF6 apps watch kdeglobals and live-reload;
a KGlobalSettings dbus signal nudges anything older.

Called from wallpaper-colors.py on every wallpaper change.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.expanduser("~/.config/hypr"))
gd = __import__("gen-discord-theme")

KDEGLOBALS = os.path.expanduser("~/.config/kdeglobals")
BACKUP = KDEGLOBALS + ".tc-backup"


def c(t):
    return "{},{},{}".format(*t)


def mixb(a, f):
    return tuple(max(0, min(255, int(x * f))) for x in a)


def main():
    p = gd.load()
    primary = gd.rgb(p.get("GRADIENT_END", "#cd9b39"))
    secondary = gd.rgb(p.get("GRADIENT_START", "#3e71c0"))
    accent = gd.rgb(p.get("VISIBLE", "#758994"))

    ink_p = gd.ink_rgb(primary)      # text on primary (View)
    ink_s = gd.ink_rgb(secondary)    # text on secondary (Window/Button)
    ink_a = gd.ink_rgb(accent)       # text on accent (Selection)

    def muted(ink):
        return mixb(ink, 0.72) if ink == gd.DARK else tuple(int(x * 0.78) for x in ink)

    def section(bg, bg_alt, fg):
        return {
            "BackgroundNormal": c(bg),
            "BackgroundAlternate": c(bg_alt),
            "ForegroundNormal": c(fg),
            "ForegroundInactive": c(muted(fg)),
            "ForegroundActive": c(accent),
            "ForegroundLink": c(accent),
            "ForegroundVisited": c(muted(fg)),
            "ForegroundNegative": "218,68,83",
            "ForegroundNeutral": "246,116,0",
            "ForegroundPositive": "39,174,96",
            "DecorationFocus": c(accent),
            "DecorationHover": c(accent),
        }

    groups = {
        "Colors:View": section(primary, primary, ink_p),
        "Colors:Window": section(secondary, mixb(secondary, 0.93), ink_s),
        "Colors:Button": section(mixb(secondary, 0.9), mixb(secondary, 0.82), ink_s),
        "Colors:Selection": section(accent, mixb(accent, 0.9), ink_a),
        "Colors:Tooltip": section(secondary, mixb(secondary, 0.93), ink_s),
        "Colors:Complementary": section(mixb(secondary, 0.6), mixb(secondary, 0.5), gd.LIGHT if gd.ink_rgb(mixb(secondary, 0.6)) == gd.LIGHT else gd.DARK),
        "Colors:Header": section(secondary, mixb(secondary, 0.9), ink_s),
    }

    try:
        text = open(KDEGLOBALS).read()
    except FileNotFoundError:
        text = ""
    if not os.path.exists(BACKUP) and text:
        open(BACKUP, "w").write(text)

    # drop existing managed sections, then append fresh ones
    for name in list(groups) + ["Colors:Header][Inactive"]:
        text = re.sub(r"\[" + re.escape(name) + r"\][^\[]*", "", text)
    # AccentColor in [General] is intentionally NOT written: the named scheme
    # (see qt6ct note below) is the single source of truth, and a kdeglobals
    # AccentColor would override the scheme's Selection colors on KF6.

    out = [text.rstrip(), ""]
    for name, keys in groups.items():
        out.append("[{}]".format(name))
        for k, v in keys.items():
            out.append("{}={}".format(k, v))
        out.append("")
    # point the named scheme at OUR generated scheme file and drop the hash —
    # KDE6 verifies ColorSchemeHash and falls back to the NAMED scheme when it
    # mismatches (it always would, we rewrite the colors), which resurrected
    # stale Breeze colors (the white alternate-row bug).
    joined = "\n".join(out)
    joined = re.sub(r"ColorSchemeHash=[^\n]*\n?", "", joined)
    joined = re.sub(r"ColorScheme=[^\n]*", "ColorScheme=Technicolor", joined)
    # in-place write (KConfigWatcher follows the file)
    with open(KDEGLOBALS, "w") as f:
        f.write(joined)

    # the named scheme file itself
    scheme_dir = os.path.expanduser("~/.local/share/color-schemes")
    os.makedirs(scheme_dir, exist_ok=True)
    sc = ["[General]", "Name=Technicolor", "ColorScheme=Technicolor", ""]
    for name, keys in groups.items():
        sc.append("[{}]".format(name))
        for k, v in keys.items():
            sc.append("{}={}".format(k, v))
        sc.append("")
    with open(os.path.join(scheme_dir, "Technicolor.colors"), "w") as f:
        f.write("\n".join(sc))

    # nudge KF5-era listeners; KF6 watches the file itself
    subprocess.run(["dbus-send", "--session", "--type=signal", "/KGlobalSettings",
                    "org.kde.KGlobalSettings.notifyChange", "int32:0", "int32:0"],
                   capture_output=True)

    # ---- qt6ct-kde (QT_QPA_PLATFORMTHEME=qt6ct) ----
    # qt6ct.conf color_scheme_path points at the Technicolor.colors scheme
    # written above: qt6ct-kde builds the Qt palette from it AND exports
    # KDE_COLOR_SCHEME_PATH so KColorScheme inside apps reads OUR colors.
    # (When it pointed at style-colors.conf — Qt-palette format — qt6ct-kde
    # silently substituted BreezeLight.colors for KColorScheme consumers;
    # Dolphin paints the view background from KColorScheme(View).background(),
    # which is what made the white rows immune to every palette fix.)
    # style-colors.conf is still written below only as a fallback. Qt apps
    # read colors AT LAUNCH — a running Dolphin keeps old colors until reopened.
    def h(t, alpha="ff"):
        return "#{}{:02x}{:02x}{:02x}".format(alpha, *t)

    ink_a = gd.ink_rgb(accent)
    blend = lambda a, b, f: tuple(int(a[i] * (1 - f) + b[i] * f) for i in range(3))
    # QPalette role order (qt6ct, 22):
    # WindowText, Button, Light, Midlight, Dark, Mid, Text, BrightText,
    # ButtonText, Base, Window, Shadow, Highlight, HighlightedText, Link,
    # LinkVisited, AlternateBase, NoRole, ToolTipBase, ToolTipText,
    # PlaceholderText, Accent
    active = [
        h(ink_s), h(mixb(secondary, 0.9)), h(blend(secondary, (255, 255, 255), 0.2)),
        h(blend(secondary, (255, 255, 255), 0.08)), h(mixb(secondary, 0.55)), h(mixb(secondary, 0.7)),
        h(ink_p), h((255, 255, 255)), h(ink_s),
        h(primary), h(secondary), h((10, 10, 12)),
        h(accent), h(ink_a), h(accent),
        h(mixb(accent, 0.8)), h(primary), h((0, 0, 0)),
        h(secondary), h(ink_s), h(ink_p, "80"), h(accent),
    ]
    dis_fg = h(blend(ink_s, secondary, 0.5))
    disabled = list(active)
    for i in (0, 6, 8, 13, 19):
        disabled[i] = dis_fg
    disabled[12] = h(mixb(accent, 0.6))
    disabled[20] = h(blend(ink_s, secondary, 0.6), "80")

    qt6_path = os.path.expanduser("~/.config/qt6ct/style-colors.conf")
    try:
        with open(qt6_path, "w") as f:
            f.write("[ColorScheme]\n")
            f.write("active_colors=" + ", ".join(active) + "\n")
            f.write("disabled_colors=" + ", ".join(disabled) + "\n")
            f.write("inactive_colors=" + ", ".join(active) + "\n")
    except Exception:
        pass


    # ---- Dolphin block layout (app-scoped via `dolphin -stylesheet ...`) ----
    # Solid rounded blocks per section; ONLY the QMainWindow background is the
    # chroma key -> the tckey windowrule renders the inter-block gaps as glass.
    KEY = (1, 186, 188)
    qss = """
/* gaps = chroma key (real Qt alpha needs Kvantum — rgba() renders black on
   stock styles). EVERY text-bearing widget must live in a solid block: text
   directly on key gets shader artifacts. */
QMainWindow {{ background-color: rgb{key}; }}
QMainWindow::separator {{ background-color: rgb{key}; width: 8px; height: 8px; }}
DolphinUrlNavigator, KUrlNavigator {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 10px; padding: 2px 6px; }}
QDockWidget::title {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 8px; }}
QToolBar {{ background-color: rgb{sec}; color: rgb{inks}; border: none; border-radius: 12px; margin: 8px; padding: 3px; }}
QStatusBar {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 12px; margin: 8px; }}
QMenu {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 10px; padding: 6px; }}
QMenu::item:selected {{ background-color: rgb{acc}; color: rgb{inka}; border-radius: 6px; }}
QToolTip {{ background-color: rgb{sec}; color: rgb{inks}; border: none; }}
/* center file view: KItemListContainer paints the rounded primary block; the
   inner QGraphicsView fills square with the KColorScheme View color (from
   DolphinView::updatePalette) — force it transparent so the radius shows. */
KItemListContainer {{ background-color: rgb{prim}; color: rgb{inkp}; selection-background-color: rgb{acc}; selection-color: rgb{inka}; border: none; border-radius: 12px; margin: 8px; padding: 12px; }}
KItemListContainer QGraphicsView {{ background: transparent; border: none; qproperty-autoFillBackground: false; }}
KItemListContainer QGraphicsView > QWidget {{ background: transparent; qproperty-autoFillBackground: false; }}
PlacesPanel {{ background-color: rgb{sec}; color: rgb{inks}; border: none; border-radius: 12px; margin: 8px; padding: 10px; }}
/* right info panel: InformationPanel is a plain QWidget with no paintEvent —
   QSS backgrounds are INERT on it (documented Qt limitation). Paint the
   full-height block on the QDockWidget so it covers the preview area too. */
QDockWidget {{ background: transparent; color: rgb{inks}; titlebar-close-icon: none; }}
/* InformationPanel is a plain QWidget (QSS-background-inert by default) —
   the tc-styledbg.so preload shim (loaded by dolphin-tc.sh) flips
   WA_StyledBackground on it so this rounded block actually paints. */
InformationPanel {{ background-color: rgb{sec}; color: rgb{inks}; border: none; border-radius: 12px; margin: 8px; padding: 6px; }}
InformationPanel QScrollArea {{ background: transparent; border: none; }}
InformationPanel QScrollArea QWidget {{ background: transparent; color: rgb{inks}; }}
InformationPanel QLabel {{ background: transparent; color: rgb{inks}; }}
/* the big file-name under the preview is a QTextEdit (palette Text = ink of
   PRIMARY = wrong surface) — force the secondary-surface ink */
InformationPanel QTextEdit {{ background: transparent; border: none; color: rgb{inks}; }}
/* "N folders, M files" blip = DolphinStatusBar's internal QScrollArea
   (AnimatedHeightWidget wrapper — the only stylable surface in there) */
DolphinStatusBar QScrollArea {{ background-color: rgb{sec}; color: rgb{inks}; border: none; border-radius: 8px; margin: 0 0 20px 24px; }}
DolphinStatusBar QLabel {{ background: transparent; color: rgb{inks}; }}
""".format(key=KEY, sec=secondary, prim=primary, prim_alt=mixb(primary, 0.93), acc=accent,
           inks=ink_s, inkp=ink_p, inka=ink_a)
    try:
        with open(os.path.expanduser("~/.config/qt6ct/technicolor.qss"), "w") as f:
            f.write(qss)
    except Exception:
        pass


if __name__ == "__main__":
    main()
