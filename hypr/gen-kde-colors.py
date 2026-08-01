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

    def section(bg, bg_alt, fg, alt_transparent=False):
        # alt_transparent: write BackgroundAlternate with alpha 0. Used only for
        # the file view (Colors:View). Dolphin's KStandardItemListWidget paints
        # ONLY the alternate (even) rows, with this colour, and leaves the normal
        # rows transparent so the QGraphicsView scene background shows through.
        # The shim live-repaints that scene background (setBackgroundBrush) on
        # every wallpaper change — so to make the WHOLE canvas track live, the
        # alternate rows must also be transparent (alpha 0), otherwise every
        # other row freezes at the launch-captured colour. (Side effect: removes
        # alternating-row striping in other KColorScheme item views too; they
        # then show a uniform Base, which is fine.)
        return {
            "BackgroundNormal": c(bg),
            "BackgroundAlternate": (c(bg_alt) + ",0") if alt_transparent else c(bg_alt),
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
        "Colors:View": section(primary, primary, ink_p, alt_transparent=True),
        "Colors:Window": section(secondary, mixb(secondary, 0.93), ink_s),
        # Button = the details-view column bar (Name/Size/Modified/Type) — it
        # reads this group, NOT Colors:Header (verified empirically). The user
        # wants that bar the MAIN (primary) surface, matching the file view, so
        # Button is primary. (Most Dolphin buttons are QSS-styled chrome, so
        # this mainly affects the column header + any unstyled buttons.)
        "Colors:Button": section(primary, mixb(primary, 0.9), ink_p),
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

    # drop existing managed sections, then append fresh ones (incl. any
    # pre-existing ColorEffects:Inactive, else our disabled one duplicates it)
    for name in list(groups) + ["Colors:Header][Inactive", "ColorEffects:Inactive"]:
        text = re.sub(r"\[" + re.escape(name) + r"\][^\[]*", "", text)
    # AccentColor in [General] is intentionally NOT written: the named scheme
    # (see qt6ct note below) is the single source of truth, and a kdeglobals
    # AccentColor would override the scheme's Selection colors on KF6.

    # Neutralize the inactive-window color effect. By default KDE desaturates/
    # dims widgets when their window loses focus — that's the "scrollbar/URL box
    # shifts color when Dolphin is unfocused" the user saw. All-zero amounts +
    # Enable=false = inactive windows keep their active colors.
    inactive_off = [
        "[ColorEffects:Inactive]",
        "ChangeSelectionColor=false",
        "Color=112,111,110",
        "ColorAmount=0",
        "ColorEffect=0",
        "ContrastAmount=0",
        "ContrastEffect=0",
        "Enable=false",
        "IntensityAmount=0",
        "IntensityEffect=0",
        "",
    ]

    out = [text.rstrip(), ""]
    for name, keys in groups.items():
        out.append("[{}]".format(name))
        for k, v in keys.items():
            out.append("{}={}".format(k, v))
        out.append("")
    out += inactive_off
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
    sc += inactive_off
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
/* The breadcrumb segments + the editable path field paint their OWN opaque
   background (from launch-captured KColorScheme), which covered the navigator's
   live QSS background so the URL box stayed a stale colour on wallpaper change.
   Force every child of the navigator transparent so the (live, QSS-reapplied)
   secondary container colour shows through; only the navigator box recolors and
   everything inside rides it. Text/handles stay the secondary ink. */
KUrlNavigatorButton, DolphinUrlNavigator QToolButton, KUrlNavigator QToolButton,
KUrlNavigator QPushButton, DolphinUrlNavigator QPushButton {{ background: transparent; color: rgb{inks}; border: none; }}
/* Styling those buttons at all stops Qt drawing Breeze's NATIVE hover, so without
   an explicit :hover they gave zero feedback — you could not tell a breadcrumb was
   clickable. Re-add hover/pressed on the accent, matching QMenu::item:selected. */
KUrlNavigatorButton:hover, DolphinUrlNavigator QToolButton:hover, KUrlNavigator QToolButton:hover,
KUrlNavigator QPushButton:hover, DolphinUrlNavigator QPushButton:hover {{ background: rgb{acc}; color: rgb{inka}; border: none; border-radius: 6px; }}
KUrlNavigatorButton:pressed, DolphinUrlNavigator QToolButton:pressed, KUrlNavigator QToolButton:pressed,
KUrlNavigator QPushButton:pressed, DolphinUrlNavigator QPushButton:pressed {{ background: rgb{acc_prs}; color: rgb{inka}; border: none; border-radius: 6px; }}
DolphinUrlNavigator QLineEdit, KUrlNavigator QLineEdit, DolphinUrlNavigator QComboBox,
KUrlNavigator QComboBox, KUrlComboBox {{ background: transparent; color: rgb{inks}; border: none; selection-background-color: rgb{acc}; selection-color: rgb{inka}; }}
QDockWidget::title {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 8px; }}
QToolBar {{ background-color: rgb{sec}; color: rgb{inks}; border: none; border-radius: 12px; margin: 8px; padding: 3px; }}
QStatusBar {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 12px; margin: 8px; }}
QMenu {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 10px; padding: 6px; }}
QMenu::item:selected {{ background-color: rgb{acc}; color: rgb{inka}; border-radius: 6px; }}
QToolTip {{ background-color: rgb{sec}; color: rgb{inks}; border: none; }}
/* center file view: KItemListContainer paints the rounded primary block; the
   inner QGraphicsView fills square with the KColorScheme View color (from
   DolphinView::updatePalette) — force it transparent so the radius shows. */
/* top margin 0 + square top corners: the file block butts flush against the tab
   strip (browser-style), instead of floating 8px below it — that 8px gap was the
   chroma-key region showing the wallpaper as a thin coloured line under the tabs.
   Sides + bottom keep the 8px float + rounded corners. */
KItemListContainer {{ background-color: rgb{prim}; color: rgb{inkp}; selection-background-color: rgb{acc}; selection-color: rgb{inka}; border: none; border-radius: 12px; border-top-left-radius: 0px; border-top-right-radius: 0px; margin: 0px 8px 8px 8px; padding: 12px; }}
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
/* details-view column bar (Name/Size/Modified/Type) — MAIN colour. The
   in-scene KItemListHeaderWidget follows the KColorScheme Header group (set to
   primary above); this QHeaderView rule covers the widget-based header paths. */
QHeaderView {{ background-color: rgb{prim}; border: none; }}
QHeaderView::section {{ background-color: rgb{prim}; color: rgb{inkp}; border: none; padding: 4px 8px; }}
/* Tabs: connected "segmented control" strip (Apple vibe) — no gaps between
   tabs, only the OUTER ends of the whole strip are rounded (via :first/:last/
   :only-one), so adjacent tabs share a flush edge. A 1px secondary-ink divider
   on every tab but the last separates two same-colour neighbours without a gap.
   Close (x) moved to the LEFT of each tab (macOS-style) via subcontrol-position
   — this genuinely relocates it (it's a real subcontrol slot, unlike padding/
   margin which only nudged the right-edge default). */
QTabBar::tab {{ background-color: rgb{sec}; color: rgb{inks}; border-radius: 0px; padding: 5px 10px; margin: 0px; min-width: 0px; border-right: 1px solid rgb{sec_div}; }}
QTabBar::tab:last, QTabBar::tab:only-one {{ border-right: none; }}
/* shift the whole connected strip right by the file view's 8px left margin, so
   the first tab's left edge lines up with the file block's left edge instead of
   jutting 8px past it */
QTabBar::tab:first, QTabBar::tab:only-one {{ border-top-left-radius: 10px; border-bottom-left-radius: 0px; margin-left: 8px; }}
QTabBar::tab:last, QTabBar::tab:only-one {{ border-top-right-radius: 10px; border-bottom-right-radius: 0px; }}
QTabBar::close-button {{ width: 20px; height: 20px; margin-right: 5px; image: url({home}/.config/qt6ct/tab-x.png); }}
QTabBar::close-button:selected {{ image: url({home}/.config/qt6ct/tab-x-sel.png); }}
/* hover highlight behind the x: a LIGHT circular disc (classic close-button
   look) — the dark x reads clearly on it. The disc is baked into the icon
   (tab-x-hover.png) rather than drawn via background-color+border-radius,
   because Qt gives the close-button a vertical-pill background box, not a
   square one, so QSS rounding came out an oval. A round disc in the square PNG
   stays a true circle at the render size. (Accent isn't used: in many palettes
   it's close to the tab colour and the disc would be near-invisible.) */
QTabBar::close-button:hover {{ image: url({home}/.config/qt6ct/tab-x-hover.png); }}
QTabBar::close-button:selected:hover {{ image: url({home}/.config/qt6ct/tab-x-sel-hover.png); }}
QTabBar::tab:selected {{ background-color: rgb{acc}; color: rgb{inka}; border-right: none; }}
QTabBar::tab:hover:!selected {{ background-color: rgb{sec_alt}; }}
/* pane border:none alone left a 1px tab-bar BASE line drawn in the chroma key
   colour (too thin for the shader to glass -> showed as a raw teal line between
   tabs and files). Zero the pane + give the tab bar a flush key base so there's
   nothing thin to mis-key. */
QTabWidget::pane {{ border: none; margin: 0; padding: 0; top: 0; }}
QTabBar {{ border: none; background: transparent; }}
QTabBar::tab:bottom, QTabBar::tab:top {{ border-bottom: none; }}
/* kill the faint gray frame the style draws around scroll/item views */
QAbstractScrollArea {{ border: none; }}
QAbstractItemView {{ border: none; outline: none; }}
/* scrollbars: the gray right/bottom edges of the file view ARE the unstyled
   scrollbar tracks. Transparent track + secondary rounded handle — no gray,
   and being QSS they hot-swap with the wallpaper (KColorScheme didn't). */
/* thin rounded-pill scrollbars. The reserved track (width/height 14) must be
   BIGGER than twice the cross-axis margin, or the handle is left 0px and
   vanishes: 14 - 3 - 3 = 8px handle, radius 4 = full capsule, inset from the
   block edge. */
QScrollBar:vertical {{ background: transparent; width: 14px; margin: 4px 3px; }}
QScrollBar:horizontal {{ background: transparent; height: 14px; margin: 3px 4px; }}
QScrollBar::handle {{ background-color: rgb{sec}; border-radius: 4px; min-height: 40px; min-width: 40px; }}
QScrollBar::handle:hover {{ background-color: rgb{acc}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}
/* info panel: drop the horizontal separator between the preview and the
   metadata (a thin QFrame line that also never recolored) */
InformationPanel QFrame {{ border: none; background: transparent; }}
""".format(key=KEY, sec=secondary, prim=primary, prim_alt=mixb(primary, 0.93), acc=accent,
           acc_prs=mixb(accent, 0.82),
           sec_alt=mixb(secondary, 0.88), sec_div=mixb(secondary, 0.78),
           xhov=blend(secondary, (255, 255, 255), 0.72),
           inks=ink_s, inkp=ink_p, inka=ink_a, home=os.path.expanduser("~"))
    # Close (x) button icons in the contrasting ink for each tab state, so the
    # x always reads against its background: ink_s on normal (secondary) tabs,
    # ink_a on the selected (accent) tab. The stock x followed neither.
    try:
        from PIL import Image, ImageDraw
        def make_x(col, path, disc=None):
            # The close-button is enlarged to 20px by the tc-style.so proxy style
            # (Breeze's PM_TabCloseIndicator metric caps it otherwise). This icon
            # renders at that 20px. The X is inset in the 24px canvas (m=7) so it
            # renders ~8-9px — a normal close-x size — while the disc (full canvas)
            # fills the whole 20px circle, so the disc is ~2x the x. (disc baked
            # into the square icon because Qt gives the close-button box a
            # non-square shape, so a QSS border-radius came out an oval; a baked
            # circle stays round.)
            s, m, lw = 24, 7, 4
            im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
            d = ImageDraw.Draw(im)
            if disc is not None:
                d.ellipse((1, 1, s - 2, s - 2), fill=tuple(disc) + (255,))
            d.line((m, m, s - m, s - m), fill=tuple(col) + (255,), width=lw)
            d.line((s - m, m, m, s - m), fill=tuple(col) + (255,), width=lw)
            im.save(path)
        xhov_rgb = blend(secondary, (255, 255, 255), 0.72)
        make_x(ink_s, os.path.expanduser("~/.config/qt6ct/tab-x.png"))
        make_x(ink_a, os.path.expanduser("~/.config/qt6ct/tab-x-sel.png"))
        make_x(ink_s, os.path.expanduser("~/.config/qt6ct/tab-x-hover.png"), disc=xhov_rgb)
        make_x(ink_a, os.path.expanduser("~/.config/qt6ct/tab-x-sel-hover.png"), disc=xhov_rgb)
    except Exception:
        pass
    try:
        with open(os.path.expanduser("~/.config/qt6ct/technicolor.qss"), "w") as f:
            f.write(qss)
    except Exception:
        pass


if __name__ == "__main__":
    main()
