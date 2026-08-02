// Settings.qml — a real toplevel app window (FloatingWindow), opened from the
// launcher's gear. Instantiated once per bar (Bar.qml): `Settings { bar: bar }`.
// Colors/state/data come through the `bar` reference so it matches the bar.
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel

FloatingWindow {
    id: win
    property var bar      // a Bar instance — colors + pin data (may briefly be null)
    property var shell    // the ShellRoot — holds the settings open/tab state

    visible: shell ? shell.settingsOpen : false
    title: "Technicolor Settings"
    implicitWidth: 780
    implicitHeight: 660
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
    onVisibleChanged: {
        if (visible) {
            confFile.reload(); curWpFile.reload(); tuneFile.reload(); win.loadGlass(); win.loadHotkeys()
            if (shell && shell.settingsTab === 1) win.refreshWallpapers()
        } else { win.addOpen = false; win.endCapture() }
    }
    Connections {
        target: shell
        function onSettingsTabChanged() {
            if (shell.settingsTab === 4) confFile.reload()
            else if (shell.settingsTab === 3) win.loadGlass()
            else if (shell.settingsTab === 2) tuneFile.reload()
            else if (shell.settingsTab === 1) win.refreshWallpapers()
            else if (shell.settingsTab === 5) win.loadHotkeys()
            else if (shell.settingsTab === 6) govConfFile.reload()
            if (shell.settingsTab !== 5) win.endCapture()   // leaving Hotkeys cancels a pending rebind
        }
        // escape hatch from the capture submap (hyprland.conf) fired — clear UI
        function onRebindCancelled() { win.endCapture() }
    }

    // ── Installed apps (for the Apps > Add picker) ──
    property var installedApps: []
    Process {
        id: appListProc
        running: win.visible
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
                win.installedApps = out
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

    // ── local.conf (System tab) ──
    FileView {
        id: confFile
        path: win.homeDir + "/.config/hypr/local.conf"
        watchChanges: false
        onLoaded: confEdit.text = this.text()
        onLoadFailed: confEdit.text = ""
    }
    Process { id: confWriteProc }
    function saveConf() {
        var b64 = Qt.btoa(confEdit.text)
        confWriteProc.command = ["bash", "-c", "printf %s '" + b64 + "' | base64 -d > '" + confFile.path + "'"]
        confWriteProc.running = true
    }

    // ── default file manager (System tab GUI picker) ──
    property var fileManagers: []   // [{ id, name }] — apps that handle dirs AND are file managers
    property string defaultFM: ""   // current handler for inode/directory (e.g. org.kde.dolphin.desktop)
    Process {
        id: fmListProc
        running: win.visible
        command: ["bash", "-c",
            "for f in /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop; do [ -f \"$f\" ] || continue; " +
            "grep -qi inode/directory \"$f\" && grep -qiE '^Categories=.*FileManager' \"$f\" && { " +
            "n=$(grep -m1 '^Name=' \"$f\" | cut -d= -f2-); printf '%s|%s\\n' \"$(basename \"$f\")\" \"$n\"; }; done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = []; var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) { var p = lines[i].split("|"); if (p.length >= 2 && p[0]) out.push({ id: p[0], name: p[1] }) }
                win.fileManagers = out
            }
        }
    }
    Process {
        id: fmQueryProc
        running: win.visible
        command: ["xdg-mime", "query", "default", "inode/directory"]
        stdout: StdioCollector { onStreamFinished: win.defaultFM = this.text.trim() }
    }
    Process { id: fmSetProc }
    function setFM(id) {
        fmSetProc.command = ["bash", "-c", "xdg-mime default '" + id + "' inode/directory; xdg-mime default '" + id + "' x-directory/normal 2>/dev/null"]
        fmSetProc.running = true
        win.defaultFM = id
    }

    // ── Default terminal (System tab) ── sets Hyprland's $terminal (Super+Q, via
    // the gitignored terminal.conf) and KDE's TerminalApplication (Dolphin's
    // Open Terminal). Lists installed TerminalEmulator apps.
    property var terminals: []        // [{ name, cmd }]
    property string currentTerminal: "kitty"
    Process {
        id: termListProc
        running: win.visible
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
                win.terminals = out
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
        var b64 = Qt.btoa("$terminal = " + cmd + "\n")
        termSetProc.command = ["bash", "-c",
            "printf %s '" + b64 + "' | base64 -d > '" + win.homeDir + "/.config/hypr/terminal.conf'; " +
            "hyprctl reload >/dev/null 2>&1; " +
            "kwriteconfig6 --file kdeglobals --group General --key TerminalApplication '" + cmd + "' 2>/dev/null"]
        termSetProc.running = true
    }

    // ── Wallpaper auto-cycle timer (Wallpaper tab) ── source of truth =
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

    // ── Effects governor (Effects tab) ── effects-governor.conf, read by
    // effects-governor.sh. That script owns ALL compositor writes; this tab only
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
    // Status readout. Only polls while the Effects tab is actually open —
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
        running: win.visible && win.shell && win.shell.settingsTab === 6
        interval: 2000; repeat: true; triggeredOnStart: true
        onTriggered: if (!govStatusProc.running) govStatusProc.running = true
    }

    // ── Wallpaper switch transition (Wallpaper tab) ── transition.conf, read by
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

    // ── Hotkeys (Hotkeys tab) ── a read-only cheat sheet built live from
    // `hyprctl binds`, so it always matches the real active binds (including
    // anything added via local.conf). This config uses plain `bind` (no bindd
    // descriptions), so friendly labels are derived from the dispatcher + arg.
    property var keybinds: []
    property string hotkeySearch: ""
    readonly property var hotkeyCategories: ["Apps", "Windows", "Focus & layout", "Workspaces", "Wallpaper", "Screenshots", "Media", "System", "Other"]
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
        win.keybinds = out
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
    function isCapturing(row) {
        var c = win.capturingBind
        return c !== null && c.dispatcher === row.dispatcher && c.arg === row.arg
            && c.modmask === row.modmask && c.rawKey === row.rawKey
    }
    function isWarnRow(row) {
        var w = win.warnBind
        return w !== null && w.dispatcher === row.dispatcher && w.arg === row.arg
            && w.modmask === row.modmask && w.rawKey === row.rawKey
    }
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
        var cur = win.overrides.slice()
        var idx = win.findOverride(row.modmask, row.rawKey, row.dispatcher, row.arg)
        if (idx >= 0) { cur[idx].newMods = newMods; cur[idx].newKey = newKey }   // keep original def
        else cur.push({ mods: row.modmask, key: row.rawKey, dispatcher: row.dispatcher, arg: row.arg, newMods: newMods, newKey: newKey })
        win.overrides = cur
        win.persistOverrides()
    }
    function resetBind(row) {
        var idx = win.findOverride(row.modmask, row.rawKey, row.dispatcher, row.arg)
        if (idx < 0) return
        var cur = win.overrides.slice(); cur.splice(idx, 1)
        win.overrides = cur
        win.persistOverrides()
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

    // ── UI font (System tab) ── source of truth = ~/.config/hypr/font.conf.
    // Bar + this window read it live via shell.uiFont; wofi via gen-wofi-font.sh.
    property var installedFonts: []
    property string currentFont: ""
    property string fontSearch: ""
    property real fontListH: 220     // resizable via the drag-divider below the list
    property real confEditH: 240     // resizable local.conf editor
    readonly property string effFont: win.currentFont !== "" ? win.currentFont : (win.bar ? win.bar.fontFamily : "sans-serif")
    Process {
        id: fontListProc
        running: win.visible
        command: ["bash", "-c", "fc-list : family | sed 's/,.*//' | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var a = []
                var lines = this.text.split("\n")
                for (var i = 0; i < lines.length; i++) { var s = lines[i].trim(); if (s !== "") a.push(s) }
                win.installedFonts = a
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

    // ── Update (System tab) ── pull latest from GitHub + copy configs (tuning
    // files are gitignored, so they're preserved). Two-click confirm so it can't
    // wipe uncommitted work by accident.
    property string updateStatus: ""
    property bool updateArmed: false
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

    // ── Liked-songs tools (System tab) ── scan for AI music + CSV backup, run
    // through the live Spicetify session (spotify-liked.py). Read-only.
    property string likedStatus: ""
    property bool likedBusy: false
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

    // ── wallpapers folder (Wallpaper tab) — single source of truth in
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
    Timer { id: wpWatchDebounce; interval: 400; onTriggered: win.refreshWallpapers() }

    // ── Colors tab state ── single source of truth = ~/.config/hypr/color-tuning.conf
    // (CONTRAST_BIAS, SATURATION, BRIGHTNESS, HUE). The bar reads CONTRAST_BIAS live
    // via shell.qml; the other three transform the colors at the source
    // (wallpaper-colors.py) so they flow to every app via colors.env on regen.
    property real tuneContrast: 0.5      // 0 dark .. 0.5 default .. 1 light
    property real tuneSaturation: 1.0    // saturation ceiling: 0 grayscale .. 1 uncapped
    property real tuneBrightness: 1.0    // brightness ceiling: 0 black .. 1 uncapped
    property real tuneHue: 0.0           // -180..180 degrees, 0 = unchanged
    FileView {
        id: tuneFile
        path: win.homeDir + "/.config/hypr/color-tuning.conf"
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
    Process { id: tuneCommitProc }
    function commitTuning() {
        var body = "CONTRAST_BIAS=" + win.tuneContrast.toFixed(3)
                 + "\nSATURATION=" + win.tuneSaturation.toFixed(3)
                 + "\nBRIGHTNESS=" + win.tuneBrightness.toFixed(3)
                 + "\nHUE=" + win.tuneHue.toFixed(1) + "\n"
        var conf = win.homeDir + "/.config/hypr/color-tuning.conf"
        tuneCommitProc.command = ["bash", "-c",
            "printf %s '" + Qt.btoa(body) + "' | base64 -d > '" + conf + "'; " +
            "wp=\"$(cat /tmp/wallpaper-current-path 2>/dev/null)\"; " +
            "[ -n \"$wp\" ] && python3 \"$HOME/.config/hypr/wallpaper-colors.py\" \"$wp\"; " +
            "\"$HOME/.config/quickshell/notif-theme-mako.sh\""]
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
    function resetContrast()   { win.tuneContrast = 0.5; if (win.shell) win.shell.contrastBias = 0.5; win.commitTuning() }
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
        surfaceTuneRepeater.refresh++
    }
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
    // any existing *_SAT/_BRIGHT/_HUE surface lines, re-emits the current set.
    Process { id: surfaceCommitProc }
    function commitSurfaceTune() {
        var body = "\n# per-surface tuning (Settings → Colors → Per-surface)\n"
        for (var i = 0; i < win.surfaceSpecs.length; i++) {
            var key = win.surfaceSpecs[i].key
            var s = win.surfaceTune[key]; if (!s) continue
            var KEY = key.toUpperCase()
            if (Math.abs((s.sat===undefined?1:s.sat) - 1) > 1e-3)    body += KEY + "_SAT=" + s.sat.toFixed(3) + "\n"
            if (Math.abs((s.bright===undefined?1:s.bright) - 1) > 1e-3) body += KEY + "_BRIGHT=" + s.bright.toFixed(3) + "\n"
            if (Math.abs((s.hue===undefined?0:s.hue)) > 1e-3)        body += KEY + "_HUE=" + s.hue.toFixed(1) + "\n"
        }
        var conf = win.homeDir + "/.config/hypr/color-tuning.conf"
        // sed strips old surface lines (uppercase PREFIX_SAT/BRIGHT/HUE) but keeps
        // the global CONTRAST_BIAS/SATURATION/BRIGHTNESS/HUE; then append the new set.
        surfaceCommitProc.command = ["bash", "-c",
            "conf='" + conf + "'; " +
            "tmp=\"$(grep -vE '^(BAR|NOTIFICATIONS|GTK|DISCORD|SPOTIFY|BRAVE|KDE|TELEGRAM)_(SAT|BRIGHT|HUE)=' \"$conf\" 2>/dev/null)\"; " +
            "printf '%s\\n' \"$tmp\" > \"$conf\"; " +
            "printf %s '" + Qt.btoa(body) + "' | base64 -d >> \"$conf\"; " +
            "wp=\"$(cat /tmp/wallpaper-current-path 2>/dev/null)\"; " +
            "[ -n \"$wp\" ] && python3 \"$HOME/.config/hypr/wallpaper-colors.py\" \"$wp\"; " +
            "\"$HOME/.config/quickshell/notif-theme-mako.sh\""]
        surfaceCommitProc.running = true
    }
    function resetSurface(key) {
        var t = win.surfaceTune; t[key] = { sat: 1.0, bright: 1.0, hue: 0.0 }
        win.surfaceTune = t; surfaceTuneRepeater.refresh++
        win.commitSurfaceTune()
    }
    FileView {
        id: surfaceTuneFile
        path: win.homeDir + "/.config/hypr/color-tuning.conf"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: win.parseSurfaceTune(this.text())
        onLoadFailed: win.surfaceTune = ({})
    }

    // ── Glass tab (hyprwater) ── live via hyprwater-set.sh (hyprctl eval under
    // the Lua config), persisted to hyprwater-tuning.conf. Each spec: key/label/
    // range/default. Anything beyond a slider's range goes through the write-in.
    readonly property var glassSpecs: [
        { key: "refraction_strength",  label: "Refraction",          from: 0, to: 3,  def: 1.0,  step: 0 },
        { key: "fresnel_strength",     label: "Fresnel (edge glow)",  from: 0, to: 1,  def: 0.3,  step: 0 },
        { key: "specular_strength",    label: "Specular (highlight)", from: 0, to: 1,  def: 0.3,  step: 0 },
        { key: "lens_distortion",      label: "Lens distortion",      from: 0, to: 1,  def: 0.1,  step: 0 },
        { key: "edge_thickness",       label: "Edge thickness",       from: 0, to: 1,  def: 0.2,  step: 0 },
        { key: "chromatic_aberration", label: "Chromatic aberration", from: 0, to: 1,  def: 0.0,  step: 0 },
        { key: "blur_strength",        label: "Blur strength",        from: 0, to: 2,  def: 0.2,  step: 0 },
        { key: "blur_iterations",      label: "Blur iterations",      from: 0, to: 4,  def: 1.0,  step: 1 },
        { key: "brightness",           label: "Brightness",           from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "contrast",             label: "Contrast",             from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "saturation",           label: "Saturation",           from: 0, to: 2,  def: 1.0,  step: 0 },
        { key: "vibrancy",             label: "Vibrancy",             from: 0, to: 2,  def: 1.0,  step: 0 }
    ]
    // Water shimmer knobs. These ride the SAME path as the Glass tab: glassLive()
    // applies instantly via hyprctl eval, glassSet() persists to
    // hyprwater-tuning.conf. Nothing new to plumb.
    readonly property var shimmerSpecs: [
        { key: "shimmer:intensity",     label: "Brightness",  hint: "How strongly the caustics show. 0 hides them without stopping the simulation.",           from: 0, to: 3,  def: 0.8,  step: 0 },
        { key: "shimmer:refraction",    label: "Warping",      hint: "How much the water bends what is behind it. This is what makes it read as looking THROUGH water rather than at lines drawn on glass \u2014 your wallpaper, or whatever window is underneath, visibly swims. 0 leaves the backdrop undistorted and only the bright veins move.", from: 0, to: 4, def: 1.0, step: 0 },
        { key: "shimmer:depth",         label: "Water depth",  hint: "Distance from the surface to the floor, with 1.0 as the nominal pool. It is the one physical length here, so it sets BOTH how far the bent light travels sideways before it lands \u2014 how much the window behind is displaced \u2014 and how hard it converges on the way, which is what thins the bright lines. Deep bends and focuses together; shallow leaves the image nearly straight and the light a soft wash.", from: 0.25, to: 3, def: 1.0, step: 0 },
        { key: "shimmer:scale",         label: "Wave size",    hint: "Size of the waves, and so of the cells between the bright lines. Larger waves also means fewer of them across a window.", from: 0.2, to: 3, def: 1.0, step: 0 },
        { key: "shimmer:speed",         label: "Speed",        hint: "How fast the water runs. Logarithmic, so most of the travel is spent down in the barely-moving range. Slow stays smooth: below 1x each step advances the physics less rather than stepping less often.", from: 0.002, to: 3, def: 1.0, step: 0, log: true },
        { key: "shimmer:agitation",     label: "Activity",     hint: "How busy the water is \u2014 how often something disturbs it, and how hard. Far left is a still pool crossed by a stray ripple every several seconds; far right is a crowded one. The scale is geometric, so the calm end has as much travel as the busy end.", from: 0, to: 1,  def: 0.5,  step: 0 },
        { key: "shimmer:viscosity",     label: "Viscosity",    hint: "How thick the water is. Thick water eats short waves within moments of them appearing, so only long smooth rollers survive and the surface stays glassy between them; thin water lets fine structure persist once it is there and keeps a busy chop. Disturbances are sized to match, so each end is fed the scale it will keep. It also sets the fastest stable wave speed \u2014 the two share one budget \u2014 so thick water propagates more slowly.", from: 0, to: 1,  def: 0.6,  step: 0 },
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
    Process { id: glassSetProc }
    function glassSet(key, val) {
        glassSetProc.command = ["bash", "-c", "\"$HOME/.config/hypr/hyprwater-set.sh\" '" + key + "' '" + val + "'"]
        glassSetProc.running = true
    }
    function glassValue(spec) {
        var v = win.glassValues[spec.key]
        return (v === undefined) ? spec.def : v
    }

    // Reusable slider: track + fill + draggable knob. moved() fires live while
    // dragging, committed() on release.
    // Vertical Flickable with smooth, accelerated mouse-wheel scrolling. A bare
    // Built-in scrollable container. ScrollView handles the mouse wheel (both
    // directions), touch and the scrollbar natively — no custom handler. contentWidth
    // is pinned to availableWidth so it only scrolls vertically; each usage supplies
    // contentHeight + a single Column child (whose width binds to parent.width).
    component SmoothList: ScrollView {
        id: sfl
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AsNeeded
        ScrollBar.vertical.background: null      // remove the default track/groove
        ScrollBar.vertical.contentItem: Rectangle {
            implicitWidth: 5; radius: 3
            color: win.fg
            opacity: sfl.ScrollBar.vertical.pressed ? 0.6 : (sfl.ScrollBar.vertical.hovered ? 0.42 : 0.26)
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }
    }

    // A grabbable horizontal splitter. Drag it to resize the section above: it
    // emits the vertical drag delta; the owner adds it to that section's height
    // property (clamped). Uses global Y so the delta is right even as it moves.
    component DragDivider: Item {
        id: dd
        signal dragged(real dy)
        width: parent ? parent.width : 100
        height: 14
        Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.16) }
        Rectangle { anchors.centerIn: parent; width: 34; height: 4; radius: 2
            color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, (ddM.containsMouse || ddM.pressed) ? 0.55 : 0.30) }
        MouseArea {
            id: ddM; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.SizeVerCursor
            property real lastY: 0
            onPressed: (m) => ddM.lastY = dd.mapToGlobal(m.x, m.y).y
            onPositionChanged: (m) => {
                if (!pressed) return
                var gy = dd.mapToGlobal(m.x, m.y).y
                dd.dragged(gy - ddM.lastY); ddM.lastY = gy
            }
        }
    }

    component TcSlider: Item {
        id: sl
        property real from: 0
        property real to: 1
        property real value: 0.5
        signal moved(real v)
        signal committed(real v)
        implicitHeight: 26
        Rectangle {
            id: trk
            anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.right: parent.right
            height: 6; radius: 3; color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.18)
            Rectangle {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                height: parent.height; radius: 3; color: win.fg; opacity: 0.55
                width: parent.width * (sl.value - sl.from) / (sl.to - sl.from)
            }
        }
        Rectangle {
            width: 18; height: 18; radius: 9; color: win.fg
            anchors.verticalCenter: parent.verticalCenter
            x: (sl.width - width) * Math.max(0, Math.min(1, (sl.value - sl.from) / (sl.to - sl.from)))
        }
        MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            // Emit the computed value; the OWNER updates the bound property (which
            // feeds sl.value back) — never assign sl.value here, or the binding breaks.
            function emit(mx) { sl.moved(sl.from + Math.max(0, Math.min(1, mx / sl.width)) * (sl.to - sl.from)) }
            onPressed: (m) => emit(m.x)
            onPositionChanged: (m) => { if (pressed) emit(m.x) }
            onReleased: sl.committed(sl.value)
        }
    }

    // A pill switch. Owner binds `on` and updates it in onToggled (don't self-assign).
    component TcToggle: Rectangle {
        id: tg
        property bool on: false
        signal toggled(bool v)
        width: 46; height: 26; radius: 13
        color: tg.on ? win.fg : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.18)
        Behavior on color { ColorAnimation { duration: 130 } }
        Rectangle {
            width: 20; height: 20; radius: 10
            anchors.verticalCenter: parent.verticalCenter
            x: tg.on ? parent.width - width - 3 : 3
            color: tg.on ? win.blockColor : win.fg
            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
        }
        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: tg.toggled(!tg.on) }
    }

    // ── content: solid rounded blocks, live liquid glass in the gaps ──
    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.close()

        Column {
            anchors.fill: parent
            anchors.margins: 14      // outer glass margin
            spacing: 12              // glass gap between blocks

            // ── header: top-left title pill. No close X — this is a keyboard-driven
            // WM, so dismiss with Esc (Keys.onEscapePressed) or re-toggle the opener. ──
            Item {
                width: parent.width; height: 48
                Rectangle {   // title pill
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    height: 44; radius: 22; color: win.blockColor
                    width: titleTxt.implicitWidth + 40
                    Text { id: titleTxt; anchors.centerIn: parent; text: "Settings"; color: win.fg; font.pixelSize: 18; font.bold: true; font.family: win.ff }
                }
            }

            // ── tab block ──
            Rectangle {
                width: parent.width; height: 52; radius: 16; color: win.blockColor
                Row {
                    id: tabBar
                    anchors.fill: parent; anchors.margins: 6; spacing: 6
                    // Effects is APPENDED, not slotted next to Glass: every tab
                    // body is keyed by index (settingsTab === N), so inserting in
                    // the middle would silently repoint five existing tabs.
                    property var tabs: ["Apps", "Wallpaper", "Colors", "Glass", "System", "Hotkeys", "Effects"]
                    Repeater {
                        model: tabBar.tabs
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            width: (tabBar.width - tabBar.spacing * (tabBar.tabs.length - 1)) / tabBar.tabs.length
                            height: parent.height; radius: 11
                            color: (win.shell && win.shell.settingsTab === index) ? win.rowHover : (tabM.containsMouse ? win.rowBg : "transparent")
                            Text { anchors.centerIn: parent; text: modelData; color: win.fg; font.pixelSize: 13; font.family: win.ff; font.bold: win.shell && win.shell.settingsTab === index }
                            MouseArea { id: tabM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (win.shell) win.shell.settingsTab = index }
                        }
                    }
                }
            }

            // ── body block ──
            Rectangle {
                width: parent.width
                height: parent.height - 48 - 52 - 12 * 2
                radius: 16; color: win.blockColor; clip: true

                Item {
                    anchors.fill: parent
                    anchors.margins: 16

                // ===== Apps tab =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 0
                    Column {
                        anchors.fill: parent; spacing: 10
                        Item {
                            width: parent.width; height: 30
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Pinned apps"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Rectangle {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 92; height: 28; radius: 8
                                color: addM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "＋ Add app"; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                MouseArea { id: addM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.addOpen = true }
                            }
                        }
                        SmoothList {
                            width: parent.width; height: parent.height - 40
                            clip: true; contentHeight: pinCol.height
                            Column {
                                id: pinCol; width: parent.width; spacing: 6
                                Repeater {
                                    model: win.bar ? win.bar.allAppPins : []
                                    delegate: Rectangle {
                                        required property int index
                                        required property var modelData
                                        width: pinCol.width; height: 44; radius: 9; color: win.rowBg
                                        Row {
                                            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                            Image {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 26; height: 26; sourceSize.width: 64; sourceSize.height: 64; smooth: true
                                                source: modelData.imgPath && modelData.imgPath !== "" ? modelData.imgPath
                                                        : (win.bar ? win.bar.resolveAppIcon(modelData.icon, "") : "")
                                            }
                                            // editable launch command — click to fix things like
                                            // Kate's ".desktop"-derived "kate -b" down to just "kate".
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.parent.width - 220; height: 26; radius: 6
                                                color: cmdIn.activeFocus ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.10) : "transparent"
                                                TextInput {
                                                    id: cmdIn
                                                    anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    text: modelData.cmd; color: win.fg; font.pixelSize: 12; font.family: win.ff
                                                    clip: true; selectByMouse: true
                                                    onEditingFinished: { if (win.bar && text !== modelData.cmd) win.bar.setPinCmd(index, text) }
                                                }
                                            }
                                        }
                                        Row {
                                            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 4
                                            Rectangle { width: 28; height: 28; radius: 6; color: upM.containsMouse ? win.rowHover : "transparent"
                                                Text { anchors.centerIn: parent; text: "▲"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                                MouseArea { id: upM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (win.bar) win.bar.movePin(index, -1) } }
                                            Rectangle { width: 28; height: 28; radius: 6; color: dnM.containsMouse ? win.rowHover : "transparent"
                                                Text { anchors.centerIn: parent; text: "▼"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                                MouseArea { id: dnM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (win.bar) win.bar.movePin(index, 1) } }
                                            Rectangle { width: 28; height: 28; radius: 6; color: imgM.containsMouse ? win.rowHover : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF03E); color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                                MouseArea { id: imgM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.pickImage(index) } }
                                            Rectangle { width: 28; height: 28; radius: 6; color: rmM.containsMouse ? Qt.rgba(0.9,0.3,0.3,0.35) : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF00D); color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                                MouseArea { id: rmM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (win.bar) win.bar.removePinAt(index) } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ===== Wallpaper tab =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 1
                    SmoothList {
                        anchors.fill: parent; clip: true; contentHeight: wpCol.height
                        Column {
                            id: wpCol; width: parent.width; spacing: 10

                        // ── Wallpapers folder: current path + Change… ──
                        Rectangle {
                            width: parent.width; height: 54; radius: 9; color: win.rowBg
                            Column {
                                anchors.left: parent.left; anchors.leftMargin: 12
                                anchors.right: chgBtn.left; anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                Text { text: "Wallpapers folder"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                Text { width: parent.width; text: win.wallpaperDir; color: win.fg; opacity: 0.7; font.pixelSize: 11; font.family: win.ff; elide: Text.ElideMiddle }
                            }
                            Rectangle {
                                id: chgBtn
                                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                width: 92; height: 30; radius: 8
                                color: chgM.containsMouse ? win.rowHover : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.16)
                                Text { anchors.centerIn: parent; text: "Change…"; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                MouseArea { id: chgM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.pickWallpaperDir() }
                            }
                        }

                        // ── cover flow ──
                        Rectangle {
                            width: parent.width; height: 300; radius: 12
                            color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.06)
                            clip: true

                            PathView {
                                id: coverflow
                                anchors.fill: parent
                                model: win.wallpaperList
                                pathItemCount: 9
                                cacheItemCount: 6
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
                                    for (var i = 0; i < win.wallpaperList.length; i++)
                                        if (win.wallpaperList[i].src === win.currentWallpaper) { currentIndex = i; return }
                                }
                                Connections {
                                    target: win
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
                                        border.color: win.fg
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
                                            if (coverflow.currentIndex === dg.index) win.applyWallpaper(dg.modelData.src)
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
                                    visible: win.wallpaperList.length > 1
                                    color: navM.containsMouse ? win.rowHover : Qt.rgba(0, 0, 0, 0.35)
                                    Text { anchors.centerIn: parent; text: String.fromCodePoint(modelData.glyph); color: "#ffffff"; font.pixelSize: 16; font.family: win.ff }
                                    MouseArea { id: navM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: modelData.left ? coverflow.decrementCurrentIndex() : coverflow.incrementCurrentIndex() }
                                }
                            }

                            // empty / loading state
                            Text {
                                anchors.centerIn: parent
                                visible: win.wallpaperList.length === 0
                                text: wpThumbsProc.running ? "Preparing previews…" : "No wallpapers in this folder"
                                color: win.fg; opacity: 0.6; font.pixelSize: 13; font.family: win.ff
                            }
                        }

                        // ── shuffle + open-folder (cycle/random merged: rotation is random) ──
                        Row {
                            width: parent.width; height: 40; spacing: 8
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 40; radius: 9
                                color: shufM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF074) + "  Shuffle wallpaper"; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                MouseArea { id: shufM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["sh", "-c", "~/.config/hypr/wallpaper-cycle.sh random"]) }
                            }
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 40; radius: 9
                                color: openM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF07C) + "  Open folder"; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                MouseArea { id: openM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["sh", "-c", "~/.config/hypr/open-folder.sh '" + win.wallpaperDir + "'"]) }
                            }
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: "Scroll to browse · click a cover to center it · click the centered one to set it." }

                        // ── switch transition ──
                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }
                        Text { text: "Transition"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Flow {
                            width: parent.width; spacing: 6
                            Repeater {
                                model: win.transitions
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: win.transitionMode === modelData.id
                                    height: 30; radius: 8; width: trLbl.implicitWidth + 24
                                    color: sel ? win.rowHover : win.rowBg
                                    border.width: sel ? 2 : 0; border.color: win.fg
                                    Text { id: trLbl; anchors.centerIn: parent; text: modelData.name; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.setTransition(modelData.id) }
                                }
                            }
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: {
                                for (var i = 0; i < win.transitions.length; i++)
                                    if (win.transitions[i].id === win.transitionMode) return "Applies on the next wallpaper change — " + win.transitions[i].desc + "."
                                return ""
                            }
                        }

                        // ── transition renderer (GPU overlay vs CPU compositor) ──
                        Row {
                            spacing: 6
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Renders on"; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                            Repeater {
                                model: [ { id: "gpu", name: "GPU" }, { id: "cpu", name: "CPU" } ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: win.transitionRender === modelData.id
                                    height: 30; radius: 8; width: rdLbl.implicitWidth + 24
                                    color: sel ? win.rowHover : win.rowBg
                                    border.width: sel ? 2 : 0; border.color: win.fg
                                    Text { id: rdLbl; anchors.centerIn: parent; text: modelData.name; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.setTransitionRender(modelData.id) }
                                }
                            }
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: win.transitionRender === "cpu"
                                ? "Classic frame compositor — keeps the graphics card free (pick this if your games are GPU-bound)."
                                : "Overlay reveal — both wallpapers keep animating, work happens on the graphics card (pick this if your games are CPU-bound). Video wallpapers always use the CPU path."
                        }

                        // ── auto-cycle timer ──
                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }
                        Text { text: "Auto-cycle"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }

                        // interval (dimmed while paused — it has no effect then)
                        Column {
                            width: parent.width; spacing: 8
                            opacity: win.cyclePaused ? 0.45 : 1.0
                            Row {
                                width: parent.width
                                Text { width: parent.width - ivVal.implicitWidth; text: "Change wallpaper every"
                                       color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                Text { id: ivVal; text: win.cycleInterval + (win.cycleInterval === 1 ? " minute" : " minutes")
                                       color: win.fg; opacity: 0.7; font.pixelSize: 12; font.bold: true; font.family: win.ff }
                            }
                            TcSlider {
                                width: parent.width
                                from: 1; to: 120; value: win.cycleInterval
                                onMoved: (v) => win.cycleInterval = Math.round(v)
                                onCommitted: (v) => win.writeTimerConf()
                            }
                        }

                        // pause toggle
                        Rectangle {
                            width: parent.width; height: Math.max(50, pauseCol.implicitHeight + 18); radius: 9; color: win.rowBg
                            Column {
                                id: pauseCol
                                anchors.left: parent.left; anchors.leftMargin: 12
                                anchors.right: pauseTg.left; anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                Text { text: "Pause auto-cycle"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                       text: "Stop rotating wallpapers entirely until you switch this back off." }
                            }
                            TcToggle {
                                id: pauseTg
                                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                on: win.cyclePaused
                                onToggled: (v) => { win.cyclePaused = v; win.writeTimerConf() }
                            }
                        }

                        // pause while a fullscreen app is open
                        Rectangle {
                            width: parent.width; height: Math.max(50, fsCol.implicitHeight + 18); radius: 9; color: win.rowBg
                            Column {
                                id: fsCol
                                anchors.left: parent.left; anchors.leftMargin: 12
                                anchors.right: fsTg.left; anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                Text { text: "Pause during fullscreen apps"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                       text: "Hold off while a game or fullscreen video is open — no transition stutter or CPU spike mid-game. Cycles as soon as you exit." }
                            }
                            TcToggle {
                                id: fsTg
                                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                on: win.cyclePauseFs
                                onToggled: (v) => { win.cyclePauseFs = v; win.writeTimerConf() }
                            }
                        }
                        }
                    }
                }

                // ===== Colors tab =====
                Item {
                    id: colorsTab
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 2
                    property var palette: win.bar
                        ? [win.bar.gradientStart, win.bar.gradientEnd, win.bar.colorFocused, win.bar.colorVisible, win.bar.colorOccupied]
                        : []
                    SmoothList {
                        anchors.fill: parent; clip: true; contentHeight: colorsCol.height
                        Column {
                            id: colorsCol; width: parent.width; spacing: 12

                        // ── live preview swatches ──
                        Row {
                            width: parent.width; height: 56; spacing: 8
                            Repeater {
                                model: colorsTab.palette
                                delegate: Rectangle {
                                    required property var modelData
                                    width: (parent.width - 8 * 4) / 5; height: 56; radius: 10
                                    color: win.previewColor(modelData, win.tuneSaturation, win.tuneBrightness, win.tuneHue)
                                    Text { anchors.centerIn: parent; text: "Ag"; font.pixelSize: 18; font.bold: true; font.family: win.ff
                                        color: win.previewInk(win.previewColor(modelData, win.tuneSaturation, win.tuneBrightness, win.tuneHue), win.tuneContrast) }
                                }
                            }
                        }

                        // ── text contrast ──
                        Item {
                            width: parent.width; height: 22
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Text contrast"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { anchors.right: rstC.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: win.tuneContrast < 0.46 ? "darker text" : (win.tuneContrast > 0.54 ? "lighter text" : "auto")
                                color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                            Rectangle {
                                id: rstC; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 54; height: 22; radius: 7; color: rstCm.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                MouseArea { id: rstCm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.resetContrast() }
                            }
                        }
                        TcSlider {
                            id: contrastSlider; width: parent.width; from: 0; to: 1; value: win.tuneContrast
                            onMoved: (v) => { win.tuneContrast = v; if (win.shell) win.shell.contrastBias = v }
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "Where text flips light↔dark over the colors. Full left = always dark text, full right = always light. Applies to every app." }

                        // ── color saturation ──
                        Item {
                            width: parent.width; height: 22
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Color saturation"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { anchors.right: rstS.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: Math.round(win.tuneSaturation * 100) + "%"
                                color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                            Rectangle {
                                id: rstS; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 54; height: 22; radius: 7; color: rstSm.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                MouseArea { id: rstSm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.resetSaturation() }
                            }
                        }
                        TcSlider {
                            id: satSlider; width: parent.width; from: 0; to: 1; value: win.tuneSaturation
                            onMoved: (v) => win.tuneSaturation = v
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "A ceiling on saturation. Full right = the wallpaper's own colors, untouched; lower it to rein in over-saturated wallpapers (already-muted ones aren't affected). Applies everywhere — bar, Discord, Spotify, Brave, Dolphin, GTK, notifications." }

                        // ── brightness ──
                        Item {
                            width: parent.width; height: 22
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Brightness"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { anchors.right: rstB.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: Math.round(win.tuneBrightness * 100) + "%"; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                            Rectangle {
                                id: rstB; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 54; height: 22; radius: 7; color: rstBm.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                MouseArea { id: rstBm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.resetBrightness() }
                            }
                        }
                        TcSlider {
                            width: parent.width; from: 0; to: 1; value: win.tuneBrightness
                            onMoved: (v) => win.tuneBrightness = v
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "A ceiling on brightness. Full right = the wallpaper's own colors; lower it to tone down very bright wallpapers (dark ones aren't affected). Pair with Text contrast for readability." }

                        // ── hue shift (the artsy / off-palette knob) ──
                        Item {
                            width: parent.width; height: 22
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Hue shift"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { anchors.right: rstH.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: (win.tuneHue > 0 ? "+" : "") + Math.round(win.tuneHue) + "°"; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                            Rectangle {
                                id: rstH; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 54; height: 22; radius: 7; color: rstHm.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                MouseArea { id: rstHm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.resetHue() }
                            }
                        }
                        TcSlider {
                            width: parent.width; from: -180; to: 180; value: win.tuneHue
                            onMoved: (v) => win.tuneHue = v
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "Rotate every color around the wheel. 0 keeps the wallpaper's real colors; nudge it for a deliberately off-palette / artsy tint (yes, it changes the whole vibe)." }

                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }

                        // ── Per-surface tuning ──
                        Text { text: "Per-surface tuning"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "Fine-tune one surface at a time, on top of the global knobs above. Saturation/Brightness are ceilings, exactly like the global sliders — full right (100%) leaves that surface as-is; lowering reins it in, but a wallpaper that's already dark/muted barely moves. They only tame a surface below the global level, never boost it. Hue rotates. Click a surface to expand." }

                        Repeater {
                            id: surfaceTuneRepeater
                            property int refresh: 0   // bump to force value re-read after mutation
                            model: win.surfaceSpecs
                            Rectangle {
                                width: parent.width
                                radius: 12; color: win.rowBg
                                height: col.height + 20
                                property bool expanded: false
                                property string skey: modelData.key
                                // touch refresh so the header summary updates after edits
                                property int _r: surfaceTuneRepeater.refresh
                                Column {
                                    id: col
                                    x: 12; y: 10; width: parent.width - 24; spacing: 8
                                    // header row (click to expand)
                                    Item {
                                        width: parent.width; height: 26
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                            text: (expanded ? "▾  " : "▸  ") + modelData.label
                                            color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            visible: !expanded
                                            // compact summary, dim when at defaults
                                            text: {
                                                var s = win.surfaceVal(skey,"sat",1.0), b = win.surfaceVal(skey,"bright",1.0), h = win.surfaceVal(skey,"hue",0.0)
                                                if (Math.abs(s-1)<0.005 && Math.abs(b-1)<0.005 && Math.abs(h)<0.5) return "default"
                                                return Math.round(s*100)+"% · "+Math.round(b*100)+"% · "+(h>0?"+":"")+Math.round(h)+"°"
                                            }
                                            color: win.fg
                                            opacity: (Math.abs(win.surfaceVal(skey,"sat",1.0)-1)<0.005 && Math.abs(win.surfaceVal(skey,"bright",1.0)-1)<0.005 && Math.abs(win.surfaceVal(skey,"hue",0.0))<0.5) ? 0.4 : 0.7
                                            font.pixelSize: 11; font.family: win.ff }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: expanded = !expanded }
                                    }
                                    // expanded body: 3 sliders + reset
                                    Column {
                                        width: parent.width; spacing: 6
                                        visible: expanded
                                        // Saturation
                                        Item { width: parent.width; height: 18
                                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Saturation"; color: win.fg; opacity: 0.85; font.pixelSize: 12; font.family: win.ff }
                                            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: Math.round(win.surfaceVal(skey,"sat",1.0)*100)+"%"; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff } }
                                        TcSlider { width: parent.width; from: 0; to: 1; value: win.surfaceVal(skey,"sat",1.0)
                                            onMoved: (v) => win.setSurfaceVal(skey,"sat",v); onCommitted: (v) => win.commitSurfaceTune() }
                                        // Brightness
                                        Item { width: parent.width; height: 18
                                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Brightness"; color: win.fg; opacity: 0.85; font.pixelSize: 12; font.family: win.ff }
                                            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: Math.round(win.surfaceVal(skey,"bright",1.0)*100)+"%"; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff } }
                                        TcSlider { width: parent.width; from: 0; to: 1; value: win.surfaceVal(skey,"bright",1.0)
                                            onMoved: (v) => win.setSurfaceVal(skey,"bright",v); onCommitted: (v) => win.commitSurfaceTune() }
                                        // Hue
                                        Item { width: parent.width; height: 18
                                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Hue shift"; color: win.fg; opacity: 0.85; font.pixelSize: 12; font.family: win.ff }
                                            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: (win.surfaceVal(skey,"hue",0.0)>0?"+":"")+Math.round(win.surfaceVal(skey,"hue",0.0))+"°"; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff } }
                                        TcSlider { width: parent.width; from: -180; to: 180; value: win.surfaceVal(skey,"hue",0.0)
                                            onMoved: (v) => win.setSurfaceVal(skey,"hue",v); onCommitted: (v) => win.commitSurfaceTune() }
                                        Rectangle { width: 60; height: 22; radius: 7; color: rsm.containsMouse ? win.rowHover : win.blockColor
                                            Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 11; font.family: win.ff }
                                            MouseArea { id: rsm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.resetSurface(skey) } }
                                    }
                                }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }

                        // ── Discord (Vesktop) ──
                        Text { text: "Discord (Vesktop)"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.75; font.pixelSize: 12; font.family: win.ff
                            text: "In Vesktop → Settings → Themes, enable \"Technicolor\", then \"Technicolor Blocks\" (in that order). Colors then follow your wallpaper live." }
                        }
                    }
                }

                // ===== Glass tab (hyprwater) =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 3
                    SmoothList {
                        anchors.fill: parent; clip: true; contentHeight: glassCol.height
                        Column {
                            id: glassCol
                            width: parent.width; spacing: 10

                            Text { text: "Liquid glass (hyprwater)"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                                text: "Live tuning of the glass effect on every window — applies instantly and persists. For values past a slider's range, or other options, use the write-in below." }

                            Repeater {
                                model: win.glassSpecs
                                delegate: Item {
                                    id: gRow
                                    required property var modelData
                                    width: glassCol.width; height: 50
                                    property real val: modelData.def
                                    Connections { target: win; function onGlassValuesChanged() { gRow.val = win.glassValue(gRow.modelData) } }
                                    Item {
                                        width: parent.width; height: 20
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: gRow.modelData.label; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                        Text { anchors.right: gReset.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                            text: gRow.modelData.step === 1 ? Math.round(gRow.val).toString() : gRow.val.toFixed(2)
                                            color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                                        Rectangle { id: gReset; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            width: 48; height: 20; radius: 6; color: gRm.containsMouse ? win.rowHover : win.rowBg
                                            Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 10; font.family: win.ff }
                                            MouseArea { id: gRm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { gRow.val = gRow.modelData.def; win.glassSet(gRow.modelData.key, gRow.modelData.def) } }
                                        }
                                    }
                                    TcSlider {
                                        width: parent.width; y: 24
                                        from: gRow.modelData.from; to: gRow.modelData.to; value: gRow.val
                                        onMoved: (v) => { var vv = gRow.modelData.step === 1 ? Math.round(v) : v; gRow.val = vv; win.glassLive(gRow.modelData.key, vv) }
                                        onCommitted: (v) => win.glassSet(gRow.modelData.key, gRow.modelData.step === 1 ? Math.round(gRow.val) : gRow.val)
                                    }
                                }
                            }

                            Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }

                            // write-in: any key + value (out-of-range, or options without a slider)
                            Text { text: "Advanced — set any value"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                                text: "Type: key value  (e.g. refraction_strength 2.5  ·  tint_color 0x20000000  ·  dark:brightness 0.9). Applies + persists." }
                            Row {
                                width: parent.width; height: 34; spacing: 8
                                Rectangle {
                                    width: parent.width - 86; height: 34; radius: 8; color: win.rowBg
                                    TextInput { id: glassWrite; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                        verticalAlignment: TextInput.AlignVCenter; color: win.fg; font.pixelSize: 12; font.family: "monospace"; clip: true
                                        onAccepted: gApply.go() }
                                    Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                        visible: glassWrite.text === ""; text: "key value"; color: win.fg; opacity: 0.4; font.pixelSize: 12; font.family: "monospace" }
                                }
                                Rectangle { id: gApply; width: 78; height: 34; radius: 8; color: gApplyM.containsMouse ? win.rowHover : win.rowBg
                                    function go() {
                                        var t = glassWrite.text.trim(); var sp = t.indexOf(" ")
                                        if (sp > 0) { win.glassSet(t.substring(0, sp).trim(), t.substring(sp + 1).trim()); glassWrite.text = ""; win.loadGlass() }
                                    }
                                    Text { anchors.centerIn: parent; text: "Apply"; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                    MouseArea { id: gApplyM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: gApply.go() }
                                }
                            }
                        }
                    }
                }

                // ===== System tab (local.conf) =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 4
                    SmoothList {
                        anchors.fill: parent; clip: true; contentHeight: sysCol.height
                        Column {
                            id: sysCol; width: parent.width; spacing: 10

                        // ── UI font (bar + this window live; wofi via gen-wofi-font.sh) ──
                        Item {
                            width: parent.width; height: 22
                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Font"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: win.effFont; color: win.fg; opacity: 0.7; font.pixelSize: 12; font.family: win.ff }
                        }
                        Rectangle {
                            width: parent.width; height: 30; radius: 8; color: win.rowBg
                            TextInput { id: fontSearchIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter; color: win.fg; font.pixelSize: 12; font.family: win.ff; clip: true
                                onTextChanged: win.fontSearch = text }
                            Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                visible: fontSearchIn.text === ""; text: "Search fonts…"; color: win.fg; opacity: 0.45; font.pixelSize: 12; font.family: win.ff }
                        }
                        SmoothList {
                            width: parent.width; height: win.fontListH; clip: true; contentHeight: fontCol.height
                            Column {
                                id: fontCol; width: parent.width; spacing: 2
                                Repeater {
                                    model: {
                                        var q = win.fontSearch.toLowerCase()
                                        if (q === "") return win.installedFonts
                                        var r = []
                                        for (var i = 0; i < win.installedFonts.length; i++)
                                            if (win.installedFonts[i].toLowerCase().indexOf(q) >= 0) r.push(win.installedFonts[i])
                                        return r
                                    }
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: fontCol.width; height: 28; radius: 7
                                        color: win.effFont === modelData ? win.rowHover : (fRowM.containsMouse ? win.rowBg : "transparent")
                                        Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                            text: modelData; color: win.fg; font.pixelSize: 13; font.family: modelData }   // previewed in its own font
                                        MouseArea { id: fRowM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.setFont(modelData) }
                                    }
                                }
                            }
                        }
                        DragDivider { width: parent.width; onDragged: (dy) => win.fontListH = Math.max(90, Math.min(520, win.fontListH + dy)) }

                        // ── Default file manager (GUI picker) ──
                        Text { text: "Default file manager"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Flow {
                            width: parent.width; spacing: 6
                            Repeater {
                                model: win.fileManagers
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: win.defaultFM === modelData.id
                                    height: 30; radius: 8; width: fmLabel.implicitWidth + 24
                                    color: sel ? win.rowHover : win.rowBg
                                    border.width: sel ? 2 : 0; border.color: win.fg
                                    Text { id: fmLabel; anchors.centerIn: parent; text: modelData.name; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.setFM(modelData.id) }
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }

                        // ── Default terminal (Super+Q + Dolphin's Open Terminal) ──
                        Text { text: "Default terminal"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Flow {
                            width: parent.width; spacing: 6
                            Repeater {
                                model: win.terminals
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: win.currentTerminal === modelData.cmd
                                    height: 30; radius: 8; width: tLabel.implicitWidth + 24
                                    color: sel ? win.rowHover : win.rowBg
                                    border.width: sel ? 2 : 0; border.color: win.fg
                                    Text { id: tLabel; anchors.centerIn: parent; text: modelData.name; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.setTerminal(modelData.cmd) }
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }

                        // ── local.conf (advanced) ──
                        Text { width: parent.width; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff; wrapMode: Text.WordWrap
                            text: "Advanced — ~/.config/hypr/local.conf (GPU, input, monitors). Save then Apply." }
                        Rectangle {
                            width: parent.width; height: win.confEditH; radius: 9; color: win.rowBg
                            Flickable {
                                anchors.fill: parent; anchors.margins: 8; clip: true
                                contentWidth: width; contentHeight: confEdit.paintedHeight
                                TextEdit {
                                    id: confEdit
                                    width: parent.width
                                    color: win.fg; font.pixelSize: 12; font.family: "monospace"
                                    selectByMouse: true; wrapMode: TextEdit.NoWrap
                                    textFormat: TextEdit.PlainText
                                }
                            }
                        }
                        DragDivider { width: parent.width; onDragged: (dy) => win.confEditH = Math.max(100, Math.min(560, win.confEditH + dy)) }
                        Row {
                            width: parent.width; height: 34; spacing: 8
                            Rectangle { width: (parent.width - 8) / 2; height: 34; radius: 8; color: saveM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Save"; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                MouseArea { id: saveM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.saveConf() } }
                            Rectangle { width: (parent.width - 8) / 2; height: 34; radius: 8; color: applyM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: "Save & Apply (reload Hyprland)"; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                MouseArea { id: applyM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { win.saveConf(); Quickshell.execDetached(["hyprctl", "reload"]) } } }
                        }

                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }
                        // ── Liked Songs tools (Spotify, via your Spicetify session) ──
                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }
                        Text { text: "Spotify Liked Songs"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: "Runs through your open Spotify (no login or dev app, read-only). Scan checks your likes against a known-AI-artist list; Back up writes them all to a CSV (~/spotify-liked-DATE.csv) so you never lose your library." }
                        Row {
                            width: parent.width; height: 36; spacing: 8
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 36; radius: 9
                                color: scanM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; color: win.fg; font.pixelSize: 13; font.family: win.ff
                                    text: (win.likedBusy && likedScanProc.running) ? "Scanning…" : "Scan for AI music" }
                                MouseArea { id: scanM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !win.likedBusy; onClicked: win.scanLiked() }
                            }
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 36; radius: 9
                                color: expM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; color: win.fg; font.pixelSize: 13; font.family: win.ff
                                    text: (win.likedBusy && likedExportProc.running) ? "Backing up…" : "Back up to CSV" }
                                MouseArea { id: expM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !win.likedBusy; onClicked: win.exportLiked() }
                            }
                        }
                        Text { width: parent.width; visible: win.likedStatus !== ""; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.75; font.pixelSize: 11; font.family: "monospace"
                            text: win.likedStatus }

                        // ── Update (pull latest from GitHub) ──
                        Text { text: "Update"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: "Pull the latest Technicolor from GitHub and copy it in. Your colors, glass, font, pins, monitors and local.conf are kept (they're gitignored)." }
                        Row {
                            width: parent.width; height: 36; spacing: 8
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 36; radius: 9
                                color: chkM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; color: win.fg; font.pixelSize: 13; font.family: win.ff
                                    text: win.checking ? "Checking…" : "Check for updates" }
                                MouseArea { id: chkM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !win.checking; onClicked: win.runCheck() }
                            }
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 36; radius: 9
                                color: updM.containsMouse ? win.rowHover : (win.updateArmed ? Qt.rgba(0.9, 0.6, 0.2, 0.30) : win.rowBg)
                                Text { anchors.centerIn: parent; color: win.fg; font.pixelSize: 13; font.family: win.ff
                                    text: win.updateArmed ? "Click again to confirm" : (updateProc.running ? "Updating…" : "Update now") }
                                MouseArea { id: updM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !updateProc.running; onClicked: win.runUpdate() }
                            }
                        }
                        // what's new (preview before updating)
                        Text { visible: win.commitCount !== ""; color: win.fg; opacity: 0.8; font.pixelSize: 12; font.bold: true; font.family: win.ff
                            text: win.commitCount === "0" ? "You're up to date."
                                : (win.commitCount === "?" ? "Latest changes on GitHub:"
                                : win.commitCount + (win.commitCount === "1" ? " new commit:" : " new commits:")) }
                        SmoothList {
                            visible: win.newCommits.length > 0
                            width: parent.width; height: Math.min(170, win.newCommits.length * 24 + 8); clip: true; contentHeight: commitCol.height
                            Column {
                                id: commitCol; width: parent.width; spacing: 0
                                Repeater {
                                    model: win.newCommits
                                    delegate: Text {
                                        required property var modelData
                                        width: commitCol.width; height: 24; verticalAlignment: Text.AlignVCenter
                                        text: modelData; color: win.fg; opacity: 0.8; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                        Text { width: parent.width; visible: win.updateStatus !== ""; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.7; font.pixelSize: 11; font.family: "monospace"
                            text: win.updateStatus }
                    }
                    }
                }

                // ===== Hotkeys tab =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 5
                    Column {
                        anchors.fill: parent; spacing: 10

                        // search
                        Rectangle {
                            width: parent.width; height: 40; radius: 9; color: win.rowBg
                            TextInput {
                                id: hkSearch
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                color: win.fg; font.pixelSize: 13; font.family: win.ff; clip: true
                                selectByMouse: true; selectionColor: win.rowHover
                                onTextChanged: win.hotkeySearch = text
                                Text { anchors.verticalCenter: parent.verticalCenter; visible: hkSearch.text === ""
                                       text: "Search shortcuts…"; color: win.fg; opacity: 0.5; font.pixelSize: 13; font.family: win.ff }
                            }
                        }

                        // grouped, searchable cheat sheet
                        SmoothList {
                            width: parent.width; height: parent.height - 50; clip: true; contentHeight: hkCol.height
                            Column {
                                id: hkCol; width: parent.width; spacing: 10
                                Repeater {
                                    model: win.hotkeyCategories
                                    delegate: Column {
                                        id: catCol
                                        required property string modelData
                                        property var rows: win.bindsFor(modelData)
                                        width: hkCol.width; spacing: 3
                                        visible: catCol.rows.length > 0
                                        Text { topPadding: 4; text: catCol.modelData; color: win.fg; opacity: 0.55
                                               font.pixelSize: 11; font.bold: true; font.family: win.ff }
                                        Repeater {
                                            model: catCol.rows
                                            delegate: Rectangle {
                                                id: hkRow
                                                required property var modelData
                                                property bool capturing: win.isCapturing(modelData)
                                                property bool warning: win.isWarnRow(modelData)
                                                width: catCol.width; height: 38; radius: 8
                                                color: hkRow.capturing ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.12)
                                                                       : (hkRowM.containsMouse ? win.rowBg : "transparent")
                                                Text {
                                                    anchors.left: parent.left; anchors.leftMargin: 10
                                                    anchors.right: rightRow.left; anchors.rightMargin: 10
                                                    anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight
                                                    text: modelData.label; color: win.fg; font.pixelSize: 13; font.family: win.ff
                                                }
                                                Row {
                                                    id: rightRow
                                                    anchors.right: parent.right; anchors.rightMargin: 10
                                                    anchors.verticalCenter: parent.verticalCenter; spacing: 6

                                                    // capture prompt
                                                    Rectangle {
                                                        visible: hkRow.capturing
                                                        height: 24; radius: 6
                                                        width: Math.min(pT.implicitWidth + 18, hkRow.width * 0.66)
                                                        color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.18)
                                                        border.width: 1; border.color: win.fg
                                                        Text { id: pT; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                                               verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                                               text: "Press a combo…  (Esc cancels)"
                                                               color: win.fg; font.pixelSize: 11; font.bold: true; font.family: win.ff }
                                                    }
                                                    // conflict message — shown beside the (unchanged) keys for a few seconds
                                                    Text {
                                                        visible: hkRow.warning
                                                        height: 24; verticalAlignment: Text.AlignVCenter
                                                        width: Math.min(implicitWidth, hkRow.width * 0.5); elide: Text.ElideRight
                                                        text: "⚠ " + win.captureWarn; color: "#ff6b6b"; font.pixelSize: 11; font.bold: true; font.family: win.ff
                                                    }
                                                    // reset to the shipped default (only when overridden)
                                                    Rectangle {
                                                        visible: !hkRow.capturing && !hkRow.warning && modelData.overridden
                                                        height: 24; width: 24; radius: 6
                                                        color: rstM.containsMouse ? win.rowHover : win.rowBg
                                                        Text { anchors.centerIn: parent; text: "↺"; color: win.fg; font.pixelSize: 14; font.family: win.ff }
                                                        MouseArea { id: rstM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: win.resetBind(modelData) }
                                                    }
                                                    // keycaps — click to rebind (editable binds only)
                                                    Rectangle {
                                                        visible: !hkRow.capturing
                                                        width: capsRow.implicitWidth + (modelData.editable ? 14 : 0); height: 24; radius: 6
                                                        color: (modelData.editable && capM.containsMouse) ? win.rowHover : "transparent"
                                                        Row {
                                                            id: capsRow
                                                            anchors.centerIn: parent; spacing: 4
                                                            Repeater {
                                                                model: modelData.caps
                                                                delegate: Rectangle {
                                                                    required property string modelData
                                                                    height: 24; width: capT.implicitWidth + 16; radius: 6
                                                                    color: win.rowHover
                                                                    border.width: 1; border.color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.18)
                                                                    Text { id: capT; anchors.centerIn: parent; text: modelData
                                                                           color: win.fg; font.pixelSize: 11; font.bold: true; font.family: win.ff }
                                                                }
                                                            }
                                                        }
                                                        MouseArea { id: capM; anchors.fill: parent; hoverEnabled: true
                                                            enabled: modelData.editable
                                                            cursorShape: modelData.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                            onClicked: win.startCapture(modelData) }
                                                    }
                                                }
                                                MouseArea { id: hkRowM; anchors.fill: parent; hoverEnabled: true; z: -1 }
                                            }
                                        }
                                    }
                                }
                                Text {
                                    width: parent.width; visible: win.hotkeyMatchCount === 0; topPadding: 8
                                    text: win.keybinds.length === 0 ? "Loading shortcuts…" : "No shortcuts match your search."
                                    color: win.fg; opacity: 0.6; font.pixelSize: 13; font.family: win.ff
                                }
                                Text {
                                    width: parent.width; wrapMode: Text.WordWrap; topPadding: 6
                                    color: win.fg; opacity: 0.45; font.pixelSize: 11; font.family: win.ff
                                    text: "Click a shortcut's keys to rebind it — hold your modifiers (Super/Ctrl/Alt/Shift) and press the key. ↺ resets one to its default. Media, volume and mouse binds are fixed. Your rebinds are saved to keybinds.conf and survive updates."
                                }
                            }
                        }
                    }
                }

                // ===== Effects tab (load governor) =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 6
                    SmoothList {
                        anchors.fill: parent; clip: true; contentHeight: fxCol.height
                        Column {
                            id: fxCol
                            width: parent.width; spacing: 10

                            Text { text: "Effects under load"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                                text: "Steps the desktop down as the GPU gets busy, so a game or a local model gets the frame time instead of the glass — then puts it back when things calm down. Leave the governor off if you would rather have a flashy desktop all the time." }

                            // live readout
                            Rectangle {
                                width: parent.width; height: 44; radius: 9; color: win.rowBg
                                Text {
                                    anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    color: win.fg; font.pixelSize: 12; font.family: win.ff
                                    text: "Now: tier " + win.govTier + " · " + ["everything on", "no shimmer", "no bar glass", "no glass", "no animations"][Math.min(win.govTier, 4)]
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    color: win.fg; opacity: 0.6; font.pixelSize: 12; font.family: win.ff
                                    text: win.govGpuBusy >= 0 ? "GPU " + win.govGpuBusy + "%" : "GPU n/a"
                                }
                            }

                            // master switch
                            Rectangle {
                                width: parent.width; height: Math.max(50, govCol.implicitHeight + 18); radius: 9; color: win.rowBg
                                Column {
                                    id: govCol
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.right: govTg.left; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: "Automatic governor"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                    Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                           text: "Turn effects down on their own when the GPU is busy. Off means they stay exactly as you set them, however heavy." }
                                }
                                TcToggle {
                                    id: govTg
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    on: win.govEnabled
                                    onToggled: (v) => { win.govEnabled = v; win.writeGovernorConf() }
                                }
                            }

                            // fullscreen trigger — the reliable one
                            Rectangle {
                                width: parent.width; height: Math.max(50, fsgCol.implicitHeight + 18); radius: 9; color: win.rowBg
                                opacity: win.govEnabled ? 1 : 0.4
                                Column {
                                    id: fsgCol
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.right: fsgTg.left; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: "Cut effects for fullscreen apps"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                    Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                           text: "Drops straight to the furthest step the moment a game goes fullscreen, rather than waiting for the GPU to cross the threshold below — a frame-capped game can sit at half load and never trip it. A merely maximised window is left alone." }
                                }
                                TcToggle {
                                    id: fsgTg
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    on: win.govFullscreen
                                    onToggled: (v) => { win.govFullscreen = v; win.writeGovernorConf() }
                                }
                            }

                            // thresholds
                            Repeater {
                                model: [
                                    { key: "high", label: "Step down above", from: 30, to: 95, unit: "% GPU" },
                                    { key: "low",  label: "Step back up below", from: 10, to: 90, unit: "% GPU" },
                                    { key: "tier", label: "Furthest step it may take", from: 1, to: 4, unit: "" }
                                ]
                                delegate: Item {
                                    id: fxRow
                                    required property var modelData
                                    width: fxCol.width; height: 50
                                    opacity: win.govEnabled ? 1 : 0.4
                                    property real val: modelData.key === "high" ? win.govGpuHigh
                                                     : modelData.key === "low"  ? win.govGpuLow : win.govMaxTier
                                    Item {
                                        width: parent.width; height: 20
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                               text: fxRow.modelData.label; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                               text: Math.round(fxRow.val) + fxRow.modelData.unit
                                               color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                                    }
                                    TcSlider {
                                        width: parent.width; y: 24
                                        enabled: win.govEnabled
                                        from: fxRow.modelData.from; to: fxRow.modelData.to; value: fxRow.val
                                        onMoved: (v) => {
                                            var vv = Math.round(v)
                                            fxRow.val = vv
                                            if (fxRow.modelData.key === "high")      win.govGpuHigh = vv
                                            else if (fxRow.modelData.key === "low")  win.govGpuLow = vv
                                            else                                     win.govMaxTier = vv
                                        }
                                        onCommitted: (v) => win.writeGovernorConf()
                                    }
                                }
                            }

                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.45; font.pixelSize: 10; font.family: win.ff
                                text: "The gap between those two numbers is deliberate: stepping down and back up at the same load would flap the desktop between two looks every couple of seconds. \"Step back up\" is held at least 5% below \"step down\"." }

                            // ── battery (laptops only) ─────────────────────────────
                            // Hidden entirely on desktops. A wireless mouse reports
                            // type=Battery, so detection also requires scope!=Device —
                            // otherwise every desktop with a Logitech mouse grows
                            // battery settings it can never use.
                            Text { visible: win.govHasBattery; text: "On battery"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Rectangle {
                                visible: win.govHasBattery
                                width: parent.width; height: Math.max(50, batCol.implicitHeight + 18); radius: 9; color: win.rowBg
                                Column {
                                    id: batCol
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.right: batTg.left; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: "Cut effects on low battery"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                    Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                           text: "Only while unplugged and below the level you pick below." }
                                }
                                TcToggle {
                                    id: batTg
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    on: win.govBatteryEnabled
                                    onToggled: (v) => { win.govBatteryEnabled = v; win.writeGovernorConf() }
                                }
                            }
                            Repeater {
                                model: win.govHasBattery ? [
                                    { key: "blow",  label: "Below this charge", from: 5,  to: 60, unit: "%" },
                                    { key: "btier", label: "Hold at least tier", from: 1, to: 4,  unit: "" }
                                ] : []
                                delegate: Item {
                                    id: batRow
                                    required property var modelData
                                    width: fxCol.width; height: 50
                                    opacity: win.govBatteryEnabled ? 1 : 0.4
                                    property real val: modelData.key === "blow" ? win.govBatteryLow : win.govBatteryTier
                                    Item {
                                        width: parent.width; height: 20
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                               text: batRow.modelData.label; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                               text: Math.round(batRow.val) + batRow.modelData.unit
                                               color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                                    }
                                    TcSlider {
                                        width: parent.width; y: 24
                                        enabled: win.govBatteryEnabled
                                        from: batRow.modelData.from; to: batRow.modelData.to; value: batRow.val
                                        onMoved: (v) => {
                                            var vv = Math.round(v); batRow.val = vv
                                            if (batRow.modelData.key === "blow") win.govBatteryLow = vv
                                            else                                 win.govBatteryTier = vv
                                        }
                                        onCommitted: (v) => win.writeGovernorConf()
                                    }
                                }
                            }

                            // ── water shimmer ──────────────────────────────────────
                            Text { text: "Water"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                                text: "Caustics on the glass, from a real wave simulation — disturbances arrive from off-screen, spread, reflect and die down. The light comes from whatever is actually behind the window, so it takes on those colours." }

                            Rectangle {
                                width: parent.width; height: Math.max(50, shCol.implicitHeight + 18); radius: 9; color: win.rowBg
                                Column {
                                    id: shCol
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.right: shTg.left; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: "Moving water"; color: win.fg; font.pixelSize: 13; font.bold: true; font.family: win.ff }
                                    Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                                           text: "Off means the simulation never runs at all, not merely that it is invisible. The governor also switches this off first when the GPU gets busy." }
                                }
                                TcToggle {
                                    id: shTg
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    on: win.glassValue({ key: "shimmer:enabled", def: 0 }) >= 0.5
                                    onToggled: (v) => { win.glassSet("shimmer:enabled", v ? 1 : 0); win.loadGlass() }
                                }
                            }

                            Repeater {
                                model: win.shimmerSpecs
                                delegate: Item {
                                    id: shRow
                                    required property var modelData
                                    width: fxCol.width; height: 78
                                    property real val: modelData.def
                                    Connections { target: win; function onGlassValuesChanged() { shRow.val = win.glassValue(shRow.modelData) } }
                                    Item {
                                        width: parent.width; height: 20
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                               text: shRow.modelData.label; color: win.fg; font.pixelSize: 12; font.family: win.ff }
                                        Text { anchors.right: shReset.left; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                               text: shRow.val < 0.1 ? shRow.val.toFixed(3) : shRow.val.toFixed(2)
                                               color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff }
                                        Rectangle { id: shReset; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            width: 48; height: 20; radius: 6; color: shRm.containsMouse ? win.rowHover : win.rowBg
                                            Text { anchors.centerIn: parent; text: "Reset"; color: win.fg; font.pixelSize: 10; font.family: win.ff }
                                            MouseArea { id: shRm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { shRow.val = shRow.modelData.def; win.glassSet(shRow.modelData.key, shRow.modelData.def) } }
                                        }
                                    }
                                    TcSlider {
                                        width: parent.width; y: 22
                                        from: shRow.modelData.log ? 0 : shRow.modelData.from
                                        to:   shRow.modelData.log ? 1 : shRow.modelData.to
                                        value: shRow.modelData.log ? win.logValToPos(shRow.modelData, shRow.val) : shRow.val
                                        onMoved: (v) => {
                                            var vv = shRow.modelData.log ? win.logPosToVal(shRow.modelData, v) : v
                                            shRow.val = vv
                                            win.glassLive(shRow.modelData.key, vv)
                                        }
                                        onCommitted: (v) => win.glassSet(shRow.modelData.key, shRow.val)
                                    }
                                    Text {
                                        width: parent.width; y: 44; wrapMode: Text.WordWrap
                                        text: shRow.modelData.hint || ""
                                        color: win.fg; opacity: 0.42; font.pixelSize: 10; font.family: win.ff
                                        lineHeight: 1.15
                                    }
                                }
                            }

                            // ── manual override ────────────────────────────────────
                            Text { text: "Set it yourself"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                            Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                                text: "Applies right now. With the governor on it will move this again on its next check, so treat these as a nudge rather than a setting. Nothing is written to your config — a Hyprland reload puts everything back." }
                            Flow {
                                width: parent.width; spacing: 6
                                Repeater {
                                    model: [
                                        { t: 0, l: "Everything on" },
                                        { t: 1, l: "No shimmer" },
                                        { t: 2, l: "No bar glass" },
                                        { t: 3, l: "No glass" },
                                        { t: 4, l: "All off" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: Math.max(96, tierLbl.implicitWidth + 22); height: 30; radius: 8
                                        color: win.govTier === modelData.t ? win.rowHover : (tierM.containsMouse ? win.rowHover : win.rowBg)
                                        border.width: win.govTier === modelData.t ? 1 : 0
                                        border.color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.35)
                                        Text { id: tierLbl; anchors.centerIn: parent; text: modelData.l; color: win.fg
                                               font.pixelSize: 11; font.family: win.ff
                                               font.bold: win.govTier === modelData.t }
                                        MouseArea { id: tierM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: win.govApplyTier(modelData.t) }
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }
        }

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
                    SmoothList {
                        width: parent.width; height: parent.height - 84; clip: true; contentHeight: resCol.height
                        Column {
                            id: resCol; width: parent.width; spacing: 4
                            Repeater {
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
                                    width: resCol.width; height: 40; radius: 8; color: pickM.containsMouse ? win.rowHover : "transparent"
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
}
