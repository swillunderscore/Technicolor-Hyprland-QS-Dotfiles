import QtQuick

// Settings → Performance: the effects governor (effects-governor.conf, read by
// effects-governor.sh), which steps the desktop's effects down under GPU load.
SmoothList {
    id: page
    readonly property var s: ST.win
    readonly property var tierNames: ["everything on", "no shimmer", "no bar glass", "no glass", "no animations"]
    contentHeight: col.height

    Column {
        id: col; width: parent.width; spacing: 10

        Section {
            title: "Effects under load"; first: true
            desc: "Steps the desktop down as the GPU gets busy, so a game or a local model gets the frame time instead of the glass — then puts it back when things calm down. Leave the governor off if you would rather have a flashy desktop all the time."
        }

        // live readout
        Rectangle {
            width: parent.width; height: 44; radius: 9; color: ST.rowBg
            Text {
                anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                color: ST.fg; font.pixelSize: 12; font.family: ST.ff
                text: "Now: tier " + page.s.govTier + " · " + page.tierNames[Math.min(page.s.govTier, 4)]
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                color: ST.fg; opacity: 0.6; font.pixelSize: 12; font.family: ST.ff
                text: page.s.govGpuBusy >= 0 ? "GPU " + page.s.govGpuBusy + "%" : "GPU n/a"
            }
        }

        ToggleRow {
            title: "Automatic governor"
            desc: "Turn effects down on their own when the GPU is busy. Off means they stay exactly as you set them, however heavy."
            on: page.s.govEnabled
            onToggled: (v) => { page.s.govEnabled = v; page.s.writeGovernorConf() }
        }
        // fullscreen trigger — the reliable one
        ToggleRow {
            opacity: page.s.govEnabled ? 1 : 0.4
            title: "Cut effects for fullscreen apps"
            desc: "Drops straight to the furthest step the moment a game goes fullscreen, rather than waiting for the GPU to cross the threshold below — a frame-capped game can sit at half load and never trip it. A merely maximised window is left alone."
            on: page.s.govFullscreen
            onToggled: (v) => { page.s.govFullscreen = v; page.s.writeGovernorConf() }
        }

        // thresholds
        SliderRow {
            opacity: page.s.govEnabled ? 1 : 0.4; enabled: page.s.govEnabled; resettable: false
            label: "Step down above"; valueText: Math.round(page.s.govGpuHigh) + "% GPU"
            from: 30; to: 95; value: page.s.govGpuHigh
            onMoved: (v) => page.s.govGpuHigh = Math.round(v)
            onCommitted: (v) => page.s.writeGovernorConf()
        }
        SliderRow {
            opacity: page.s.govEnabled ? 1 : 0.4; enabled: page.s.govEnabled; resettable: false
            label: "Step back up below"; valueText: Math.round(page.s.govGpuLow) + "% GPU"
            from: 10; to: 90; value: page.s.govGpuLow
            onMoved: (v) => page.s.govGpuLow = Math.round(v)
            onCommitted: (v) => page.s.writeGovernorConf()
        }
        SliderRow {
            opacity: page.s.govEnabled ? 1 : 0.4; enabled: page.s.govEnabled; resettable: false
            label: "Furthest step it may take"; valueText: Math.round(page.s.govMaxTier) + " · " + page.tierNames[Math.round(page.s.govMaxTier)]
            from: 1; to: 4; value: page.s.govMaxTier
            onMoved: (v) => page.s.govMaxTier = Math.round(v)
            onCommitted: (v) => page.s.writeGovernorConf()
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; color: ST.fg; opacity: 0.45; font.pixelSize: 10; font.family: ST.ff
            text: "The gap between those two numbers is deliberate: stepping down and back up at the same load would flap the desktop between two looks every couple of seconds. \"Step back up\" is held at least 5% below \"step down\"." }

        // ── battery (laptops only) ── Hidden entirely on desktops. A wireless
        // mouse reports type=Battery, so detection also requires scope!=Device —
        // otherwise every desktop with a Logitech mouse grows battery settings it
        // can never use.
        Section { visible: page.s.govHasBattery; title: "On battery" }
        ToggleRow {
            visible: page.s.govHasBattery
            title: "Cut effects on low battery"
            desc: "Only while unplugged and below the level you pick below."
            on: page.s.govBatteryEnabled
            onToggled: (v) => { page.s.govBatteryEnabled = v; page.s.writeGovernorConf() }
        }
        SliderRow {
            visible: page.s.govHasBattery
            opacity: page.s.govBatteryEnabled ? 1 : 0.4; enabled: page.s.govBatteryEnabled; resettable: false
            label: "Below this charge"; valueText: Math.round(page.s.govBatteryLow) + "%"
            from: 5; to: 60; value: page.s.govBatteryLow
            onMoved: (v) => page.s.govBatteryLow = Math.round(v)
            onCommitted: (v) => page.s.writeGovernorConf()
        }
        SliderRow {
            visible: page.s.govHasBattery
            opacity: page.s.govBatteryEnabled ? 1 : 0.4; enabled: page.s.govBatteryEnabled; resettable: false
            label: "Hold at least tier"; valueText: Math.round(page.s.govBatteryTier).toString()
            from: 1; to: 4; value: page.s.govBatteryTier
            onMoved: (v) => page.s.govBatteryTier = Math.round(v)
            onCommitted: (v) => page.s.writeGovernorConf()
        }

        // ── manual override ──
        Section {
            title: "Set it yourself"
            desc: "Applies right now. With the governor on it will move this again on its next check, so treat these as a nudge rather than a setting. Nothing is written to your config — a Hyprland reload puts everything back."
        }
        Chips {
            model: [
                { id: 0, name: "Everything on" },
                { id: 1, name: "No shimmer" },
                { id: 2, name: "No bar glass" },
                { id: 3, name: "No glass" },
                { id: 4, name: "All off" }
            ]
            selected: page.s.govTier
            onPicked: (id) => page.s.govApplyTier(id)
        }
    }
}
