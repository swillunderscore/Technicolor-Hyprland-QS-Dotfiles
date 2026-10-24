// Settings.qml — a real toplevel app window (FloatingWindow), opened from the
// launcher's gear. Instantiated once, on the shell root (shell.qml). Colors and
// pin data come through the `bar` reference so it matches the bar.
//
// This file is the window, the sidebar and every setting's state + backend
// (files, scripts, processes). The pages themselves are in settings/ and read
// all of that through ST.win; each is created only while it is shown.
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import "settings"

FloatingWindow {
    id: win
    property var bar      // a Bar instance — colors + pin data (may briefly be null)
    property var shell    // the ShellRoot — holds the settings open/tab state

    visible: shell ? shell.settingsOpen : false
    title: "Technicolor Settings"
    // Open at the size Hyprland is about to give the window: window-geometry.py
    // keeps a learned `size W H` rule for it. A first buffer of any other size
    // sat small in the window's top-left corner until Qt answered the resize,
    // which took ~0.75 s while the lists below were reloading.
    property int ruleWidth: 960
    property int ruleHeight: 720
    implicitWidth: ruleWidth
    implicitHeight: ruleHeight
    FileView {
        path: win.homeDir + "/.config/hypr/window-geometry.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var lines = this.text().split("\n"), w = 960, h = 720
            for (var i = 0; i < lines.length; i++) {
                var l = lines[i]
                if (l.indexOf("org\\.quickshell") < 0 || l.indexOf("Technicolor\\ Settings") < 0) continue
                var m = l.match(/^windowrule = size (\d+) (\d+),/)
                if (m) { w = parseInt(m[1]); h = parseInt(m[2]) }
            }
            win.ruleWidth = w; win.ruleHeight = h
        }
    }

    // Reassigning a list model rebuilds every delegate (313 fonts, each in its
    // own face); the lists reload on every open, so only swap in real changes.
    function setIfChanged(prop, val) {
        if (JSON.stringify(win[prop]) !== JSON.stringify(val)) win[prop] = val
    }
    // Transparent so hyprwater renders live liquid glass in the gaps between the
    // solid rounded blocks — same model as the themed app windows (e.g. Dolphin).
    color: "transparent"

    readonly property color bodyColor: bar ? bar.solidify(bar.lerpColor(0.0)) : "#1e1e2e"
    readonly property color blockColor: bodyColor   // solid rounded-block fill
    readonly property color fg: bar ? bar.contrastText(bodyColor) : "#ffffff"
    readonly property color rowBg: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
    readonly property color rowHover: Qt.rgba(fg.r, fg.g, fg.b, 0.18)
    readonly property string ff: bar ? bar.fontFamily : "sans"
    readonly property string homeDir: Quickshell.env("HOME") || ""
    property bool addOpen: false

    function close() { win.addOpen = false; if (shell) shell.settingsOpen = false }

    // ── pages ── the sidebar, in order. `page` is shell.settingsTab, which the
    // IPC (`qs ipc call settings tab N`) also sets, so N follows this list.
    readonly property var pages: [
        { name: "Bar & Apps",  glyph: 0xF009 },
        { name: "Wallpaper",   glyph: 0xF03E },
        { name: "Colors",      glyph: 0xF1FC },
        { name: "Glass",       glyph: 0xF2D0 },
        { name: "Water",       glyph: 0xF043 },
        { name: "Performance", glyph: 0xF0E4 },
        { name: "Hotkeys",     glyph: 0xF11C },
        { name: "System",      glyph: 0xF013 }
    ]
    readonly property int pageHotkeys: 6
    readonly property int pageSystem: 7
    readonly property int page: shell ? Math.max(0, Math.min(pages.length - 1, shell.settingsTab)) : 0
    // Fetch what the shown page reads, when it is shown — not everything on
    // every open (that was ~5 processes, 30 hyprctl calls and a 313-font list).
    function loadPage(i) {
        if (i === 1)      { curWpFile.reload(); win.refreshWallpapers() }
        else if (i === 2) { win.tuneEditPicked = false; win.refreshTunePath(); tuneFile.reload(); win.refreshTheme() }
        else if (i === 3) { win.loadGlass(); win.loadTermOpacity() }
        else if (i === 4) win.loadGlass()
        else if (i === 5) govConfFile.reload()
        else if (i === 6) win.loadHotkeys()
        else if (i === 7) confFile.reload()
    }
    onVisibleChanged: {
        if (visible) win.loadPage(win.page)
        else { win.addOpen = false; win.endCapture() }
    }
    onPageChanged: {
        if (win.visible) win.loadPage(win.page)
        if (win.page !== win.pageHotkeys) win.endCapture()   // leaving Hotkeys cancels a pending rebind
    }
    Connections {
        target: shell
        // escape hatch from the capture submap (hyprland.conf) fired — clear UI
        function onRebindCancelled() { win.endCapture() }
    }

    // ── Installed apps (for the Apps > Add picker) ──
    property var installedApps: []
    Process {
        id: appListProc
        running: win.addOpen
        command: ["bash", "-c",
            "find /usr/share/applications ~/.local/share/applications /var/lib/flatpak/exports/share/applications ~/.local/share/flatpak/exports/share/applications -maxdepth 1 -name '*.desktop' 2>/dev/null | while read f; do " +
            "grep -qi '^NoDisplay=true' \"$f\" && continue; " +
            "n=$(grep -m1 '^Name=' \"$f\" | cut -d= -f2-); " +
            "ic=$(grep -m1 '^Icon=' \"$f\" | cut -d= -f2-); " +
            "ex=$(grep -m1 '^Exec=' \"$f\" | cut -d= -f2- | sed 's/ *%[a-zA-Z]//g'); " +
            "did=$(basename \"$f\" .desktop); " +
            "[ -n \"$n\" ] && printf '%s|%s|%s|%s\\n' \"$n\" \"$ic\" \"$ex\" \"$did\"; done | sort -u -t'|' -k1,1"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = []
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].split("|")
                    if (p.length >= 4 && p[0]) out.push({ name: p[0], icon: p[1], exec: p[2], desktopId: p[3] })
                }
                win.setIfChanged("installedApps", out)
            }
        }
    }

    // ── per-pin custom-icon picker (kdialog, fallback zenity) ──
    property int imgPickIndex: -1
    Process {
        id: imgPickProc
        stdout: StdioCollector {
            onStreamFinished: {
                var path = this.text.trim()
                if (path && win.imgPickIndex >= 0 && bar) {
                    var a = bar.pinsForEdit()
                    if (a[win.imgPickIndex]) { a[win.imgPickIndex].imgPath = "file://" + path; bar.savePins(a) }
                }
                win.imgPickIndex = -1
            }
        }
    }
    function pickImage(i) {
        win.imgPickIndex = i
        // Use kdialog — the KDE file dialog (the same Dolphin-style picker, with a
        // Places sidebar + an editable/paste-able path bar). Two gotchas fixed:
        //  • QT_QPA_PLATFORMTHEME=kde — the user's global theme is qt6ct, which makes
        //    kdialog fall back to Qt's plain "Look in:" dialog (no breadcrumb, can't
        //    paste); forcing kde gives the real KDE file dialog.
        //  • if/else, not `kdialog || zenity` — the `||` fired the GTK zenity dialog
        //    whenever kdialog was closed/cancelled (a second, wrong dialog). zenity is
        //    only a fallback for systems without kdialog.
        imgPickProc.command = ["bash", "-c",
            "if command -v kdialog >/dev/null 2>&1; then " +
            "QT_QPA_PLATFORMTHEME=kde kdialog --getopenfilename ~ 'Images (*.png *.jpg *.jpeg *.svg *.webp *.gif)' 2>/dev/null; " +
            "else zenity --file-selection --file-filter='Images | *.png *.jpg *.jpeg *.svg *.webp *.gif' 2>/dev/null; fi"]
        imgPickProc.running = true
    }

    // ── local.conf (System page) ──
    FileView {
        id: confFile
        path: win.homeDir + "/.config/hypr/local.conf"
        watchChanges: false
        onLoaded: win.confText = this.text()
        onLoadFailed: win.confText = ""
    }
    property string confText: ""   // System page's editor reads and writes this
    Process { id: confWriteProc }
    function saveConf() {
        var b64 = Qt.btoa(win.confText)
        confWriteProc.command = ["bash", "-c", "printf %s '" + b64 + "' | base64 -d > '" + confFile.path + "'"]
        confWriteProc.running = true
    }

    // ── default file manager (System page picker) ──
    property var fileManagers: []   // [{ id, name }] — apps that handle dirs AND are file managers
    property string defaultFM: ""   // current handler for inode/directory (e.g. org.kde.dolphin.desktop)
    Process {
        id: fmListProc
        running: win.visible && win.page === win.pageSystem
        command: ["bash", "-c",
            "for f in /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop; do [ -f \"$f\" ] || continue; " +
            "grep -qi inode/directory \"$f\" && grep -qiE '^Categories=.*FileManager' \"$f\" && { " +
            "n=$(grep -m1 '^Name=' \"$f\" | cut -d= -f2-); printf '%s|%s\\n' \"$(basename \"$f\")\" \"$n\"; }; done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = []; var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) { var p = lines[i].split("|"); if (p.length >= 2 && p[0]) out.push({ id: p[0], name: p[1] }) }
                win.setIfChanged("fileManagers", out)
            }
        }
    }
    Process {
        id: fmQueryProc
        running: win.visible && win.page === win.pageSystem
        command: ["xdg-mime", "query", "default", "inode/directory"]
        stdout: StdioCollector { onStreamFinished: win.defaultFM = this.text.trim() }
    }
    Process { id: fmSetProc }
    function setFM(id) {
        fmSetProc.command = ["bash", "-c", "xdg-mime default '" + id + "' inode/directory; xdg-mime default '" + id + "' x-directory/normal 2>/dev/null"]
        fmSetProc.running = true
        win.defaultFM = id
    }

    // ── Default terminal (System page) ── sets Hyprland's $terminal (Super+Q, via
    // the gitignored terminal.conf) and KDE's TerminalApplication (Dolphin's
    // Open Terminal). Lists installed TerminalEmulator apps.
    property var terminals: []        // [{ name, cmd }]
    property string currentTerminal: "kitty"
    Process {
        id: termListProc
        running: win.visible && win.page === win.pageSystem
        command: ["bash", "-c",
            "for f in /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop; do " +
            "[ -f \"$f\" ] || continue; grep -qiE '^Categories=.*TerminalEmulator' \"$f\" || continue; " +
            "grep -qi '^NoDisplay=true' \"$f\" && continue; case \"$(basename \"$f\")\" in *-open.desktop) continue;; esac; " +
            "n=$(grep -m1 '^Name=' \"$f\" | cut -d= -f2-); ex=$(grep -m1 '^Exec=' \"$f\" | cut -d= -f2- | awk '{print $1}'); " +
            "[ -n \"$n\" ] && [ -n \"$ex\" ] && printf '%s|%s\\n' \"$n\" \"$ex\"; done | sort -u -t'|' -k2,2"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = []; var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) { var p = lines[i].split("|"); if (p.length >= 2 && p[0]) out.push({ name: p[0], cmd: p[1] }) }
                win.setIfChanged("terminals", out)
            }
        }
    }
    FileView {
        id: termConfFile
        path: win.homeDir + "/.config/hypr/terminal.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: { var m = this.text().match(/\$terminal\s*=\s*(.+)/); win.currentTerminal = m ? m[1].trim() : "kitty" }
        onLoadFailed: win.currentTerminal = "kitty"
    }
    Process { id: termSetProc }
    function setTerminal(cmd) {
        if (!cmd) return
        win.currentTerminal = cmd
        // White glass only knows how to turn kitty's text dark.
        if (!win.whiteGlassTerminalOk && win.glassValue({ key: "adaptive_white", def: 0 }) >= 0.5) win.setWhiteGlass(false)
        var b64 = Qt.btoa("$terminal = " + cmd + "\n")
        termSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/terminal.conf'; " +
            "hyprctl reload >/dev/null 2>&1; " +
            "kwriteconfig6 --file kdeglobals --group General --key TerminalApplication '" + cmd + "' 2>/dev/null"]
        termSetProc.running = true
    }

    // ── Terminal transparency (Glass page) ── the terminal's OWN background alpha,
    // so only the background goes see-through and the text stays fully solid (a
    // compositor windowrule would fade the text with it). Every terminal spells
    // that differently, so terminal-opacity.py owns the per-terminal knowledge and
    // this side stays dumb: ask it for the current value, hand it a new one.
    // It reports `support` — live (open windows change as you drag) / restart
    // (applies to new windows) / none — and the UI below says exactly that rather
    // than promising something the terminal can't do.
    // Hung off the property rather than off the picker's click, so the slider
    // re-targets however the default terminal changed — the picker above, a hand
    // edit of terminal.conf, or terminal.conf simply finishing its first load.
    onCurrentTerminalChanged: win.loadTermOpacity()
    property real   termOpacity: 1.0
    property bool   termAuto: false           // lift opacity on bright wallpapers
    property real   termLuma: -1              // current wallpaper brightness, -1 = unknown
    property real   termApplied: 1.0          // what the terminal is actually set to
    property string termOpacityName: ""       // pretty name, e.g. "Alacritty"
    property string termOpacitySupport: ""    // live | restart | none
    property string termOpacityNote: ""       // why it's limited, when it is
    Process {
        id: termOpacityGetProc
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var eq = lines[i].indexOf("=")
                    if (eq < 0) continue
                    var k = lines[i].substring(0, eq), v = lines[i].substring(eq + 1)
                    if (k === "opacity") { var f = parseFloat(v); if (!isNaN(f)) win.termOpacity = f }
                    else if (k === "name") win.termOpacityName = v
                    else if (k === "support") win.termOpacitySupport = v
                    else if (k === "note") win.termOpacityNote = v
                }
            }
        }
    }
    // Always pass --term explicitly: setTerminal() writes terminal.conf and
    // re-queries in the same breath, and letting the script re-read that file
    // would race its own write.
    function termOpacityCmd(verb) {
        return ["bash", "-c", "\"$HOME/.config/hypr/terminal-opacity.py\" " + verb
                + " --term '" + win.currentTerminal + "'"]
    }
    function loadTermOpacity() {
        termOpacityGetProc.command = win.termOpacityCmd("get")
        termOpacityGetProc.running = true
        termStateGetProc.running = true
    }
    // The floor + auto flag live in terminal-opacity.conf, separately from what
    // the terminal is currently set to (which `get` reports). On a bright
    // wallpaper with auto on those two deliberately differ.
    Process {
        id: termStateGetProc
        command: ["bash", "-c", "\"$HOME/.config/hypr/terminal-opacity.py\" state"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var eq = lines[i].indexOf("=")
                    if (eq < 0) continue
                    var k = lines[i].substring(0, eq), v = parseFloat(lines[i].substring(eq + 1))
                    if (isNaN(v)) continue
                    if (k === "floor") win.termOpacity = v
                    else if (k === "auto") win.termAuto = (v === 1)
                    else if (k === "luma") win.termLuma = v
                    else if (k === "applied") win.termApplied = v
                }
            }
        }
    }
    Process { id: termAutoProc }
    function setTermAuto(on) {
        win.termAuto = on
        // White glass rides the adaptive tint: without it kitty's black text
        // would sit on dark glass. Off together.
        if (!on && win.glassValue({ key: "adaptive_white", def: 0 }) >= 0.5) win.setWhiteGlass(false)
        termAutoProc.command = ["bash", "-c",
            "\"$HOME/.config/hypr/terminal-opacity.py\" auto " + (on ? "1" : "0")
            + " --term '" + win.currentTerminal + "'"]
        termAutoProc.running = true
        termStateRefresh.restart()
    }
    // The script re-reads the wallpaper and recomputes, so pick the answer back
    // up rather than guessing it here.
    Timer { id: termStateRefresh; interval: 350; onTriggered: termStateGetProc.running = true }
    // Same split as the Glass page: live() is throttled skip-if-busy while dragging,
    // commit() always lands so the released value is the one that persists.
    Process { id: termOpacityLiveProc }
    Process { id: termOpacityCommitProc }
    function liveTermOpacity(v) {
        if (termOpacityLiveProc.running) return
        termOpacityLiveProc.command = win.termOpacityCmd("set " + v.toFixed(2))
        termOpacityLiveProc.running = true
    }
    function commitTermOpacity(v) {
        termOpacityCommitProc.command = win.termOpacityCmd("set " + v.toFixed(2))
        termOpacityCommitProc.running = true
        termStateRefresh.restart()
    }

    // ── Wallpaper auto-cycle timer (Wallpaper page) ── source of truth =
    // ~/.config/hypr/wallpaper-timer.conf, re-read live by wallpaper-timer.sh
    // (interval, pause, pause-while-a-fullscreen-app-is-open).
    property int  cycleInterval: 60      // minutes
    property bool cyclePaused: false
    property bool cyclePauseFs: true
    FileView {
        id: timerConfFile
        path: win.homeDir + "/.config/hypr/wallpaper-timer.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var t = this.text()
            var mi = t.match(/INTERVAL_MIN\s*=\s*([0-9]+)/)
            var mp = t.match(/PAUSED\s*=\s*([01])/)
            var mf = t.match(/PAUSE_ON_FULLSCREEN\s*=\s*([01])/)
            if (mi) win.cycleInterval = parseInt(mi[1])
            win.cyclePaused   = mp ? mp[1] === "1" : false
            win.cyclePauseFs  = mf ? mf[1] === "1" : true
        }
    }
    Process { id: timerSetProc }
    function writeTimerConf() {
        var body = "INTERVAL_MIN=" + Math.round(win.cycleInterval) +
                   "\nPAUSED=" + (win.cyclePaused ? 1 : 0) +
                   "\nPAUSE_ON_FULLSCREEN=" + (win.cyclePauseFs ? 1 : 0) + "\n"
        var b64 = Qt.btoa(body)
        timerSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/wallpaper-timer.conf'"]
        timerSetProc.running = true
    }

    // ── Effects governor (Performance page) ── effects-governor.conf, read by
    // effects-governor.sh. That script owns ALL compositor writes; this page only
    // edits the conf and calls it. Two reasons that split matters:
    //   1. the daemon re-reads the conf every tick, so a slider takes effect
    //      without restarting anything;
    //   2. under the Lua parser `hyprctl keyword` is REJECTED ("use eval"), and
    //      keeping every write in one script means that lesson lives in one place
    //      instead of being re-learned in QML.
    property bool  govEnabled: true
    property real  govGpuHigh: 70
    property real  govGpuLow: 45
    property real  govMaxTier: 3
    property bool  govFullscreen: true
    property bool  govBatteryEnabled: true
    property real  govBatteryLow: 25
    property real  govBatteryTier: 2
    property int   govTier: 0          // live tier, polled for the readout
    property int   govGpuBusy: -1
    property bool  govHasBattery: false // false on desktops → battery UI hidden

    FileView {
        id: govConfFile
        path: win.homeDir + "/.config/hypr/effects-governor.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var t = this.text()
            function num(k, d) { var m = t.match(new RegExp(k + "\\s*=\\s*([0-9]+)")); return m ? parseInt(m[1]) : d }
            win.govEnabled        = num("ENABLED", 1) === 1
            win.govFullscreen     = num("FULLSCREEN_ENABLED", 1) === 1
            win.govGpuHigh        = num("GPU_HIGH", 70)
            win.govGpuLow         = num("GPU_LOW", 45)
            win.govMaxTier        = num("MAX_TIER", 3)
            win.govBatteryEnabled = num("BATTERY_ENABLED", 1) === 1
            win.govBatteryLow     = num("BATTERY_LOW", 25)
            win.govBatteryTier    = num("BATTERY_TIER", 2)
        }
    }
    Process { id: govSetProc }
    function writeGovernorConf() {
        // GPU_LOW must stay below GPU_HIGH — the gap IS the hysteresis. If they
        // meet, a workload sitting on that number flaps the desktop between two
        // looks every poll. Clamped here so the sliders cannot express it.
        var lo = Math.min(win.govGpuLow, win.govGpuHigh - 5)
        var body = "ENABLED=" + (win.govEnabled ? 1 : 0) +
                   "\nFULLSCREEN_ENABLED=" + (win.govFullscreen ? 1 : 0) +
                   "\nGPU_HIGH=" + Math.round(win.govGpuHigh) +
                   "\nGPU_LOW=" + Math.round(lo) +
                   "\nPOLL_SECONDS=2" +
                   "\nMAX_TIER=" + Math.round(win.govMaxTier) +
                   "\nBATTERY_ENABLED=" + (win.govBatteryEnabled ? 1 : 0) +
                   "\nBATTERY_LOW=" + Math.round(win.govBatteryLow) +
                   "\nBATTERY_TIER=" + Math.round(win.govBatteryTier) + "\n"
        var b64 = Qt.btoa(body)
        govSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/effects-governor.conf'"]
        govSetProc.running = true
    }
    // Manual tier apply (the quick toggles). Goes through the script so the
    // hyprctl-eval details stay in exactly one file.
    Process { id: govTierProc }
    function govApplyTier(t) {
        govTierProc.command = ["bash", "-c", "\"$HOME/.config/hypr/effects-governor.sh\" tier " + t]
        govTierProc.running = true
        win.govTier = t
    }
    // Status readout. Only polls while the Performance page is actually open —
    // a settings panel has no business waking every 2s in the background.
    Process {
        id: govStatusProc
        command: ["bash", "-c", "\"$HOME/.config/hypr/effects-governor.sh\" status; echo \"hasbat:$(\"$HOME/.config/hypr/effects-governor.sh\" has-battery)\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = this.text
                var mt = t.match(/tier:\s*([0-9]+)/);      if (mt) win.govTier = parseInt(mt[1])
                var mg = t.match(/gpu_busy:\s*(-?[0-9]+)/); if (mg) win.govGpuBusy = parseInt(mg[1])
                win.govHasBattery = /hasbat:yes/.test(t)
            }
        }
    }
    Timer {
        running: win.visible && win.page === 5
        interval: 2000; repeat: true; triggeredOnStart: true
        onTriggered: if (!govStatusProc.running) govStatusProc.running = true
    }

    // ── Wallpaper switch transition (Wallpaper page) ── transition.conf, read by
    // wallpaper-cycle.sh; the named reveal patterns live in wallpaper-transition.py.
    property string transitionMode: "luminance"
    // gpu = quickshell overlay reveal (both wallpapers keep animating);
    // cpu = classic frame compositor (keeps the GPU free for GPU-bound games).
    property string transitionRender: "gpu"
    readonly property var transitions: [
        { id: "luminance", name: "Brightness", desc: "brightest areas appear first" },
        { id: "shadow",    name: "Shadows",    desc: "darkest areas appear first" },
        { id: "radial",    name: "Radial",     desc: "reveals from the center out" },
        { id: "iris",      name: "Iris",       desc: "closes in from the edges" },
        { id: "wipe",      name: "Wipe",       desc: "sweeps left to right" },
        { id: "curtain",   name: "Curtain",    desc: "sweeps top to bottom" },
        { id: "diagonal",  name: "Diagonal",   desc: "sweeps from the top-left corner" },
        { id: "clock",     name: "Clock",      desc: "sweeps around like a clock hand" },
        { id: "blinds",    name: "Blinds",     desc: "vertical bands open together" },
        { id: "dissolve",  name: "Dissolve",   desc: "random pixel dissolve" },
        { id: "random",    name: "Random",     desc: "a different one each switch" }
    ]
    FileView {
        id: transitionFile
        path: win.homeDir + "/.config/hypr/transition.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var t = this.text()
            var m = t.match(/MODE\s*=\s*(\w+)/);   win.transitionMode   = m ? m[1] : "luminance"
            var r = t.match(/RENDER\s*=\s*(\w+)/); win.transitionRender = r ? r[1] : "gpu"
        }
        onLoadFailed: { win.transitionMode = "luminance"; win.transitionRender = "gpu" }
    }
    Process { id: transitionSetProc }
    function writeTransitionConf() {
        var b64 = Qt.btoa("MODE=" + win.transitionMode + "\nRENDER=" + win.transitionRender + "\n")
        transitionSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/transition.conf'"]
        transitionSetProc.running = true
    }
    function setTransition(mode) { win.transitionMode = mode; writeTransitionConf() }
    function setTransitionRender(r) { win.transitionRender = r; writeTransitionConf() }

    // ── Hotkeys (Hotkeys page) ── a read-only cheat sheet built live from
    // `hyprctl binds`, so it always matches the real active binds (including
    // anything added via local.conf). This config uses plain `bind` (no bindd
    // descriptions), so friendly labels are derived from the dispatcher + arg.
    property var keybinds: []
    property string hotkeySearch: ""
    readonly property var hotkeyCategories: ["Apps", "Windows", "Focus & layout", "Workspaces", "Wallpaper", "Screenshots", "Voice & transcription", "Media", "System", "Other"]
    function modNames(mask) {
        var o = []
        if (mask & 64) o.push("Super")
        if (mask & 4)  o.push("Ctrl")
        if (mask & 8)  o.push("Alt")
        if (mask & 1)  o.push("Shift")
        return o
    }
    function keyName(k) {
        var m = {
            "left":"←","right":"→","up":"↑","down":"↓","ESCAPE":"Esc","SPACE":"Space",
            "PRINT":"PrtSc","bracketleft":"[","bracketright":"]","mouse_down":"Scroll ↑",
            "mouse_up":"Scroll ↓","mouse:272":"L-Click","mouse:273":"R-Click","SUPER_L":"Super",
            "XF86AudioRaiseVolume":"Vol +","XF86AudioLowerVolume":"Vol −","XF86AudioMute":"Mute",
            "XF86AudioMicMute":"Mic Mute","XF86MonBrightnessUp":"Bright +","XF86MonBrightnessDown":"Bright −",
            "XF86AudioNext":"⏭","XF86AudioPrev":"⏮","XF86AudioPlay":"⏯","XF86AudioPause":"⏯"
        }
        return m[k] || k
    }
    function describeBind(b) {
        var d = b.dispatcher, a = (b.arg || "")
        if (a.indexOf("alttabrelease") >= 0 || a.indexOf("qs ipc call") >= 0) return null   // implementation plumbing (alt-tab release, rebind-cancel escape)
        var dir = { l:"left", r:"right", u:"up", d:"down" }
        if (d === "movefocus")   return { cat:"Focus & layout", label:"Focus window " + (dir[a.trim()] || a) }
        if (d === "movewindow") {
            if (a.trim() === "") return { cat:"Focus & layout", label:"Drag to move window" }
            return { cat:"Focus & layout", label:"Move window " + (dir[a.trim()] || a) }
        }
        if (d === "resizewindow")   return { cat:"Focus & layout", label:"Drag to resize window" }
        if (d === "mouse") {        // bindm: Super + click-drag
            if (a === "movewindow")   return { cat:"Focus & layout", label:"Drag to move window" }
            if (a === "resizewindow") return { cat:"Focus & layout", label:"Drag to resize window" }
            return { cat:"Focus & layout", label: a }
        }
        if (d === "global" && a.indexOf("alttab") >= 0) return { cat:"Focus & layout", label:"Window switcher" }
        if (d === "dpms")           return { cat:"System", label:"Sleep the displays" }
        if (d === "killactive")     return { cat:"Windows", label:"Close window" }
        if (d === "togglefloating") return { cat:"Windows", label:"Toggle floating" }
        if (d === "fullscreen")     return { cat:"Windows", label:"Toggle fullscreen" }
        if (d === "exec") {
            var rules = [
                ["wallpaper-cycle.sh next", "Wallpaper", "Next wallpaper"],
                ["window-action.sh close", "Windows", "Close window"],
                ["window-action.sh maximize", "Windows", "Maximize (stays floating)"],
                ["window-action.sh float", "Windows", "Toggle tiling"],
                ["minimize.sh", "Windows", "Minimize window"],
                ["workspace-move.sh left --move", "Workspaces", "Send window to previous"],
                ["workspace-move.sh right --move", "Workspaces", "Send window to next"],
                ["workspace-move.sh left", "Workspaces", "Previous workspace"],
                ["workspace-move.sh right", "Workspaces", "Next workspace"],
                ["wlogout", "System", "Logout / power menu"],
                ["tmux kill-server", "System", "Kill AI background tasks"],
                ["volume.sh up", "Media", "Volume up"],
                ["volume.sh down", "Media", "Volume down"],
                ["volume.sh mute", "Media", "Mute audio"],
                ["set-mute @DEFAULT_AUDIO_SOURCE", "Media", "Mute microphone"],
                ["playerctl next", "Media", "Next track"],
                ["playerctl previous", "Media", "Previous track"],
                ["playerctl play-pause", "Media", "Play / pause"]
            ]
            for (var i = 0; i < rules.length; i++)
                if (a.indexOf(rules[i][0]) >= 0) return { cat: rules[i][1], label: rules[i][2] }
            if (a.indexOf("brightnessctl") >= 0) return { cat:"Media", label: a.indexOf("5%+") >= 0 ? "Brightness up" : "Brightness down" }
            if (a.indexOf("grim") >= 0) return { cat:"Screenshots", label: a.indexOf("slurp") >= 0 ? "Screenshot a region" : "Screenshot full screen" }
            var parts = a.split(" "), prog = parts[0].split("/").pop(), rest = parts.slice(1).join(" ").trim()
            if (prog === win.currentTerminal || ["kitty","alacritty","konsole","foot","wezterm"].indexOf(prog) >= 0) return { cat:"Apps", label:"Open terminal" }
            if (a.indexOf("wofi") >= 0 || a.indexOf("--show drun") >= 0 || a.indexOf("rofi") >= 0) return { cat:"Apps", label:"App launcher" }
            if (/dolphin|nautilus|thunar|nemo|pcmanfm|caja|files/.test(prog)) return { cat:"Apps", label:"Open file manager" }   // also matches wrappers like dolphin-tc.sh
            // Fallback for any other exec bind — custom scripts, private hotkeys,
            // anything not in the table above. Include the args so variant binds
            // to the same script (e.g. clean / raw / cancel) are distinguishable.
            return { cat:"Other", label:"Run " + prog + (rest ? " " + rest : "") }
        }
        return { cat:"Other", label: d + (a ? " " + a : "") }
    }
    function bindsFor(cat) {
        var q = win.hotkeySearch.toLowerCase(), r = []
        for (var i = 0; i < win.keybinds.length; i++) {
            var b = win.keybinds[i]
            if (b.cat !== cat) continue
            if (q !== "" && b.label.toLowerCase().indexOf(q) < 0 && b.combo.indexOf(q) < 0) continue
            r.push(b)
        }
        return r
    }
    readonly property int hotkeyMatchCount: {
        var q = win.hotkeySearch.toLowerCase(), n = 0
        for (var i = 0; i < win.keybinds.length; i++) {
            var b = win.keybinds[i]
            if (q === "" || b.label.toLowerCase().indexOf(q) >= 0 || b.combo.indexOf(q) >= 0) n++
        }
        return n
    }
    // ── Lua-config hotkeys ── under the Lua config manager every bind reports
    // dispatcher "__lua" to `hyprctl binds`, so nothing can be inferred from it.
    // hyprland.lua instead exports keybinds-manifest.json (id, category, label,
    // live combo, default, editable) and applies overrides from
    // keybind-overrides.conf at parse time. Manifest present → that is the
    // truth; absent (conf-based config) → the legacy dispatcher-guessing below.
    property var kbManifest: []
    property var luaOverrides: ({})
    readonly property bool luaHotkeys: kbManifest.length > 0
    FileView {
        id: manifestFile
        path: win.homeDir + "/.config/hypr/keybinds-manifest.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var v = []
            try { v = JSON.parse(this.text()) } catch (e) { v = [] }
            win.kbManifest = Array.isArray(v) ? v : []
            win.rebuildKeybinds()
        }
        onLoadFailed: { win.kbManifest = []; win.rebuildKeybinds() }
    }
    FileView {
        id: luaOverridesFile
        path: win.homeDir + "/.config/hypr/keybind-overrides.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var m = ({}), lines = this.text().split("\n")
            for (var i = 0; i < lines.length; i++) {
                var mt = lines[i].match(/^\s*([\w-]+)\s*=\s*(.+?)\s*$/)
                if (mt && mt[1].charAt(0) !== "#") m[mt[1]] = mt[2]
            }
            win.luaOverrides = m
            win.rebuildKeybinds()
        }
        onLoadFailed: { win.luaOverrides = ({}); win.rebuildKeybinds() }
    }
    function comboParse(c) {   // "SUPER + SHIFT + left" → { mods: 65, key: "left" }
        var toks = c.split("+"), mods = 0, key = ""
        for (var i = 0; i < toks.length; i++) {
            var t = toks[i].trim()
            if (t === "SUPER") mods |= 64
            else if (t === "CTRL") mods |= 4
            else if (t === "ALT") mods |= 8
            else if (t === "SHIFT") mods |= 1
            else if (t !== "") key = t
        }
        return { mods: mods, key: key }
    }
    function comboConfStr(mods, key) {   // inverse of comboParse, hl.bind's format
        var p = []
        if (mods & 64) p.push("SUPER")
        if (mods & 4)  p.push("CTRL")
        if (mods & 8)  p.push("ALT")
        if (mods & 1)  p.push("SHIFT")
        p.push(key)
        return p.join(" + ")
    }

    property var rawBinds: []        // last raw `hyprctl binds` payload
    Process {
        id: bindsProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var arr = []
                try { arr = JSON.parse(this.text) } catch (e) { arr = [] }
                win.rawBinds = arr
                win.rebuildKeybinds()
            }
        }
    }
    function loadHotkeys() { bindsProc.running = true }

    // ── Rebinding ── overrides persist to keybind-overrides.json (gitignored);
    // from them keybinds.conf is generated (unbind original + bind new) and
    // sourced last in hyprland.conf so it wins. Editing captures a combo in the
    // __tc_capture submap; reset drops the override so the shipped default
    // re-applies. An override entry stores the ORIGINAL combo (its def, for the
    // unbind + reset) and the new combo.
    property var overrides: []       // [{mods,key,dispatcher,arg,newMods,newKey}]
    FileView {
        id: overridesFile
        path: win.homeDir + "/.config/hypr/keybind-overrides.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var v = []
            try { v = JSON.parse(this.text()) } catch (e) { v = [] }
            win.overrides = Array.isArray(v) ? v : []
            win.rebuildKeybinds()
        }
        onLoadFailed: { win.overrides = []; win.rebuildKeybinds() }
    }
    Process { id: overridesSetProc; onRunningChanged: if (!running) win.loadHotkeys() }

    function findOverride(mods, key, disp, arg) {   // by NEW combo (what's live now)
        for (var i = 0; i < win.overrides.length; i++) {
            var o = win.overrides[i]
            if (o.newMods === mods && o.newKey === key && o.dispatcher === disp && o.arg === arg) return i
        }
        return -1
    }
    function rebuildKeybinds() {
        if (win.luaHotkeys) {
            var mout = [], mseen = ({})
            for (var mi = 0; mi < win.kbManifest.length; mi++) {
                var m = win.kbManifest[mi]
                var p = win.comboParse(m.combo)
                var mcaps = win.modNames(p.mods).concat([win.keyName(p.key)])
                var mcombo = mcaps.join(" ").toLowerCase()
                var mdk = m.label + "|" + mcombo
                if (mseen[mdk]) continue
                mseen[mdk] = 1
                mout.push({ id: m.id, cat: m.cat, label: m.label, caps: mcaps, combo: mcombo,
                            editable: m.editable === true, modmask: p.mods, rawKey: p.key,
                            dispatcher: "", arg: "",
                            overridden: win.luaOverrides[m.id] !== undefined })
            }
            win.keybinds = mout
            return
        }
        var arr = win.rawBinds, out = [], seen = ({})
        for (var i = 0; i < arr.length; i++) {
            var b = arr[i]
            var desc = win.describeBind(b)
            if (!desc) continue
            var mods = b.modmask, rawKey = b.key, arg = (b.arg || "")
            var caps = win.modNames(mods).concat([win.keyName(rawKey)])
            var combo = caps.join(" ").toLowerCase()
            var dk = desc.label + "|" + combo
            if (seen[dk]) continue
            seen[dk] = 1
            // editable = plain keyboard bind (no flags, not a mouse/scroll bind)
            var editable = !b.mouse && !b.repeat && !b.locked && !b.release && rawKey.indexOf("mouse") < 0
            out.push({ cat: desc.cat, label: desc.label, caps: caps, combo: combo,
                       editable: editable, modmask: mods, rawKey: rawKey,
                       dispatcher: b.dispatcher, arg: arg,
                       overridden: win.findOverride(mods, rawKey, b.dispatcher, arg) >= 0 })
        }
        win.setIfChanged("keybinds", out)
    }

    // capture state
    property var capturingBind: null
    property var warnBind: null        // row flashing a transient conflict message
    property string captureWarn: ""
    Timer { id: captureTimeout; interval: 9000; onTriggered: win.endCapture() }
    Timer { id: warnTimer; interval: 3500; onTriggered: { win.warnBind = null; win.captureWarn = "" } }
    function startCapture(row) {
        if (!row || !row.editable) return
        win.warnBind = null; win.captureWarn = ""; warnTimer.stop()
        win.capturingBind = row
        captureKey.forceActiveFocus()
        Hyprland.dispatch('hl.dsp.submap("__tc_capture")')
        captureTimeout.restart()
    }
    function stopMonitor() {            // leave the capture submap, stop listening
        win.capturingBind = null
        captureTimeout.stop()
        Hyprland.dispatch('hl.dsp.submap("reset")')
    }
    function endCapture() { win.warnBind = null; win.captureWarn = ""; warnTimer.stop(); win.stopMonitor() }
    // conflict / bad key: stop capturing (so it must be re-clicked) and flash the
    // message on the unchanged row for a few seconds.
    function flashWarn(row, msg) { win.stopMonitor(); win.warnBind = row; win.captureWarn = msg; warnTimer.restart() }
    function sameBindRow(a, b) {
        if (a === null || b === null) return false
        if (a.id !== undefined || b.id !== undefined) return a.id === b.id
        return a.dispatcher === b.dispatcher && a.arg === b.arg
            && a.modmask === b.modmask && a.rawKey === b.rawKey
    }
    function isCapturing(row) { return win.sameBindRow(win.capturingBind, row) }
    function isWarnRow(row)   { return win.sameBindRow(win.warnBind, row) }
    function isModifierKey(k) {
        return k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt
            || k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R
            || k === Qt.Key_AltGr || k === Qt.Key_CapsLock || k === Qt.Key_NumLock
    }
    function qtKeyName(e) {
        var k = e.key
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)   // 'A'..'Z'
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)   // '0'..'9'
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1)
        var m = {}
        m[Qt.Key_Left]="left"; m[Qt.Key_Right]="right"; m[Qt.Key_Up]="up"; m[Qt.Key_Down]="down"
        m[Qt.Key_Space]="space"; m[Qt.Key_Return]="return"; m[Qt.Key_Enter]="KP_Enter"
        m[Qt.Key_Tab]="tab"; m[Qt.Key_Backspace]="backspace"; m[Qt.Key_Delete]="delete"
        m[Qt.Key_Home]="home"; m[Qt.Key_End]="end"; m[Qt.Key_PageUp]="prior"; m[Qt.Key_PageDown]="next"
        m[Qt.Key_Insert]="insert"; m[Qt.Key_Print]="print"
        m[Qt.Key_BracketLeft]="bracketleft"; m[Qt.Key_BracketRight]="bracketright"
        m[Qt.Key_Comma]="comma"; m[Qt.Key_Period]="period"; m[Qt.Key_Slash]="slash"
        m[Qt.Key_Semicolon]="semicolon"; m[Qt.Key_Apostrophe]="apostrophe"
        m[Qt.Key_Minus]="minus"; m[Qt.Key_Equal]="equal"; m[Qt.Key_Backslash]="backslash"
        m[Qt.Key_QuoteLeft]="grave"
        if (m[k] !== undefined) return m[k]
        if (e.text && e.text.length === 1 && e.text.charCodeAt(0) > 32) return e.text.toUpperCase()
        return ""    // unsupported
    }
    function modConfStr(mask) {
        var p = []
        if (mask & 64) p.push("SUPER")
        if (mask & 4)  p.push("CTRL")
        if (mask & 8)  p.push("ALT")
        if (mask & 1)  p.push("SHIFT")
        return p.join(" ")
    }
    function comboText(mods, key) { return win.modNames(mods).concat([win.keyName(key)]).join("+") }
    function conflictLabel(mods, key, row) {
        for (var i = 0; i < win.keybinds.length; i++) {
            var kb = win.keybinds[i]
            if (kb.modmask === mods && kb.rawKey === key && !(kb.dispatcher === row.dispatcher && kb.arg === row.arg)) return kb.label
        }
        return ""
    }
    function commitCapture(mods, key) {
        var row = win.capturingBind
        if (!row) return
        if (key === "") { win.flashWarn(row, "Unsupported key"); return }
        if (mods === row.modmask && key === row.rawKey) { win.endCapture(); return }   // unchanged
        var cl = win.conflictLabel(mods, key, row)
        if (cl !== "") { win.flashWarn(row, win.comboText(mods, key) + " is already “" + cl + "”"); return }
        win.endCapture()
        win.applyRebind(row, mods, key)
    }
    function applyRebind(row, newMods, newKey) {
        if (win.luaHotkeys) {
            var lm = JSON.parse(JSON.stringify(win.luaOverrides))
            lm[row.id] = win.comboConfStr(newMods, newKey)
            win.luaOverrides = lm
            win.persistLuaOverrides()
            return
        }
        var cur = win.overrides.slice()
        var idx = win.findOverride(row.modmask, row.rawKey, row.dispatcher, row.arg)
        if (idx >= 0) { cur[idx].newMods = newMods; cur[idx].newKey = newKey }   // keep original def
        else cur.push({ mods: row.modmask, key: row.rawKey, dispatcher: row.dispatcher, arg: row.arg, newMods: newMods, newKey: newKey })
        win.overrides = cur
        win.persistOverrides()
    }
    function resetBind(row) {
        if (win.luaHotkeys) {
            if (win.luaOverrides[row.id] === undefined) return
            var lm = JSON.parse(JSON.stringify(win.luaOverrides))
            delete lm[row.id]
            win.luaOverrides = lm
            win.persistLuaOverrides()
            return
        }
        var idx = win.findOverride(row.modmask, row.rawKey, row.dispatcher, row.arg)
        if (idx < 0) return
        var cur = win.overrides.slice(); cur.splice(idx, 1)
        win.overrides = cur
        win.persistOverrides()
    }
    // Write the id = combo lines hyprland.lua reads at parse time, then reload:
    // the reload re-registers every bind on its (possibly new) combo and
    // rewrites the manifest, whose FileView watcher refreshes this list.
    function persistLuaOverrides() {
        var L = ["# Keybind overrides written by Settings → Hotkeys. hyprland.lua reads",
                 "# this at parse time and registers the new combo instead of the default.", ""]
        for (var id in win.luaOverrides) L.push(id + " = " + win.luaOverrides[id])
        var b64 = Qt.btoa(L.join("\n") + "\n")
        overridesSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/keybind-overrides.conf'; " +
            "hyprctl reload >/dev/null 2>&1"]
        overridesSetProc.running = true
    }
    function buildKeybindsConf() {
        var L = ["# Keybind overrides written by Settings → Hotkeys. Sourced last in",
                 "# hyprland.conf so these win; gitignored so updates never revert them.", ""]
        for (var i = 0; i < win.overrides.length; i++) {
            var o = win.overrides[i]
            L.push("unbind = " + win.modConfStr(o.mods) + ", " + o.key)
            var b = "bind = " + win.modConfStr(o.newMods) + ", " + o.newKey + ", " + o.dispatcher
            if (o.arg && o.arg !== "") b += ", " + o.arg
            L.push(b)
        }
        return L.join("\n") + "\n"
    }
    function persistOverrides() {
        var jb64 = Qt.btoa(JSON.stringify(win.overrides))
        var cb64 = Qt.btoa(win.buildKeybindsConf())
        overridesSetProc.command = ["bash", "-c",
            "printf %s '" + jb64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/keybind-overrides.json'; " +
            "printf %s '" + cb64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/keybinds.conf'; " +
            "hyprctl reload >/dev/null 2>&1"]
        overridesSetProc.running = true
    }

    // ── UI font (System page) ── source of truth = ~/.config/hypr/font.conf.
    // Bar + this window read it live via shell.uiFont; wofi via gen-wofi-font.sh.
    property var installedFonts: []
    property string currentFont: ""
    property string fontSearch: ""
    property real fontListH: 220     // resizable via the drag-divider below the list
    property real confEditH: 240     // resizable local.conf editor
    readonly property string effFont: win.currentFont !== "" ? win.currentFont : (win.bar ? win.bar.fontFamily : "sans-serif")
    Process {
        id: fontListProc
        running: win.visible && win.page === win.pageSystem
        command: ["bash", "-c", "fc-list : family | sed 's/,.*//' | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var a = []
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) { var s = lines[i].trim(); if (s !== "") a.push(s) }
                win.setIfChanged("installedFonts", a)
            }
        }
    }
    FileView {
        id: fontConfFile
        path: win.homeDir + "/.config/hypr/font.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: win.currentFont = this.text().trim()
        onLoadFailed: win.currentFont = ""
    }
    Process { id: fontSetProc }
    function setFont(name) {
        if (!name) return
        win.currentFont = name
        if (win.shell) win.shell.uiFont = name   // instant: bar + this window re-font live
        var b64 = Qt.btoa(name)
        fontSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/font.conf'; " +
            "\"$HOME/.config/hypr/gen-wofi-font.sh\""]
        fontSetProc.running = true
    }

    // ── Bar icon options (Bar & Apps page) ── hypr/bar.conf, read by shell.qml. The
    // shell properties are set first so every bar changes on the click; the
    // file then makes it stick across restarts.
    Process { id: barConfProc }
    function setBarOption(key, on) {
        if (!win.shell) return
        if (key === "LAUNCHER_TINT") win.shell.launcherTint = on
        if (key === "DIM_MINIMIZED") win.shell.dimMinimized = on
        writeBarConf()
    }
    // Tray icons: hide/show one tray item by its id (the app keeps running).
    function setTrayShown(id, shown) {
        if (!win.shell || id === "") return
        var h = win.shell.trayHidden.filter(function (x) { return x !== id })
        if (!shown) h.push(id)
        win.shell.trayHidden = h
        writeBarConf()
    }
    // Every key goes back in: the file is rewritten whole.
    function writeBarConf() {
        var text = "# Written by Settings > Bar & Apps. 1 = on, 0 = off.\n" +
                   "LAUNCHER_TINT=" + (win.shell.launcherTint ? 1 : 0) + "\n" +
                   "DIM_MINIMIZED=" + (win.shell.dimMinimized ? 1 : 0) + "\n" +
                   "TRAY_HIDDEN=" + win.shell.trayHidden.join(",") + "\n"
        barConfProc.command = ["bash", "-c",
            "printf %s '" + Qt.btoa(text) + "' | base64 -d > '" + win.homeDir + "/.config/hypr/bar.conf'"]
        barConfProc.running = true
    }

    // ── Update (System page) ── pull latest from GitHub + copy configs (tuning
    // files are gitignored, so they're preserved). Two-click confirm so it can't
    // wipe uncommitted work by accident.
    property string updateStatus: ""
    property bool updateArmed: false
    readonly property bool updateRunning: updateProc.running
    Process {
        id: updateProc
        stdout: SplitParser { splitMarker: "\n"; onRead: function (line) { if (line.trim() !== "") win.updateStatus = line } }
    }
    Timer { id: updateDisarm; interval: 4000; onTriggered: win.updateArmed = false }
    function runUpdate() {
        if (!win.updateArmed) { win.updateArmed = true; win.updateStatus = "Click again to confirm — this overwrites shipped files with GitHub's latest."; updateDisarm.restart(); return }
        win.updateArmed = false; updateDisarm.stop()
        win.updateStatus = "Starting…"
        updateProc.command = ["bash", "-c", "\"$HOME/.config/hypr/technicolor-update.sh\""]
        updateProc.running = true
    }
    // Preview: list the commits not yet pulled (GitHub API, no clone).
    property var newCommits: []
    property string commitCount: ""
    property bool checking: false
    Process {
        id: checkProc
        stdout: StdioCollector {
            onStreamFinished: {
                win.checking = false
                var lines = this.text.split("\n").filter(function (s) { return s.trim() !== "" })
                win.commitCount = lines.length ? lines[0] : "?"
                win.newCommits = lines.slice(1)
            }
        }
    }
    function runCheck() { win.checking = true; win.newCommits = []; win.commitCount = ""; checkProc.command = ["bash", "-c", "\"$HOME/.config/hypr/technicolor-check.sh\""]; checkProc.running = true }

    // ── Liked-songs tools (System page) ── scan for AI music + CSV backup, run
    // through the live Spicetify session (spotify-liked.py). Read-only.
    property string likedStatus: ""
    property bool likedBusy: false
    readonly property bool likedScanRunning: likedScanProc.running
    readonly property bool likedExportRunning: likedExportProc.running
    Process {
        id: likedScanProc
        onRunningChanged: if (running) { win.likedBusy = true; win.likedStatus = "Scanning your Liked Songs…" }
        stdout: StdioCollector { onStreamFinished: { win.likedBusy = false; win.likedStatus = this.text.trim() || "(no output — is Spotify open with the theme applied?)" } }
    }
    Process {
        id: likedExportProc
        onRunningChanged: if (running) { win.likedBusy = true; win.likedStatus = "Backing up your Liked Songs…" }
        stdout: StdioCollector { onStreamFinished: { win.likedBusy = false; win.likedStatus = this.text.trim() || "(no output — is Spotify open with the theme applied?)" } }
    }
    function scanLiked()   { if (win.likedBusy) return; likedScanProc.command   = ["bash", "-c", "\"$HOME/.config/hypr/scan-ai-music.sh\" 2>&1"]; likedScanProc.running = true }
    function exportLiked() { if (win.likedBusy) return; likedExportProc.command = ["bash", "-c", "\"$HOME/.config/hypr/export-liked-songs.sh\" 2>&1"]; likedExportProc.running = true }

    // ── wallpapers folder (Wallpaper page) — single source of truth in
    // ~/.config/hypr/wallpaper-dir.conf; every wallpaper script reads it. ──
    property string wallpaperDir: win.homeDir + "/Wallpapers/animated"
    FileView {
        id: wpDirFile
        path: win.homeDir + "/.config/hypr/wallpaper-dir.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: { var t = this.text().trim(); win.wallpaperDir = t !== "" ? t : win.homeDir + "/Wallpapers/animated" }
        onLoadFailed: win.wallpaperDir = win.homeDir + "/Wallpapers/animated"
    }
    Process { id: wpDirSetProc; onRunningChanged: if (!running) win.refreshWallpapers() }
    function setWallpaperDir(dir) {
        if (!dir) return
        win.wallpaperDir = dir
        var b64 = Qt.btoa(dir)
        // write the config, then immediately cycle so a wallpaper from the new
        // folder shows (and wallpaper-cycle.sh re-syncs its upscale cache).
        wpDirSetProc.command = ["bash", "-c", "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/wallpaper-dir.conf'; \"$HOME/.config/hypr/wallpaper-cycle.sh\" random"]
        wpDirSetProc.running = true
    }
    Process {
        id: wpDirPickProc
        stdout: StdioCollector { onStreamFinished: { var p = this.text.trim(); if (p) win.setWallpaperDir(p) } }
    }
    function pickWallpaperDir() {
        wpDirPickProc.command = ["bash", "-c", "if command -v kdialog >/dev/null 2>&1; then QT_QPA_PLATFORMTHEME=kde kdialog --getexistingdirectory '" + win.wallpaperDir + "' 2>/dev/null; else zenity --file-selection --directory 2>/dev/null; fi"]
        wpDirPickProc.running = true
    }

    // ── cover-flow data: one entry per wallpaper { src, thumb } ──
    property var wallpaperList: []
    property string currentWallpaper: ""
    readonly property bool wpThumbsRunning: wpThumbsProc.running
    Process {
        id: wpThumbsProc
        // wallpaper-thumbs.sh caches, so re-running is cheap; prints src<TAB>thumb
        command: ["bash", "-c", "\"$HOME/.config/hypr/wallpaper-thumbs.sh\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = []
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].split("\t")
                    if (p.length >= 2 && p[0]) out.push({ src: p[0], thumb: p[1] })
                }
                win.wallpaperList = out
            }
        }
    }
    function refreshWallpapers() { wpThumbsProc.running = true }
    // current wallpaper → center the flow on it
    FileView {
        id: curWpFile
        path: "/tmp/wallpaper-current-path"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: win.currentWallpaper = this.text().trim()
    }
    function applyWallpaper(src) {
        if (!src) return
        win.currentWallpaper = src
        var safe = src.split("'").join("'\\''")   // single-quote-safe
        Quickshell.execDetached(["sh", "-c", "~/.config/hypr/wallpaper-cycle.sh '" + safe + "'"])
    }

    // Live folder watch: dropping/removing a wallpaper in the folder refreshes
    // the cover flow automatically (QFileSystemWatcher under the hood). Active
    // only while the window is open; debounced so a burst of files = one rebuild.
    FolderListModel {
        id: wpFolderModel
        folder: win.visible ? ("file://" + win.wallpaperDir) : ""
        showDirs: false
        caseSensitive: false
        nameFilters: ["*.gif", "*.webp", "*.webm", "*.mp4", "*.png", "*.jpg", "*.jpeg"]
        onCountChanged: wpWatchDebounce.restart()
    }
    // Its light/ and dark/ subfolders too (light/dark mode, hypr/wallpaper-list.sh).
    FolderListModel {
        folder: win.visible ? ("file://" + win.wallpaperDir + "/light") : ""
        showDirs: false; caseSensitive: false; nameFilters: wpFolderModel.nameFilters
        onCountChanged: wpWatchDebounce.restart()
    }
    FolderListModel {
        folder: win.visible ? ("file://" + win.wallpaperDir + "/dark") : ""
        showDirs: false; caseSensitive: false; nameFilters: wpFolderModel.nameFilters
        onCountChanged: wpWatchDebounce.restart()
    }
    Timer { id: wpWatchDebounce; interval: 400; onTriggered: win.refreshWallpapers() }

    // "Shows in" (Wallpaper page): which light/dark mode a wallpaper belongs to
    // is just where it sits — light/, dark/, or loose in the folder for both.
    function wallpaperModeOf(src) {
        var d = win.wallpaperDir.replace(/\/+$/, "")
        if (src.indexOf(d + "/light/") === 0) return "light"
        if (src.indexOf(d + "/dark/") === 0) return "dark"
        return "both"
    }
    Process { id: wpMoveProc; onExited: win.refreshWallpapers() }
    function moveWallpaperMode(src, to) {
        wpMoveProc.command = [win.homeDir + "/.config/hypr/wallpaper-mode-move.sh", src, to]
        wpMoveProc.running = true
    }

    // ── Appearance (Colors page) ── light/dark mode. hypr/theme-mode.py owns the
    // schedule and hypr/theme-mode.conf; Settings only asks it things. themeStatus
    // is its `status` JSON: setting, mode, next_mode, next (epoch s), location,
    // location_source ("city" | "timezone" | "none"), light_at, dark_at.
    readonly property string themePy: win.homeDir + "/.config/hypr/theme-mode.py"
    property var themeStatus: ({})
    property string citySearch: ""
    property var cityResults: []
    property var themePending: null
    Process {
        id: themeStatusProc
        command: ["python3", win.themePy, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { win.themeStatus = JSON.parse(this.text) } catch (e) {}
                // The Colors page opens on the sliders of the mode on screen.
                if (!win.tuneEditPicked && win.themeStatus.mode) win.tuneEditMode = win.themeStatus.mode
            }
        }
    }
    function refreshTheme() { if (!themeStatusProc.running) themeStatusProc.running = true }
    // `set` prints the new status first, then pushes the mode (and rebuilds the
    // palette if it changed). A click while one is still running is queued, not lost.
    Process {
        id: themeSetProc
        stdout: SplitParser { splitMarker: "\n"; onRead: function (line) { try { win.themeStatus = JSON.parse(line) } catch (e) {} } }
        onExited: if (win.themePending) { var p = win.themePending; win.themePending = null; win.setTheme(p) }
    }
    function setTheme(pairs) {   // ["MODE=auto", "CITY=…", …]
        if (themeSetProc.running) { win.themePending = (win.themePending || []).concat(pairs); return }
        themeSetProc.command = ["python3", win.themePy, "set"].concat(pairs)
        themeSetProc.running = true
    }
    function pickCity(c) {
        var label = [c.name, c.region, c.country].filter(function (x) { return x !== "" }).join(", ")
        win.setTheme(["CITY=" + label, "LAT=" + c.lat, "LON=" + c.lon])
        win.citySearch = ""
    }
    Process {
        id: citySearchProc
        stdout: StdioCollector { onStreamFinished: { try { win.cityResults = JSON.parse(this.text) } catch (e) { win.cityResults = [] } } }
    }
    Timer {
        id: cityDebounce; interval: 150
        onTriggered: {
            if (win.citySearch.trim() === "") { win.cityResults = []; return }
            if (citySearchProc.running) { cityDebounce.restart(); return }
            citySearchProc.command = ["python3", win.themePy, "cities", win.citySearch]
            citySearchProc.running = true
        }
    }
    onCitySearchChanged: cityDebounce.restart()
    // The status line names the next switch; keep it current while the page is open.
    Timer { interval: 60000; repeat: true; running: win.visible && win.page === 2; onTriggered: win.refreshTheme() }
    // "22:00" -> "10:00 PM", and back. parseClock also takes "10pm", "10:30 pm", "7".
    function fmtClock(hhmm) {
        var m = /^(\d{1,2}):(\d{2})$/.exec(hhmm || ""); if (!m) return hhmm || ""
        var h = parseInt(m[1]); return ((h + 11) % 12 + 1) + ":" + m[2] + (h < 12 ? " AM" : " PM")
    }
    function parseClock(s) {
        var m = /^\s*(\d{1,2})(?::(\d{2}))?\s*([ap])?\.?m?\.?\s*$/i.exec(s || ""); if (!m) return ""
        var h = parseInt(m[1]), mi = m[2] ? parseInt(m[2]) : 0, ap = m[3] ? m[3].toLowerCase() : ""
        if (mi > 59 || h > 23 || (ap && (h < 1 || h > 12))) return ""
        if (ap === "p" && h < 12) h += 12
        if (ap === "a" && h === 12) h = 0
        return (h < 10 ? "0" : "") + h + ":" + (mi < 10 ? "0" : "") + mi
    }
    function themeLine(st) {
        if (!st || !st.mode) return ""
        if (!st.next) return st.mode === "dark" ? "Always dark" : "Always light"
        var t = Qt.formatTime(new Date(st.next * 1000), "h:mm AP")
        return "Now " + st.mode + " · switches to " + st.next_mode + " at " + t
    }

    // ── Colors page state ── single source of truth = the color-tuning file of
    // the mode being edited (CONTRAST_BIAS, SATURATION, BRIGHTNESS, HUE + the
    // per-surface keys): hypr/color-tuning.conf for dark, color-tuning-light.conf
    // for light once it's been edited (it reads dark's until then). theme-mode.py
    // owns both: `tuning MODE` says which file to read, `tune MODE K=V` writes.
    // The bar reads CONTRAST_BIAS live via shell.qml; the other three transform
    // the colors at the source (wallpaper-colors.py) so they flow to every app
    // via colors.env on regen.
    property string tuneEditMode: "dark"     // which mode's sliders the page edits
    property bool tuneEditPicked: false      // picked by hand since the page opened
    readonly property bool tuneEditingLive: win.tuneEditMode === (win.themeStatus.mode || "dark")
    // theme-mode.py tuning_path's rule, evaluated here so switching the edited
    // mode can't race an answer for the other one: light reads its own file
    // once it exists, dark's until then.
    property bool lightTuneExists: false
    FileView {
        id: lightTuneProbe
        path: win.homeDir + "/.config/hypr/color-tuning-light.conf"
        onLoaded: win.lightTuneExists = true
        onLoadFailed: win.lightTuneExists = false
    }
    readonly property string tuneReadPath: win.homeDir + "/.config/hypr/"
        + (win.tuneEditMode === "light" && win.lightTuneExists ? "color-tuning-light.conf" : "color-tuning.conf")
    function refreshTunePath() { lightTuneProbe.reload() }
    function pickTuneMode(m) { win.tuneEditPicked = true; win.tuneEditMode = m }
    // The five palette colors BEFORE any sliders (wallpaper-colors.py), so the
    // swatches can preview either mode's set — colors.env has the live mode's
    // ceilings baked in. Order matches the Colors page swatches.
    property var rawPalette: []
    FileView {
        path: win.homeDir + "/.config/quickshell/colors-raw.env"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var m = {}, lines = this.text().split("\n")
            for (var i = 0; i < lines.length; i++) { var p = lines[i].split("="); if (p.length === 2) m[p[0].trim()] = p[1].trim() }
            var keys = ["GRADIENT_START", "GRADIENT_END", "FOCUSED", "VISIBLE", "OCCUPIED"], out = []
            for (var j = 0; j < keys.length; j++) { if (!m[keys[j]]) { win.rawPalette = []; return } out.push(m[keys[j]]) }
            win.rawPalette = out
        }
        onLoadFailed: win.rawPalette = []
    }
    property real tuneContrast: 0.5      // 0 dark .. 0.5 default .. 1 light
    property real tuneSaturation: 1.0    // saturation ceiling: 0 grayscale .. 1 uncapped
    property real tuneBrightness: 1.0    // brightness ceiling: 0 black .. 1 uncapped
    property real tuneHue: 0.0           // -180..180 degrees, 0 = unchanged
    FileView {
        id: tuneFile
        path: win.tuneReadPath
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            var lines = this.text().split("\n")
            for (var i = 0; i < lines.length; i++) {
                var p = lines[i].split("="); if (p.length !== 2) continue
                var k = p[0].trim(); var f = parseFloat(p[1].trim()); if (isNaN(f)) continue
                if (k === "CONTRAST_BIAS") win.tuneContrast = f
                else if (k === "SATURATION") win.tuneSaturation = f
                else if (k === "BRIGHTNESS") win.tuneBrightness = f
                else if (k === "HUE") win.tuneHue = f
            }
        }
        onLoadFailed: { win.tuneContrast = 0.5; win.tuneSaturation = 1.0; win.tuneBrightness = 1.0; win.tuneHue = 0.0 }
    }
    // Write the config AND re-run the whole color pipeline in ONE sequential
    // command, so wallpaper-colors.py / the generators never read a half-written
    // config. Re-extracts from the current wallpaper, applies the knobs at the
    // source, regenerates every app theme, refreshes mako.
    // theme-mode.py tune keeps every other line of the file (the old writer
    // rewrote it with just these four and dropped the per-surface keys), and
    // reruns the pipeline only when the edited set is the one on screen.
    Process {
        id: tuneCommitProc
        onExited: { win.refreshTunePath(); if (win.shell) win.shell.refreshTuningPath() }
    }
    function commitTuning() {
        tuneCommitProc.command = ["python3", win.themePy, "tune", win.tuneEditMode,
            "CONTRAST_BIAS=" + win.tuneContrast.toFixed(3),
            "SATURATION=" + win.tuneSaturation.toFixed(3),
            "BRIGHTNESS=" + win.tuneBrightness.toFixed(3),
            "HUE=" + win.tuneHue.toFixed(1)]
        tuneCommitProc.running = true
    }
    // Live preview helpers. Take the knobs as arguments so the swatch bindings
    // track them (a value read only inside the function body wouldn't re-evaluate).
    function previewInk(c, bias) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        var thr = bias <= 0.5 ? (bias / 0.5) * 0.55 : 0.55 + ((bias - 0.5) / 0.5) * 0.45
        return lum > thr ? "#000000" : "#FFFFFF"
    }
    function previewColor(c, sat, bright, hue) {
        // sat/bright are CEILINGS (cap), matching apply_tuning in wallpaper-colors.py.
        var hh = c.hslHue; if (hh < 0) hh = 0
        hh = hh + hue / 360.0; hh = hh - Math.floor(hh)
        return Qt.hsla(hh, Math.min(c.hslSaturation, sat),
                       Math.min(c.hslLightness, bright), 1)
    }
    function resetContrast()   { win.tuneContrast = 0.5; if (win.shell && win.tuneEditingLive) win.shell.contrastBias = 0.5; win.commitTuning() }
    function resetSaturation() { win.tuneSaturation = 1.0; win.commitTuning() }
    function resetBrightness() { win.tuneBrightness = 1.0; win.commitTuning() }
    function resetHue()        { win.tuneHue = 0.0; win.commitTuning() }

    // ── Per-surface tuning ── each surface layers its OWN sat/bright(MULTIPLIERS,
    // 1.0 = unchanged, <1 tones down, >1 boosts) + hue on top of the global knobs
    // above. Keys live in the same color-tuning.conf as <KEY>_SAT / _BRIGHT / _HUE
    // (e.g. DISCORD_SAT). Read by gen-discord-theme.py's _surface_tuning_for (the
    // six generators) + surface-tune.py (bar/notifications).
    readonly property var surfaceSpecs: [
        { key: "bar",          label: "Quickshell bar" },
        { key: "notifications", label: "Notifications" },
        { key: "gtk",          label: "GTK apps" },
        { key: "discord",      label: "Discord (Vesktop)" },
        { key: "spotify",      label: "Spotify" },
        { key: "brave",        label: "Brave" },
        { key: "kde",          label: "Dolphin / KDE apps" },
        { key: "telegram",     label: "Telegram (re-import)" }
    ]
    // surfaceTune[key] = {sat,bright,hue}. Mutated via reassignment so bindings update.
    property var surfaceTune: ({})
    function surfaceVal(key, field, def) {
        var s = win.surfaceTune[key]
        return (s && s[field] !== undefined) ? s[field] : def
    }
    function setSurfaceVal(key, field, v) {
        var t = win.surfaceTune
        if (!t[key]) t[key] = { sat: 1.0, bright: 1.0, hue: 0.0 }
        t[key][field] = v
        win.surfaceTune = t        // reassign whole object so QML re-evaluates bindings
        win.surfaceRefresh++
    }
    property int surfaceRefresh: 0   // bumped after edits so the Colors page re-reads
    property int _surfaceParseTick: 0
    function parseSurfaceTune(text) {
        var t = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (ln === "" || ln[0] === "#" || ln.indexOf("=") < 0) continue
            var p = ln.split("="); var k = p[0].trim(); var f = parseFloat(p[1].trim())
            if (isNaN(f)) continue
            var m = k.match(/^([A-Z]+)_(SAT|BRIGHT|HUE)$/)
            if (!m) continue
            var key = m[1].toLowerCase()
            // skip the GLOBAL SATURATION/BRIGHTNESS/HUE (no surface prefix matched those)
            if (["contrast","saturation","brightness","hue"].indexOf(key) >= 0) continue
            if (!t[key]) t[key] = { sat: 1.0, bright: 1.0, hue: 0.0 }
            if (m[2] === "SAT") t[key].sat = f
            else if (m[2] === "BRIGHT") t[key].bright = f
            else t[key].hue = f
        }
        win.surfaceTune = t
    }
    // Append/replace the per-surface keys, then re-run the SAME pipeline as the
    // global commit so every surface regenerates. Reads color-tuning.conf, strips
    // the old banner + any existing *_SAT/_BRIGHT/_HUE surface lines (any prefix,
    // so surfaces retired from surfaceSpecs don't linger), re-emits the current
    // set. Idempotent: committing twice leaves a byte-identical file.
    // Every surface's three keys, through theme-mode.py tune: a value at its
    // default is sent empty, which removes the key. Same pipeline rule as above.
    Process {
        id: surfaceCommitProc
        onExited: win.refreshTunePath()
    }
    function commitSurfaceTune() {
        var pairs = []
        for (var i = 0; i < win.surfaceSpecs.length; i++) {
            var key = win.surfaceSpecs[i].key
            var s = win.surfaceTune[key] || {}
            var KEY = key.toUpperCase()
            var sat = s.sat === undefined ? 1 : s.sat, bright = s.bright === undefined ? 1 : s.bright, hue = s.hue === undefined ? 0 : s.hue
            pairs.push(KEY + "_SAT=" + (Math.abs(sat - 1) > 1e-3 ? sat.toFixed(3) : ""))
            pairs.push(KEY + "_BRIGHT=" + (Math.abs(bright - 1) > 1e-3 ? bright.toFixed(3) : ""))
            pairs.push(KEY + "_HUE=" + (Math.abs(hue) > 1e-3 ? hue.toFixed(1) : ""))
        }
        surfaceCommitProc.command = ["python3", win.themePy, "tune", win.tuneEditMode].concat(pairs)
        surfaceCommitProc.running = true
    }
    function resetSurface(key) {
        var t = win.surfaceTune; t[key] = { sat: 1.0, bright: 1.0, hue: 0.0 }
        win.surfaceTune = t; win.surfaceRefresh++
        win.commitSurfaceTune()
    }
    FileView {
        id: surfaceTuneFile
        path: win.tuneReadPath
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: win.parseSurfaceTune(this.text())
        onLoadFailed: win.surfaceTune = ({})
    }

    // ── Glass page (hyprwater) ── live via hyprwater-set.sh (hyprctl eval under
    // the Lua config), persisted to hyprwater-tuning.conf. Each spec: key/label/
    // range/default. Anything beyond a slider's range goes through the write-in.
    readonly property var glassSpecs: [
        { key: "refraction_strength",  label: "Refraction",          from: 0, to: 3,  def: 1.0,  step: 0 },
        { key: "fresnel_strength",     label: "Fresnel (edge glow)",  from: 0, to: 1,  def: 0.3,  step: 0 },
        { key: "specular_strength",    label: "Specular (highlight)", from: 0, to: 1,  def: 0.3,  step: 0 },
        { key: "lens_distortion",      label: "Lens distortion",      from: 0, to: 1,  def: 0.1,  step: 0 },
        { key: "edge_thickness",       label: "Edge thickness",       from: 0, to: 1,  def: 0.2,  step: 0 },
        { key: "chromatic_aberration", label: "Chromatic aberration", from: 0, to: 1,  def: 0.0,  step: 0 },
        // to:5 not 2 — at quarter-res sampling (which kicks in at 1.3) the
        // blur shader's tap cap used to sit at 5.33; past it the kernel
        // truncated instead of widening. The cap is 40 now (one combined pass).
        { key: "blur_strength",        label: "Blur strength",        from: 0, to: 5,  def: 0.2,  step: 0 },
        { key: "blur_iterations",      label: "Blur iterations",      from: 0, to: 4,  def: 1.0,  step: 1 },
        { key: "brightness",           label: "Brightness",           from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "contrast",             label: "Contrast",             from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "saturation",           label: "Saturation",           from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "vibrancy",             label: "Vibrancy",             from: 0, to: 2,  def: 1.0,  step: 0 }
    ]
    // Water shimmer knobs. These ride the SAME path as the Glass page: glassLive()
    // applies instantly via hyprctl eval, glassSet() persists to
    // hyprwater-tuning.conf. Nothing new to plumb.
    readonly property var shimmerSpecs: [
        { key: "shimmer:intensity",     label: "Brightness",  hint: "How far the water swings either side of the plain image — how bright the veins get and how dark the gaps between them, how hard the surface bends and glints. It is an amplitude, not an exposure: turning it down flattens the water toward still glass, it never darkens anything. Logarithmic, because the interesting settings are all down at the quiet end. Past 1.0 the surface stops steepening and only the veins keep over-exposing.", from: 0.02, to: 3, def: 0.8, step: 0, log: true },
        { key: "shimmer:depth",         label: "Water depth",  hint: "Distance from the surface to the floor, with 1.0 as the nominal pool. It is the one physical length here, so it sets BOTH how far the bent light travels sideways before it lands \u2014 how much the window behind is displaced \u2014 and how hard it converges on the way, which is what thins the bright lines. Deep bends and focuses together; shallow leaves the image nearly straight and the light a soft wash.", from: 0.25, to: 5, def: 1.0, step: 0 },
        { key: "shimmer:scale",         label: "Wave size",    hint: "Size of the waves, and so of the cells between the bright lines. Larger waves also means fewer of them across a window.", from: 0.2, to: 3, def: 1.0, step: 0 },
        { key: "shimmer:speed",         label: "Speed",        hint: "How fast the water runs. Logarithmic, so most of the travel is spent down in the barely-moving range. Slow stays smooth: below 1x each step advances the physics less rather than stepping less often.", from: 0.002, to: 3, def: 1.0, step: 0, log: true },
        { key: "shimmer:agitation",     label: "Activity",     hint: "How busy the water is \u2014 how often something disturbs it, and how hard. Far left is a still pool crossed by a stray ripple every several seconds; far right is a crowded one. The scale is geometric, so the calm end has as much travel as the busy end.", from: 0, to: 1,  def: 0.5,  step: 0 },
        { key: "shimmer:viscosity",     label: "Viscosity",    hint: "How thick the water is. LOW = thin: ripples persist, the surface stays busy, waves travel fast. HIGH = syrup: short waves die within moments, only long rollers survive, waves travel slower.", from: 0, to: 1,  def: 0.6,  step: 0 },
        { key: "shimmer:absorption",    label: "Water color", hint: "How much the water itself absorbs. 1.0 is the measured spectrum for pure water \u2014 strong in red, almost none in blue, which is why depth turns things blue. 0 makes the water colourless, which no real water is, but it is your desktop.", from: 0, to: 1,  def: 1.0,  step: 0 },
        { key: "shimmer:murk",          label: "Murk",         hint: "Suspended silt. Particles block what is behind them AND scatter stray light at you, so murky water washes toward a pale haze rather than going dark. Colourless at source \u2014 large particles scatter all wavelengths equally, same reason fog is white.", from: 0, to: 1,  def: 0.0,  step: 0 },
        { key: "shimmer:mouse",         label: "Mouse wake",   hint: "How heavily the cursor rests on the water. A fingertip trailed through the pool \u2014 a thin wake of ripples follows where you point, deposited by distance moved, not speed \u2014 and every click taps the surface, a small ring spreading from where you pressed. Zero lifts it off the surface entirely.", from: 0, to: 1,  def: 0.3, step: 0 },
        { key: "shimmer:window_physics", label: "Window physics", hint: "How hard a window grips the water. Dragging one shoves it aside \u2014 a crest piles against the advancing edge, a trough fills in behind, sized to the window and deposited by distance dragged. That bow wave is the steepest water on screen, so it is also what lights the leading edge: turn this down and the drag glint fades with it. At zero windows glide over the surface without touching it.", from: 0, to: 1, def: 1.0, step: 0 },
    ]

    // Log-scaled sliders. A linear 0.002..3 track spends ~99% of its travel
    // above 0.05, which is exactly the part nobody wants — so the SLIDER carries
    // a 0..1 position and the value is exponential in it. Fine control lands
    // where the useful settings actually are.
    function logPosToVal(spec, pos) {
        return spec.from * Math.pow(spec.to / spec.from, Math.max(0, Math.min(1, pos)))
    }
    function logValToPos(spec, v) {
        if (!(v > 0)) return 0
        return Math.log(v / spec.from) / Math.log(spec.to / spec.from)
    }

    property var glassValues: ({})    // key -> live value, populated by loadGlass()
    Process {
        id: glassGetProc
        command: ["bash", "-c", "\"$HOME/.config/hypr/hyprwater-get.sh\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = {}
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].split("="); if (p.length !== 2) continue
                    var f = parseFloat(p[1].trim()); if (!isNaN(f)) m[p[0].trim()] = f
                }
                win.glassValues = m
            }
        }
    }
    function loadGlass() { glassGetProc.running = true }
    // Live (cheap, skip-if-busy throttle); persistence happens on release.
    // Under the Lua config manager `hyprctl keyword` is rejected — apply live via
    // `hyprctl eval hl.config({plugin={hyprwater={<nested>}}})`. Colon keys
    // (dark:brightness) nest; tint_color takes a bare hex int (no quotes).
    Process { id: glassLiveProc }
    function glassLive(key, val) {
        if (glassLiveProc.running) return
        var parts = key.split(":")
        var inner = parts[parts.length - 1] + "=" + val
        for (var i = parts.length - 2; i >= 0; i--) inner = parts[i] + "={" + inner + "}"
        glassLiveProc.command = ["hyprctl", "eval", "hl.config({plugin={hyprwater={" + inner + "}}}) return 1"]
        glassLiveProc.running = true
    }
    // ── White glass (Glass page) ── hyprwater adaptive_white lifts terminal glass
    // toward white; terminal-colors.py turns kitty's text black to match. kitty
    // only: the one terminal whose colors change live.
    readonly property bool whiteGlassTerminalOk: win.currentTerminal.trim().split(/\s+/)[0] === "kitty"
    Process { id: whiteGlassProc; onExited: win.loadGlass() }
    function setWhiteGlass(on) {
        whiteGlassProc.command = ["bash", "-c",
            "\"$HOME/.config/hypr/hyprwater-set.sh\" adaptive_white " + (on ? 1 : 0) + "; "
            + "\"$HOME/.config/hypr/terminal-colors.py\" " + (on ? "light" : "default")]
        whiteGlassProc.running = true
    }
    Process { id: glassSetProc }
    function glassSet(key, val) {
        glassSetProc.command = ["bash", "-c", "\"$HOME/.config/hypr/hyprwater-set.sh\" '" + key + "' '" + val + "'"]
        glassSetProc.running = true
    }
    function glassValue(spec) {
        var v = win.glassValues[spec.key]
        return (v === undefined) ? spec.def : v
    }

    // The row components (TcSlider, TcToggle, SliderRow, ToggleRow, Section,
    // Chips, TcButton, SmoothList, DragDivider) and the pages are in settings/.
    Component.onCompleted: ST.win = win
    Component.onDestruction: if (ST.win === win) ST.win = null

    // ── content: solid rounded blocks, live liquid glass in the gaps ──
    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.close()

        Row {
            anchors.fill: parent
            anchors.margins: 14      // outer glass margin
            spacing: 12              // glass gap between blocks

            // ── sidebar block: title, then one entry per page. No close X —
            // this is a keyboard-driven WM, so dismiss with Esc or re-toggle the
            // opener. ──
            Rectangle {
                id: sidebar
                width: 196; height: parent.height; radius: 16; color: win.blockColor
                Column {
                    anchors.fill: parent; anchors.margins: 10; spacing: 4
                    Text { leftPadding: 10; topPadding: 6; bottomPadding: 12
                           text: "Settings"; color: win.fg; font.pixelSize: 18; font.bold: true; font.family: win.ff }
                    Repeater {
                        model: win.pages
                        delegate: Rectangle {
                            required property int index
                            required property var modelData
                            readonly property bool sel: win.page === index
                            width: parent.width; height: 38; radius: 10
                            color: sel ? win.rowHover : (navM.containsMouse ? win.rowBg : "transparent")
                            Text { id: navGlyph; anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                   width: 20; horizontalAlignment: Text.AlignHCenter
                                   text: String.fromCodePoint(modelData.glyph); color: win.fg; opacity: sel ? 1 : 0.7
                                   font.pixelSize: 14; font.family: win.ff }
                            Text { anchors.left: navGlyph.right; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                   text: modelData.name; color: win.fg; font.pixelSize: 13; font.bold: sel; font.family: win.ff }
                            MouseArea { id: navM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: if (win.shell) win.shell.settingsTab = index }
                        }
                    }
                }
            }

            // ── body block: the shown page ──
            Rectangle {
                width: parent.width - sidebar.width - parent.spacing; height: parent.height
                radius: 16; color: win.blockColor; clip: true
                Text { id: pageTitle; x: 18; y: 14
                       text: win.pages[win.page].name; color: win.fg; font.pixelSize: 20; font.bold: true; font.family: win.ff }
                Loader {
                    anchors.top: pageTitle.bottom; anchors.topMargin: 12
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    anchors.leftMargin: 18; anchors.rightMargin: 18; anchors.bottomMargin: 16
                    // Only the shown page exists, and only while the window is
                    // open; its state that should survive (search text, list
                    // heights) lives on this window.
                    active: win.visible && ST.win === win
                    sourceComponent: [pgBarApps, pgWallpaper, pgColors, pgGlass, pgWater, pgPerformance, pgHotkeys, pgSystem][win.page]
                }
            }
        }
        Component { id: pgBarApps;     PageBarApps {} }
        Component { id: pgWallpaper;   PageWallpaper {} }
        Component { id: pgColors;      PageColors {} }
        Component { id: pgGlass;       PageGlass {} }
        Component { id: pgWater;       PageWater {} }
        Component { id: pgPerformance; PagePerformance {} }
        Component { id: pgHotkeys;     PageHotkeys {} }
        Component { id: pgSystem;      PageSystem {} }

        // Keyboard sink for rebinding: focused only while capturing. While the
        // __tc_capture submap is active (entered in startCapture), every combo —
        // even normally-bound ones — lands here instead of firing its action.
        Item {
            id: captureKey
            width: 0; height: 0
            focus: win.capturingBind !== null
            Keys.onPressed: (e) => {
                if (win.capturingBind === null) return
                e.accepted = true
                if (win.isModifierKey(e.key)) return          // wait for the non-modifier key
                if (e.key === Qt.Key_Escape) { win.endCapture(); return }
                var mods = 0
                if (e.modifiers & Qt.ShiftModifier)   mods |= 1
                if (e.modifiers & Qt.ControlModifier) mods |= 4
                if (e.modifiers & Qt.AltModifier)     mods |= 8
                if (e.modifiers & Qt.MetaModifier)    mods |= 64
                win.commitCapture(mods, win.qtKeyName(e))
            }
        }

        // ── Add-app picker overlay ──
        Rectangle {
            anchors.fill: parent
            visible: win.addOpen
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: win.addOpen = false }
            Rectangle {
                anchors.centerIn: parent
                width: Math.min(520, parent.width - 80); height: Math.min(520, parent.height - 80)
                radius: 14; color: win.bodyColor
                MouseArea { anchors.fill: parent; onClicked: {} }
                Column {
                    anchors.fill: parent; anchors.margins: 14; spacing: 10
                    Text { text: "Pick an app to pin"; color: win.fg; font.pixelSize: 15; font.bold: true; font.family: win.ff }
                    Rectangle {
                        width: parent.width; height: 32; radius: 8; color: win.rowBg
                        TextInput {
                            id: appSearch; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                            verticalAlignment: TextInput.AlignVCenter
                            color: win.fg; font.pixelSize: 13; font.family: win.ff; clip: true
                            focus: win.addOpen
                        }
                        Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            visible: appSearch.text === ""; text: "Search…"; color: win.fg; opacity: 0.5; font.pixelSize: 13; font.family: win.ff }
                    }
                    // A ListView: only the visible rows (and their icon lookups) exist.
                    SmoothList {
                        width: parent.width; height: parent.height - 84
                        ListView {
                            id: resList
                            spacing: 4
                            boundsBehavior: Flickable.StopAtBounds
                            model: {
                                var q = appSearch.text.toLowerCase()
                                if (q === "") return win.installedApps
                                var r = []
                                for (var i = 0; i < win.installedApps.length; i++)
                                    if (win.installedApps[i].name.toLowerCase().indexOf(q) >= 0) r.push(win.installedApps[i])
                                return r
                            }
                            delegate: Rectangle {
                                required property var modelData
                                width: resList.width; height: 40; radius: 8; color: pickM.containsMouse ? win.rowHover : "transparent"
                                Row {
                                    anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                    Image { anchors.verticalCenter: parent.verticalCenter; width: 24; height: 24; sourceSize.width: 64; sourceSize.height: 64; smooth: true
                                        source: win.bar ? win.bar.resolveAppIcon(modelData.desktopId !== "" ? modelData.desktopId : modelData.icon, modelData.name) : "" }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.name; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                }
                                MouseArea {
                                    id: pickM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (win.bar) win.bar.addPin({ icon: modelData.desktopId !== "" ? modelData.desktopId : modelData.icon, cmd: modelData.exec, nerdGlyph: "", imgPath: "" })
                                        win.addOpen = false; appSearch.text = ""
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
