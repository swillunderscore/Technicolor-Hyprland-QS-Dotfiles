import QtQuick

// Settings → Colors: the global palette knobs (color-tuning.conf, applied by
// wallpaper-colors.py), per-surface tuning on top of them, and the Discord note.
SmoothList {
    id: page
    readonly property var s: ST.win
    readonly property var palette: s && s.bar
        ? [s.bar.gradientStart, s.bar.gradientEnd, s.bar.colorFocused, s.bar.colorVisible, s.bar.colorOccupied]
        : []
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        Section {
            title: "Palette"; first: true
            desc: "Every themed surface takes its colors from the wallpaper. These four knobs adjust that palette for all of them at once."
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
            onMoved: (v) => { page.s.tuneContrast = v; if (page.s.shell) page.s.shell.contrastBias = v }
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
