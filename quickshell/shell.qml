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
    // Scrolling per-process rate history ({comm: [downBps, upBps]} per nethogs
    // refresh, newest last) — the net popup draws one graph line per app.
    property var netProcHist: []

    Process {
        id: nethogsProc
        command: [root.homeDir + "/.config/quickshell/nethogs-stream.py"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(data) {
                var p = data.trim().split(/\s+/)
                if (p[0] === "netprocs") {
                    var tick = {}
                    for (var i = 1; i < p.length; i++) {
                        // comm:down:up — comm may itself contain ':'; rates
                        // are the last two fields.
                        var f = p[i].split(":")
                        if (f.length < 3) continue
                        var up = parseInt(f[f.length - 1]) || 0
                        var dn = parseInt(f[f.length - 2]) || 0
                        var comm = f.slice(0, f.length - 2).join(":")
                        if (comm) tick[comm] = [dn, up]
                    }
                    var h = root.netProcHist.slice()
                    h.push(tick)
                    while (h.length > 48) h.shift()   // == Bar.qml ioHistLen
                    root.netProcHist = h
                    return
                }
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
            sharedNetProcHist: root.netProcHist

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
    // Overlay lifetime target: reveal (1540ms) + awww warm-decode buffer. The
    // overlay plans NEW's entry frame so its first frame-0 wrap — the awww
    // handoff — lands here, capping the double-render linger at ~3s instead
    // of up to a full animation loop (see WallpaperFade.syncStart).
    readonly property int wfWrapTargetMs: 4500
    property real wfProgress: 0
    property double wfWarmDone: 0    // Date.now() when the warm awww apply exited; 0 = pending
    property int wfOverlayFrame: -1  // driver overlay's live animation frame
    property bool wfErrored: false
    property var wfPending: null     // latest queued start() while a reveal runs (spam-W)

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
        if (wfActive && wfWarmDone <= 0 && !wfErrored) {
            // A reveal is still running: queue the newest request instead of
            // restarting from the pre-spam base — the current reveal finishes,
            // then we transition onward to the LATEST target (spam-W friendly).
            wfPending = { path: path, map: map, frames: frames, avgMs: avgMs }
            return
        }
        if (wfActive) wfFinish()      // lingering post-reveal: drop and move on
        wfApplyProc.running = false
        wfRestartProc.running = false
        wfSafety.stop()
        wfWarmDone = 0
        wfErrored = false
        wfNew = ""; wfNew = path      // cycle to force a reload/frame-0 restart
        wfMap = ""; wfMap = map
        wfFrames = Math.max(1, frames)
        wfAvgMs = Math.max(1, avgMs)
        wfProgress = 0
        wfPrevFrame = -1
        wfActive = true
        wfAnim.restart()
        // Hard cap: the wrap is planned for ~wfWrapTargetMs, but if the entry
        // seek mis-lands (variable frame delays) the next wrap is up to one
        // loop later — cover reveal + one loop + slack. The overlay always
        // comes down.
        wfSafety.interval = 1540 + Math.max(6000, wfFrames * wfAvgMs + 4000)
        wfSafety.restart()
    }
    function wfFinish() {
        wfAnim.stop()
        wfSafety.stop()
        wfActive = false
        wfProgress = 0
        wfWarmDone = 0
        if (wfPending) {              // chain to the newest queued request
            var p = wfPending; wfPending = null
            wfStart(p.path, p.map, p.frames, p.avgMs)
        }
    }
    function wfImageError() {         // NEW failed to decode: plain instant swap
        wfErrored = true
        wfAnim.stop()
        wfApplyProc.running = true
    }

    // Warm apply — fired at reveal end, invisible under the fully-opaque
    // overlay, so a cache-cold decode never freezes the visible wallpaper.
    // It leaves awww playing NEW at some unknowable phase; the RESTART apply
    // below is what synchronizes the clocks.
    Process {
        id: wfApplyProc
        command: ["awww", "img", root.wfNew, "--fill-color", "000000",
                  "--resize", "crop", "--filter", "Nearest",
                  "--transition-type", "none", "--transition-fps", "255"]
        onExited: {
            root.wfWarmDone = Date.now()
            // Stills (or failed decodes) have no frame clock — the overlay is
            // already pixel-identical to awww; drop now.
            if (root.wfFrames <= 1 || root.wfErrored) root.wfFinish()
        }
    }
    // Deterministic handoff: awww ALWAYS starts an animation at frame 0, so
    // re-applying the (now cache-warm, ~40ms) image the moment the overlay
    // wraps to frame 0 puts both surfaces at frame ~0 together — no modeling
    // of awww's hidden animation clock (which starts after an unobservable
    // decode delay; guessing it made the drop snap the wallpaper back to its
    // loop start).
    Process {
        id: wfRestartProc
        command: ["awww", "img", root.wfNew, "--fill-color", "000000",
                  "--resize", "crop", "--filter", "Nearest",
                  "--transition-type", "none", "--transition-fps", "255"]
        onExited: if (root.wfActive) root.wfFinish()
    }
    property int wfPrevFrame: -1
    onWfOverlayFrameChanged: {
        var f = wfOverlayFrame
        var p = wfPrevFrame
        wfPrevFrame = f
        if (!wfActive || wfWarmDone <= 0 || wfFrames <= 1 || wfErrored) return
        if (wfRestartProc.running) return
        if (Date.now() - wfWarmDone <= 150) return
        // Fire ONE frame before the wrap (the apply's ~one-frame latency then
        // lands awww's frame 0 right as the overlay wraps), or on any detected
        // wrap — an exact ===0 check misses when Qt skips frames under load.
        if (f === wfFrames - 1 || f === 0 || (p >= 0 && f < p))
            wfRestartProc.running = true
    }
    Timer { id: wfSafety; onTriggered: { if (root.wfWarmDone <= 0) wfApplyProc.running = true; root.wfFinish() } }

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
