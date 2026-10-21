import QtQuick
import Quickshell

// Settings → System: font, default apps, updates, Spotify tools, and the
// machine-local Hyprland config.
SmoothList {
    id: page
    readonly property var s: ST.win
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        // ── UI font (bar + this window live; wofi via gen-wofi-font.sh) ──
        Section {
            title: "Font"; first: true
            Text { text: page.s.effFont; color: ST.fg; opacity: 0.7; font.pixelSize: 12; font.family: ST.ff }
        }
        Rectangle {
            width: parent.width; height: 30; radius: 8; color: ST.rowBg
            TextInput { id: fontSearchIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter; color: ST.fg; font.pixelSize: 12; font.family: ST.ff; clip: true
                text: page.s.fontSearch
                onTextChanged: page.s.fontSearch = text }
            Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                visible: fontSearchIn.text === ""; text: "Search fonts…"; color: ST.fg; opacity: 0.45; font.pixelSize: 12; font.family: ST.ff }
        }
        // A ListView, so only the rows in view exist. Each row loads its own
        // font to preview it; building all ~300 up front held the window's first
        // frame back ~0.4 s whenever it opened on this page.
        SmoothList {
            width: parent.width; height: page.s.fontListH
            ListView {
                id: fontList
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds
                model: {
                    var q = page.s.fontSearch.toLowerCase()
                    if (q === "") return page.s.installedFonts
                    var r = []
                    for (var i = 0; i < page.s.installedFonts.length; i++)
                        if (page.s.installedFonts[i].toLowerCase().indexOf(q) >= 0) r.push(page.s.installedFonts[i])
                    return r
                }
                delegate: Rectangle {
                    required property var modelData
                    width: fontList.width; height: 28; radius: 7
                    color: page.s.effFont === modelData ? ST.rowHover : (fRowM.containsMouse ? ST.rowBg : "transparent")
                    Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                        text: modelData; color: ST.fg; font.pixelSize: 13; font.family: modelData }   // previewed in its own font
                    MouseArea { id: fRowM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.s.setFont(modelData) }
                }
            }
        }
        DragDivider { width: parent.width; onDragged: (dy) => page.s.fontListH = Math.max(90, Math.min(520, page.s.fontListH + dy)) }

        // ── Default apps ──
        Section { title: "Default apps" }
        Text { text: "File manager"; color: ST.fg; opacity: 0.85; font.pixelSize: 12; font.family: ST.ff }
        Chips {
            model: page.s.fileManagers
            selected: page.s.defaultFM
            onPicked: (id) => page.s.setFM(id)
        }
        Text { text: "Terminal (Super+Q, and Dolphin's Open Terminal)"; color: ST.fg; opacity: 0.85; font.pixelSize: 12; font.family: ST.ff }
        Chips {
            // Chips select by id; a terminal is identified by its command.
            model: page.s.terminals.map(t => ({ id: t.cmd, name: t.name }))
            selected: page.s.currentTerminal
            onPicked: (id) => page.s.setTerminal(id)
        }

        // ── Update (pull latest from GitHub) ──
        Section {
            title: "Update"
            desc: "Pull the latest Technicolor from GitHub and copy it in. Your colors, glass, font, pins, monitors and local.conf are kept (they're gitignored)."
        }
        Row {
            width: parent.width; height: 36; spacing: 8
            TcButton {
                width: (parent.width - 8) / 2
                enabled: !page.s.checking
                text: page.s.checking ? "Checking…" : "Check for updates"
                onClicked: page.s.runCheck()
            }
            TcButton {
                width: (parent.width - 8) / 2
                enabled: !page.s.updateRunning
                armed: page.s.updateArmed
                text: page.s.updateArmed ? "Click again to confirm" : (page.s.updateRunning ? "Updating…" : "Update now")
                onClicked: page.s.runUpdate()
            }
        }
        // what's new (preview before updating)
        Text { visible: page.s.commitCount !== ""; color: ST.fg; opacity: 0.8; font.pixelSize: 12; font.bold: true; font.family: ST.ff
            text: page.s.commitCount === "0" ? "You're up to date."
                : (page.s.commitCount === "?" ? "Latest changes on GitHub:"
                : page.s.commitCount + (page.s.commitCount === "1" ? " new commit:" : " new commits:")) }
        SmoothList {
            visible: page.s.newCommits.length > 0
            width: parent.width; height: Math.min(170, page.s.newCommits.length * 24 + 8); contentHeight: commitCol.height
            Column {
                id: commitCol; width: parent.width; spacing: 0
                Repeater {
                    model: page.s.newCommits
                    delegate: Text {
                        required property var modelData
                        width: commitCol.width; height: 24; verticalAlignment: Text.AlignVCenter
                        text: modelData; color: ST.fg; opacity: 0.8; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight
                    }
                }
            }
        }
        Text { width: parent.width; visible: page.s.updateStatus !== ""; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.7; font.pixelSize: 11; font.family: "monospace"
            text: page.s.updateStatus }

        // ── Liked Songs tools (Spotify, via your Spicetify session) ──
        Section {
            title: "Spotify Liked Songs"
            desc: "Runs through your open Spotify (no login or dev app, read-only). Scan checks your likes against a known-AI-artist list; Back up writes them all to a CSV (~/spotify-liked-DATE.csv) so you never lose your library."
        }
        Row {
            width: parent.width; height: 36; spacing: 8
            TcButton {
                width: (parent.width - 8) / 2
                enabled: !page.s.likedBusy
                text: page.s.likedScanRunning ? "Scanning…" : "Scan for AI music"
                onClicked: page.s.scanLiked()
            }
            TcButton {
                width: (parent.width - 8) / 2
                enabled: !page.s.likedBusy
                text: page.s.likedExportRunning ? "Backing up…" : "Back up to CSV"
                onClicked: page.s.exportLiked()
            }
        }
        Text { width: parent.width; visible: page.s.likedStatus !== ""; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.75; font.pixelSize: 11; font.family: "monospace"
            text: page.s.likedStatus }

        // ── local.conf (advanced) ──
        Section {
            title: "Advanced — local.conf"
            desc: "~/.config/hypr/local.conf: GPU, input, monitors, anything machine-specific. Save, then Apply to reload Hyprland."
        }
        Rectangle {
            width: parent.width; height: page.s.confEditH; radius: 9; color: ST.rowBg
            Flickable {
                anchors.fill: parent; anchors.margins: 8; clip: true
                contentWidth: width; contentHeight: confEdit.paintedHeight
                TextEdit {
                    id: confEdit
                    width: parent.width
                    color: ST.fg; font.pixelSize: 12; font.family: "monospace"
                    selectByMouse: true; wrapMode: TextEdit.NoWrap
                    textFormat: TextEdit.PlainText
                    // The file's text lives on the window (confText) so Save works
                    // from there; edits flow back as you type.
                    text: page.s.confText
                    onTextChanged: if (text !== page.s.confText) page.s.confText = text
                }
            }
        }
        DragDivider { width: parent.width; onDragged: (dy) => page.s.confEditH = Math.max(100, Math.min(560, page.s.confEditH + dy)) }
        Row {
            width: parent.width; height: 34; spacing: 8
            TcButton { width: (parent.width - 8) / 2; height: 34; text: "Save"; onClicked: page.s.saveConf() }
            TcButton { width: (parent.width - 8) / 2; height: 34; text: "Save & Apply (reload Hyprland)"
                onClicked: { page.s.saveConf(); Quickshell.execDetached(["hyprctl", "reload"]) } }
        }
    }
}
