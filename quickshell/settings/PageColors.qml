import QtQuick

// Settings → Colors: light/dark mode (Appearance, hypr/theme-mode.py), the
// global palette knobs (color-tuning.conf, applied by wallpaper-colors.py),
// per-surface tuning on top of them, and the Discord note.
SmoothList {
    id: page
    readonly property var s: ST.win
    // The swatches start from the colors BEFORE the sliders when they're known,
    // so either mode's set previews right; the bar's live colors otherwise.
    readonly property var palette: s && s.rawPalette.length === 5
        ? s.rawPalette.map(function (h) { return Qt.color(h) })
        : (s && s.bar
            ? [s.bar.gradientStart, s.bar.gradientEnd, s.bar.colorFocused, s.bar.colorVisible, s.bar.colorOccupied]
            : [])
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        // ── Appearance: light/dark mode (hypr/theme-mode.py) ──
        Section {
            title: "Appearance"; first: true
            desc: "Light or dark mode for the whole desktop. Auto switches at sunset and sunrise where you are — the same times Android's \"sunset to sunrise\" dark theme uses."
        }
        Chips {
            model: [{ id: "auto", name: "Auto (sunset to sunrise)" }, { id: "custom", name: "Custom times" },
                    { id: "light", name: "Light" }, { id: "dark", name: "Dark" }]
            selected: page.s.themeStatus.setting || "dark"
            onPicked: (id) => page.s.setTheme(["MODE=" + id])
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: page.s.themeLine(page.s.themeStatus)
            color: ST.fg; opacity: 0.7; font.pixelSize: 12; font.family: ST.ff
        }
        Column {
            width: parent.width; spacing: 6
            visible: page.s.themeStatus.setting === "auto"
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: page.s.themeStatus.location_source === "city" ? "Location: " + page.s.themeStatus.location
                    : page.s.themeStatus.location_source === "timezone"
                        ? "Location: " + page.s.themeStatus.location + " (your time zone's city). Search below to pick your own."
                        : "No location yet — search for your city. Until then the custom times are used."
                color: ST.fg; font.pixelSize: 12; font.family: ST.ff
            }
            Rectangle {
                width: parent.width; height: 30; radius: 8; color: ST.rowBg
                TextInput { id: cityIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter; color: ST.fg; font.pixelSize: 12; font.family: ST.ff; clip: true
                    text: page.s.citySearch
                    onTextChanged: page.s.citySearch = text }
                Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                    visible: cityIn.text === ""; text: "Search for your city…"; color: ST.fg; opacity: 0.45; font.pixelSize: 12; font.family: ST.ff }
            }
            Repeater {
                model: page.s.cityResults
                delegate: Rectangle {
                    required property var modelData
                    width: parent.width; height: 30; radius: 8
                    color: cityM.containsMouse ? ST.rowHover : ST.rowBg
                    Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name + (modelData.region !== "" ? ", " + modelData.region : "") + ", " + modelData.country
                        color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
                    MouseArea { id: cityM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { page.s.pickCity(modelData); cityIn.text = "" } }
                }
            }
        }
        Row {
            visible: page.s.themeStatus.setting === "custom"
            spacing: 10
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Dark from"; color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
            Rectangle {
                width: 100; height: 30; radius: 8; color: ST.rowBg
                TextInput { id: darkIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter; color: ST.fg; font.pixelSize: 12; font.family: ST.ff; clip: true
                    text: page.s.fmtClock(page.s.themeStatus.dark_at || "22:00")
                    onEditingFinished: {
                        var v = page.s.parseClock(text); if (v !== "") page.s.setTheme(["DARK_AT=" + v])
                        text = Qt.binding(function () { return page.s.fmtClock(page.s.themeStatus.dark_at || "22:00") })
                    } }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Light from"; color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
            Rectangle {
                width: 100; height: 30; radius: 8; color: ST.rowBg
                TextInput { id: lightIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter; color: ST.fg; font.pixelSize: 12; font.family: ST.ff; clip: true
                    text: page.s.fmtClock(page.s.themeStatus.light_at || "06:00")
                    onEditingFinished: {
                        var v = page.s.parseClock(text); if (v !== "") page.s.setTheme(["LIGHT_AT=" + v])
                        text = Qt.binding(function () { return page.s.fmtClock(page.s.themeStatus.light_at || "06:00") })
                    } }
            }
        }

        Section {
            title: "Palette"
            desc: "Every themed surface takes its colors from the wallpaper. These four knobs adjust that palette for all of them at once. Light and dark mode each keep their own set of these sliders (and of the per-surface ones below)."
        }
        Row {
            width: parent.width; spacing: 10
            Text { id: editLbl; anchors.verticalCenter: parent.verticalCenter
                text: "Editing"; color: ST.fg; font.pixelSize: 12; font.bold: true; font.family: ST.ff }
            Chips {
                width: parent.width - editLbl.width - 10
                model: [{ id: "light", name: "Light mode" }, { id: "dark", name: "Dark mode" }]
                selected: page.s.tuneEditMode
                onPicked: (id) => page.s.pickTuneMode(id)
            }
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap
            visible: !page.s.tuneEditingLive
            text: "The desktop is in " + (page.s.themeStatus.mode || "dark") + " mode now, so these show up at the next switch. The swatches preview them."
            color: ST.fg; opacity: 0.6; font.pixelSize: 11; font.family: ST.ff
        }

        // ── live preview swatches ──
        Row {
            width: parent.width; height: 56; spacing: 8
            Repeater {
                model: page.palette
                delegate: Rectangle {
                    required property var modelData
                    readonly property color shown: page.s.previewColor(modelData, page.s.tuneSaturation, page.s.tuneBrightness, page.s.tuneHue)
                    width: (parent.width - 8 * 4) / 5; height: 56; radius: 10
                    color: shown
                    Text { anchors.centerIn: parent; text: "Ag"; font.pixelSize: 18; font.bold: true; font.family: ST.ff
                        color: page.s.previewInk(parent.shown, page.s.tuneContrast) }
                }
            }
        }

        SliderRow {
            label: "Text contrast"
            valueText: page.s.tuneContrast < 0.46 ? "darker text" : (page.s.tuneContrast > 0.54 ? "lighter text" : "auto")
            hint: "Where text flips light↔dark over the colors. Full left = always dark text, full right = always light. Applies to every app."
            from: 0; to: 1; value: page.s.tuneContrast
            onMoved: (v) => { page.s.tuneContrast = v; if (page.s.shell && page.s.tuneEditingLive) page.s.shell.contrastBias = v }
            onCommitted: (v) => page.s.commitTuning()
            onReset: page.s.resetContrast()
        }
        SliderRow {
            label: "Color saturation"
            valueText: Math.round(page.s.tuneSaturation * 100) + "%"
            hint: "A ceiling on saturation. Full right = the wallpaper's own colors, untouched; lower it to rein in over-saturated wallpapers (already-muted ones aren't affected). Applies everywhere — bar, Discord, Spotify, Brave, Dolphin, GTK, notifications."
            from: 0; to: 1; value: page.s.tuneSaturation
            onMoved: (v) => page.s.tuneSaturation = v
            onCommitted: (v) => page.s.commitTuning()
            onReset: page.s.resetSaturation()
        }
        SliderRow {
            label: "Brightness"
            valueText: Math.round(page.s.tuneBrightness * 100) + "%"
            hint: "A ceiling on brightness. Full right = the wallpaper's own colors; lower it to tone down very bright wallpapers (dark ones aren't affected). Pair with Text contrast for readability."
            from: 0; to: 1; value: page.s.tuneBrightness
            onMoved: (v) => page.s.tuneBrightness = v
            onCommitted: (v) => page.s.commitTuning()
            onReset: page.s.resetBrightness()
        }
        SliderRow {
            label: "Hue shift"
            valueText: (page.s.tuneHue > 0 ? "+" : "") + Math.round(page.s.tuneHue) + "°"
            hint: "Rotate every color around the wheel. 0 keeps the wallpaper's real colors; nudge it for a deliberately off-palette / artsy tint (yes, it changes the whole vibe)."
            from: -180; to: 180; value: page.s.tuneHue
            onMoved: (v) => page.s.tuneHue = v
            onCommitted: (v) => page.s.commitTuning()
            onReset: page.s.resetHue()
        }

        // ── Per-surface tuning ──
        Section {
            title: "Per-surface tuning"
            desc: "Fine-tune one surface at a time, on top of the palette knobs above. Saturation/Brightness are ceilings, exactly like the global sliders — full right (100%) leaves that surface as-is; lowering reins it in, but a wallpaper that's already dark/muted barely moves. They only tame a surface below the global level, never boost it. Hue rotates. Click a surface to expand."
        }
        Repeater {
            model: page.s.surfaceSpecs
            Rectangle {
                id: surf
                required property var modelData
                readonly property string skey: modelData.key
                // read the refresh tick so the summary updates after edits
                readonly property int _r: page.s.surfaceRefresh
                property bool expanded: false
                readonly property real sat:    { void surf._r; return page.s.surfaceVal(skey, "sat", 1.0) }
                readonly property real bright: { void surf._r; return page.s.surfaceVal(skey, "bright", 1.0) }
                readonly property real hue:    { void surf._r; return page.s.surfaceVal(skey, "hue", 0.0) }
                readonly property bool atDefault: Math.abs(sat - 1) < 0.005 && Math.abs(bright - 1) < 0.005 && Math.abs(hue) < 0.5
                width: col.width; radius: 12; color: ST.rowBg
                height: body.height + 20
                Column {
                    id: body
                    x: 12; y: 10; width: parent.width - 24; spacing: 8
                    // header row (click to expand)
                    Item {
                        width: parent.width; height: 26
                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            text: (surf.expanded ? "▾  " : "▸  ") + surf.modelData.label
                            color: ST.fg; font.pixelSize: 13; font.bold: true; font.family: ST.ff }
                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            visible: !surf.expanded
                            // compact summary, dim when at defaults
                            text: surf.atDefault ? "default"
                                : Math.round(surf.sat * 100) + "% · " + Math.round(surf.bright * 100) + "% · " + (surf.hue > 0 ? "+" : "") + Math.round(surf.hue) + "°"
                            color: ST.fg; opacity: surf.atDefault ? 0.4 : 0.7
                            font.pixelSize: 11; font.family: ST.ff }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: surf.expanded = !surf.expanded }
                    }
                    // expanded body: 3 sliders + reset
                    Column {
                        width: parent.width; spacing: 6
                        visible: surf.expanded
                        SliderRow {
                            label: "Saturation"; resettable: false
                            valueText: Math.round(surf.sat * 100) + "%"
                            from: 0; to: 1; value: surf.sat
                            onMoved: (v) => page.s.setSurfaceVal(surf.skey, "sat", v)
                            onCommitted: (v) => page.s.commitSurfaceTune()
                        }
                        SliderRow {
                            label: "Brightness"; resettable: false
                            valueText: Math.round(surf.bright * 100) + "%"
                            from: 0; to: 1; value: surf.bright
                            onMoved: (v) => page.s.setSurfaceVal(surf.skey, "bright", v)
                            onCommitted: (v) => page.s.commitSurfaceTune()
                        }
                        SliderRow {
                            label: "Hue shift"; resettable: false
                            valueText: (surf.hue > 0 ? "+" : "") + Math.round(surf.hue) + "°"
                            from: -180; to: 180; value: surf.hue
                            onMoved: (v) => page.s.setSurfaceVal(surf.skey, "hue", v)
                            onCommitted: (v) => page.s.commitSurfaceTune()
                        }
                        Rectangle { width: 60; height: 22; radius: 7; color: rsm.containsMouse ? ST.rowHover : ST.blockColor
                            Text { anchors.centerIn: parent; text: "Reset"; color: ST.fg; font.pixelSize: 11; font.family: ST.ff }
                            MouseArea { id: rsm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.s.resetSurface(surf.skey) } }
                    }
                }
            }
        }

        // ── Discord (Vesktop) ──
        Section { title: "Discord (Vesktop)" }
        Text { width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.75; font.pixelSize: 12; font.family: ST.ff
            text: "In Vesktop → Settings → Themes, enable \"Technicolor\", then \"Technicolor Blocks\" (in that order). Colors then follow your wallpaper live." }
    }
}
