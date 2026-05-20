//@ pragma UseQApplication
//@ pragma IconTheme hicolor
// shell.qml — Quickshell entry point
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    // Resolve $HOME at runtime so the config is portable across users/machines.
    readonly property string homeDir: Quickshell.env("HOME") || "/home"

    property color colorFocused: "#F1CEB2"
    property color colorVisible: "#D79F89"
    property color colorOccupied: "#947073"
    property color colorEmpty: "#585B70"
    property color gradientStart: "#89B4FA"
    property color gradientEnd: "#F38BA8"

    // Cross-fade bar colors over the same window as the wallpaper transition
    // (wallpaper-transition.py: NFRAMES=22, FRAME_INTERVAL=0.070 -> ~1540ms).
    // InOutCubic matches the wallpaper's ease_in_out smoothstep curve.
    Behavior on colorFocused  { ColorAnimation { duration: 1500; easing.type: Easing.InOutCubic } }
    Behavior on colorVisible  { ColorAnimation { duration: 1500; easing.type: Easing.InOutCubic } }
    Behavior on colorOccupied { ColorAnimation { duration: 1500; easing.type: Easing.InOutCubic } }
    Behavior on gradientStart { ColorAnimation { duration: 1500; easing.type: Easing.InOutCubic } }
    Behavior on gradientEnd   { ColorAnimation { duration: 1500; easing.type: Easing.InOutCubic } }

    function parseColors() {
        var content = colorsFile.text();
        if (!content) return;
        var lines = content.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].split("=");
            if (parts.length !== 2) continue;
            var key = parts[0].trim();
            var val = parts[1].trim();
            if (key === "FOCUSED")        root.colorFocused   = val;
            if (key === "VISIBLE")        root.colorVisible   = val;
            if (key === "OCCUPIED")       root.colorOccupied  = val;
            if (key === "GRADIENT_START") root.gradientStart   = val;
            if (key === "GRADIENT_END")   root.gradientEnd     = val;
        }
    }

    FileView {
        id: colorsFile
        path: root.homeDir + "/.config/quickshell/colors.env"
        watchChanges: true
        onFileChanged: this.reload()
        onTextChanged: root.parseColors()
    }

    readonly property int workspaceCeiling: {
        var ceil = 2;
        var wsList = Hyprland.workspaces.values;
        for (var i = 0; i < wsList.length; i++) {
            var ws = wsList[i];
            if (ws.id <= 0) continue;
            if (ws.id > ceil) ceil = ws.id;
        }
        var mons = Hyprland.monitors.values;
        for (var j = 0; j < mons.length; j++) {
            var mws = mons[j].activeWorkspace;
            if (mws && mws.id > ceil) ceil = mws.id;
        }
        return ceil;
    }

    function workspaceGoto(target, monId) {
        gotoProc.command = [root.homeDir + "/.config/hypr/workspace-goto.sh", target.toString(), monId.toString()]
        gotoProc.running = true
    }

    Process {
        id: gotoProc
    }

    // ── Network attribution (shared across all bars) ──
    // nethogs has to run as root and there's no reason to spawn it per
    // monitor, so the streamer lives here and bars read off these properties.
    property string netTopUpComm: "-"
    property int netTopUpBytes: 0
    property string netTopDownComm: "-"
    property int netTopDownBytes: 0
    property int netTopTick: 0      // bumps on every nethogs refresh — bars use
                                    // this as the cue to push a fresh bucket

    Process {
        id: nethogsProc
        command: [root.homeDir + "/.config/quickshell/nethogs-stream.py"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(data) {
                var p = data.trim().split(/\s+/)
                if (p[0] !== "nettop" || p.length < 7) return
                root.netTopUpComm = p[2] || "-"
                root.netTopUpBytes = parseInt(p[3]) || 0
                root.netTopDownComm = p[5] || "-"
                root.netTopDownBytes = parseInt(p[6]) || 0
                root.netTopTick = root.netTopTick + 1
            }
        }
    }

    property var primaryBar: null

    Variants {
        model: Quickshell.screens

        Bar {
            property var modelData
            screen: modelData

            barScreen: modelData
            colorFocused: root.colorFocused
            colorVisible: root.colorVisible
            colorOccupied: root.colorOccupied
            colorEmpty: root.colorEmpty
            workspaceCeiling: root.workspaceCeiling
            gradientStart: root.gradientStart
            gradientEnd: root.gradientEnd
            sharedNetTopUpComm: root.netTopUpComm
            sharedNetTopDownComm: root.netTopDownComm

            Component.onCompleted: root.primaryBar = this
            Component.onDestruction: if (root.primaryBar === this) root.primaryBar = null
        }
    }

    AltTabPie { barRef: root.primaryBar }
}
