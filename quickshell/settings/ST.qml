pragma Singleton
import Quickshell
import QtQuick

// The Settings window, for the pages and row components in this folder: they
// are separate files, so they cannot see its id. Settings.qml sets `win` when
// it is created. Colors are re-exported so a row reads ST.fg, not ST.win.fg.
Singleton {
    property var win: null

    readonly property color fg:         win ? win.fg : "#ffffff"
    readonly property color rowBg:      win ? win.rowBg : Qt.rgba(1, 1, 1, 0.10)
    readonly property color rowHover:   win ? win.rowHover : Qt.rgba(1, 1, 1, 0.18)
    readonly property color blockColor: win ? win.blockColor : "#1e1e2e"
    readonly property string ff:        win ? win.ff : "sans"
}
