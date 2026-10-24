import QtQuick

// Settings → Glass: the liquid-glass look on every window (hyprwater), and how
// readable a terminal stays over it. Sliders apply live (glassLive) while
// dragging and persist to hyprwater-tuning.conf (glassSet) on release.
SmoothList {
    id: page
    readonly property var s: ST.win
    contentHeight: col.height

    function specs(keys) {
        var out = []
        for (var i = 0; i < keys.length; i++)
            for (var j = 0; j < s.glassSpecs.length; j++)
                if (s.glassSpecs[j].key === keys[i]) out.push(s.glassSpecs[j])
        return out
    }

    // One glass spec as a slider row. `val` is a local copy so dragging is
    // instant; it re-reads the plugin whenever loadGlass() lands.
    component GlassSlider: SliderRow {
        id: g
        required property var modelData
        property real val: page.s.glassValue(modelData)
        Connections { target: page.s; function onGlassValuesChanged() { g.val = page.s.glassValue(g.modelData) } }
        label: modelData.label
        hint: modelData.hint || ""
        valueText: modelData.step === 1 ? Math.round(val).toString() : val.toFixed(2)
        from: modelData.from; to: modelData.to; value: val
        onMoved: (v) => { var vv = modelData.step === 1 ? Math.round(v) : v; g.val = vv; page.s.glassLive(modelData.key, vv) }
        onCommitted: (v) => page.s.glassSet(modelData.key, modelData.step === 1 ? Math.round(g.val) : g.val)
        onReset: { g.val = modelData.def; page.s.glassSet(modelData.key, modelData.def) }
    }

    Column {
        id: col; width: parent.width; spacing: 10

        Section {
            title: "Look"; first: true
            desc: "The glass on every window and on the bar. Applies as you drag and is kept. For values past a slider's range use Advanced at the bottom."
        }
        Repeater {
            model: page.specs(["refraction_strength", "lens_distortion", "edge_thickness", "chromatic_aberration", "fresnel_strength", "specular_strength"])
            delegate: GlassSlider {}
        }

        Section { title: "Blur"; desc: "How frosted the glass is. Iterations widen the same blur further; it costs the same either way." }
        Repeater {
            model: page.specs(["blur_strength", "blur_iterations"])
            delegate: GlassSlider {}
        }

        Section { title: "Color"; desc: "What the glass does to the colors behind it." }
        Repeater {
            model: page.specs(["brightness", "contrast", "saturation", "vibrancy"])
            delegate: GlassSlider {}
        }

        // ── Readability: the terminal's own see-through amount, and the
        // glass tint that keeps text readable over bright backdrops ──
        Section {
            title: "Readability"
            desc: "Terminal transparency follows whichever default terminal is set in System; terminal-opacity.py knows where each one keeps it."
        }
        // Slider runs 1.0 → 0.0 on purpose: dragging RIGHT makes it more
        // see-through, which is what the label reads out.
        SliderRow {
            visible: page.s.termOpacitySupport !== "none"
            label: "Terminal transparency" + (page.s.termOpacityName ? " — " + page.s.termOpacityName : "")
            // With Adapt on the two differ, so show both: what you asked for,
            // and what this wallpaper actually got.
            valueText: page.s.termAuto && Math.abs(page.s.termApplied - page.s.termOpacity) > 0.005
                       ? Math.round((1 - page.s.termOpacity) * 100) + "% → now " + Math.round((1 - page.s.termApplied) * 100) + "%"
                       : Math.round((1 - page.s.termOpacity) * 100) + "% see-through"
            from: 1.0; to: 0.0; value: page.s.termOpacity
            onMoved: (v) => { page.s.termOpacity = v; page.s.liveTermOpacity(v) }
            onCommitted: (v) => page.s.commitTermOpacity(page.s.termOpacity)
            onReset: { page.s.termOpacity = 1.0; page.s.commitTermOpacity(1.0) }
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.55; font.pixelSize: 11; font.family: ST.ff
            text: {
                if (page.s.termOpacitySupport === "none")
                    return (page.s.termOpacityName || "This terminal") + " has no transparency setting Technicolor can drive"
                           + (page.s.termOpacityNote ? " — " + page.s.termOpacityNote + "." : ".")
                           + " Pick a different default terminal in System and the slider comes back."
                var base = "Only the terminal's BACKGROUND goes see-through — the text stays fully solid and readable, which is why this drives "
                         + (page.s.termOpacityName || "the terminal") + "'s own opacity rather than a compositor rule. "
                var how = page.s.termOpacitySupport === "restart"
                        ? "Saved to its config now; windows you open from here on come up see-through."
                        : "Every open window changes as you drag, and it's saved to its config."
                var auto = page.s.termAuto
                         ? " With Adapt on, this is the MOST see-through it goes — readability is handled where the glass is."
                         : ""
                return base + how + auto + (page.s.termOpacityNote ? " (" + page.s.termOpacityNote + ")" : "")
            } }
        ToggleRow {
            visible: page.s.termOpacitySupport !== "none"
            title: "Adapt to what’s behind"
            desc: "The glass tints per-pixel wherever the backdrop showing through is bright — a white page behind a clear window included — and stays fully clear over dark ones. Live, no stepping. The slider stays the see-through amount."
                  + (page.s.termLuma >= 0 ? " This wallpaper reads " + Math.round(page.s.termLuma * 100) + "% bright." : "")
            on: page.s.termAuto
            onToggled: (v) => page.s.setTermAuto(v)
        }
        // hyprwater key keeps its old name, adaptive_tint_terminals_only, so
        // saved configs still apply
        ToggleRow {
            title: "Tint: terminals only"
            desc: "Only terminal windows (kitty, Alacritty, Ghostty, WezTerm, foot, Konsole, and friends) get tinted — the adaptive tint, the glass tint color, and its dimming of bright areas. Every other window, the bar and all overlays keep clear, untinted glass, and the bar’s pills stop following the terminal transparency."
            on: page.s.glassValue({ key: "adaptive_tint_terminals_only", def: 0 }) >= 0.5
            onToggled: (v) => { page.s.glassSet("adaptive_tint_terminals_only", v ? 1 : 0); page.s.loadGlass() }
        }
        // White glass: hyprwater adaptive_white + kitty's text black
        // (hypr/terminal-colors.py). Separate from light/dark mode.
        ToggleRow {
            visible: page.s.termAuto && page.s.whiteGlassTerminalOk
            title: "White glass"
            desc: "Terminal glass lifts toward white instead of darkening, and the text turns black (with colors that stay readable on white). Separate from light/dark mode."
            on: page.s.glassValue({ key: "adaptive_white", def: 0 }) >= 0.5
            onToggled: (v) => page.s.setWhiteGlass(v)
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.55; font.pixelSize: 11; font.family: ST.ff
            visible: page.s.termAuto && !page.s.whiteGlassTerminalOk
            text: "White glass (black text on white terminal glass) needs kitty as the default terminal (System page): it's the terminal whose text colors can change live." }

        // write-in: any key + value (out-of-range, or options without a slider)
        Section {
            title: "Advanced — set any value"
            desc: "Type: key value  (e.g. refraction_strength 2.5  ·  tint_color 0x20000000  ·  dark:brightness 0.9). Applies + persists."
        }
        Row {
            width: parent.width; height: 34; spacing: 8
            Rectangle {
                width: parent.width - 86; height: 34; radius: 8; color: ST.rowBg
                TextInput { id: glassWrite; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter; color: ST.fg; font.pixelSize: 12; font.family: "monospace"; clip: true
                    onAccepted: apply.go() }
                Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                    visible: glassWrite.text === ""; text: "key value"; color: ST.fg; opacity: 0.4; font.pixelSize: 12; font.family: "monospace" }
            }
            TcButton {
                id: apply; width: 78; height: 34
                text: "Apply"
                function go() {
                    var t = glassWrite.text.trim(); var sp = t.indexOf(" ")
                    if (sp > 0) { page.s.glassSet(t.substring(0, sp).trim(), t.substring(sp + 1).trim()); glassWrite.text = ""; page.s.loadGlass() }
                }
                onClicked: go()
            }
        }
    }
}
