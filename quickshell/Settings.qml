// Settings.qml — a real toplevel app window (FloatingWindow), opened from the
// launcher's gear. Instantiated once per bar (Bar.qml): `Settings { bar: bar }`.
// Colors/state/data come through the `bar` reference so it matches the bar.
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import Qt.labs.folderlistmodel

FloatingWindow {
    id: win
    property var bar      // a Bar instance — colors + pin data (may briefly be null)
    property var shell    // the ShellRoot — holds the settings open/tab state

    visible: shell ? shell.settingsOpen : false
    title: "Technicolor Settings"
    implicitWidth: 780
    implicitHeight: 660
    // Transparent so hyprglass renders live liquid glass in the gaps between the
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
            confFile.reload(); curWpFile.reload(); tuneFile.reload(); win.loadGlass()
            if (shell && shell.settingsTab === 1) win.refreshWallpapers()
        } else win.addOpen = false
    }
    Connections {
        target: shell
        function onSettingsTabChanged() {
            if (shell.settingsTab === 4) confFile.reload()
            else if (shell.settingsTab === 3) win.loadGlass()
            else if (shell.settingsTab === 2) tuneFile.reload()
            else if (shell.settingsTab === 1) win.refreshWallpapers()
        }
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
        imgPickProc.command = ["bash", "-c",
            "kdialog --getopenfilename ~ 'Images (*.png *.jpg *.jpeg *.svg *.webp *.gif)' 2>/dev/null || " +
            "zenity --file-selection --file-filter='*.png *.jpg *.jpeg *.svg *.webp *.gif' 2>/dev/null"]
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

    // ── UI font (System tab) ── source of truth = ~/.config/hypr/font.conf.
    // Bar + this window read it live via shell.uiFont; wofi via gen-wofi-font.sh.
    property var installedFonts: []
    property string currentFont: ""
    property string fontSearch: ""
    property real fontListH: 220     // resizable via the drag-divider below the list
    property real confEditH: 240     // resizable local.conf editor
    readonly property string effFont: win.currentFont !== "" ? win.currentFont : (win.bar ? win.bar.fontFamily : "SF Pro")
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
        wpDirPickProc.command = ["bash", "-c", "kdialog --getexistingdirectory '" + win.wallpaperDir + "' 2>/dev/null || zenity --file-selection --directory 2>/dev/null"]
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
        Hyprland.dispatch("exec ~/.config/hypr/wallpaper-cycle.sh '" + safe + "'")
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
    property real tuneSaturation: 1.0    // 0 grayscale .. 1 as-is .. 1.5 vivid
    property real tuneBrightness: 1.0    // 0 black .. 1 as-is .. 2 brighter
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
        var hh = c.hslHue; if (hh < 0) hh = 0
        hh = hh + hue / 360.0; hh = hh - Math.floor(hh)
        return Qt.hsla(hh, Math.max(0, Math.min(1, c.hslSaturation * sat)),
                       Math.max(0, Math.min(1, c.hslLightness * bright)), 1)
    }
    function resetContrast()   { win.tuneContrast = 0.5; if (win.shell) win.shell.contrastBias = 0.5; win.commitTuning() }
    function resetSaturation() { win.tuneSaturation = 1.0; win.commitTuning() }
    function resetBrightness() { win.tuneBrightness = 1.0; win.commitTuning() }
    function resetHue()        { win.tuneHue = 0.0; win.commitTuning() }

    // ── Glass tab (hyprglass) ── live via `hyprctl keyword`, persisted to
    // hyprglass-tuning.conf (sourced by hyprland.conf). Each spec: key/label/
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
    property var glassValues: ({})    // key -> live value, populated by loadGlass()
    Process {
        id: glassGetProc
        command: ["bash", "-c", "\"$HOME/.config/hypr/hyprglass-get.sh\""]
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
    Process { id: glassLiveProc }
    function glassLive(key, val) {
        if (glassLiveProc.running) return
        glassLiveProc.command = ["hyprctl", "keyword", "plugin:hyprglass:" + key, String(val)]
        glassLiveProc.running = true
    }
    Process { id: glassSetProc }
    function glassSet(key, val) {
        glassSetProc.command = ["bash", "-c", "\"$HOME/.config/hypr/hyprglass-set.sh\" '" + key + "' '" + val + "'"]
        glassSetProc.running = true
    }
    function glassValue(spec) {
        var v = win.glassValues[spec.key]
        return (v === undefined) ? spec.def : v
    }

    // Reusable slider: track + fill + draggable knob. moved() fires live while
    // dragging, committed() on release.
    // Vertical Flickable with smooth, accelerated mouse-wheel scrolling. A bare
    // Flickable jumps a fixed step per notch with no easing (feels janky); this
    // animates contentY to an accumulating target so fast scrolls glide. Trackpad
    // wheel (pixel deltas) is left to the Flickable's native smooth handling.
    component SmoothList: Flickable {
        id: sfl
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        NumberAnimation { id: sflAnim; target: sfl; property: "contentY"; duration: 200; easing.type: Easing.OutCubic }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse
            onWheel: (ev) => {
                var max = Math.max(0, sfl.contentHeight - sfl.height)
                if (max <= 0) return
                var base = sflAnim.running ? sflAnim.to : sfl.contentY
                var t = Math.max(0, Math.min(max, base - (ev.angleDelta.y / 120) * 120))
                sflAnim.to = t; sflAnim.restart()
            }
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

    // ── content: solid rounded blocks, live liquid glass in the gaps ──
    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.close()

        Column {
            anchors.fill: parent
            anchors.margins: 14      // outer glass margin
            spacing: 12              // glass gap between blocks

            // ── header: title pill + close circle, each its own block on glass ──
            Item {
                width: parent.width; height: 48
                Rectangle {   // title pill
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    height: 44; radius: 22; color: win.blockColor
                    width: titleTxt.implicitWidth + 40
                    Text { id: titleTxt; anchors.centerIn: parent; text: "Settings"; color: win.fg; font.pixelSize: 18; font.bold: true; font.family: win.ff }
                }
                Rectangle {   // close circle
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: 44; height: 44; radius: 22
                    color: closeM.containsMouse ? win.rowHover : win.blockColor
                    Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF00D); color: win.fg; font.pixelSize: 18; font.family: win.ff }
                    MouseArea { id: closeM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.close() }
                }
            }

            // ── tab block ──
            Rectangle {
                width: parent.width; height: 52; radius: 16; color: win.blockColor
                Row {
                    id: tabBar
                    anchors.fill: parent; anchors.margins: 6; spacing: 6
                    property var tabs: ["Apps", "Wallpaper", "Colors", "Glass", "System"]
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
                                    onClicked: Hyprland.dispatch("exec ~/.config/hypr/wallpaper-cycle.sh random") }
                            }
                            Rectangle {
                                width: (parent.width - 8) / 2; height: 40; radius: 9
                                color: openM.containsMouse ? win.rowHover : win.rowBg
                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF07C) + "  Open folder"; color: win.fg; font.pixelSize: 13; font.family: win.ff }
                                MouseArea { id: openM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: Hyprland.dispatch("exec ~/.config/hypr/open-folder.sh '" + win.wallpaperDir + "'") }
                            }
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.6; font.pixelSize: 11; font.family: win.ff
                            text: "Scroll to browse · click a cover to center it · click the centered one to set it." }
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
                            id: satSlider; width: parent.width; from: 0; to: 1.5; value: win.tuneSaturation
                            onMoved: (v) => win.tuneSaturation = v
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "Mute (left, grayscale) or boost (right) the wallpaper colors everywhere — bar, Discord, Spotify, Brave, Dolphin, GTK, notifications." }

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
                            width: parent.width; from: 0; to: 2; value: win.tuneBrightness
                            onMoved: (v) => win.tuneBrightness = v
                            onCommitted: (v) => win.commitTuning()
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.55; font.pixelSize: 11; font.family: win.ff
                            text: "Darken (left) or lighten (right) every color. Affects readability, so pair it with Text contrast." }

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

                        // ── Discord (Vesktop) ──
                        Text { text: "Discord (Vesktop)"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: win.fg; opacity: 0.75; font.pixelSize: 12; font.family: win.ff
                            text: "In Vesktop → Settings → Themes, enable \"Technicolor\", then \"Technicolor Blocks\" (in that order). Colors then follow your wallpaper live." }
                        }
                    }
                }

                // ===== Glass tab (hyprglass) =====
                Item {
                    anchors.fill: parent
                    visible: win.shell && win.shell.settingsTab === 3
                    Flickable {
                        anchors.fill: parent; clip: true
                        contentWidth: width; contentHeight: glassCol.height
                        flickableDirection: Flickable.VerticalFlick; boundsBehavior: Flickable.StopAtBounds
                        Column {
                            id: glassCol
                            width: parent.width; spacing: 10

                            Text { text: "Liquid glass (hyprglass)"; color: win.fg; font.pixelSize: 14; font.bold: true; font.family: win.ff }
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
                                MouseArea { id: applyM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { win.saveConf(); Hyprland.dispatch("exec hyprctl reload") } } }
                        }

                        Rectangle { width: parent.width; height: 1; color: win.fg; opacity: 0.12 }
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
                }
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
