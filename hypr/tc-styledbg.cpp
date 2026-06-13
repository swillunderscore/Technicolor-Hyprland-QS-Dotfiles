// tc-styledbg.cpp — LD_PRELOAD shim for the technicolor Dolphin theme.
//
// Two jobs:
//
// 1) Dolphin's InformationPanel is a plain QWidget: Qt documents that QSS
//    backgrounds are inert on those (no paintEvent), so the right panel could
//    only be filled square via autoFillBackground — no rounded block possible.
//    This shim flips Qt::WA_StyledBackground on it as it becomes visible,
//    which makes QStyleSheetStyle paint the full QSS box (background,
//    border-radius, margin) like any styled widget.
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
#include <QDir>
#include <QFile>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QWidget>
#include <cstring>
#include <dlfcn.h>

static void initQssWatcher()
{
    static bool done = false;
    if (done || !qApp)
        return;
    done = true;
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
        QFile f(path);
        if (f.open(QIODevice::ReadOnly))
            qApp->setStyleSheet(QString::fromUtf8(f.readAll()));
    });
}

extern "C" void _ZN7QWidget10setVisibleEb(QWidget *self, bool visible)
{
    static auto real = reinterpret_cast<void (*)(QWidget *, bool)>(
        dlsym(RTLD_NEXT, "_ZN7QWidget10setVisibleEb"));
    if (visible && self && !self->testAttribute(Qt::WA_StyledBackground)) {
        const char *cn = self->metaObject()->className();
        if (!std::strcmp(cn, "InformationPanel") || !std::strcmp(cn, "TerminalPanel")
            || !std::strcmp(cn, "FoldersPanel"))
            self->setAttribute(Qt::WA_StyledBackground, true);
    }
    if (visible)
        initQssWatcher();
    real(self, visible);
}
