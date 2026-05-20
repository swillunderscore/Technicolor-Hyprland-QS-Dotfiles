// AltTabPie.qml — Pie menu showing all open windows, triggered by alt+tab
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

Scope {
    id: pieRoot

    property bool menuVisible: false
    property var windowList: []
    property int selectedIndex: -1
    property int cursorX: 0
    property int cursorY: 0
    property var targetScreen: null

    readonly property int pieRadius: 140
    readonly property int itemSize: 60
    readonly property int iconSize: 40
    readonly property string fontFamily: Quickshell.env("QS_FONT") || "SF Pro"

    property var barRef: null

    // Fetch window list and cursor position
    Process {
        id: fetchProc
        command: ["bash", "-c",
            "echo '---CURSOR---'; hyprctl cursorpos -j; echo '---WINDOWS---'; " +
            "hyprctl clients -j | jq -c '[.[] | select(.mapped == true and .hidden == false and .class != \"\" and .class != \"quickshell\") | {address, title, class, workspace: .workspace.id, floating: .floating}]'"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                var text = this.text
                var cursorPart = text.split("---WINDOWS---")[0].replace("---CURSOR---", "").trim()
                var windowPart = text.split("---WINDOWS---")[1].trim()

                try {
                    var cur = JSON.parse(cursorPart)
                    pieRoot.cursorX = cur.x
                    pieRoot.cursorY = cur.y
                } catch(e) {
                    pieRoot.cursorX = 960
                    pieRoot.cursorY = 540
                }

                try {
                    pieRoot.windowList = JSON.parse(windowPart)
                } catch(e) {
                    pieRoot.windowList = []
                }

                // Find which screen the cursor is on using Hyprland monitors
                var mons = Hyprland.monitors.values
                for (var i = 0; i < mons.length; i++) {
                    var m = mons[i]
                    var mx = m.x
                    var my = m.y
                    var mw = m.width
                    var mh = m.height
                    if (pieRoot.cursorX >= mx && pieRoot.cursorX < mx + mw &&
                        pieRoot.cursorY >= my && pieRoot.cursorY < my + mh) {
                        // Find the matching Quickshell screen
                        var screens = Quickshell.screens
                        for (var j = 0; j < screens.length; j++) {
                            var qs = Hyprland.monitorFor(screens[j])
                            if (qs && qs.id === m.id) {
                                pieRoot.targetScreen = screens[j]
                                break
                            }
                        }
                        break
                    }
                }

                if (pieRoot.windowList.length > 0) {
                    pieRoot.selectedIndex = 0
                    pieRoot.menuOpenedAt = Date.now()
                    pieRoot.menuVisible = true
                }
            }
        }
    }

    function showMenu() {
        pieRoot.menuVisible = false
        pieRoot.windowList = []
        pieRoot.selectedIndex = -1
        pieRoot.mouseMovedFromCenter = false
        fetchProc.running = true
    }

    function activateSelected() {
        if (selectedIndex < 0 || selectedIndex >= windowList.length) {
            pieRoot.menuVisible = false
            return
        }
        var win = windowList[selectedIndex]
        pieRoot.menuVisible = false

        var monState = Hyprland.focusedMonitor
        var currentWs = monState ? monState.activeWorkspace.id : 1
        Hyprland.dispatch("movetoworkspacesilent " + currentWs + ",address:" + win.address)
        Hyprland.dispatch("focuswindow address:" + win.address)
        // Toggle float and back — forces re-tile on the current monitor
        // Fixes windows retaining offscreen coordinates from other monitor layouts
        Hyprland.dispatch("togglefloating address:" + win.address)
        Hyprland.dispatch("togglefloating address:" + win.address)
    }

    function close() {
        pieRoot.menuVisible = false
        pieRoot.windowList = []
        pieRoot.selectedIndex = -1
    }

    property bool mouseMovedFromCenter: false
    property real menuOpenedAt: 0

    // Global shortcut — triggered by Hyprland bind
    GlobalShortcut {
        name: "alttab"
        onPressed: pieRoot.showMenu()
    }

    // Release shortcut — selects the hovered item
    GlobalShortcut {
        name: "alttabrelease"
        onPressed: {
            // Ignore if menu just opened (macro might release immediately)
            if (Date.now() - pieRoot.menuOpenedAt < 300) return
            if (pieRoot.menuVisible && pieRoot.mouseMovedFromCenter && pieRoot.selectedIndex >= 0) {
                pieRoot.activateSelected()
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: pieWindow
            property var modelData
            screen: modelData

            // Visible on ALL screens when pie is open — non-target screens are just click-catchers
            visible: pieRoot.menuVisible
            readonly property bool isTarget: pieRoot.targetScreen === modelData
            color: "transparent"
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quickshell:pie"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            // Convert global cursor to screen-local using Hyprland monitor position
            readonly property var hyprMon: Hyprland.monitorFor(modelData)
            readonly property real localX: pieRoot.cursorX - (hyprMon ? hyprMon.x : 0)
            readonly property real localY: pieRoot.cursorY - (hyprMon ? hyprMon.y : 0)

            // Full-screen input catcher + keyboard handler
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.01)
                focus: true
                Keys.onEscapePressed: pieRoot.close()
                Keys.onReleased: function(event) {
                    if (event.key === Qt.Key_Alt && pieRoot.mouseMovedFromCenter && pieRoot.selectedIndex >= 0) {
                        pieRoot.activateSelected()
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: pieRoot.close()
                }
            }

            // Dim background circle at cursor — only on target screen
            Rectangle {
                visible: pieWindow.isTarget
                x: pieWindow.localX - width / 2
                y: pieWindow.localY - height / 2
                width: (pieRoot.pieRadius + pieRoot.itemSize) * 2 + 20
                height: width
                radius: width / 2
                color: Qt.rgba(0, 0, 0, 0.4)
            }

            // Center dot
            Rectangle {
                visible: pieWindow.isTarget
                x: pieWindow.localX - 4
                y: pieWindow.localY - 4
                width: 8; height: 8; radius: 4
                color: Qt.rgba(1, 1, 1, 0.3)
            }

            // Mouse tracker for slice selection — only on target screen
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                propagateComposedEvents: true
                acceptedButtons: Qt.NoButton
                visible: pieWindow.isTarget
                onPositionChanged: function(mouse) {
                    var cx = mouse.x - pieWindow.localX
                    var cy = mouse.y - pieWindow.localY
                    var dist = Math.sqrt(cx * cx + cy * cy)

                    if (dist < 30) return

                    pieRoot.mouseMovedFromCenter = true

                    var angle = Math.atan2(cy, cx)
                    if (angle < 0) angle += 2 * Math.PI

                    var count = pieRoot.windowList.length
                    if (count === 0) return

                    var sliceAngle = 2 * Math.PI / count
                    var adjustedAngle = (angle + Math.PI / 2 + sliceAngle / 2) % (2 * Math.PI)
                    var idx = Math.floor(adjustedAngle / sliceAngle)
                    if (idx >= count) idx = 0
                    pieRoot.selectedIndex = idx
                }
            }

            // Pie items — only on target screen
            Item {
                visible: pieWindow.isTarget
                anchors.fill: parent

            Repeater {
                model: pieRoot.windowList.length
                delegate: Item {
                    id: pieItem
                    required property int index
                    readonly property var winData: pieRoot.windowList[index]
                    readonly property bool isSelected: pieRoot.selectedIndex === index

                    readonly property int count: pieRoot.windowList.length
                    readonly property real angle: (index / count) * 2 * Math.PI - Math.PI / 2
                    readonly property real itemX: pieWindow.localX + Math.cos(angle) * pieRoot.pieRadius - pieRoot.itemSize / 2
                    readonly property real itemY: pieWindow.localY + Math.sin(angle) * pieRoot.pieRadius - pieRoot.itemSize / 2

                    x: itemX; y: itemY
                    width: pieRoot.itemSize; height: pieRoot.itemSize

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: pieItem.isSelected ? Qt.rgba(1, 1, 1, 0.25) : Qt.rgba(0, 0, 0, 0.6)
                        border.width: pieItem.isSelected ? 2 : 1
                        border.color: pieItem.isSelected ? "#CDD6F4" : Qt.rgba(1, 1, 1, 0.1)

                        scale: pieItem.isSelected ? 1.2 : 1.0
                        Behavior on scale { NumberAnimation { duration: 100 } }
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Image {
                            id: pieIcon; anchors.centerIn: parent
                            width: pieRoot.iconSize; height: width
                            sourceSize.width: 64; sourceSize.height: 64
                            mipmap: true; smooth: true
                            visible: status === Image.Ready
                            source: {
                                var cls = pieItem.winData ? pieItem.winData.class : ""
                                var ttl = pieItem.winData ? pieItem.winData.title : ""
                                if (!cls || cls === "") return ""
                                // Use bar's resolver if available
                                if (pieRoot.barRef) {
                                    void pieRoot.barRef.iconCacheReady
                                    void pieRoot.barRef.steamIconVersion
                                    try {
                                        var r = pieRoot.barRef.resolveAppIcon(cls, ttl)
                                        if (r !== "") return r
                                    } catch(e) {}
                                }
                                // Fallback: try iconPath directly
                                var p = Quickshell.iconPath(cls, true)
                                if (p !== "") return p
                                p = Quickshell.iconPath(cls.toLowerCase(), true)
                                if (p !== "") return p
                                var parts = cls.split(".")
                                if (parts.length > 1) {
                                    p = Quickshell.iconPath(parts[parts.length - 1], true)
                                    if (p !== "") return p
                                }
                                return Quickshell.iconPath(cls, false)
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !pieIcon.visible
                            text: pieItem.winData && pieItem.winData.class ? pieItem.winData.class[0].toUpperCase() : "?"
                            color: "#CDD6F4"
                            font.pixelSize: 18; font.family: pieRoot.fontFamily; font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pieRoot.selectedIndex = pieItem.index
                                pieRoot.activateSelected()
                            }
                        }
                    }

                    // Title label for selected item
                    Rectangle {
                        anchors.top: parent.bottom; anchors.topMargin: 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: titleText.implicitWidth + 12
                        height: titleText.implicitHeight + 6
                        radius: 4
                        color: Qt.rgba(0, 0, 0, 0.8)
                        visible: pieItem.isSelected

                        Text {
                            id: titleText
                            anchors.centerIn: parent
                            text: {
                                if (!pieItem.winData) return ""
                                var t = pieItem.winData.title || pieItem.winData.class || ""
                                return t.length > 30 ? t.substring(0, 27) + "..." : t
                            }
                            color: "#CDD6F4"
                            font.pixelSize: 11; font.family: pieRoot.fontFamily
                        }
                    }
                }
            }
            }
        }
    }
}

