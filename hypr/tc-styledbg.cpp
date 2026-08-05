// tc-styledbg.cpp — LD_PRELOAD shim for the technicolor Dolphin theme.
//
// Two jobs:
//
// 1) Dolphin's InformationPanel/TerminalPanel/FoldersPanel are plain QWidgets:
//    Qt documents that QSS backgrounds are inert on those (no paintEvent), so
//    the panels could only be filled square via autoFillBackground — no
//    rounded block possible. This shim flips Qt::WA_StyledBackground on them as
//    they become visible, which makes QStyleSheetStyle paint the full QSS box
//    (background, border-radius, margin) like any styled widget.
//    NOTE: the central file view (KItemListContainer) is painted by Dolphin
//    from KColorScheme, NOT QSS — WA_StyledBg and a transparent scroll viewport
//    don't dislodge that. The live recolor for it is the QGraphicsView
//    setBackgroundBrush write in the QSS watcher (see job 2), not QSS.
//    (qobject_cast to QAbstractScrollArea can't be used here: it pulls a
//    QtWidgets DATA symbol that crashes LD_PRELOAD-inheriting QtCore-only
//    helpers like kioworker — so the view is matched by class-name walk and
//    reinterpret_cast, which only binds lazy function symbols.)
//
// 2) Live recolor: gen-kde-colors.py rewrites ~/.config/qt6ct/technicolor.qss
//    on every wallpaper change, but Qt only reads `-stylesheet` files at
//    launch — a running Dolphin kept stale colors until relaunched. The shim
//    watches the QSS file and re-applies it via qApp->setStyleSheet(), so
//    Dolphin hot-swaps with the rest of the desktop. (The generator replaces
//    the file, so the watcher re-adds the path after each signal; a short
//    debounce coalesces write bursts and skips half-written files.)
//
// Mechanism: interpose QWidget::setVisible (vtable slots resolve through the
// dynamic linker, so LD_PRELOAD wins even for virtual dispatch). Only depends
// on the Qt6 ABI (stable across Qt 6.x); widgets are matched by class NAME,
// so Dolphin updates don't affect it. The watcher initializes lazily from the
// first setVisible call — main thread, QApplication already constructed. If
// the .so ever fails to load, dolphin just runs with the square panel and
// launch-time colors — nothing breaks.
//
// Built automatically by dolphin-tc.sh when missing or older than this file.
#include <QApplication>
#include <QBrush>
#include <QColor>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileSystemWatcher>
#include <QGraphicsItem>
#include <QGraphicsScene>
#include <QGraphicsView>
#include <QGraphicsWidget>
#include <QPalette>
#include <QRegularExpression>
#include <QTimer>
#include <QWidget>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>
#ifdef HAVE_KCONFIG
#include <KSharedConfig>
#endif

// ── Stop LD_PRELOAD leaking into Dolphin's child processes ───────────────────
// dolphin-tc.sh exports LD_PRELOAD=tc-styledbg.so so this shim loads into
// Dolphin. The problem: Dolphin then passes LD_PRELOAD to EVERY process it
// launches, and this .so links libKF6ConfigCore.so.6 — which is absent inside
// sandboxes like Steam's pressure-vessel runtime, so the /bin/bash that
// bootstraps steamwebhelper (and each game launch) dies with "cannot open
// shared object file", hanging Steam and blocking games. The shim is only ever
// useful IN Dolphin itself (all its work is in-process; the kioworker notes
// below are crash-safety, not features), so at load time we strip OUR entry
// from LD_PRELOAD: we're already loaded into this process, but its children
// won't inherit us. constructor(101) runs before main() and long before Dolphin
// spawns anything. Any other preload the user set is preserved.
__attribute__((constructor(101))) static void tc_unleak_ld_preload()
{
    const char *pre = getenv("LD_PRELOAD");
    if (!pre || !*pre)
        return;
    const std::string in(pre);
    std::string out;
    size_t i = 0;
    while (i <= in.size()) {
        const size_t sep = in.find_first_of(": ", i);  // entries split on ':' or ' '
        const std::string tok =
            in.substr(i, sep == std::string::npos ? std::string::npos : sep - i);
        if (!tok.empty() && tok.find("tc-styledbg.so") == std::string::npos) {
            if (!out.empty())
                out += ':';
            out += tok;
        }
        if (sep == std::string::npos)
            break;
        i = sep + 1;
    }
    if (out.empty())
        unsetenv("LD_PRELOAD");
    else
        setenv("LD_PRELOAD", out.c_str(), 1);
}

static void initQssWatcher()
{
    static bool done = false;
    if (done || !qApp)
        return;
    done = true;

    // Install the proxy style that enlarges the tab close button (so the hover
    // disc can be large — Breeze hard-caps it via PM_TabCloseIndicator*, which
    // QSS can't override; see tc-style.cpp). dlopen'd here, in the GUI-only
    // watcher init, so the QtCore-only kioworker never loads its QtWidgets
    // vtable. Deferred to the event loop so we don't reparent the style mid
    // setVisible. Best-effort: if the lib is missing, the close button just
    // stays Breeze-sized.
    QTimer::singleShot(0, qApp, []() {
        const QByteArray lib =
            (QDir::homePath() + "/.config/hypr/tc-style.so").toLocal8Bit();
        if (void *h = dlopen(lib.constData(), RTLD_NOW)) {
            if (auto fn = reinterpret_cast<void (*)()>(dlsym(h, "tc_install_style")))
                fn();
        }
    });

    const QString path = QDir::homePath() + "/.config/qt6ct/technicolor.qss";
    if (!QFile::exists(path))
        return;
    auto *watcher = new QFileSystemWatcher(qApp);
    auto *debounce = new QTimer(qApp);
    debounce->setSingleShot(true);
    debounce->setInterval(150);
    watcher->addPath(path);
    QObject::connect(watcher, &QFileSystemWatcher::fileChanged, debounce,
                     [watcher, debounce, path]() {
                         if (!watcher->files().contains(path) && QFile::exists(path))
                             watcher->addPath(path);
                         debounce->start();
                     });
    QObject::connect(debounce, &QTimer::timeout, qApp, [path]() {
        QByteArray qss;
        {
            QFile f(path);
            if (f.open(QIODevice::ReadOnly))
                qss = f.readAll();
        }
        if (!qss.isEmpty())
            qApp->setStyleSheet(QString::fromUtf8(qss));

        // Live-recolor the file-list canvas. The file rows are drawn on a
        // QGraphicsScene inside a QGraphicsView (KItemListContainer's viewport);
        // the empty canvas area you see between/around rows is the VIEW'S SCENE
        // BACKGROUND. KItemListView captures palette Base only once at creation
        // (so neither QSS nor a palette write moves it mid-session), but
        // QGraphicsView::setBackgroundBrush is a plain runtime setter that
        // repaints immediately — so painting the scene background with the live
        // file color recolors the canvas with no relaunch and no view-mode
        // toggle. (reinterpret_cast is safe: QGraphicsView's QWidget subobject
        // is at offset 0, single inheritance; and setBackgroundBrush is a lazily
        // bound FUNCTION symbol, not a DATA symbol, so it never trips the
        // QtCore-only kioworker the way qobject_cast's staticMetaObject did.)
        QColor fileBg, fileInk;
        QRegularExpression re(QStringLiteral(
            "KItemListContainer\\s*\\{\\s*background-color:\\s*rgb\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)"
            "[^}]*?color:\\s*rgb\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)"));
        QRegularExpressionMatch mm = re.match(QString::fromUtf8(qss));
        if (mm.hasMatch()) {
            fileBg = QColor(mm.captured(1).toInt(), mm.captured(2).toInt(), mm.captured(3).toInt());
            fileInk = QColor(mm.captured(4).toInt(), mm.captured(5).toInt(), mm.captured(6).toInt());
        }
        if (fileBg.isValid()) {
            // The details-view column header (Name/Size/Modified/Type) is an
            // in-scene QGraphicsObject (KItemListHeaderWidget) that paints its
            // columns with style()->drawControl(CE_Header, opt) where opt.palette
            // defaults to qApp's palette — NOT its own widget palette and NOT
            // anything the QWidget PaletteChange/reparse broadcast reaches. So it
            // froze at the launch color while the canvas/chrome recolored. Fix:
            // push the header's roles onto the APPLICATION palette. Scope to
            // Button/Window(+text) — those drive CE_Header on Breeze/Fusion;
            // every other surface is QSS- or KColorScheme-driven and overrides
            // the app palette, so this stays contained to the header.
            QPalette ap = qApp->palette();
            ap.setColor(QPalette::Button, fileBg);
            ap.setColor(QPalette::Window, fileBg);
            ap.setColor(QPalette::Base, fileBg);
            if (fileInk.isValid()) {
                ap.setColor(QPalette::ButtonText, fileInk);
                ap.setColor(QPalette::WindowText, fileInk);
                // Text/HighlightedText drive the file ROW labels: like the canvas
                // bg they were captured at launch, so a dark->light wallpaper flip
                // left light text on a now-light canvas (no contrast). The rows
                // pull their color from the KItemListView style option below, but
                // also seed the app palette so any qApp-fallback path is correct.
                ap.setColor(QPalette::Text, fileInk);
            }
            qApp->setPalette(ap);

            const QWidgetList all = QApplication::allWidgets();
            for (QWidget *w : all) {
                bool isGV = false;
                for (const QMetaObject *mo = w->metaObject(); mo; mo = mo->superClass())
                    if (!std::strcmp(mo->className(), "QGraphicsView")) { isGV = true; break; }
                if (!isGV)
                    continue;
                auto *gv = reinterpret_cast<QGraphicsView *>(w);
                gv->setBackgroundBrush(QBrush(fileBg));
                QPalette p = w->palette();
                p.setColor(QPalette::Base, fileBg);
                p.setColor(QPalette::AlternateBase, fileBg);
                w->setPalette(p);
                gv->viewport()->update();

                // Repaint the in-scene widgets so they pick up the new colors
                // NOW (an ApplicationPaletteChange doesn't auto-invalidate scene
                // items). Header: reads qApp palette (CE_Header) -> just update().
                // ItemListView: the file rows read their text color from THIS
                // view's palette/style option (captured at launch), so push the
                // live ink onto its palette (Text/WindowText) before updating; the
                // PaletteChange that setPalette posts makes KItemListView rebuild
                // its style option, so the rows re-read the fresh ink.
                // (toGraphicsObject + className are function symbols; QGraphicsObject
                // is the FIRST base of QGraphicsWidget so the cast is offset 0 — no
                // DATA symbol, kioworker-safe.)
                if (QGraphicsScene *sc = gv->scene()) {
                    const QList<QGraphicsItem *> items = sc->items();
                    for (QGraphicsItem *it : items) {
                        QGraphicsObject *obj = it->toGraphicsObject();
                        if (!obj)
                            continue;
                        const char *cn = obj->metaObject()->className();
                        auto *gw = reinterpret_cast<QGraphicsWidget *>(obj);
                        if (std::strstr(cn, "ItemListView") && fileInk.isValid()) {
                            QPalette vp = gw->palette();
                            vp.setColor(QPalette::Text, fileInk);
                            vp.setColor(QPalette::WindowText, fileInk);
                            vp.setColor(QPalette::Base, fileBg);
                            gw->setPalette(vp);
                        }
                        if (std::strstr(cn, "Header") || std::strstr(cn, "ItemListView"))
                            gw->update();
                    }
                }
            }
        }
        // Reparse the cached KColorScheme configs so the WIDGET-based
        // KColorScheme surfaces (column header, scrollbars) re-decode fresh
        // colors on the PaletteChange broadcast below. (KSharedConfig/KConfig
        // aren't QObjects -> only lazy function symbols, so LD_PRELOAD helpers
        // like kioworker are unaffected. Needs KF6 KConfigCore; the block
        // compiles out without it.)
        // The central file-list canvas is handled by the setBackgroundBrush
        // write above, NOT by this reparse: KItemListView captures palette Base
        // once at view creation (no refresh hook — QSS, palette writes, scene
        // re-add and qApp palette were all tried and ignored), but the empty
        // canvas IS the QGraphicsView scene background, and setBackgroundBrush
        // repaints live. Pairs with [Colors:View] BackgroundAlternate alpha 0
        // (gen-kde-colors.py) so the alternate rows are transparent and the
        // whole canvas tracks that live brush instead of freezing every 2nd row.
#ifdef HAVE_KCONFIG
        {
            QByteArray csp = qgetenv("KDE_COLOR_SCHEME_PATH");
            QString schemePath = csp.isEmpty()
                ? (QDir::homePath() + "/.local/share/color-schemes/Technicolor.colors")
                : QString::fromLocal8Bit(csp);
            if (QFile::exists(schemePath))
                KSharedConfig::openConfig(schemePath)->reparseConfiguration();
            KSharedConfig::openConfig()->reparseConfiguration();
        }
#endif
        const QWidgetList widgets = QApplication::allWidgets();
        for (QWidget *w : widgets) {
            QEvent pc(QEvent::PaletteChange);
            QApplication::sendEvent(w, &pc);
            QEvent apc(QEvent::ApplicationPaletteChange);
            QApplication::sendEvent(w, &apc);
        }
    });
}

extern "C" void _ZN7QWidget10setVisibleEb(QWidget *self, bool visible)
{
    static auto real = reinterpret_cast<void (*)(QWidget *, bool)>(
        dlsym(RTLD_NEXT, "_ZN7QWidget10setVisibleEb"));
    if (visible && self && !self->testAttribute(Qt::WA_StyledBackground)) {
        const char *cn = self->metaObject()->className();
        if (!std::strcmp(cn, "InformationPanel") || !std::strcmp(cn, "TerminalPanel")
            || !std::strcmp(cn, "FoldersPanel")
            // The URL navigator is also a plain QWidget (QSS-background-inert):
            // styling it directly only painted a thin padding edge, and the
            // breadcrumb children covered the rest, so the box stayed a stale
            // color on wallpaper change. Flipping WA_StyledBackground makes its
            // QSS rounded box actually paint, and (with the navigator's children
            // forced transparent in the QSS) that live secondary box is what the
            // breadcrumbs ride on — so the URL box recolors with everything else.
            || !std::strcmp(cn, "DolphinUrlNavigator") || !std::strcmp(cn, "KUrlNavigator"))
            self->setAttribute(Qt::WA_StyledBackground, true);
    }
    if (visible)
        initQssWatcher();
    real(self, visible);
}
