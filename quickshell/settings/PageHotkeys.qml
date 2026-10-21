import QtQuick

// Settings → Hotkeys: a searchable cheat sheet built live from `hyprctl binds`,
// with click-to-rebind. The capture itself (submap + key sink) lives in
// Settings.qml, because it has to outlive this page's scroll position.
Item {
    id: page
    readonly property var s: ST.win

    Column {
        anchors.fill: parent; spacing: 10

        // search (stays put while the list scrolls)
        Rectangle {
            width: parent.width; height: 40; radius: 9; color: ST.rowBg
            TextInput {
                id: hkSearch
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                color: ST.fg; font.pixelSize: 13; font.family: ST.ff; clip: true
                selectByMouse: true; selectionColor: ST.rowHover
                text: page.s.hotkeySearch
                onTextChanged: page.s.hotkeySearch = text
                Text { anchors.verticalCenter: parent.verticalCenter; visible: hkSearch.text === ""
                       text: "Search shortcuts…"; color: ST.fg; opacity: 0.5; font.pixelSize: 13; font.family: ST.ff }
            }
        }

        // grouped, searchable cheat sheet
        SmoothList {
            width: parent.width; height: parent.height - 50; contentHeight: hkCol.height
            Column {
                id: hkCol; width: parent.width; spacing: 10
                Repeater {
                    model: page.s.hotkeyCategories
                    delegate: Column {
                        id: catCol
                        required property string modelData
                        property var rows: page.s.bindsFor(modelData)
                        width: hkCol.width; spacing: 3
                        visible: catCol.rows.length > 0
                        Text { topPadding: 4; text: catCol.modelData; color: ST.fg; opacity: 0.55
                               font.pixelSize: 11; font.bold: true; font.family: ST.ff }
                        Repeater {
                            model: catCol.rows
                            delegate: Rectangle {
                                id: hkRow
                                required property var modelData
                                property bool capturing: page.s.isCapturing(modelData)
                                property bool warning: page.s.isWarnRow(modelData)
                                width: catCol.width; height: 38; radius: 8
                                color: hkRow.capturing ? Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.12)
                                                       : (hkRowM.containsMouse ? ST.rowBg : "transparent")
                                Text {
                                    anchors.left: parent.left; anchors.leftMargin: 10
                                    anchors.right: rightRow.left; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight
                                    text: hkRow.modelData.label; color: ST.fg; font.pixelSize: 13; font.family: ST.ff
                                }
                                Row {
                                    id: rightRow
                                    anchors.right: parent.right; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 6

                                    // capture prompt
                                    Rectangle {
                                        visible: hkRow.capturing
                                        height: 24; radius: 6
                                        width: Math.min(pT.implicitWidth + 18, hkRow.width * 0.66)
                                        color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.18)
                                        border.width: 1; border.color: ST.fg
                                        Text { id: pT; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                               verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                               text: "Press a combo…  (Esc cancels)"
                                               color: ST.fg; font.pixelSize: 11; font.bold: true; font.family: ST.ff }
                                    }
                                    // conflict message — shown beside the (unchanged) keys for a few seconds
                                    Text {
                                        visible: hkRow.warning
                                        height: 24; verticalAlignment: Text.AlignVCenter
                                        width: Math.min(implicitWidth, hkRow.width * 0.5); elide: Text.ElideRight
                                        text: "⚠ " + page.s.captureWarn; color: "#ff6b6b"; font.pixelSize: 11; font.bold: true; font.family: ST.ff
                                    }
                                    // reset to the shipped default (only when overridden)
                                    Rectangle {
                                        visible: !hkRow.capturing && !hkRow.warning && hkRow.modelData.overridden
                                        height: 24; width: 24; radius: 6
                                        color: rstM.containsMouse ? ST.rowHover : ST.rowBg
                                        Text { anchors.centerIn: parent; text: "↺"; color: ST.fg; font.pixelSize: 14; font.family: ST.ff }
                                        MouseArea { id: rstM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: page.s.resetBind(hkRow.modelData) }
                                    }
                                    // keycaps — click to rebind (editable binds only)
                                    Rectangle {
                                        visible: !hkRow.capturing
                                        width: capsRow.implicitWidth + (hkRow.modelData.editable ? 14 : 0); height: 24; radius: 6
                                        color: (hkRow.modelData.editable && capM.containsMouse) ? ST.rowHover : "transparent"
                                        Row {
                                            id: capsRow
                                            anchors.centerIn: parent; spacing: 4
                                            Repeater {
                                                model: hkRow.modelData.caps
                                                delegate: Rectangle {
                                                    required property string modelData
                                                    height: 24; width: capT.implicitWidth + 16; radius: 6
                                                    color: ST.rowHover
                                                    border.width: 1; border.color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.18)
                                                    Text { id: capT; anchors.centerIn: parent; text: modelData
                                                           color: ST.fg; font.pixelSize: 11; font.bold: true; font.family: ST.ff }
                                                }
                                            }
                                        }
                                        MouseArea { id: capM; anchors.fill: parent; hoverEnabled: true
                                            enabled: hkRow.modelData.editable
                                            cursorShape: hkRow.modelData.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onClicked: page.s.startCapture(hkRow.modelData) }
                                    }
                                }
                                MouseArea { id: hkRowM; anchors.fill: parent; hoverEnabled: true; z: -1 }
                            }
                        }
                    }
                }
                Text {
                    width: parent.width; visible: page.s.hotkeyMatchCount === 0; topPadding: 8
                    text: page.s.keybinds.length === 0 ? "Loading shortcuts…" : "No shortcuts match your search."
                    color: ST.fg; opacity: 0.6; font.pixelSize: 13; font.family: ST.ff
                }
                Text {
                    width: parent.width; wrapMode: Text.WordWrap; topPadding: 6
                    color: ST.fg; opacity: 0.45; font.pixelSize: 11; font.family: ST.ff
                    text: "Click a shortcut's keys to rebind it — hold your modifiers (Super/Ctrl/Alt/Shift) and press the key. ↺ resets one to its default. Media, volume, mouse and Alt-Tab binds are fixed. Rebinds persist to " + (page.s.luaHotkeys ? "keybind-overrides.conf" : "keybinds.conf") + " and survive updates."
                }
            }
        }
    }
}
