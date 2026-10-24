import QtQuick
import Quickshell.Services.SystemTray

// Settings → Bar & Apps: how the bar draws its app icons, which tray icons it
// shows, and the pinned launchers (launcher-apps.json, via the bar's pin functions).
SmoothList {
    id: page
    readonly property var s: ST.win
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        Section { title: "Bar icons"; first: true }
        ToggleRow {
            title: "Tint launcher icons"
            desc: "Recolor the pinned app icons along the wallpaper gradient. Off shows each app's own icon colors."
            on: page.s && page.s.shell ? page.s.shell.launcherTint : true
            onToggled: (v) => page.s.setBarOption("LAUNCHER_TINT", v)
        }
        ToggleRow {
            title: "Dim minimized icons"
            desc: "Show minimized windows' icons half see-through until you hover them."
            on: page.s && page.s.shell ? page.s.shell.dimMinimized : false
            onToggled: (v) => page.s.setBarOption("DIM_MINIMIZED", v)
        }

        Section {
            title: "Tray icons"
            desc: "Turn one off to keep it out of the bar's tray. The app keeps running. Only apps that are running right now are listed."
        }
        Repeater {
            model: SystemTray.items
            delegate: ToggleRow {
                required property var modelData
                title: modelData.title !== "" ? modelData.title : modelData.id
                on: page.s && page.s.shell ? page.s.shell.trayHidden.indexOf(modelData.id) < 0 : true
                onToggled: (v) => page.s.setTrayShown(modelData.id, v)
            }
        }

        Section {
            title: "Pinned apps"
            desc: "Edit a launch command in place; ▲▼ reorder, the picture icon sets a custom image."
            Rectangle {
                width: 92; height: 28; radius: 8
                color: addM.containsMouse ? ST.rowHover : ST.rowBg
                Text { anchors.centerIn: parent; text: "＋ Add app"; color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
                MouseArea { id: addM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.s.addOpen = true }
            }
        }
        Repeater {
            model: page.s && page.s.bar ? page.s.bar.allAppPins : []
            delegate: Rectangle {
                id: pin
                required property int index
                required property var modelData
                width: col.width; height: 44; radius: 9; color: ST.rowBg
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                    Image {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26; height: 26; sourceSize.width: 64; sourceSize.height: 64; smooth: true
                        source: pin.modelData.imgPath && pin.modelData.imgPath !== "" ? pin.modelData.imgPath
                                : (page.s.bar ? page.s.bar.resolveAppIcon(pin.modelData.icon, "") : "")
                    }
                    // editable launch command — click to fix things like
                    // Kate's ".desktop"-derived "kate -b" down to just "kate".
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: pin.width - 220; height: 26; radius: 6
                        color: cmdIn.activeFocus ? Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.10) : "transparent"
                        TextInput {
                            id: cmdIn
                            anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                            verticalAlignment: TextInput.AlignVCenter
                            text: pin.modelData.cmd; color: ST.fg; font.pixelSize: 12; font.family: ST.ff
                            clip: true; selectByMouse: true
                            onEditingFinished: { if (page.s.bar && text !== pin.modelData.cmd) page.s.bar.setPinCmd(pin.index, text) }
                        }
                    }
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 4
                    Repeater {
                        model: [
                            { glyph: "▲", danger: false, act: "up" },
                            { glyph: "▼", danger: false, act: "down" },
                            { glyph: String.fromCodePoint(0xF03E), danger: false, act: "image" },
                            { glyph: String.fromCodePoint(0xF00D), danger: true, act: "remove" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            width: 28; height: 28; radius: 6
                            color: bm.containsMouse ? (modelData.danger ? Qt.rgba(0.9, 0.3, 0.3, 0.35) : ST.rowHover) : "transparent"
                            Text { anchors.centerIn: parent; text: modelData.glyph; color: ST.fg; font.pixelSize: 11; font.family: ST.ff }
                            MouseArea {
                                id: bm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.act === "image") { page.s.pickImage(pin.index); return }
                                    if (!page.s.bar) return
                                    if (modelData.act === "up") page.s.bar.movePin(pin.index, -1)
                                    else if (modelData.act === "down") page.s.bar.movePin(pin.index, 1)
                                    else page.s.bar.removePinAt(pin.index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
