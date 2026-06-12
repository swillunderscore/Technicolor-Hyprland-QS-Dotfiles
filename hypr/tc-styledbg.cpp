// tc-styledbg.cpp — LD_PRELOAD shim for the technicolor Dolphin theme.
//
// Dolphin's InformationPanel is a plain QWidget: Qt documents that QSS
// backgrounds are inert on those (no paintEvent), so the right panel could
// only be filled square via autoFillBackground — no rounded block possible.
// This shim flips Qt::WA_StyledBackground on it as it becomes visible, which
// makes QStyleSheetStyle paint the full QSS box (background, border-radius,
// margin) like any styled widget.
//
// Mechanism: interpose QWidget::setVisible (vtable slots resolve through the
// dynamic linker, so LD_PRELOAD wins even for virtual dispatch). Only depends
// on the Qt6 ABI (stable across Qt 6.x); widgets are matched by class NAME,
// so Dolphin updates don't affect it. If the .so ever fails to load, dolphin
// just runs with the square panel — nothing breaks.
//
// Built automatically by dolphin-tc.sh when missing or older than this file.
#include <QWidget>
#include <cstring>
#include <dlfcn.h>

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
    real(self, visible);
}
