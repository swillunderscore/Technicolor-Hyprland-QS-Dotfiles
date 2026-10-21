import QtQuick

// Settings → Water: the moving water on the glass (hyprwater's shimmer:*
// keys). Same live/persist path as the Glass page.
SmoothList {
    id: page
    readonly property var s: ST.win
    readonly property bool waterOn: s.glassValue({ key: "shimmer:enabled", def: 0 }) >= 0.5
    contentHeight: col.height

    function specs(keys) {
        var out = []
        for (var i = 0; i < keys.length; i++)
            for (var j = 0; j < s.shimmerSpecs.length; j++)
                if (s.shimmerSpecs[j].key === keys[i]) out.push(s.shimmerSpecs[j])
        return out
    }

    // One shimmer spec as a slider row; log specs carry a 0..1 position.
    component WaterSlider: SliderRow {
        id: w
        required property var modelData
        property real val: page.s.glassValue(modelData)
        Connections { target: page.s; function onGlassValuesChanged() { w.val = page.s.glassValue(w.modelData) } }
        opacity: page.waterOn ? 1 : 0.5
        label: modelData.label
        hint: modelData.hint || ""
        valueText: val < 0.1 ? val.toFixed(3) : val.toFixed(2)
        from: modelData.log ? 0 : modelData.from
        to:   modelData.log ? 1 : modelData.to
        value: modelData.log ? page.s.logValToPos(modelData, val) : val
        onMoved: (v) => {
            var vv = modelData.log ? page.s.logPosToVal(modelData, v) : v
            w.val = vv
            page.s.glassLive(modelData.key, vv)
        }
        onCommitted: (v) => page.s.glassSet(modelData.key, w.val)
        onReset: { w.val = modelData.def; page.s.glassSet(modelData.key, modelData.def) }
    }

    Column {
        id: col; width: parent.width; spacing: 10

        Section {
            title: "Water"; first: true
            desc: "Caustics on the glass, from a real wave simulation — disturbances arrive from off-screen, spread, reflect and die down. The light comes from whatever is actually behind the window, so it takes on those colors."
        }
        ToggleRow {
            title: "Moving water"
            desc: "Off means the simulation never runs at all, not merely that it is invisible. The governor (Performance) also switches this off first when the GPU gets busy."
            on: page.waterOn
            onToggled: (v) => { page.s.glassSet("shimmer:enabled", v ? 1 : 0); page.s.loadGlass() }
        }

        Section { title: "Waves" }
        Repeater { model: page.specs(["shimmer:scale", "shimmer:speed", "shimmer:agitation", "shimmer:viscosity"]); delegate: WaterSlider {} }

        Section { title: "Light" }
        Repeater { model: page.specs(["shimmer:intensity", "shimmer:depth", "shimmer:absorption", "shimmer:murk"]); delegate: WaterSlider {} }

        Section { title: "Currents" }
        ToggleRow {
            opacity: page.waterOn ? 1 : 0.5
            title: "Velocity field"
            desc: "The water itself flows. Motion leaves real momentum behind — whirlpools spin off a dragged window's corners and linger for a few seconds, and waves crossing a current get bent and carried by it. Off, the water still waves but never flows."
            on: page.s.glassValue({ key: "shimmer:currents", def: 1 }) >= 0.5
            onToggled: (v) => { page.s.glassSet("shimmer:currents", v ? 1 : 0); page.s.loadGlass() }
        }
        SliderRow {
            id: curRes
            // Powers of two only: the fluid FBOs realloc live on any value, but
            // between detents nothing changes visibly enough to earn the
            // in-between positions — so the slider SNAPS.
            readonly property var steps: [128, 256, 512, 1024, 2048]
            property int val: 512
            function sync() {
                const v = page.s.glassValue({ key: "shimmer:currents_resolution", def: 512 });
                let best = 0;
                for (let i = 0; i < steps.length; i++)
                    if (Math.abs(steps[i] - v) < Math.abs(steps[best] - v)) best = i;
                val = steps[best];
            }
            Component.onCompleted: sync()
            Connections { target: page.s; function onGlassValuesChanged() { curRes.sync() } }
            opacity: page.waterOn ? 1 : 0.5
            label: "Whirlpool detail"
            valueText: val + " × " + val
            hint: "Grid resolution of the velocity field. Finer grids hold smaller, tighter whirlpools; coarser ones smear the same momentum into broad slow swirls. Changing it restarts the currents from still water."
            from: 0; to: steps.length - 1
            value: Math.max(0, steps.indexOf(val))
            onMoved: (v) => curRes.val = curRes.steps[Math.round(Math.max(0, Math.min(curRes.steps.length - 1, v)))]
            onCommitted: (v) => { page.s.glassSet("shimmer:currents_resolution", curRes.val); page.s.loadGlass() }
            onReset: { curRes.val = 512; page.s.glassSet("shimmer:currents_resolution", 512); page.s.loadGlass() }
        }

        Section { title: "Interaction" }
        Repeater { model: page.specs(["shimmer:mouse", "shimmer:window_physics"]); delegate: WaterSlider {} }
    }
}
