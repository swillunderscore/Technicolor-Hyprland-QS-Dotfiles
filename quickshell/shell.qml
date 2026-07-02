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
        path: root.homeDir + "/.config/quickshell/colors-bar.env"
        watchChanges: true
        onFileChanged: this.reload()
        onTextChanged: root.parseColors()
    }

    // Text-contrast slider (Settings → Colors). 0.5 = default crossover, 0 =
    // always dark text, 1 = always light. The bar reads it live; Settings can
    // also set it directly for instant drag feedback (both write this property).
    property real contrastBias: 0.5
    function parseTuning() {
        var content = tuningFile.text();
        if (!content) return;
        var lines = content.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].split("=");
            if (parts.length !== 2) continue;
            if (parts[0].trim() === "CONTRAST_BIAS") {
                var f = parseFloat(parts[1].trim());
                if (!isNaN(f)) root.contrastBias = f;
            }
        }
    }
    FileView {
        id: tuningFile
        path: root.homeDir + "/.config/hypr/color-tuning.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onTextChanged: root.parseTuning()
    }

    // UI font (Settings → System → Font). Bar + Settings window read this live;
    // wofi follows via gen-wofi-font.sh. Default = QS_FONT env, else the system
    // default sans — so a fresh install renders instantly without a specific font.
    readonly property string fontFallback: Quickshell.env("QS_FONT") || "sans-serif"
    property string uiFont: root.fontFallback
    FileView {
        id: fontFile
        path: root.homeDir + "/.config/hypr/font.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: { var t = this.text().trim(); root.uiFont = t !== "" ? t : root.fontFallback }
        onLoadFailed: root.uiFont = root.fontFallback
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

    // Settings window state — a stable singleton on the shell root, NOT on a bar
    // instance (those go stale across config reloads, which left the window unable
    // to open). 0=Apps, 1=Wallpaper, 2=System.
    property bool settingsOpen: false
    property int settingsTab: 0
    // Reliable open: reset to false first, so a window the compositor closed
    // (Super+C etc.) is rebuilt. A FloatingWindow destroyed by the WM leaves
    // `visible` bound true with no surface — only a false->true transition
    // recreates it; setting true again when already true is a no-op.
    function showSettings() { root.settingsOpen = false; settingsShowTimer.restart() }
    Timer { id: settingsShowTimer; interval: 24; onTriggered: root.settingsOpen = true }

    Variants {
        model: Quickshell.screens

        Bar {
            property var modelData
            screen: modelData

            barScreen: modelData
            shell: root
            onSettingsRequested: root.showSettings()
            colorFocused: root.colorFocused
            colorVisible: root.colorVisible
            colorOccupied: root.colorOccupied
            colorEmpty: root.colorEmpty
            workspaceCeiling: root.workspaceCeiling
            gradientStart: root.gradientStart
            gradientEnd: root.gradientEnd
            contrastBias: root.contrastBias
            fontFamily: root.uiFont
            sharedNetTopUpComm: root.netTopUpComm
            sharedNetTopDownComm: root.netTopDownComm

            Component.onCompleted: root.primaryBar = this
            Component.onDestruction: if (root.primaryBar === this) root.primaryBar = null
        }
    }

    // ── GPU wallpaper transition ─────────────────────────────────────────────
    // wallpaper-cycle.sh calls `qs ipc call wallfade start <new> <map> <frames>
    // <avgMs>`; per-screen WallpaperFade overlays reveal NEW (animating) over
    // awww's still-animating OLD, then awww swaps underneath. See
    // WallpaperFade.qml for the full why.
    property bool wfActive: false
    property string wfNew: ""
    property string wfMap: ""
    property int wfFrames: 1
    property real wfAvgMs: 100
    property real wfProgress: 0
    property double wfApplyTime: 0   // Date.now() when awww confirmed NEW; 0 = pending
    property int wfOverlayFrame: -1  // driver overlay's live animation frame

    NumberAnimation {
        id: wfAnim
        target: root; property: "wfProgress"
        from: 0; to: 1
        duration: 1540                // matches the old reveal (22 × 70ms)
        // Linear on purpose: the smoothstep frontier ease lives in the shader,
        // exactly like wallpaper-transition.py eased its frame times.
        onFinished: wfApplyProc.running = true
    }

    function wfStart(path, map, frames, avgMs) {
        wfApplyProc.running = false   // cancel a pending handoff from a prior run
        wfSafety.stop()
        wfApplyTime = 0
        wfNew = ""; wfNew = path      // cycle to force a reload/frame-0 restart
        wfMap = ""; wfMap = map
        wfFrames = Math.max(1, frames)
        wfAvgMs = Math.max(1, avgMs)
        wfProgress = 0
        wfActive = true
        wfAnim.restart()
        // Hard cap: reveal + one full animation loop to find the aligned frame
        // + slack. If anything goes sideways the overlay always comes down.
        wfSafety.interval = 1540 + Math.max(3000, wfFrames * wfAvgMs + 2500)
        wfSafety.restart()
    }
    function wfFinish() {
        wfAnim.stop()
        wfSafety.stop()
        wfActive = false
        wfProgress = 0
    }
    function wfImageError() {         // NEW failed to decode: plain instant swap
        wfAnim.stop()
        wfApplyProc.running = true
    }

    // The single authoritative awww apply — fired once per transition, at
    // reveal end, invisible under the fully-opaque overlay (so a cache-cold
    // decode no longer freezes the visible wallpaper like the old handoff).
    Process {
        id: wfApplyProc
        command: ["awww", "img", root.wfNew, "--fill-color", "000000",
                  "--resize", "crop", "--filter", "Nearest",
                  "--transition-type", "none", "--transition-fps", "255"]
        onExited: {
            root.wfApplyTime = Date.now()
            // Stills (or failed decodes) have no frame clock to align — the
            // overlay content is already pixel-identical to awww; drop now.
            if (root.wfFrames <= 1) root.wfFinish()
        }
    }
    Timer { id: wfSafety; onTriggered: { if (root.wfApplyTime <= 0) wfApplyProc.running = true; root.wfFinish() } }

    // Seamless drop: once awww is running NEW underneath, model its frame
    // clock (started at frame 0 at wfApplyTime) and hide the overlay at an
    // instant both surfaces show the SAME frame. Polled between frame
    // boundaries — two same-rate clocks with a constant offset are only ever
    // equal mid-frame, never at the edges, so a frame-change check can't work.
    Timer {
        id: wfAlign
        interval: 20; repeat: true
        running: root.wfActive && root.wfApplyTime > 0 && root.wfFrames > 1
        onTriggered: {
            var fa = Math.floor((Date.now() - root.wfApplyTime) / root.wfAvgMs) % root.wfFrames
            if (fa === root.wfOverlayFrame) root.wfFinish()
        }
    }

    Variants {
        model: Quickshell.screens
        WallpaperFade {
            shell: root
            isDriver: modelData === Quickshell.screens[0]
        }
    }

    IpcHandler {
        target: "wallfade"
        function start(path: string, map: string, frames: int, avgMs: real): void {
            root.wfStart(path, map, frames, avgMs)
        }
    }

    AltTabPie { barRef: root.primaryBar }

    // One settings window for the whole shell — a normal toplevel app window
    // (FloatingWindow), bound to primaryBar's settings state. Opened by the bar's
    // gear button OR from the app list via the IPC handler below.
    Settings { bar: root.primaryBar; shell: root }

    // Makes Settings launchable like any app: technicolor-settings.desktop runs
    // `qs ipc call settings open`. Registered once, here at the shell root.
    // Emitted when the keybind-capture submap's escape hatch fires (see
    // hyprland.conf __tc_capture); the Settings window listens and cancels its
    // pending rebind so the UI doesn't sit stuck in "press a key".
    signal rebindCancelled()
    IpcHandler {
        target: "settings"
        function open(): void { root.showSettings() }
        function toggle(): void { if (root.settingsOpen) root.settingsOpen = false; else root.showSettings() }
        function tab(n: int): void { root.settingsTab = n; root.showSettings() }
        function gear(): void { if (root.primaryBar) root.primaryBar.settingsRequested() }  // mirrors the gear button's signal path (diagnostic)
        function rebindcancel(): void { root.rebindCancelled() }
    }
}
