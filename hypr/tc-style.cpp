// tc-style.cpp — a QProxyStyle that ONLY enlarges the tab close button.
//
// WHY: Breeze sizes the QTabBar close button from PM_TabCloseIndicatorWidth/
// Height (~16px) and Qt ignores QSS width/height for it, so the hover disc baked
// into the close-button icon was hard-capped tiny. This proxy raises just those
// two metrics; everything else passes through unchanged.
//
// CRITICAL — preserve the look: the proxy MUST wrap the user's configured style
// (qt6ct -> Breeze). A null base makes QProxyStyle pick the platform default
// instead, which visibly changes every widget. So we read the style name from
// qt6ct.conf and wrap a fresh instance of exactly that.
//
// The CloseButtons cache their size at startup before this installs, so we
// recreate them (toggle tabsClosable) to re-query the new metric.
//
// Separate .so (not in tc-styledbg.so): QProxyStyle's vtable is a QtWidgets DATA
// symbol resolved at load; tc-styledbg.so is LD_PRELOADed into the QtCore-only
// kioworker and would crash. This is dlopen()ed only from the GUI-only watcher.
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QProxyStyle>
#include <QString>
#include <QStyle>
#include <QStyleFactory>
#include <QTabBar>
#include <QTimer>
#include <QWidget>

namespace {
const int CLOSE_SIZE = 20;

class TcStyle : public QProxyStyle {
public:
    explicit TcStyle(QStyle *base) : QProxyStyle(base) {}
    int pixelMetric(PixelMetric metric, const QStyleOption *opt,
                    const QWidget *widget) const override
    {
        if (metric == PM_TabCloseIndicatorWidth || metric == PM_TabCloseIndicatorHeight)
            return CLOSE_SIZE;
        return QProxyStyle::pixelMetric(metric, opt, widget);
    }
};

QString baseStyleKey()
{
    QFile cf(QDir::homePath() + "/.config/qt6ct/qt6ct.conf");
    if (cf.open(QIODevice::ReadOnly)) {
        const QString txt = QString::fromUtf8(cf.readAll());
        const QStringList lines = txt.split('\n');
        for (const QString &line : lines)
            if (line.startsWith("style="))
                return line.mid(6).trimmed();
    }
    return QStringLiteral("Breeze");
}

void refreshTabBars()
{
    const QWidgetList all = QApplication::allWidgets();
    for (QWidget *w : all)
        if (auto *tb = qobject_cast<QTabBar *>(w))
            if (tb->tabsClosable()) {
                tb->setTabsClosable(false);
                tb->setTabsClosable(true);
            }
}
}

extern "C" void tc_install_style()
{
    static bool done = false;
    if (done || !qApp)
        return;
    QStyle *base = QStyleFactory::create(baseStyleKey());
    if (!base)
        base = QStyleFactory::create(QStringLiteral("Breeze"));
    if (!base)
        return;  // never replace the style with the wrong base — leave it alone
    done = true;
    qApp->setStyle(new TcStyle(base));
    QTimer::singleShot(400, qApp, refreshTabBars);
}
