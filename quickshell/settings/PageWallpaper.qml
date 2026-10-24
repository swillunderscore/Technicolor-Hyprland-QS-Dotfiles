import QtQuick
import Quickshell

// Settings → Wallpaper: folder + cover flow, switch transition, auto-cycle.
SmoothList {
    id: page
    readonly property var s: ST.win
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        Section { title: "Wallpapers"; first: true }

        // ── folder: current path + Change… ──
        Rectangle {
            width: parent.width; height: 54; radius: 9; color: ST.rowBg
            Column {
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.right: chgBtn.left; anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter; spacing: 2
                Text { text: "Folder"; color: ST.fg; font.pixelSize: 13; font.bold: true; font.family: ST.ff }
                Text { width: parent.width; text: page.s.wallpaperDir; color: ST.fg; opacity: 0.7; font.pixelSize: 11; font.family: ST.ff; elide: Text.ElideMiddle }
            }
            TcButton {
                id: chgBtn
                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                width: 92; height: 30
                text: "Change…"
                onClicked: page.s.pickWallpaperDir()
            }
        }

        // ── cover flow ──
        Rectangle {
            width: parent.width; height: 300; radius: 12
            color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.06)
            clip: true

            PathView {
                id: coverflow
                anchors.fill: parent
                model: page.s.wallpaperList
                pathItemCount: 9
                // No cache items: PathView builds those asynchronously, and this
                // page is destroyed whenever you switch away — mid-build that
                // logged "destroyed during incubation". The thumbnails load
                // asynchronously anyway, so on-demand delegates are cheap.
                cacheItemCount: 0
                snapMode: PathView.SnapToItem
                highlightRangeMode: PathView.StrictlyEnforceRange
                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightMoveDuration: 260
                dragMargin: height       // draggable anywhere in the strip
                clip: true

                readonly property real cardH: height * 0.62
                readonly property real cardW: cardH * 16 / 9

                function syncToCurrent() {
                    for (var i = 0; i < page.s.wallpaperList.length; i++)
                        if (page.s.wallpaperList[i].src === page.s.currentWallpaper) { currentIndex = i; return }
                }
                Component.onCompleted: syncToCurrent()
                Connections {
                    target: page.s
                    function onWallpaperListChanged() { coverflow.syncToCurrent() }
                    function onCurrentWallpaperChanged() { coverflow.syncToCurrent() }
                }

                path: Path {
                    startX: 0; startY: coverflow.height / 2
                    PathAttribute { name: "iScale"; value: 0.55 }
                    PathAttribute { name: "iAngle"; value: 60 }
                    PathAttribute { name: "iZ"; value: 0 }
                    PathAttribute { name: "iOpac"; value: 0.4 }
                    PathLine { x: coverflow.width * 0.5 - coverflow.cardW * 0.12; y: coverflow.height / 2 }
                    PathPercent { value: 0.46 }
                    PathAttribute { name: "iScale"; value: 1.0 }
                    PathAttribute { name: "iAngle"; value: 0 }
                    PathAttribute { name: "iZ"; value: 100 }
                    PathAttribute { name: "iOpac"; value: 1.0 }
                    PathLine { x: coverflow.width * 0.5 + coverflow.cardW * 0.12; y: coverflow.height / 2 }
                    PathPercent { value: 0.54 }
                    PathLine { x: coverflow.width; y: coverflow.height / 2 }
                    PathAttribute { name: "iScale"; value: 0.55 }
                    PathAttribute { name: "iAngle"; value: -60 }
                    PathAttribute { name: "iZ"; value: 0 }
                    PathAttribute { name: "iOpac"; value: 0.4 }
                }

                delegate: Item {
                    id: dg
                    required property var modelData
                    required property int index
                    width: coverflow.cardW
                    height: coverflow.cardH
                    z: PathView.iZ === undefined ? 0 : PathView.iZ
                    scale: PathView.iScale === undefined ? 1 : PathView.iScale
                    opacity: PathView.iOpac === undefined ? 1 : PathView.iOpac
                    transform: Rotation {
                        origin.x: dg.width / 2; origin.y: dg.height / 2
                        axis { x: 0; y: 1; z: 0 }
                        angle: dg.PathView.iAngle === undefined ? 0 : dg.PathView.iAngle
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 10; color: "#000000"; clip: true
                        border.width: dg.PathView.isCurrentItem ? 3 : 0
                        border.color: ST.fg
                        Image {
                            anchors.fill: parent
                            source: dg.modelData.thumb ? "file://" + dg.modelData.thumb : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true; cache: true
                            sourceSize.width: 480; sourceSize.height: 270
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (coverflow.currentIndex === dg.index) page.s.applyWallpaper(dg.modelData.src)
                            else coverflow.currentIndex = dg.index
                        }
                    }
                }

                // vertical wheel → horizontal flow
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (ev) => {
                        var d = ev.angleDelta.y !== 0 ? ev.angleDelta.y : ev.angleDelta.x
                        if (d > 0) coverflow.decrementCurrentIndex()
                        else if (d < 0) coverflow.incrementCurrentIndex()
                    }
                }
            }

            // ‹ › nudge buttons (for no-wheel / discoverability)
            Repeater {
                model: [ { left: true, glyph: 0xF053 }, { left: false, glyph: 0xF054 } ]
                delegate: Rectangle {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: modelData.left ? parent.left : undefined
                    anchors.right: modelData.left ? undefined : parent.right
                    anchors.margins: 8
                    width: 34; height: 48; radius: 8
                    visible: page.s.wallpaperList.length > 1
                    color: navM.containsMouse ? ST.rowHover : Qt.rgba(0, 0, 0, 0.35)
                    Text { anchors.centerIn: parent; text: String.fromCodePoint(modelData.glyph); color: "#ffffff"; font.pixelSize: 16; font.family: ST.ff }
                    MouseArea { id: navM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: modelData.left ? coverflow.decrementCurrentIndex() : coverflow.incrementCurrentIndex() }
                }
            }

            // empty / loading state
            Text {
                anchors.centerIn: parent
                visible: page.s.wallpaperList.length === 0
                text: page.s.wpThumbsRunning ? "Preparing previews…" : "No wallpapers in this folder"
                color: ST.fg; opacity: 0.6; font.pixelSize: 13; font.family: ST.ff
            }
        }

        // ── light/dark: which mode the centered wallpaper shows in ──
        Row {
            width: parent.width; spacing: 10
            visible: page.s.wallpaperList.length > 0
            Text { id: showsLbl; anchors.verticalCenter: parent.verticalCenter
                text: "Shows in"; color: ST.fg; font.pixelSize: 12; font.bold: true; font.family: ST.ff }
            Chips {
                readonly property var cur: page.s.wallpaperList[coverflow.currentIndex]
                width: parent.width - showsLbl.width - 10
                model: [{ id: "light", name: "Light mode" }, { id: "dark", name: "Dark mode" }, { id: "both", name: "Both" }]
                selected: cur ? page.s.wallpaperModeOf(cur.src) : ""
                onPicked: (id) => { if (cur && id !== selected) page.s.moveWallpaperMode(cur.src, id) }
            }
        }

        // ── shuffle + open folder (cycle/random merged: rotation is random) ──
        Row {
            width: parent.width; height: 40; spacing: 8
            TcButton {
                width: (parent.width - 8) / 2; height: 40
                text: String.fromCodePoint(0xF074) + "  Shuffle wallpaper"
                onClicked: Quickshell.execDetached(["sh", "-c", "~/.config/hypr/wallpaper-cycle.sh random"])
            }
            TcButton {
                width: (parent.width - 8) / 2; height: 40
                text: String.fromCodePoint(0xF07C) + "  Open folder"
                onClicked: Quickshell.execDetached(["sh", "-c", "~/.config/hypr/open-folder.sh '" + page.s.wallpaperDir + "'"])
            }
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.6; font.pixelSize: 11; font.family: ST.ff
            text: "Scroll to browse · click a cover to center it · click the centered one to set it. The covers are the current light/dark mode's wallpapers: the folder's light/ or dark/ subfolder, plus the ones loose in the folder, which show in both." }

        // ── switch transition ──
        Section {
            title: "Transition"
            desc: {
                for (var i = 0; i < page.s.transitions.length; i++)
                    if (page.s.transitions[i].id === page.s.transitionMode) return "Applies on the next wallpaper change — " + page.s.transitions[i].desc + "."
                return ""
            }
        }
        Chips {
            model: page.s.transitions
            selected: page.s.transitionMode
            onPicked: (id) => page.s.setTransition(id)
        }
        Row {
            spacing: 8
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Renders on"; color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
            Chips {
                width: 140
                model: [ { id: "gpu", name: "GPU" }, { id: "cpu", name: "CPU" } ]
                selected: page.s.transitionRender
                onPicked: (id) => page.s.setTransitionRender(id)
            }
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.6; font.pixelSize: 11; font.family: ST.ff
            text: page.s.transitionRender === "cpu"
                ? "Classic frame compositor — keeps the graphics card free (pick this if your games are GPU-bound)."
                : "Overlay reveal — both wallpapers keep animating, work happens on the graphics card (pick this if your games are CPU-bound). Video wallpapers always use the CPU path."
        }

        // ── auto-cycle timer ──
        Section { title: "Auto-cycle" }
        SliderRow {
            // dimmed while paused — it has no effect then
            opacity: page.s.cyclePaused ? 0.45 : 1.0
            label: "Change wallpaper every"
            valueText: page.s.cycleInterval + (page.s.cycleInterval === 1 ? " minute" : " minutes")
            resettable: false
            from: 1; to: 120; value: page.s.cycleInterval
            onMoved: (v) => page.s.cycleInterval = Math.round(v)
            onCommitted: (v) => page.s.writeTimerConf()
        }
        ToggleRow {
            title: "Pause auto-cycle"
            desc: "Stop rotating wallpapers entirely until you switch this back off."
            on: page.s.cyclePaused
            onToggled: (v) => { page.s.cyclePaused = v; page.s.writeTimerConf() }
        }
        ToggleRow {
            title: "Pause during fullscreen apps"
            desc: "Hold off while a game or fullscreen video is open — no transition stutter or CPU spike mid-game. Cycles as soon as you exit."
            on: page.s.cyclePauseFs
            onToggled: (v) => { page.s.cyclePauseFs = v; page.s.writeTimerConf() }
        }
    }
}
