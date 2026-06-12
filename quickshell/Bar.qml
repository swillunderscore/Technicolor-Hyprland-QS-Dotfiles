// Bar.qml — Bottom bar, one instance per monitor
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes

PanelWindow {
    id: bar

    required property var barScreen
    required property color colorFocused
    required property color colorVisible
    required property color colorOccupied
    required property color colorEmpty
    required property int workspaceCeiling
    required property color gradientStart
    required property color gradientEnd

    // Fed from shell.qml's nethogs streamer. Used to annotate net history
    // buckets with the top sender/receiver app for that 1-second window.
    property string sharedNetTopUpComm: "-"
    property string sharedNetTopDownComm: "-"

    readonly property var hyprMon: Hyprland.monitorFor(barScreen)
    readonly property bool isPrimary: hyprMon ? hyprMon.id === 0 : true
    readonly property string homeDir: Quickshell.env("HOME") || "/home"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

    // Launcher pins. allAppPins is the full list; appPins is what actually
    // renders. At startup pinAvailProc drops any pin whose launch command
    // isn't present on this machine, so the shared config hides apps a given
    // system doesn't have (here, everything's installed -> all of them show).
    readonly property var allAppPins: [
        { icon: "brave-desktop",                    cmd: "brave",                                   nerdGlyph: "", imgPath: "" },
        { icon: "kitty",                            cmd: "kitty",                                   nerdGlyph: "", imgPath: "" },
        { icon: "vesktop",                          cmd: "vesktop",                                 nerdGlyph: "", imgPath: "" },
        { icon: "steam",                            cmd: "steam",                                   nerdGlyph: "", imgPath: "" },
        { icon: "",                                 cmd: bar.homeDir + "/.local/bin/launch_slippi_and_keyb0xx.sh",nerdGlyph: "", imgPath: "file://" + bar.homeDir + "/Slippi/73bff6acc99072beb352c16a24b3e6cd.png" },
        { icon: "org.kde.dolphin",                  cmd: "~/.config/hypr/dolphin-tc.sh",                                 nerdGlyph: "", imgPath: "" },
        { icon: "spotify",                          cmd: "spotify",                                 nerdGlyph: "", imgPath: "file:///usr/share/icons/char-white/apps/16/spotify-client.svg" },
        { icon: "org.telegram.desktop",             cmd: "flatpak run org.telegram.desktop",        nerdGlyph: "", imgPath: "" },
        { icon: "io.missioncenter.MissionCenter",   cmd: "missioncenter",                           nerdGlyph: "", imgPath: "" },
        { icon: "unityhub",                         cmd: "unityhub",                                nerdGlyph: "", imgPath: "" }
    ]
    property var appPins: allAppPins

    Process {
        id: pinAvailProc
        command: ["bash", "-c",
            'avail=""; i=0; for c in "$@"; do first=${c%% *}; ok=0; case "$first" in /*) { [ -x "$first" ] || [ -e "$first" ]; } && ok=1;; flatpak) rest=${c#* }; appid=${rest#* }; appid=${appid%% *}; flatpak info "$appid" >/dev/null 2>&1 && ok=1;; *) command -v "$first" >/dev/null 2>&1 && ok=1;; esac; [ "$ok" = 1 ] && avail="$avail $i"; i=$((i+1)); done; echo $avail',
            "bash"].concat(bar.allAppPins.map(function (p) { return p.cmd }))
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var idxs = this.text.trim().split(/\s+/).filter(function (s) { return s !== "" })
                if (!idxs.length) return
                var filtered = []
                for (var i = 0; i < idxs.length; i++) {
                    var n = parseInt(idxs[i])
                    if (!isNaN(n) && bar.allAppPins[n]) filtered.push(bar.allAppPins[n])
                }
                if (filtered.length) bar.appPins = filtered
            }
        }
    }

    property double lastMenuCloseTime: 0

    function lerpColor(t) {
        return Qt.rgba(
            gradientStart.r + (gradientEnd.r - gradientStart.r) * t,
                       gradientStart.g + (gradientEnd.g - gradientStart.g) * t,
                       gradientStart.b + (gradientEnd.b - gradientStart.b) * t,
                       1.0
        )
    }
    function lerpColorAlpha(t, a) {
        return Qt.rgba(
            gradientStart.r + (gradientEnd.r - gradientStart.r) * t,
                       gradientStart.g + (gradientEnd.g - gradientStart.g) * t,
                       gradientStart.b + (gradientEnd.b - gradientStart.b) * t,
                       a
        )
    }

    function pad3(n) { return ("  " + n).slice(-3) }
    function contrastText(c) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return lum > 0.55 ? "#000000" : "#FFFFFF"
    }
    // The *opposite* of contrastText, toned off pure black/white so it still
    // reads on bright or dark backgrounds. Used for the second I/O series.
    function contrastAlt(c) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return lum > 0.55 ? Qt.rgba(0.83, 0.83, 0.88, 1.0) : Qt.rgba(0.20, 0.20, 0.24, 1.0)
    }
    function contrastDim(c) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.35) : Qt.rgba(1, 1, 1, 0.35)
    }
    function solidify(c) { return Qt.rgba(c.r, c.g, c.b, 1.0) }

    // Builds an opaque body shape (SVG path) with rounded bottom corners and a
    // drippy/wavy TOP edge that rises with `p` (0..1). No transparency — the path
    // is fully filled below the edge; above it is simply not drawn.
    // `blr` overrides the bottom-LEFT corner radius (defaults to `r`); pass 0
    // for a square bottom-left (e.g. the launcher, which sits flush to a pill).
    function dripPath(w, h, r, p, seed, blr) {
        if (blr === undefined) blr = r
        var edgeY = h * (1.0 - p)
        var endFade = p > 0.86 ? (p - 0.86) / 0.14 : 0.0
        var waveStr = (Math.sin(p * Math.PI) * 0.9 + 0.1) * (1.0 - endFade)
        var dripPhase = Math.sin(p * Math.PI) * (1.0 - endFade)
        var topR = r * endFade
        var N = 30
        var path = "M " + blr.toFixed(1) + "," + h.toFixed(1)
        path += " L " + (w - r).toFixed(1) + "," + h.toFixed(1)
        path += " Q " + w.toFixed(1) + "," + h.toFixed(1) + " " + w.toFixed(1) + "," + (h - r).toFixed(1)
        path += " L " + w.toFixed(1) + "," + (edgeY + topR).toFixed(1)
        if (topR > 0.5)
            path += " Q " + w.toFixed(1) + "," + edgeY.toFixed(1) + " " + (w - topR).toFixed(1) + "," + edgeY.toFixed(1)
        var x0 = topR, x1 = w - topR
        for (var i = N; i >= 0; i--) {
            var t = i / N
            var win = Math.sin(t * Math.PI)
            var x = x0 + (x1 - x0) * t
            var wave = Math.sin(t * 9.0 + seed) * 11.0 * waveStr * win
            var wave2 = Math.sin(t * 19.0 - seed * 2.0) * 6.0 * waveStr * win
            var wave3 = Math.sin(t * 37.0 + seed * 3.0) * 3.0 * waveStr * win
            var drip = (Math.exp(-Math.pow((t - 0.17) * 7.0, 2)) * 36.0
                      + Math.exp(-Math.pow((t - 0.45) * 9.0, 2)) * 22.0
                      + Math.exp(-Math.pow((t - 0.76) * 8.0, 2)) * 31.0) * dripPhase * win
            var y = Math.max(-58, edgeY - wave - wave2 - wave3 - drip)
            path += " L " + x.toFixed(1) + "," + y.toFixed(1)
        }
        if (topR > 0.5)
            path += " Q 0," + edgeY.toFixed(1) + " 0," + (edgeY + topR).toFixed(1)
        path += " L 0," + (h - blr).toFixed(1)
        if (blr > 0.5)
            path += " Q 0," + h.toFixed(1) + " " + blr.toFixed(1) + "," + h.toFixed(1)
        path += " Z"
        return path
    }
    function contrastHover(c) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.14)
    }
    function contrastRow(c) {
        var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.06) : Qt.rgba(1, 1, 1, 0.07)
    }

    readonly property color colText: "#ECEEF8"

    // ── Icon resolver with desktop file cache ──
    property var iconCache: ({})
    property bool iconCacheReady: false
    property var steamIconMap: ({})
    property var steamIconRequested: ({})
    property int steamIconVersion: 0  // bumped to trigger re-eval

    Process {
        id: steamIconProc
        property string steamId: ""
        stdout: StdioCollector {
            onStreamFinished: {
                var line = this.text.trim()
                var eq = line.indexOf("=")
                if (eq > 0) {
                    var sid = line.substring(0, eq)
                    var path = line.substring(eq + 1)
                    if (path !== "") {
                        var m = bar.steamIconMap
                        m[sid] = "file://" + path
                        bar.steamIconMap = m
                        bar.steamIconVersion++
                    }
                }
            }
        }
    }

    // Scan all .desktop files at startup to build appId → iconName map
    Process {
        id: iconCacheProc
        command: ["bash", "-c",
        "find /usr/share/applications ~/.local/share/applications " +
        "/var/lib/flatpak/exports/share/applications " +
        "~/.local/share/flatpak/exports/share/applications " +
        "-maxdepth 1 -name '*.desktop' 2>/dev/null | while read f; do " +
        "id=$(basename \"$f\" .desktop); " +
        "icon=$(grep -m1 '^Icon=' \"$f\" 2>/dev/null | cut -d= -f2); " +
        "wmclass=$(grep -m1 '^StartupWMClass=' \"$f\" 2>/dev/null | cut -d= -f2); " +
        "[ -n \"$icon\" ] && echo \"$id=$icon\"; " +
        "[ -n \"$wmclass\" ] && [ -n \"$icon\" ] && echo \"$wmclass=$icon\"; " +
        "done"
        ]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var map = {}
                var lines = this.text.trim().split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var parts = lines[i].split("=")
                    if (parts.length >= 2) {
                        var key = parts[0]
                        var val = parts.slice(1).join("=")
                        // Clean icon value
                        val = val.replace(/\.exe\d*$/, "")
                        val = val.replace(/\.(svg|png|xpm|ico)$/, "")
                        if (val.indexOf("/") === 0 && !val.match(/\.[a-z]+$/)) {
                            // absolute path without extension - already stripped, use as-is
                        } else if (val.indexOf("/") === 0) {
                            val = val.substring(val.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "")
                        }
                        map[key] = val
                        map[key.toLowerCase()] = val
                    }
                }
                bar.iconCache = map
                bar.iconCacheReady = true
            }
        }
    }

    function resolveAppIcon(appId, title) {
        if (!appId || appId === "") return ""

            // Manual overrides for apps that can't be auto-resolved
            var overrides = {
                "Slippi Launcher": "file://" + bar.homeDir + "/Slippi/73bff6acc99072beb352c16a24b3e6cd.png"
            }
            if (overrides[appId]) return overrides[appId]

                // Title-based matching for generic class names (AppImage "Apprun" etc)
                if (title && (appId === "Apprun" || appId === "apprun" || appId === "AppRun")) {
                    var titleLower = title.toLowerCase()
                    // Try matching title words against icon names
                    var titleWords = titleLower.replace(/[^a-z0-9 ]/g, "").split(" ")
                    for (var tw = 0; tw < titleWords.length; tw++) {
                        if (titleWords[tw].length < 3) continue
                            var tp = Quickshell.iconPath(titleWords[tw], true)
                            if (tp !== "") return tp
                    }
                    // Check cache by title words
                    if (iconCacheReady) {
                        for (var tw2 = 0; tw2 < titleWords.length; tw2++) {
                            if (titleWords[tw2].length < 3) continue
                                if (iconCache[titleWords[tw2]]) {
                                    var tc = Quickshell.iconPath(iconCache[titleWords[tw2]], true)
                                    if (tc !== "") return tc
                                }
                        }
                    }
                }

                // 0. Steam games: steam_app_NNNN → library cache icon
                if (appId.indexOf("steam_app_") === 0) {
                    var steamId = appId.substring(10)
                    var cacheDir = bar.homeDir + "/.local/share/Steam/appcache/librarycache/" + steamId
                    // Check steamIconMap (populated async)
                    if (steamIconMap[steamId]) return steamIconMap[steamId]
                        // Trigger async lookup if not yet done
                        if (!steamIconRequested[steamId]) {
                            steamIconRequested[steamId] = true
                            steamIconProc.steamId = steamId
                            steamIconProc.command = ["bash", "-c",
                            "find '" + cacheDir + "' -maxdepth 1 \\( -name '*.jpg' -o -name '*.png' \\) -type f " +
                            "-exec stat --format='%s %n' {} \\; 2>/dev/null | sort -n | head -1 | " +
                            "awk '{print \"" + steamId + "=\" $2}'"]
                            steamIconProc.running = true
                        }
                        return ""
                }

                // 1. Check the desktop file cache (try appId + normalized variants)
                function tryCacheIcon(key) {
                    if (!key || !iconCacheReady || !iconCache[key]) return ""
                    var ic = iconCache[key]
                    if (ic.indexOf("/") === 0) {
                        var b = ic.substring(ic.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "")
                        var r = Quickshell.iconPath(b, true)
                        if (r !== "") return r
                        r = Quickshell.iconPath(b, false)
                        if (r !== "") return r
                        return "file://" + ic
                    }
                    var r2 = Quickshell.iconPath(ic, true)
                    if (r2 !== "") return r2
                    return Quickshell.iconPath(ic, false)
                }

                var variants = [
                    appId,
                    appId.toLowerCase(),
                    appId.replace(/-/g, " "),
                    appId.replace(/ /g, "-"),
                    appId.replace(/_/g, " "),
                    appId.replace(/ /g, "_"),
                    appId.toLowerCase().replace(/-/g, " "),
                    appId.toLowerCase().replace(/ /g, "-"),
                    appId.toLowerCase().replace(/-/g, ""),
                    appId.toLowerCase().replace(/ /g, "")
                ]
                for (var vi = 0; vi < variants.length; vi++) {
                    var cr = tryCacheIcon(variants[vi])
                    if (cr !== "") return cr
                }

                // 2. Try appId and normalized variants as icon names
                for (var vi2 = 0; vi2 < variants.length; vi2++) {
                    var dp = Quickshell.iconPath(variants[vi2], true)
                    if (dp !== "") return dp
                    dp = Quickshell.iconPath(variants[vi2], false)
                    if (dp !== "") return dp
                }

                // 3. Strip reverse-DNS (org.kde.kate → kate)
                var parts = appId.split(".")
                if (parts.length > 1) {
                    var short = parts[parts.length - 1]
                    var sp = Quickshell.iconPath(short, true)
                    if (sp !== "") return sp
                    sp = Quickshell.iconPath(short.toLowerCase(), true)
                    if (sp !== "") return sp
                }

                // 4. Last resort
                return Quickshell.iconPath(appId, false)
    }
    readonly property color colDim: "#585B70"
    readonly property int bw: isPrimary ? 2 : 1
    readonly property int rad: isPrimary ? 10 : 8
    readonly property int fs: isPrimary ? 15 : 12
    readonly property int vm: isPrimary ? 4 : 1
    readonly property int hm: isPrimary ? 5 : 4
    readonly property string fontFamily: Quickshell.env("QS_FONT") || "SF Pro"

    readonly property color borderDrawer: lerpColorAlpha(0.0, 0.8)
    readonly property color borderCpu:    lerpColorAlpha(0.10, 0.7)
    readonly property color borderGpu:    lerpColorAlpha(0.22, 0.7)
    readonly property color borderMem:    lerpColorAlpha(0.34, 0.7)
    // Right-side pills evenly spaced across the palette: vol → clock → notif
    // → power, each ~0.15 apart. Keeps the gradient flowing smoothly to the
    // edge instead of bunching all bright colors together at the right.
    readonly property color borderVol:    lerpColorAlpha(0.55, 0.7)
    readonly property color borderClock:  lerpColorAlpha(0.70, 0.7)
    readonly property color borderNotif:  lerpColorAlpha(0.86, 0.75)
    readonly property color borderPower:  lerpColorAlpha(1.0, 0.8)

    property int cpuUsage: 0
    property int cpuTemp: 0
    property int gpuUsage: 0
    property int gpuTemp: 0
    property int memUsage: 0
    property real memUsedGB: 0
    property real memTotalGB: 0
    property int swapUsage: 0
    property real swapUsedGB: 0
    property real swapTotalGB: 0
    property string swapLabel: "SWAP"
    property int vramUsage: 0
    property real vramUsedGB: 0
    property real vramTotalGB: 0
    property int diskFreePercent: 0
    property var lastCpuIdle: 0
    property var lastCpuTotal: 0
    // I/O rates (bytes/sec) + scrolling history for the sparkline charts
    property real netRxRate: 0
    property real netTxRate: 0
    property real diskRdRate: 0
    property real diskWrRate: 0
    property var netHist: []    // [{a: rx, b: tx, aApp, bApp}, ...] newest last
    property var diskHist: []   // [{a: read, b: write, aApp, bApp}, ...]
    // Per-pid cumulative read/write bytes from the previous tick. Used to
    // diff `pio` lines from sysmon.sh and find the top reader/writer for
    // this 1-second window. {pid: [readBytes, writeBytes]}
    property var prevPio: ({})
    // Per-stat usage history (0..100), newest last
    property var cpuHist: []
    property var gpuHist: []
    property var vramHist: []
    property var memHist: []
    property var swapHist: []
    property var lastNetRx: -1
    property var lastNetTx: -1
    property var lastDiskRd: -1
    property var lastDiskWr: -1
    readonly property int ioHistLen: 48
    property string clockText: ""

    function fmtRate(bps) {
        if (bps < 1024) return Math.round(bps) + "B"
        if (bps < 1048576) return (bps / 1024).toFixed(0) + "K"
        if (bps < 1073741824) return (bps / 1048576).toFixed(1) + "M"
        return (bps / 1073741824).toFixed(2) + "G"
    }
    function pushHist(arr, v) {
        var a = arr.slice()
        a.push(v)
        while (a.length > bar.ioHistLen) a.shift()
        return a
    }
    // Peak (max) of field "a" or "b" across a net/disk history buffer — the top
    // of that series' graph over the visible window.
    function histPeak(arr, field) {
        if (!arr || !arr.length) return 0
        var m = 0
        for (var i = 0; i < arr.length; i++) {
            var v = arr[i][field]
            if (v > m) m = v
        }
        return m
    }

    function closeLauncher() {
        bar.launcherOpen = false;
        bar.lastMenuCloseTime = Date.now();
        if (launcherPanel) launcherPanel.searchText = "";
    }

    // Persistent per-app notification counts. Maintained outside Quickshell by
    // ~/.config/quickshell/notif-bump.sh (called by mako's on-notify hook) and
    // ~/.config/quickshell/notif-clear.sh (called by ~/.config/hypr/notif-focus-watcher.sh
    // on each Hyprland activewindow event). Stored as a JSON object keyed by
    // lowercased desktop-entry or app_name: {"vesktop": 3, "org.telegram.desktop": 1}
    property var notifCounts: ({})

    FileView {
        id: notifCountsFile
        path: bar.runtimeDir + "/quickshell-notif-counts.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: bar.parseNotifCounts()
        onLoadFailed: bar.notifCounts = ({})
    }

    function parseNotifCounts() {
        try {
            var t = notifCountsFile.text()
            bar.notifCounts = t ? JSON.parse(t) : {}
        } catch (e) {
            bar.notifCounts = {}
        }
    }

    // Telegram's TOTAL unread incl muted chats, from its Unity LauncherEntry
    // badge (muted chats never fire mako, so this is their only source).
    // Bridged by ~/.config/hypr/tg-badge-listener.py.
    property int tgCount: 0
    property bool tgVisible: false
    FileView {
        id: tgCountFile
        path: bar.runtimeDir + "/quickshell-tg-count.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: bar.parseTgCount()
        onLoadFailed: { bar.tgCount = 0; bar.tgVisible = false }
    }
    function parseTgCount() {
        try {
            var t = tgCountFile.text()
            var o = t ? JSON.parse(t) : {}
            bar.tgCount = o.count || 0
            bar.tgVisible = !!o.visible && (o.count || 0) > 0
        } catch (e) { bar.tgCount = 0; bar.tgVisible = false }
    }
    // Telegram's UNMUTED unread (from mako). When the total above is > 0 but
    // this is 0, every unread is muted → the badge is drawn gray.
    readonly property int tgUnmuted: notifCountForClass("org.telegram.desktop")

    // Full notification log — append-only ring buffer (cap 50) written by
    // notif-bump.sh. Each entry: {id, ts, key, display, app_name, desktop_entry,
    // summary, body, urgency}. Cleared in lockstep with counts when the user
    // focuses the matching app's window.
    property var notifLog: []
    FileView {
        id: notifLogFile
        path: bar.runtimeDir + "/quickshell-notif-log.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: bar.parseNotifLog()
        onLoadFailed: bar.notifLog = []
    }
    function parseNotifLog() {
        try {
            var t = notifLogFile.text()
            bar.notifLog = t ? JSON.parse(t) : []
        } catch (e) {
            bar.notifLog = []
        }
    }

    // Silenced apps — { key: { display, app_name, desktop_entry } }.
    // Managed by notif-silence.sh which also rewrites the mako config block
    // between QS_SILENCE markers so popups stop appearing too.
    property var silencedApps: ({})
    FileView {
        id: silencedAppsFile
        path: bar.homeDir + "/.config/quickshell/silenced-apps.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: bar.parseSilencedApps()
        onLoadFailed: bar.silencedApps = ({})
    }
    function parseSilencedApps() {
        try {
            var t = silencedAppsFile.text()
            bar.silencedApps = t ? JSON.parse(t) : {}
        } catch (e) {
            bar.silencedApps = {}
        }
    }

    // Per-app audit log of notifications mako suppressed because of a silence
    // rule. Capped at 20 per app inside notif-bump.sh.
    property var suppressedApps: ({})
    FileView {
        id: suppressedAppsFile
        path: bar.runtimeDir + "/quickshell-notif-suppressed.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: bar.parseSuppressedApps()
        onLoadFailed: bar.suppressedApps = ({})
    }
    function parseSuppressedApps() {
        try {
            var t = suppressedAppsFile.text()
            bar.suppressedApps = t ? JSON.parse(t) : {}
        } catch (e) {
            bar.suppressedApps = {}
        }
    }

    // FileView's inotify watch is only armed after a successful load. If a
    // runtime JSON file doesn't exist when the bar starts (notif-bump.sh
    // hasn't run yet), the initial load fails and FileView never sees the
    // file appear later. Seed empties at startup, then poke each FileView to
    // engage its watcher.
    Process {
        running: true
        command: ["bash", "-c",
            "for f in quickshell-notif-counts.json quickshell-notif-log.json quickshell-notif-suppressed.json; do "
          + "p=\"$XDG_RUNTIME_DIR/$f\"; "
          + "if [ ! -f \"$p\" ]; then "
          + "  case \"$f\" in *log.json) echo '[]' > \"$p\";; *) echo '{}' > \"$p\";; esac; "
          + "fi; done"]
        onExited: function(code, status) {
            notifCountsFile.reload()
            notifLogFile.reload()
            suppressedAppsFile.reload()
        }
    }

    // Which silenced-tab rows are currently expanded to show their suppressed
    // audit log. Toggled by clicking the row header. Map of key → bool.
    property var expandedSilenced: ({})
    function toggleSilencedExpand(key) {
        var e = {}
        for (var k in bar.expandedSilenced) e[k] = bar.expandedSilenced[k]
        e[key] = !e[key]
        bar.expandedSilenced = e
    }

    Process { id: silenceProc; command: ["true"] }
    function silenceApp(key, display, appName, desktopEntry) {
        // Pass args positionally via `bash -c '...' _ a b c d` so values with
        // spaces/quotes don't need escaping.
        silenceProc.command = ["bash", "-c",
            "exec ~/.config/quickshell/notif-silence.sh add \"$1\" \"$2\" \"$3\" \"$4\"",
            "_", key || "", display || "", appName || "", desktopEntry || ""]
        silenceProc.running = false; silenceProc.running = true
    }
    function unsilenceApp(key) {
        silenceProc.command = ["bash", "-c",
            "exec ~/.config/quickshell/notif-silence.sh remove \"$1\"",
            "_", key || ""]
        silenceProc.running = false; silenceProc.running = true
    }

    // Resolve an icon for a notification record. Tries mako's own app_icon
    // first (path or themed name), then falls back to the bar's app-icon
    // resolver against desktop_entry/app_name. Returns "" if nothing matches —
    // delegate then shows a letter avatar.
    function notifIcon(rec) {
        if (!rec) return ""
        var ai = rec.app_icon || ""
        if (ai !== "") {
            if (ai.indexOf("/") === 0) return "file://" + ai
            var p = Quickshell.iconPath(ai, true)
            if (p !== "") return p
            p = Quickshell.iconPath(ai, false)
            if (p !== "") return p
        }
        var appId = rec.desktop_entry || rec.app_name || rec.display || rec.key || ""
        if (appId) {
            try {
                var r = bar.resolveAppIcon(appId, rec.summary || "")
                if (r) return r
            } catch (e) {}
        }
        return ""
    }

    Process { id: activateProc; command: ["true"] }
    function activateNotif(notifId, key) {
        if (notifId === undefined || notifId === null) return
        activateProc.command = ["bash", "-c",
            "exec ~/.config/quickshell/notif-activate.sh \"$1\" \"$2\"",
            "_", String(notifId), key || ""]
        activateProc.running = false; activateProc.running = true
    }
    Process { id: clearAllProc; command: ["true"] }
    function clearAllNotifs() {
        clearAllProc.command = ["bash", "-c",
            "exec ~/.config/quickshell/notif-clear.sh --all"]
        clearAllProc.running = false; clearAllProc.running = true
    }
    function clearAllSuppressed() {
        clearAllProc.command = ["bash", "-c",
            "exec ~/.config/quickshell/notif-clear.sh --suppressed"]
        clearAllProc.running = false; clearAllProc.running = true
    }

    // Sum unread counts for a given window class using the same fuzzy match
    // as workspaceBadgeCounts: case-insensitive substring either direction
    // (with a length>=3 guard to avoid 2-char false positives).
    function notifCountForClass(cls) {
        if (!cls) return 0
        var c = cls.toLowerCase()
        var counts = bar.notifCounts || {}
        var total = 0
        for (var k in counts) {
            var key = k.toLowerCase()
            if (!key) continue
            if (key.length >= 3 && c.indexOf(key) >= 0) { total += counts[k]; continue }
            if (c.length >= 3 && key.indexOf(c) >= 0) { total += counts[k]; continue }
        }
        return total
    }

    // Effective badge for a window class: Telegram uses its Unity total (incl
    // muted chats); everything else uses the mako unread count. muted == there
    // is a total but nothing unmuted (→ gray badge).
    function effectiveBadgeCount(cls) {
        if (cls && cls.toLowerCase().indexOf("telegram") >= 0) {
            var t = bar.tgVisible ? bar.tgCount : 0
            return t > 0 ? t : bar.tgUnmuted
        }
        return bar.notifCountForClass(cls)
    }
    function effectiveBadgeMuted(cls) {
        if (cls && cls.toLowerCase().indexOf("telegram") >= 0)
            return (bar.tgVisible ? bar.tgCount : 0) > 0 && bar.tgUnmuted <= 0
        return false
    }

    // Flat array of {app, count} — handy for diagnostics & for the
    // workspace badge sum below. Used only as a list of notif-bearing apps.
    readonly property var allBadges: {
        var badges = []
        var counts = bar.notifCounts || {}
        for (var k in counts) {
            // Telegram is handled below from its Unity total (incl muted), so
            // skip its mako entry here to avoid double-counting.
            if (counts[k] > 0 && k.toLowerCase().indexOf("telegram") < 0)
                badges.push({ app: k, count: counts[k], muted: false })
        }
        // Telegram: prefer the Unity total (incl muted chats); fall back to the
        // mako count if the bridge hasn't reported yet. muted == no unmuted.
        var tgTotal = (bar.tgVisible ? bar.tgCount : 0)
        if (tgTotal <= 0) tgTotal = bar.tgUnmuted
        if (tgTotal > 0)
            badges.push({ app: "org.telegram.desktop", count: tgTotal, muted: bar.tgUnmuted <= 0 })
        return badges
    }

    // Minimized windows — anything stashed on the special:minimized workspace
    // by ~/.config/hypr/minimize.sh (SUPER+scroll_down)
    property var minimizedWindows: []

    Process {
        id: minimizedProc
        command: ["bash", "-c",
        "hyprctl clients -j | jq -c '[.[] | select(.workspace.name == \"special:minimized\") | {address, title, appId: .class}]'"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                try { bar.minimizedWindows = JSON.parse(this.text) }
                catch(e) { bar.minimizedWindows = [] }
            }
        }
    }

    // Snappier polling than the 3s stat timer so the tray reacts ~immediately
    // when you scroll-minimize a window
    Timer {
        interval: 800; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { minimizedProc.running = true; windowsByWsProc.running = true }
    }

    // Map of workspace id -> list of window classes (lowercase). Used to compute
    // folder-style aggregate notification badges on each workspace dot.
    property var windowsByWs: ({})

    Process {
        id: windowsByWsProc
        command: ["bash", "-c",
        "hyprctl clients -j | jq -c '[.[] | select(.mapped == true and .hidden == false and .workspace.id > 0) | {ws: .workspace.id, cls: (.class | ascii_downcase)}] | group_by(.ws) | map({key: (.[0].ws | tostring), value: [.[].cls]}) | from_entries'"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                try { bar.windowsByWs = JSON.parse(this.text) }
                catch(e) { bar.windowsByWs = ({}) }
            }
        }
    }

    // For each workspace, sum unread counts of all notification-bearing apps
    // that have a window on that workspace. Folder-badge style (iOS folder
    // shows aggregate of all contained app badges).
    readonly property var workspaceBadgeCounts: {
        var counts = {}
        var badges = bar.allBadges
        if (badges.length === 0) return counts
        var map = bar.windowsByWs || {}
        for (var wsKey in map) {
            var classes = map[wsKey] || []
            var total = 0
            for (var k = 0; k < badges.length; k++) {
                var badge = badges[k]
                var bname = (badge.app || "").toLowerCase()
                if (!bname) continue
                for (var m = 0; m < classes.length; m++) {
                    var c = classes[m] || ""
                    if (c.indexOf(bname) >= 0 || (bname.length >= 3 && bname.indexOf(c) >= 0)) {
                        total += (badge.count || 0)
                        break
                    }
                }
            }
            if (total > 0) counts[wsKey] = total
        }
        return counts
    }

    // Per-workspace: true when EVERY badge-bearing app on that dot is muted-only
    // (Telegram muted with nothing unmuted, and no other notifying app). Drives
    // the gray badge color — "only muted notifications on this workspace".
    readonly property var workspaceBadgeMuted: {
        var res = {}
        var badges = bar.allBadges
        var map = bar.windowsByWs || {}
        for (var wsKey in map) {
            var classes = map[wsKey] || []
            var anyBadge = false, anyUnmuted = false
            for (var k = 0; k < badges.length; k++) {
                var bname = (badges[k].app || "").toLowerCase()
                if (!bname) continue
                for (var m = 0; m < classes.length; m++) {
                    var c = classes[m] || ""
                    if (c.indexOf(bname) >= 0 || (bname.length >= 3 && bname.indexOf(c) >= 0)) {
                        anyBadge = true
                        if (!badges[k].muted) anyUnmuted = true
                        break
                    }
                }
            }
            res[wsKey] = anyBadge && !anyUnmuted
        }
        return res
    }

    // Sink that the bar pill (icon, %, slider) drives. null → follow system default.
    property var barControlledSink: null
    // True once the user has explicitly chosen a sink in the volume popup; stops
    // the auto-picker from overriding their choice on the next sink change.
    property bool userPickedSink: false
    readonly property var audioSink: {
        if (barControlledSink && barControlledSink.audio && audioSinks.indexOf(barControlledSink) !== -1)
            return barControlledSink
        return Pipewire.defaultAudioSink
    }
    PwObjectTracker { objects: bar.audioSink ? [bar.audioSink] : [] }
    readonly property int volumePercent: audioSink && audioSink.audio ? Math.round(audioSink.audio.volume * 100) : 100
    readonly property bool audioMuted: audioSink && audioSink.audio ? audioSink.audio.muted : false

    readonly property var audioSinks: {
        var out = []
        var ns = Pipewire.nodes.values
        for (var i = 0; i < ns.length; i++) {
            var n = ns[i]
            if (n && n.isSink && !n.isStream && n.audio) out.push(n)
        }
        return out
    }
    PwObjectTracker { objects: bar.audioSinks }
    function sinkLabel(n) {
        if (!n) return ""
        return n.description || n.nickname || n.name || "Unknown sink"
    }
    function sinkBlob(s) {
        return ((s.description || "") + " " + (s.nickname || "") + " " + (s.name || "")).toLowerCase()
    }
    function autoPickSink() {
        // Respect an explicit choice from the popup — never override it.
        if (bar.userPickedSink) return
        var sinks = bar.audioSinks
        var pick = null
        // First pass: onboard Ryzen-family HD Audio Controller
        for (var i = 0; i < sinks.length && !pick; i++) {
            var b = sinkBlob(sinks[i])
            if ((b.indexOf("hd audio") !== -1 || b.indexOf("hd-audio") !== -1) &&
                (b.indexOf("family") !== -1 || b.indexOf("ryzen") !== -1 ||
                 b.indexOf("starship") !== -1 || b.indexOf("matisse") !== -1 ||
                 b.indexOf("vermeer") !== -1 || b.indexOf("raphael") !== -1))
                pick = sinks[i]
        }
        // Second pass: any onboard HD Audio that isn't HDMI
        for (var j = 0; j < sinks.length && !pick; j++) {
            var b2 = sinkBlob(sinks[j])
            if ((b2.indexOf("hd audio") !== -1 || b2.indexOf("hd-audio") !== -1) &&
                b2.indexOf("hdmi") === -1)
                pick = sinks[j]
        }
        // No "any analog" fallback — that grabbed whatever loaded first (often a
        // high-priority Bluetooth/USB speaker) and locked onto it. When nothing
        // onboard is found yet, leave it null so the bar follows the system
        // default; this re-runs as sinks appear and upgrades to onboard once seen.
        bar.barControlledSink = pick
    }
    onAudioSinksChanged: autoPickSink()
    Component.onCompleted: { autoPickSink(); publishSink() }

    // Publish the id of the sink the bar currently drives so the keyboard volume
    // keys (hypr/volume.sh) act on the same sink the popup selected, instead of
    // the system default. Only the primary bar writes the file to avoid races.
    Process { id: sinkPublish }
    function publishSink() {
        if (!isPrimary) return
        var id = bar.audioSink ? bar.audioSink.id : 0
        if (!id) return
        sinkPublish.command = ["sh", "-c", "printf '%s' " + id + " > \"$XDG_RUNTIME_DIR/quickshell-bar-sink\""]
        sinkPublish.running = true
    }
    onAudioSinkChanged: publishSink()

    // Static height — never changes, so bar never shifts
    anchors { bottom: true; left: true; right: true }
    implicitHeight: isPrimary ? 50 : 37
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell:bar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // ── Stat readers ──
    // Fast tick (1s): one cheap script dumps every counter we graph.
    Process {
        id: fastStatProc
        command: [bar.homeDir + "/.config/quickshell/sysmon.sh"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.split("\n")
            // Per-tick per-process disk I/O: collect, then diff after the loop.
            var currPio = {}
            // Defer disk/net bucket pushes until after pio lines are diffed
            // and the net top-app names are available.
            var pNetRx = 0, pNetTx = 0, hasNet = false
            var pDiskRd = 0, pDiskWr = 0, hasDisk = false
            for (var li = 0; li < lines.length; li++) {
                var p = lines[li].trim().split(/\s+/)
                if (p[0] === "pio") {
                    // pio PID COMM RBYTES WBYTES
                    if (p.length >= 5) currPio[p[1]] = [p[2], parseFloat(p[3]) || 0, parseFloat(p[4]) || 0]
                    continue
                }
                if (p[0] === "cpu") {
                    var idle = (parseInt(p[4]) || 0) + (parseInt(p[5]) || 0)
                    var total = 0
                    for (var i = 1; i <= 7; i++) total += parseInt(p[i]) || 0
                    if (bar.lastCpuTotal > 0) {
                        var dT = total - bar.lastCpuTotal, dI = idle - bar.lastCpuIdle
                        bar.cpuUsage = dT > 0 ? Math.round(100 * (1 - dI / dT)) : 0
                        bar.cpuHist = bar.pushHist(bar.cpuHist, bar.cpuUsage)
                    }
                    bar.lastCpuTotal = total; bar.lastCpuIdle = idle
                } else if (p[0] === "gpu") {
                    var g = parseInt(p[1])
                    if (!isNaN(g)) { bar.gpuUsage = g; bar.gpuHist = bar.pushHist(bar.gpuHist, g) }
                } else if (p[0] === "vram") {
                    var vu = parseFloat(p[1]) || 0, vt = parseFloat(p[2]) || 1
                    bar.vramUsedGB = vu / 1073741824
                    bar.vramTotalGB = vt / 1073741824
                    bar.vramUsage = Math.round(100 * vu / vt)
                    bar.vramHist = bar.pushHist(bar.vramHist, bar.vramUsage)
                } else if (p[0] === "mem") {
                    var mt = parseFloat(p[1]) || 1, ma = parseFloat(p[2]) || 0
                    bar.memUsage = Math.round(100 * (1 - ma / mt))
                    bar.memTotalGB = mt / 1048576
                    bar.memUsedGB = (mt - ma) / 1048576
                    bar.memHist = bar.pushHist(bar.memHist, bar.memUsage)
                } else if (p[0] === "swap") {
                    var su = parseFloat(p[1]) || 0, ssz = parseFloat(p[2]) || 1
                    bar.swapUsage = ssz > 0 ? Math.round(100 * su / ssz) : 0
                    bar.swapTotalGB = ssz / 1048576
                    bar.swapUsedGB = su / 1048576
                    bar.swapHist = bar.pushHist(bar.swapHist, bar.swapUsage)
                } else if (p[0] === "net") {
                    pNetRx = parseFloat(p[1]) || 0
                    pNetTx = parseFloat(p[2]) || 0
                    hasNet = true
                } else if (p[0] === "disk") {
                    pDiskRd = parseFloat(p[1]) || 0
                    pDiskWr = parseFloat(p[2]) || 0
                    hasDisk = true
                } else if (p[0] === "swapkind") {
                    if (p[1]) bar.swapLabel = p[1]
                }
            }

            // ── Disk: diff per-process counters to find top reader/writer ──
            var topR = 0, topW = 0, topRComm = "-", topWComm = "-"
            for (var pid in currPio) {
                var cur = currPio[pid]
                var prev = bar.prevPio[pid]
                if (!prev) continue
                var dr = cur[1] - prev[1]
                var dw = cur[2] - prev[2]
                if (dr > topR) { topR = dr; topRComm = cur[0] }
                if (dw > topW) { topW = dw; topWComm = cur[0] }
            }
            bar.prevPio = currPio

            if (hasDisk) {
                if (bar.lastDiskRd >= 0) {
                    bar.diskRdRate = Math.max(0, pDiskRd - bar.lastDiskRd) * 512
                    bar.diskWrRate = Math.max(0, pDiskWr - bar.lastDiskWr) * 512
                    var dh = bar.diskHist.slice()
                    dh.push({ a: bar.diskRdRate, b: bar.diskWrRate, aApp: topRComm, bApp: topWComm })
                    while (dh.length > bar.ioHistLen) dh.shift()
                    bar.diskHist = dh
                }
                bar.lastDiskRd = pDiskRd
                bar.lastDiskWr = pDiskWr
            }

            if (hasNet) {
                if (bar.lastNetRx >= 0) {
                    bar.netRxRate = Math.max(0, pNetRx - bar.lastNetRx)
                    bar.netTxRate = Math.max(0, pNetTx - bar.lastNetTx)
                    var nh = bar.netHist.slice()
                    // a = download (rx), b = upload (tx); top apps from shell.qml.
                    nh.push({ a: bar.netRxRate, b: bar.netTxRate,
                              aApp: bar.sharedNetTopDownComm,
                              bApp: bar.sharedNetTopUpComm })
                    while (nh.length > bar.ioHistLen) nh.shift()
                    bar.netHist = nh
                }
                bar.lastNetRx = pNetRx
                bar.lastNetTx = pNetTx
            }
        } }
    }
    Process { id: cpuTempProc; command: ["bash", "-c", "for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); case $n in k10temp|coretemp|zenpower|k8temp|cpu_thermal) [ -f $h/temp1_input ] && awk '{printf \"%.0f\", $1/1000}' $h/temp1_input && break;; esac; done"]; stdout: StdioCollector { onStreamFinished: { var v = parseInt(this.text.trim()); if (!isNaN(v)) bar.cpuTemp = v } } }
    Process { id: gpuTempProc; command: ["bash", "-c", "for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); case $n in amdgpu) f=$h/temp2_input; [ -f $f ] || f=$h/temp1_input; awk '{printf \"%.0f\", $1/1000}' $f && break;; i915|xe|nouveau) [ -f $h/temp1_input ] && awk '{printf \"%.0f\", $1/1000}' $h/temp1_input && break;; esac; done"]; stdout: StdioCollector { onStreamFinished: { var v = parseInt(this.text.trim()); if (!isNaN(v) && v > 10) bar.gpuTemp = v } } }
    Process { id: diskProc; command: ["bash", "-c", "df / --output=pcent | tail -1 | tr -d ' %'"]; stdout: StdioCollector { onStreamFinished: { var v = parseInt(this.text.trim()); if (!isNaN(v)) bar.diskFreePercent = 100 - v } } }

    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            var d = new Date()
            var month = ("0" + (d.getMonth() + 1)).slice(-2)
            var day = ("0" + d.getDate()).slice(-2)
            var year = d.getFullYear()
            var hours = d.getHours()
            var ampm = hours >= 12 ? "PM" : "AM"
            hours = hours % 12; if (hours === 0) hours = 12
            var mins = ("0" + d.getMinutes()).slice(-2)
            bar.clockText = month + "/" + day + "/" + year + "     " + hours + ":" + mins + " " + ampm
        }
    }
    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: fastStatProc.running = true
    }
    Timer {
        interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            cpuTempProc.running = true; gpuTempProc.running = true
            diskProc.running = true
        }
    }

    component Pill: Item {
        property color borderColor: "transparent"
        property bool filled: false
        property bool flatTop: false
        default property alias content: innerContent.data
            Rectangle {
                anchors.fill: parent
                radius: bar.rad
                topLeftRadius: parent.flatTop ? 0 : bar.rad
                topRightRadius: parent.flatTop ? 0 : bar.rad
                color: parent.borderColor
                Behavior on topLeftRadius { NumberAnimation { duration: 280; easing.type: Easing.InOutCubic } }
                Behavior on topRightRadius { NumberAnimation { duration: 280; easing.type: Easing.InOutCubic } }
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: parent.filled ? 0 : bar.bw
                readonly property int innerRad: parent.filled ? bar.rad : Math.max(0, bar.rad - bar.bw)
                radius: innerRad
                topLeftRadius: parent.flatTop ? 0 : innerRad
                topRightRadius: parent.flatTop ? 0 : innerRad
                color: parent.filled
                    ? Qt.rgba(parent.borderColor.r, parent.borderColor.g, parent.borderColor.b, 1.0)
                    : Qt.rgba(0, 0, 0, 0.72)
                Behavior on topLeftRadius { NumberAnimation { duration: 280; easing.type: Easing.InOutCubic } }
                Behavior on topRightRadius { NumberAnimation { duration: 280; easing.type: Easing.InOutCubic } }
            }
            Item { id: innerContent; anchors.fill: parent }
    }

    // ── System-monitor palette: pulled from the bar's blue→pink ramp ──
    readonly property color cpuColor:  lerpColor(0.05)
    readonly property color gpuColor:  lerpColor(0.125)
    readonly property color vramColor: lerpColor(0.20)
    readonly property color memColor:  lerpColor(0.275)
    readonly property color swapColor: lerpColor(0.35)
    readonly property color netColor:  lerpColor(0.425)
    readonly property color diskColor: lerpColor(0.50)

    // Circular usage meter — full-height ring drawn in a single solid colour
    // (`fg`): a thin full-circle track plus a thick progress arc, no opacity
    // tricks. Usage % sits in the centre of the ring; title (and optional
    // second line, e.g. temp) sit to the side at the same size/colour.
    component Ring: RowLayout {
        id: ring
        property real value: 0
        property string title: ""
        property string sub: ""
        property color fg: "#000000"
        spacing: isPrimary ? 5 : 3

        property real displayValue: value
        Behavior on displayValue { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

        Item {
            id: ringBox
            Layout.fillHeight: true
            Layout.preferredWidth: height
            onWidthChanged: ringCanvas.requestPaint()
            onHeightChanged: ringCanvas.requestPaint()

            Canvas {
                id: ringCanvas
                anchors.centerIn: parent
                readonly property int d: Math.min(parent.width, parent.height) - (isPrimary ? 3 : 2)
                width: d > 0 ? d : 1
                height: d > 0 ? d : 1
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var cx = width / 2, cy = height / 2
                    var prog = isPrimary ? 3.5 : 2.5
                    var r = width / 2 - prog / 2 - 0.5
                    if (r < 1) return
                    // thin full-circle track (same colour, lighter line weight)
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, 0, Math.PI * 2)
                    ctx.strokeStyle = ring.fg
                    ctx.lineWidth = 1
                    ctx.stroke()
                    // thick progress arc on top
                    var frac = Math.max(0, Math.min(100, ring.displayValue)) / 100
                    if (frac > 0.001) {
                        ctx.beginPath()
                        ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac)
                        ctx.strokeStyle = ring.fg
                        ctx.lineWidth = prog
                        ctx.lineCap = "round"
                        ctx.stroke()
                    }
                }
            }
            Text {
                anchors.centerIn: ringCanvas
                text: Math.round(ring.displayValue)
                color: ring.fg
                font.pixelSize: isPrimary ? 13 : 10
                font.family: bar.fontFamily
            }
        }
        Column {
            Layout.alignment: Qt.AlignVCenter
            spacing: -1
            Text {
                text: ring.title
                color: ring.fg
                font.pixelSize: isPrimary ? 11 : 9
                font.family: bar.fontFamily
            }
            Text {
                text: ring.sub
                visible: ring.sub !== ""
                color: ring.fg
                font.pixelSize: isPrimary ? 11 : 9
                font.family: bar.fontFamily
            }
        }
        onDisplayValueChanged: ringCanvas.requestPaint()
        onFgChanged: ringCanvas.requestPaint()
        Component.onCompleted: ringCanvas.requestPaint()
    }

    // Scrolling sparkline — two solid-line series in contrasting colours
    // (`fg` and `fg2`). Newest sample pinned to the right edge. Labels carry
    // the live rates, coloured to match their line.
    component IoChart: Item {
        id: chart
        property var history: []
        property string labelA: ""
        property string labelB: ""
        property color fg: "#000000"
        property color fg2: "#D4D4DC"
        readonly property int chartW: isPrimary ? 64 : 48
        // Pinned so big rates ("234M ↑99M") don't stretch the bar; labels
        // elide instead of growing the surrounding layout.
        implicitWidth: chartW

        ColumnLayout {
            anchors.fill: parent
            spacing: 1

            Canvas {
                id: chartCanvas
                Layout.fillHeight: true
                Layout.fillWidth: true
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var h = chart.history, n = h.length
                    if (n < 2) return
                    var mx = 1
                    for (var i = 0; i < n; i++) {
                        if (h[i].a > mx) mx = h[i].a
                        if (h[i].b > mx) mx = h[i].b
                    }
                    var stepX = width / (bar.ioHistLen - 1)
                    var x0 = width - (n - 1) * stepX
                    var span = height - 2
                    ctx.lineWidth = isPrimary ? 1.8 : 1.4
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    ctx.strokeStyle = chart.fg
                    ctx.beginPath()
                    for (i = 0; i < n; i++) {
                        var ya = height - (h[i].a / mx) * span - 1
                        if (i) ctx.lineTo(x0 + i * stepX, ya); else ctx.moveTo(x0 + i * stepX, ya)
                    }
                    ctx.stroke()
                    ctx.strokeStyle = chart.fg2
                    ctx.beginPath()
                    for (i = 0; i < n; i++) {
                        var yb = height - (h[i].b / mx) * span - 1
                        if (i) ctx.lineTo(x0 + i * stepX, yb); else ctx.moveTo(x0 + i * stepX, yb)
                    }
                    ctx.stroke()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                spacing: isPrimary ? 4 : 3
                clip: true
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    text: chart.labelA
                    elide: Text.ElideRight
                    color: chart.fg
                    font.pixelSize: isPrimary ? 9 : 7
                    font.family: bar.fontFamily
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignLeft
                    text: chart.labelB
                    elide: Text.ElideRight
                    color: chart.fg2
                    font.pixelSize: isPrimary ? 9 : 7
                    font.family: bar.fontFamily
                }
            }
        }
        onHistoryChanged: chartCanvas.requestPaint()
    }

    // One section of the long system-monitor bar: wraps a Ring/IoChart, reports
    // hover so the detail popup can open against it.
    component MonCell: Item {
        id: cell
        property string monKey: ""
        default property alias content: cellContent.data
        Layout.fillHeight: true
        implicitWidth: (cellContent.children.length > 0
                        ? cellContent.children[0].implicitWidth : 0) + (isPrimary ? 14 : 9)
        Item { id: cellContent; anchors.fill: parent }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: {
                var pt = cell.mapToItem(null, cell.width / 2, 0)
                bar.hoveredMonX = Math.round(pt.x)
                bar.hoveredMon = cell.monKey
            }
            onExited: { if (bar.hoveredMon === cell.monKey) bar.hoveredMon = "" }
        }
    }

    // Hairline divider between sections of the long monitor bar.
    component MonSep: Rectangle {
        Layout.fillHeight: true
        Layout.topMargin: isPrimary ? 8 : 6
        Layout.bottomMargin: isPrimary ? 8 : 6
        implicitWidth: 1
        color: Qt.rgba(0, 0, 0, 0.28)
    }

    // Larger history graph for the detail popups. `data` is an array of numbers
    // (single series) or {a,b} objects (dual). `fixedMax > 0` pins the Y scale.
    // `autoScaledMax` mirrors the autoscale formula so a sibling icon overlay
    // can map sample values to the same y-coordinates.
    // Returns an icon path only if the icon actually exists in the theme.
    // The bool arg to Quickshell.iconPath is "check": true verifies and
    // returns empty for missing icons; false returns a placeholder URL
    // that loads as the magenta/black "missing texture" box. We need true.
    function strictIconPath(app) {
        if (!app || app === "-") return ""
        var p = Quickshell.iconPath(app, true)
        if (p !== "") return p
        var lower = app.toLowerCase()
        if (lower !== app) {
            p = Quickshell.iconPath(lower, true)
            if (p !== "") return p
        }
        if (bar.iconCacheReady) {
            if (bar.iconCache[app]) {
                p = Quickshell.iconPath(bar.iconCache[app], true)
                if (p !== "") return p
            }
            if (bar.iconCache[lower]) {
                p = Quickshell.iconPath(bar.iconCache[lower], true)
                if (p !== "") return p
            }
        }
        return ""
    }

    // Stable hue from a comm name, so the chip fallback for the same app
    // is always the same color across reloads. Saturation/lightness picked
    // to stay readable on both dark and light popup backgrounds.
    function commColor(comm) {
        if (!comm || comm === "-") return Qt.rgba(0.4, 0.4, 0.4, 1.0)
        var h = 0
        for (var i = 0; i < comm.length; i++) h = ((h * 31) + comm.charCodeAt(i)) | 0
        var hue = (Math.abs(h) % 360) / 360
        return Qt.hsla(hue, 0.55, 0.48, 1.0)
    }
    function monGraphAutoMax(data, dual, fixedMax, seriesPick) {
        if (fixedMax > 0) return fixedMax
        var n = data ? data.length : 0, m = 1
        for (var i = 0; i < n; i++) {
            var va, vb
            if (seriesPick === "a")      { va = data[i].a || 0; vb = 0 }
            else if (seriesPick === "b") { va = data[i].b || 0; vb = 0 }
            else {
                va = dual ? (data[i].a || 0) : data[i]
                vb = dual ? (data[i].b || 0) : 0
            }
            if (va > m) m = va
            if (vb > m) m = vb
        }
        return m
    }
    component MonGraph: Canvas {
        id: mg
        property var data: []
        property bool dual: false
        // When set, draws only one series from {a,b} samples. "" → use the
        // older single-array-of-numbers shape (cpu/mem/etc).
        property string seriesPick: ""
        property color stroke: "#000000"
        property color stroke2: "#D4D4DC"
        property real fixedMax: 0
        onDataChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onSeriesPickChanged: requestPaint()
        onDualChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var d = mg.data, n = d ? d.length : 0
            if (n < 2) return
            var pick = mg.seriesPick
            function va(i) {
                if (pick === "a") return d[i].a || 0
                if (pick === "b") return d[i].b || 0
                return mg.dual ? (d[i].a || 0) : d[i]
            }
            function vb(i) {
                if (pick === "a" || pick === "b") return 0
                return mg.dual ? (d[i].b || 0) : 0
            }
            var mx = mg.fixedMax > 0 ? mg.fixedMax : 1
            if (mg.fixedMax <= 0) {
                for (var ai = 0; ai < n; ai++) {
                    var va0 = va(ai), vb0 = vb(ai)
                    if (va0 > mx) mx = va0
                    if (vb0 > mx) mx = vb0
                }
            }
            var stepX = width / (bar.ioHistLen - 1)
            var x0 = width - (n - 1) * stepX
            var span = height - 2
            ctx.lineWidth = 1.8
            ctx.lineJoin = "round"; ctx.lineCap = "round"
            ctx.strokeStyle = mg.stroke
            ctx.beginPath()
            for (var ia = 0; ia < n; ia++) {
                var ya = height - (va(ia) / mx) * span - 1
                if (ia) ctx.lineTo(x0 + ia * stepX, ya); else ctx.moveTo(x0 + ia * stepX, ya)
            }
            ctx.stroke()
            if (mg.dual && pick === "") {
                ctx.strokeStyle = mg.stroke2
                ctx.beginPath()
                for (var ib = 0; ib < n; ib++) {
                    var yb = height - (vb(ib) / mx) * span - 1
                    if (ib) ctx.lineTo(x0 + ib * stepX, yb); else ctx.moveTo(x0 + ib * stepX, yb)
                }
                ctx.stroke()
            }
        }
    }

    Process { id: wlogoutLauncher; command: ["wlogout"] }
    Process { id: pavucontrolLauncher; command: ["pavucontrol"] }

    // Launcher panel state
    property bool launcherOpen: false
    // Re-scan DDC monitors each time the menu opens. `ddcutil detect` only sees
    // monitors that are powered on, and Hyprland drops/re-adds outputs when a
    // monitor is switched off overnight — which can leave the one-shot startup
    // scan stuck on a single slider. By the time the menu is opened the displays
    // are long awake, so this picks up every monitor without any timing guess.
    onLauncherOpenChanged: if (launcherOpen && !ddcDetectProc.running) ddcDetectProc.running = true
    // System-monitor hover detail popup state
    property string hoveredMon: ""
    property int hoveredMonX: 0
    // Volume right-click menu state
    property bool volMenuOpen: false
    // Clock calendar popup state
    property bool clockMenuOpen: false
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()
    function calStep(delta) {
        var m = bar.calMonth + delta
        var y = bar.calYear
        while (m < 0) { m += 12; y -= 1 }
        while (m > 11) { m -= 12; y += 1 }
        bar.calMonth = m; bar.calYear = y
    }
    function calToday() {
        var n = new Date()
        bar.calMonth = n.getMonth(); bar.calYear = n.getFullYear()
    }
    function openClockMenu() {
        if (bar.clockMenuOpen) { bar.closeClockMenu(); return }
        bar.calToday()
        var p = clockPill.mapToItem(null, clockPill.width / 2, 0)
        clockMenuPanel.anchorX = Math.round(p.x)
        bar.clockMenuOpen = true
    }
    function closeClockMenu() {
        bar.clockMenuOpen = false
    }

    // Notification tray popup state — 0 = Active, 1 = Silenced
    property bool notifMenuOpen: false
    property int notifMenuTab: 0
    function openNotifMenu() {
        if (bar.notifMenuOpen) { bar.closeNotifMenu(); return }
        var p = notifPill.mapToItem(null, notifPill.width / 2, 0)
        notifMenuPanel.anchorX = Math.round(p.x)
        bar.notifMenuOpen = true
    }
    function closeNotifMenu() {
        bar.notifMenuOpen = false
    }

    // ══════════════════════════════════════════════
    // LEFT SIDE
    // ══════════════════════════════════════════════
    RowLayout {
        id: leftSection
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        spacing: bar.hm

        Pill {
            borderColor: bar.borderDrawer; filled: true
            flatTop: bar.launcherOpen
            Layout.preferredWidth: isPrimary ? 42 : 32; Layout.preferredHeight: parent.height - bar.vm * 2; Layout.leftMargin: bar.hm
            Text {
                id: hamburgerIcon
                anchors.centerIn: parent
                text: String.fromCodePoint(0xEB94)
                color: bar.contrastText(bar.borderDrawer)
                font.pixelSize: isPrimary ? 20 : 15
                font.family: bar.fontFamily
                rotation: bar.launcherOpen ? 90 : 0
                scale: bar.launcherOpen ? 1.15 : 1.0
                Behavior on rotation { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            }
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor;
                onClicked: function(mouse) {
                    if (Date.now() - bar.lastMenuCloseTime < 150) return;
                    if (bar.launcherOpen) {
                        bar.closeLauncher();
                    } else {
                        bar.launcherOpen = true;
                    }
                }
            }
        }

        // \u2500\u2500 System monitor: one long gradient bar, a hover popup per stat \u2500\u2500
        Rectangle {
            id: sysMon
            Layout.preferredWidth: sysMonRow.implicitWidth + (isPrimary ? 10 : 6)
            Layout.preferredHeight: parent.height - bar.vm * 2
            radius: bar.rad
            readonly property color fg: bar.contrastText(bar.lerpColor(0.275))
            readonly property color fg2: bar.contrastAlt(bar.lerpColor(0.275))
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: bar.lerpColor(0.05) }
                GradientStop { position: 1.0; color: bar.lerpColor(0.50) }
            }

            RowLayout {
                id: sysMonRow
                anchors.fill: parent
                anchors.leftMargin: isPrimary ? 6 : 4
                anchors.rightMargin: isPrimary ? 6 : 4
                spacing: 0

                MonCell {
                    monKey: "cpu"
                    Ring {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        value: bar.cpuUsage; title: "CPU"; sub: bar.cpuTemp + "\u00B0"
                        fg: sysMon.fg
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "gpu"
                    Ring {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        value: bar.gpuUsage; title: "GPU"; sub: bar.gpuTemp + "\u00B0"
                        fg: sysMon.fg
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "vram"
                    Ring {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        value: bar.vramUsage; title: "VRAM"
                        fg: sysMon.fg
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "mem"
                    Ring {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        value: bar.memUsage; title: "MEM"
                        fg: sysMon.fg
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "zram"
                    Ring {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        value: bar.swapUsage; title: bar.swapLabel
                        fg: sysMon.fg
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "net"
                    IoChart {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        history: bar.netHist
                        fg: sysMon.fg
                        fg2: sysMon.fg2
                        labelA: "\u2193" + bar.fmtRate(bar.netRxRate)
                        labelB: "\u2191" + bar.fmtRate(bar.netTxRate)
                    }
                }
                MonSep {}
                MonCell {
                    monKey: "disk"
                    IoChart {
                        anchors.centerIn: parent
                        height: parent.height - (isPrimary ? 4 : 3)
                        history: bar.diskHist
                        fg: sysMon.fg
                        fg2: sysMon.fg2
                        labelA: "R " + bar.fmtRate(bar.diskRdRate)
                        labelB: "W " + bar.fmtRate(bar.diskWrRate)
                    }
                }
            }
        }

        // ── App launchers ──
        Rectangle {
            Layout.preferredWidth: appLauncherRow.implicitWidth + (isPrimary ? 16 : 10)
            Layout.preferredHeight: parent.height - bar.vm * 2
            color: Qt.rgba(0, 0, 0, 0.65); radius: bar.rad
            readonly property int appCount: bar.appPins.length

            RowLayout {
                id: appLauncherRow; anchors.centerIn: parent; spacing: 0
                Repeater {
                    model: bar.appPins
                    delegate: Item {
                        id: launcherItem
                        required property var modelData
                        required property int index
                        readonly property real gradientT: parent.parent.appCount > 1 ? index / (parent.parent.appCount - 1) : 0.5
                        readonly property color iconTint: bar.lerpColor(gradientT)
                        Layout.preferredWidth: isPrimary ? 38 : 28
                        Layout.preferredHeight: isPrimary ? 38 : 28

                        Image {
                            id: launcherIcon; anchors.centerIn: parent
                            width: isPrimary ? 28 : 20; height: width
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: isPrimary ? 64 : 48; sourceSize.height: isPrimary ? 64 : 48
                            mipmap: true
                            source: {
                                if (modelData.imgPath !== "") return modelData.imgPath
                                    if (modelData.icon === "") return ""
                                        var p = Quickshell.iconPath(modelData.icon, true)
                                        return p !== "" ? p : Quickshell.iconPath(modelData.icon, false)
                            }
                            visible: false; smooth: true; layer.enabled: true
                        }
                        ShaderEffect {
                            anchors.centerIn: parent; width: launcherIcon.width; height: launcherIcon.height
                            visible: modelData.nerdGlyph === "" && launcherIcon.status === Image.Ready
                            property var source: launcherIcon
                            property real tintR: launcherItem.iconTint.r
                            property real tintG: launcherItem.iconTint.g
                            property real tintB: launcherItem.iconTint.b
                            fragmentShader: "tint.frag.qsb"
                        }
                        Text {
                            anchors.centerIn: parent; visible: modelData.nerdGlyph !== ""
                            text: modelData.nerdGlyph; color: launcherItem.iconTint
                            font.pixelSize: isPrimary ? 20 : 15; font.family: bar.fontFamily
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: modelData.nerdGlyph === "" && launcherIcon.status !== Image.Ready
                            text: modelData.icon !== "" ? modelData.icon[0].toUpperCase() : "?"
                            color: launcherItem.iconTint
                            font.pixelSize: isPrimary ? 14 : 11; font.family: bar.fontFamily; font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor; hoverEnabled: true
                            onClicked: Hyprland.dispatch("exec " + modelData.cmd)
                            onEntered: launcherItem.scale = 1.2; onExited: launcherItem.scale = 1.0
                        }
                        Behavior on scale { NumberAnimation { duration: 100 } }
                    }
                }
            }
        }
    }


    // Delayed window focus — waits for carousel to finish
    Timer {
        id: focusDelayTimer
        property string windowAddr: ""
        interval: 1200; repeat: false
        onTriggered: {
            if (windowAddr !== "")
                Hyprland.dispatch("focuswindow address:" + windowAddr)
                windowAddr = ""
        }
    }


    // ══════════════════════════════════════════════
    // CENTER: workspace dots + preview
    // ══════════════════════════════════════════════

    property int hoveredWsId: -1
    property int lastHoveredWsId: -1
    property bool previewOpen: false
    property var wsLayoutData: []
    property color hoveredDotColor: colorEmpty
    property real hoveredDotGlobalX: 0
    property string hoveredDotState: ""

    Process {
        id: layoutProc
        command: [bar.homeDir + "/.config/hypr/workspace-layout.sh", bar.hoveredWsId.toString()]
        stdout: StdioCollector {
            onStreamFinished: {
                try { bar.wsLayoutData = JSON.parse(this.text) }
                catch(e) { bar.wsLayoutData = [] }
            }
        }
    }

    // Refresh layout while preview is open
    Timer {
        interval: 1500; repeat: true
        running: bar.previewOpen && bar.hoveredWsId > 0
        onTriggered: layoutProc.running = true
    }

    // ── Dots container (normal, inside the bar) ──
    Rectangle {
        id: dotsContainer
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height - (isPrimary ? 6 : 4)
        width: dotsRow.implicitWidth + (isPrimary ? 16 : 10)
        color: Qt.rgba(0, 0, 0, 0.65); radius: isPrimary ? 14 : 12

        RowLayout {
            id: dotsRow; anchors.centerIn: parent; spacing: 0
            Repeater {
                model: bar.workspaceCeiling
                delegate: Item {
                    id: dotDelegate
                    required property int index
                    readonly property int wsId: index + 1
                    readonly property var wsObj: {
                        var all = Hyprland.workspaces.values
                        for (var i = 0; i < all.length; i++) {
                            if (all[i].id === wsId) return all[i]
                        }
                        return null
                    }
                    readonly property bool isFocused: wsObj ? wsObj.focused : false
                    readonly property bool isActive: wsObj ? wsObj.active : false
                    readonly property bool hasWindows: wsObj ? wsObj.toplevels.values.length > 0 : false
                    readonly property string dotState: {
                        if (isFocused) return "focused"
                            if (isActive) return "visible"
                                if (hasWindows) return "occupied"
                                    return "empty"
                    }
                    readonly property color dotColor: {
                        if (dotState === "focused") return bar.colorFocused
                            if (dotState === "visible") return bar.colorVisible
                                if (dotState === "occupied") return bar.colorOccupied
                                    return bar.colorEmpty
                    }
                    Layout.preferredWidth: isPrimary ? 28 : 22
                    Layout.preferredHeight: isPrimary ? 36 : 28

                    Text {
                        id: dotText
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: dotDelegate.dotState === "focused" ? (isPrimary ? -6 : -4) : 0
                        text: {
                            if (dotDelegate.dotState === "empty") return "\u25C7"       // hollow diamond
                                if (dotDelegate.dotState === "focused") return "\u25CF"     // filled circle
                                    if (dotDelegate.dotState === "visible") return "\u25CF"     // filled circle
                                        return "\u25C6"                                              // filled diamond (occupied)
                        }
                        color: dotDelegate.dotColor
                        font.pixelSize: {
                            if (dotDelegate.dotState === "focused") return isPrimary ? 22 : 18
                                return isPrimary ? 20 : 16
                        }
                        font.family: bar.fontFamily
                        scale: {
                            if (bar.hoveredWsId === dotDelegate.wsId && bar.previewOpen) return 1.5
                                if (dotDelegate.dotState === "focused") return 1.3
                                    return 1.0
                        }
                        opacity: 1.0
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    }

                    // Folder-style aggregate notification badge — counts unread
                    // across every app with a window on this workspace
                    Rectangle {
                        readonly property int badgeCount: bar.workspaceBadgeCounts[dotDelegate.wsId.toString()] || 0
                        readonly property bool badgeMuted: bar.workspaceBadgeMuted[dotDelegate.wsId.toString()] || false
                        visible: badgeCount > 0
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: isPrimary ? 2 : 1
                        anchors.rightMargin: isPrimary ? -2 : -1
                        width: Math.max(dotBadgeText.implicitWidth + (isPrimary ? 6 : 4), isPrimary ? 16 : 12)
                        height: isPrimary ? 14 : 11
                        radius: height / 2
                        color: badgeMuted ? Qt.rgba(0.42, 0.44, 0.5, 0.92) : bar.gradientEnd
                        border.color: Qt.rgba(0, 0, 0, 0.6); border.width: 1
                        z: 2
                        Text {
                            id: dotBadgeText
                            anchors.centerIn: parent
                            text: parent.badgeCount > 99 ? "99+" : parent.badgeCount.toString()
                            color: bar.contrastText(parent.color)
                            font.pixelSize: isPrimary ? 9 : 7
                            font.bold: true
                            font.family: bar.fontFamily
                        }
                    }

                    Timer {
                        id: hoverDelay
                        interval: 300; repeat: false
                        onTriggered: {
                            // Restore dot color before opening preview — so when the dot
                            // becomes visible again later, it won't flash the highlight
                            dotText.color = Qt.binding(function() { return dotDelegate.dotColor })
                            var mapped = dotDelegate.mapToItem(null, dotDelegate.width / 2, 0)
                            bar.hoveredDotGlobalX = mapped.x
                            bar.hoveredDotColor = dotDelegate.dotColor
                            bar.hoveredDotState = dotDelegate.dotState
                            bar.hoveredWsId = dotDelegate.wsId
                            bar.wsLayoutData = []
                            layoutProc.running = true
                            bar.previewOpen = true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: {
                            bar.lastHoveredWsId = -1
                            wsPreviewPopup.closePreview()
                            root.workspaceGoto(dotDelegate.wsId, bar.hyprMon ? bar.hyprMon.id : 0)
                        }
                        onEntered: {
                            if (bar.previewOpen) {
                                // Switch preview instantly — no highlight on the dot
                                hoverDelay.stop()
                                var mapped = dotDelegate.mapToItem(null, dotDelegate.width / 2, 0)
                                bar.hoveredDotGlobalX = mapped.x
                                bar.hoveredDotColor = dotDelegate.dotColor
                                bar.hoveredDotState = dotDelegate.dotState
                                bar.hoveredWsId = dotDelegate.wsId
                                bar.wsLayoutData = []
                                layoutProc.running = true
                            } else {
                                dotText.color = "#F8F8F2"
                                hoverDelay.start()
                            }
                        }
                        onExited: {
                            dotText.color = Qt.binding(function() { return dotDelegate.dotColor })
                            hoverDelay.stop()
                        }
                    }
                }
            }
        }
    }

    // Hover bridge — sits above the dots container, catches mouse traveling to popup
    MouseArea {
        id: dotsBridge
        visible: bar.previewOpen
        anchors.horizontalCenter: dotsContainer.horizontalCenter
        anchors.bottom: dotsContainer.top
        width: dotsContainer.width + 60
        height: isPrimary ? 10 : 8
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    // ── Preview popup (tag shape — grows from dot) ──
    PopupWindow {
        id: wsPreviewPopup
        anchor.window: bar
        anchor.rect.x: bar.hoveredDotGlobalX - prevW / 2
        anchor.rect.y: -(prevH + tagTailH - tailOverlap) + (bar.hoveredDotState === "focused" ? (isPrimary ? -6 : -4) : 0)

        readonly property int prevW: isPrimary ? 300 : 230
        readonly property int prevH: isPrimary ? 170 : 130
        readonly property int tagTailH: isPrimary ? 58 : 44
        readonly property int tailOverlap: isPrimary ? 34 : 24
        readonly property int bdr: isPrimary ? 3 : 2
        readonly property int cardRadius: isPrimary ? 10 : 8
        readonly property int dotSize: isPrimary ? 22 : 16

        implicitWidth: prevW
        implicitHeight: prevH + tagTailH
        visible: bar.previewOpen || closeAnim.running
        color: "transparent"

        // Input mask: only the card area accepts clicks, tail is click-through to bar
        mask: Region {
            item: cardInputRegion
        }

        Item {
            id: cardInputRegion
            x: 0; y: 0
            width: wsPreviewPopup.prevW
            height: wsPreviewPopup.prevH
        }

        property bool showContent: bar.previewOpen
        property int hovWsId: bar.hoveredWsId
        property int hovMonId: bar.hyprMon ? bar.hyprMon.id : 0

        function closePreview() {
            bar.previewOpen = false
            bar.hoveredWsId = -1
            bar.wsLayoutData = []
        }

        property string pendingFocusAddr: ""
        property alias focusTimer: _focusTimer
        Timer {
            id: _focusTimer
            interval: 1200; repeat: false
            onTriggered: {
                if (wsPreviewPopup.pendingFocusAddr !== "")
                    Hyprland.dispatch("focuswindow address:" + wsPreviewPopup.pendingFocusAddr)
                    wsPreviewPopup.pendingFocusAddr = ""
            }
        }

        Timer {
            id: closeAnim
            interval: 520
            onTriggered: { running = false; bar.lastHoveredWsId = -1 }
        }

        MouseArea {
            id: popupMouseTracker
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            propagateComposedEvents: true
        }

        // ── The tag: fluid grow from dot ──
        Item {
            id: tagShape
            anchors.fill: parent
            visible: wsPreviewPopup.showContent || closeAnim.running

            property real liquidProgress: wsPreviewPopup.showContent ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 500; easing.type: Easing.InOutCubic } }

            // ── 1. Tag visual shape (source texture) ──
            Item {
                id: tagSourceItem
                anchors.fill: parent

                // Card border
                Rectangle {
                    id: cardOuter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: wsPreviewPopup.prevH
                    radius: wsPreviewPopup.cardRadius
                    color: bar.hoveredDotColor
                    Behavior on color { ColorAnimation { duration: 150 } }

                    // Dark inner
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: wsPreviewPopup.bdr
                        radius: Math.max(0, parent.radius - wsPreviewPopup.bdr)
                        color: Qt.rgba(0.06, 0.06, 0.08, 0.95)
                    }
                }

                // Stem
                Canvas {
                    id: tagTail
                    anchors.top: cardOuter.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    height: wsPreviewPopup.tagTailH

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        var col = bar.hoveredDotColor.toString()
                        var cx = width / 2
                        var topW = wsPreviewPopup.prevW
                        var dotR = wsPreviewPopup.dotSize / 2
                        var h = height
                        if (h < 2) return
                            var mouthW = topW * 0.85
                            var isDiamond = (bar.hoveredDotState === "occupied" || bar.hoveredDotState === "empty")
                            ctx.fillStyle = col
                            ctx.beginPath()
                            ctx.moveTo(cx - mouthW / 2, 0)
                            ctx.lineTo(cx + mouthW / 2, 0)
                            ctx.bezierCurveTo(cx + mouthW * 0.15, 0, cx + dotR, h * 0.12, cx + dotR, h - dotR)
                            if (isDiamond) {
                                // Diamond bottom
                                ctx.lineTo(cx, h)
                                ctx.lineTo(cx - dotR, h - dotR)
                            } else {
                                // Circle bottom
                                ctx.arc(cx, h - dotR, dotR, 0, Math.PI, false)
                            }
                            ctx.bezierCurveTo(cx - dotR, h * 0.12, cx - mouthW * 0.15, 0, cx - mouthW / 2, 0)
                            ctx.closePath()
                            ctx.fill()
                    }

                    Connections {
                        target: bar
                        function onHoveredDotColorChanged() { tagTail.requestPaint() }
                        function onHoveredDotStateChanged() { tagTail.requestPaint() }
                    }
                    Component.onCompleted: requestPaint()
                }
            }

            // ── 2. Liquid mask (procedural rising fill) ──
            ShaderEffect {
                id: liquidMaskEffect
                anchors.fill: parent
                fragmentShader: "liquidmask.frag.qsb"
                property real progress: tagShape.liquidProgress
                property real totalH: wsPreviewPopup.prevH + wsPreviewPopup.tagTailH
                property real seed: Math.random() * 100
            }

            // ── 3. Combined: tag shape × liquid mask ──
            ShaderEffect {
                id: combinedEffect
                anchors.fill: parent
                fragmentShader: "combine.frag.qsb"
                property var src: ShaderEffectSource { sourceItem: tagSourceItem; hideSource: true }
                property var mask: ShaderEffectSource { sourceItem: liquidMaskEffect; hideSource: true }
            }

            // ── 4. Workspace content overlay ──
            Item {
                id: wsAreaClip
                x: wsPreviewPopup.bdr
                y: wsPreviewPopup.bdr
                width: wsPreviewPopup.prevW - wsPreviewPopup.bdr * 2
                height: wsPreviewPopup.prevH - wsPreviewPopup.bdr * 2
                clip: true
                opacity: tagShape.liquidProgress > 0.5 ? (tagShape.liquidProgress - 0.5) / 0.5 : 0.0

                Rectangle {
                    id: wsArea
                    anchors.fill: parent
                    radius: Math.max(0, wsPreviewPopup.cardRadius - wsPreviewPopup.bdr)
                    color: "transparent"
                    clip: true

                    Text {
                        anchors.centerIn: parent
                        visible: bar.wsLayoutData.length === 0 && bar.previewOpen
                        text: "Workspace " + bar.hoveredWsId
                        color: bar.colDim
                        font.pixelSize: isPrimary ? 12 : 10
                        font.family: bar.fontFamily
                    }

                    Repeater {
                        model: bar.wsLayoutData.length
                        delegate: Item {
                            id: winItem
                            required property int index
                            readonly property var winData: bar.wsLayoutData[index]
                            readonly property real areaW: wsArea.width
                            readonly property real areaH: wsArea.height
                            readonly property var bounds: {
                                var minX = 99999, minY = 99999, maxX = 0, maxY = 0
                                for (var i = 0; i < bar.wsLayoutData.length; i++) {
                                    var w = bar.wsLayoutData[i]
                                    if (w.x < minX) minX = w.x
                                        if (w.y < minY) minY = w.y
                                            if (w.x + w.w > maxX) maxX = w.x + w.w
                                                if (w.y + w.h > maxY) maxY = w.y + w.h
                                }
                                return { minX: minX, minY: minY, totalW: maxX - minX, totalH: maxY - minY }
                            }
                            readonly property real pad: 4
                            readonly property real scaleX: bounds.totalW > 0 ? (areaW - pad * 2) / bounds.totalW : 1
                            readonly property real scaleY: bounds.totalH > 0 ? (areaH - pad * 2) / bounds.totalH : 1
                            readonly property real sf: Math.min(scaleX, scaleY)
                            readonly property real offX: (areaW - bounds.totalW * sf) / 2
                            readonly property real offY: (areaH - bounds.totalH * sf) / 2
                            x: offX + (winData.x - bounds.minX) * sf
                            y: offY + (winData.y - bounds.minY) * sf
                            width: Math.max(winData.w * sf, 1)
                            height: Math.max(winData.h * sf, 1)

                            Rectangle {
                                anchors.fill: parent; anchors.margins: 1
                                radius: isPrimary ? 4 : 3
                                color: winMouse.containsMouse ? Qt.rgba(0.2, 0.2, 0.25, 1.0) : Qt.rgba(0.12, 0.12, 0.16, 1.0)
                                border.width: winMouse.containsMouse ? 1.5 : 0.5
                                border.color: winMouse.containsMouse ? bar.hoveredDotColor : Qt.rgba(1, 1, 1, 0.08)
                                Behavior on color { ColorAnimation { duration: 80 } }

                                Image {
                                    id: winIcon; anchors.centerIn: parent
                                    width: Math.min(parent.width * 0.45, parent.height * 0.45, isPrimary ? 32 : 22); height: width
                                    sourceSize.width: 128; sourceSize.height: 128
                                    mipmap: true; smooth: true
                                    visible: status === Image.Ready
                                    source: { void bar.iconCacheReady; void bar.steamIconVersion; return (winItem.winData && winItem.winData.class) ? bar.resolveAppIcon(winItem.winData.class, winItem.winData.title) : "" }
                                }
                                Text {
                                    anchors.centerIn: parent; visible: !winIcon.visible
                                    text: winItem.winData && winItem.winData.class ? winItem.winData.class[0].toUpperCase() : "?"
                                    color: Qt.rgba(1, 1, 1, 0.4)
                                    font.pixelSize: Math.min(parent.width * 0.3, parent.height * 0.3, isPrimary ? 16 : 11)
                                    font.family: bar.fontFamily; font.bold: true
                                }
                                Text {
                                    anchors.bottom: parent.bottom; anchors.bottomMargin: 2
                                    anchors.horizontalCenter: parent.horizontalCenter; width: parent.width - 6
                                    visible: winMouse.containsMouse && parent.width > 50
                                    text: winItem.winData ? (winItem.winData.title || winItem.winData.class || "") : ""
                                    color: "#CDD6F4"; font.pixelSize: isPrimary ? 8 : 6; font.family: bar.fontFamily
                                    elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                }
                                MouseArea {
                                    id: winMouse; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; hoverEnabled: true
                                    onClicked: {
                                        var addr = (winItem.winData && winItem.winData.address) ? winItem.winData.address : ""
                                        var wsTarget = wsPreviewPopup.hovWsId
                                        var monTarget = wsPreviewPopup.hovMonId
                                        bar.lastHoveredWsId = -1
                                        wsPreviewPopup.closePreview()
                                        Hyprland.dispatch("exec " + bar.homeDir + "/.config/hypr/workspace-goto.sh " + wsTarget + " " + monTarget)
                                        if (addr !== "") {
                                            wsPreviewPopup.pendingFocusAddr = addr
                                            wsPreviewPopup.focusTimer.start()
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

    // ── Close preview with grace period ──
    property int closeCountdown: 0
    Timer {
        interval: 50; repeat: true; running: bar.previewOpen
        onTriggered: {
            var mouseIsRelevant = false

            if (popupMouseTracker.containsMouse) mouseIsRelevant = true
                if (dotsBridge.containsMouse) mouseIsRelevant = true

                    if (!mouseIsRelevant && wsArea && wsArea.children) {
                        for (var k = 0; k < wsArea.children.length; k++) {
                            var item = wsArea.children[k]
                            if (item && item.children) {
                                for (var m = 0; m < item.children.length; m++) {
                                    var rect = item.children[m]
                                    if (rect && rect.children) {
                                        for (var n = 0; n < rect.children.length; n++) {
                                            var ma = rect.children[n]
                                            if (ma && ma.containsMouse !== undefined && ma.containsMouse) { mouseIsRelevant = true; break }
                                        }
                                    }
                                    if (mouseIsRelevant) break
                                }
                            }
                            if (mouseIsRelevant) break
                        }
                    }

                    if (!mouseIsRelevant) {
                        for (var i = 0; i < dotsRow.children.length; i++) {
                            var child = dotsRow.children[i]
                            if (child && child.children) {
                                for (var j = 0; j < child.children.length; j++) {
                                    var dma = child.children[j]
                                    if (dma && dma.containsMouse !== undefined && dma.containsMouse) { mouseIsRelevant = true; break }
                                }
                            }
                            if (mouseIsRelevant) break
                        }
                    }

                    if (mouseIsRelevant) {
                        bar.closeCountdown = 0
                    } else {
                        bar.closeCountdown++
                        if (bar.closeCountdown >= 8) {
                            closeAnim.start()
                            bar.lastHoveredWsId = bar.hoveredWsId
                            bar.previewOpen = false
                            bar.hoveredWsId = -1
                            bar.wsLayoutData = []
                            bar.closeCountdown = 0
                        }
                    }
        }
    }

    // ── System-monitor hover detail popup — one shared window that paints up
    //    from the bar like the volume/calendar menus. Content is keyed off the
    //    hovered section and latched so it survives the close animation. ──
    PopupWindow {
        id: monPopup
        anchor.window: bar
        anchor.rect.x: Math.max(4, Math.min(bar.hoveredMonX - implicitWidth / 2,
                                            bar.width - implicitWidth - 4))
        anchor.rect.y: bar.vm - implicitHeight
        // Wayland layer-shell windows don't resize smoothly — the compositor
        // renegotiates the surface every frame, which the user perceives as
        // flicker. Keep the popup *window* a fixed (big) size and animate
        // only the visible body inside it, anchored to the bottom so it
        // still appears to grow from the bar.
        readonly property bool ioWide: monPopup.activeMon === "net" || monPopup.activeMon === "disk"
        implicitWidth: isPrimary ? 570 : 430
        implicitHeight: isPrimary ? 470 : 360
        property real bodyW: ioWide ? (isPrimary ? 570 : 430) : (isPrimary ? 230 : 178)
        property real bodyH: ioWide ? (isPrimary ? 470 : 360) : (isPrimary ? 132 : 104)
        Behavior on bodyW { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        Behavior on bodyH { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        visible: monPopup.shown || monShape.liquidProgress > 0.001
        color: "transparent"
        mask: Region {}

        readonly property int radius: isPrimary ? 14 : 10

        // Debounced "a section is hovered". Sliding between adjacent sections
        // keeps the popup painted — only the content swaps.
        property bool shown: false
        property string activeMon: "cpu"
        Connections {
            target: bar
            function onHoveredMonChanged() {
                if (bar.hoveredMon !== "") {
                    monCloseDebounce.stop()
                    monPopup.activeMon = bar.hoveredMon
                    monPopup.shown = true
                } else {
                    monCloseDebounce.restart()
                }
            }
        }
        Timer {
            id: monCloseDebounce
            interval: 90
            onTriggered: monPopup.shown = false
        }

        readonly property string mk: monPopup.activeMon
        readonly property real monT: mk === "cpu" ? 0.05 : mk === "gpu" ? 0.125
            : mk === "vram" ? 0.20 : mk === "mem" ? 0.275 : mk === "zram" ? 0.35
            : mk === "net" ? 0.425 : mk === "disk" ? 0.50 : 0.275
        property color bodyColor: bar.solidify(bar.lerpColor(monT))
        Behavior on bodyColor { ColorAnimation { duration: 200 } }
        readonly property color fg: bar.contrastText(bodyColor)
        readonly property color fg2: bar.contrastAlt(bodyColor)
        readonly property bool graphDual: mk === "net" || mk === "disk"
        readonly property string monTitle: mk === "cpu" ? "CPU" : mk === "gpu" ? "GPU"
            : mk === "vram" ? "VRAM" : mk === "mem" ? "MEMORY" : mk === "zram" ? bar.swapLabel
            : mk === "net" ? "NETWORK" : mk === "disk" ? "DISK I/O" : ""
        readonly property string bigVal: mk === "cpu" ? bar.cpuUsage + "%"
            : mk === "gpu" ? bar.gpuUsage + "%" : mk === "vram" ? bar.vramUsage + "%"
            : mk === "mem" ? bar.memUsage + "%" : mk === "zram" ? bar.swapUsage + "%"
            : mk === "net" ? "Peak ↓ " + bar.fmtRate(bar.histPeak(bar.netHist, "a"))
            : mk === "disk" ? "Peak R " + bar.fmtRate(bar.histPeak(bar.diskHist, "a")) : ""
        readonly property string subVal: mk === "cpu" ? bar.cpuTemp + "°C"
            : mk === "gpu" ? bar.gpuTemp + "°C"
            : mk === "vram" ? bar.vramUsedGB.toFixed(1) + " / " + bar.vramTotalGB.toFixed(1) + " GB"
            : mk === "mem" ? bar.memUsedGB.toFixed(1) + " / " + bar.memTotalGB.toFixed(1) + " GB"
            : mk === "zram" ? bar.swapUsedGB.toFixed(2) + " / " + bar.swapTotalGB.toFixed(1) + " GB"
            : mk === "net" ? "Peak ↑ " + bar.fmtRate(bar.histPeak(bar.netHist, "b"))
            : mk === "disk" ? "Peak W " + bar.fmtRate(bar.histPeak(bar.diskHist, "b")) : ""
        readonly property var graphData: mk === "cpu" ? bar.cpuHist : mk === "gpu" ? bar.gpuHist
            : mk === "vram" ? bar.vramHist : mk === "mem" ? bar.memHist : mk === "zram" ? bar.swapHist
            : mk === "net" ? bar.netHist : mk === "disk" ? bar.diskHist : []

        // Unique apps that appeared in this series within the visible window.
        // Persists for ~48s after the app stops appearing (matches scroll
        // speed) so the legend doesn't flicker on intermittent activity.
        // Each entry renders as a real icon when one exists, otherwise as
        // a colored dot — the legend doubles as a key for both kinds.
        readonly property var allAppsA: {
            if (!monPopup.graphDual) return []
            var d = monPopup.graphData
            if (!d) return []
            var seen = {}, list = []
            for (var i = 0; i < d.length; i++) {
                var s = d[i]
                if (!s) continue
                var app = s.aApp
                if (!app || app === "-" || seen[app]) continue
                seen[app] = true
                list.push(app)
            }
            return list
        }
        readonly property var allAppsB: {
            if (!monPopup.graphDual) return []
            var d = monPopup.graphData
            if (!d) return []
            var seen = {}, list = []
            for (var i = 0; i < d.length; i++) {
                var s = d[i]
                if (!s) continue
                var app = s.bApp
                if (!app || app === "-" || seen[app]) continue
                seen[app] = true
                list.push(app)
            }
            return list
        }

        // Paint-up body — opaque Shape with an animated drippy top edge.
        // Sized to the animated bodyW/bodyH, not the popup window size, and
        // anchored to the bottom so it still appears to rise from the bar.
        // X is set so the body is centered on the hovered cell, even when
        // the popup window itself is clamped against the screen edge.
        Item {
            id: monShape
            width: monPopup.bodyW
            height: monPopup.bodyH
            x: Math.max(0, Math.min(
                bar.hoveredMonX - monPopup.anchor.rect.x - width / 2,
                monPopup.implicitWidth - width))
            y: monPopup.implicitHeight - height
            property real liquidProgress: monPopup.shown ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 460; easing.type: Easing.InOutQuint } }

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: monPopup.bodyColor
                    PathSvg {
                        path: bar.dripPath(monShape.width, monShape.height,
                                           monPopup.radius, monShape.liquidProgress, 29.0)
                    }
                }
            }

            // Content — fades + slides up as the paint rises
            Item {
                id: monContent
                anchors.fill: parent
                anchors.margins: isPrimary ? 11 : 8
                readonly property real reveal: monShape.liquidProgress > 0.45
                    ? (monShape.liquidProgress - 0.45) / 0.55 : 0.0
                visible: reveal > 0.001
                opacity: reveal
                transform: Translate { y: (1.0 - monContent.reveal) * 16 }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: isPrimary ? 3 : 2

                    // Header — title + bigVal beside it for non-IO popups.
                    // IO popups use per-graph labels below instead, so the
                    // bigVal here is hidden for those.
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: monPopup.monTitle
                            color: monPopup.fg
                            font.pixelSize: isPrimary ? 12 : 10
                            font.family: bar.fontFamily
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: !monPopup.graphDual
                            text: monPopup.bigVal
                            color: monPopup.fg
                            font.pixelSize: isPrimary ? 13 : 11
                            font.family: bar.fontFamily
                            font.bold: true
                        }
                    }

                    // ── Non-IO single-graph view ──
                    Text {
                        visible: !monPopup.graphDual
                        text: monPopup.subVal
                        color: monPopup.fg
                        font.pixelSize: isPrimary ? 11 : 9
                        font.family: bar.fontFamily
                        font.bold: true
                    }
                    MonGraph {
                        visible: !monPopup.graphDual
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        data: monPopup.graphData
                        dual: false
                        fixedMax: 100
                        stroke: monPopup.fg
                    }

                    // ── IO stacked-graph view: series B (up/write) on top in
                    //    fg2, series A (down/read) on bottom in fg — matches
                    //    the bar's small chart so the two views read the same.
                    Text {
                        visible: monPopup.graphDual
                        text: monPopup.subVal
                        color: monPopup.fg2
                        font.pixelSize: isPrimary ? 11 : 9
                        font.family: bar.fontFamily
                        font.bold: true
                    }
                    // B graph block — the legend below is part of this block
                    // (per-graph rather than popup-wide) and only takes the
                    // space it needs; persists across the scroll window so
                    // it doesn't flicker as buckets roll.
                    Item {
                        visible: monPopup.graphDual
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        readonly property real iconPx: isPrimary ? 20 : 16
                        MonGraph {
                            id: popupGraphB
                            anchors.fill: parent
                            data: monPopup.graphData
                            dual: monPopup.graphDual
                            seriesPick: "b"
                            fixedMax: 0
                            // Match the bar's small chart: series B uses fg2.
                            stroke: monPopup.fg2
                        }
                        Repeater {
                            model: monPopup.graphDual && popupGraphB.data ? popupGraphB.data.length : 0
                            delegate: Item {
                                id: bIcon
                                required property int index
                                readonly property var sample: popupGraphB.data && index < popupGraphB.data.length ? popupGraphB.data[index] : null
                                readonly property real val: sample ? (sample.b || 0) : 0
                                readonly property string app: sample ? (sample.bApp || "") : ""
                                readonly property int n: popupGraphB.data ? popupGraphB.data.length : 0
                                readonly property real stepX: popupGraphB.width / (bar.ioHistLen - 1)
                                readonly property real x0: popupGraphB.width - (n - 1) * stepX
                                readonly property real span: popupGraphB.height - 2
                                readonly property real iconPx: parent.iconPx
                                readonly property string resolvedIcon: bar.strictIconPath(app)
                                width: iconPx; height: iconPx
                                x: x0 + index * stepX - iconPx / 2
                                y: Math.max(0, popupGraphB.height - (val / Math.max(1, bar.monGraphAutoMax(popupGraphB.data, true, 0, "b"))) * span - 1 - iconPx)
                                visible: val > 0 && app !== "" && app !== "-"
                                Image {
                                    id: bImg
                                    anchors.fill: parent
                                    sourceSize.width: bIcon.iconPx * 2
                                    sourceSize.height: bIcon.iconPx * 2
                                    mipmap: true; smooth: true; asynchronous: true
                                    fillMode: Image.PreserveAspectFit
                                    source: bIcon.resolvedIcon
                                    visible: status === Image.Ready
                                }
                                Rectangle {
                                    // No-icon fallback: small filled circle
                                    // colored by comm; the legend below maps
                                    // dot colors to app names.
                                    anchors.centerIn: parent
                                    width: parent.width * 0.7
                                    height: width
                                    radius: width / 2
                                    color: bar.commColor(bIcon.app)
                                    visible: !bImg.visible
                                }
                            }
                        }
                    }
                    // Legend for the B series — one chip per app that's
                    // appeared in the visible window. Renders the real icon
                    // when one exists, otherwise a colored dot matching the
                    // graph overlay.
                    Flow {
                        visible: monPopup.graphDual && monPopup.allAppsB.length > 0
                        Layout.fillWidth: true
                        spacing: isPrimary ? 10 : 7
                        Repeater {
                            model: monPopup.allAppsB
                            delegate: Row {
                                required property string modelData
                                readonly property string legendIcon: bar.strictIconPath(modelData)
                                readonly property int chipSize: isPrimary ? 14 : 11
                                spacing: isPrimary ? 4 : 3
                                Item {
                                    width: parent.chipSize; height: parent.chipSize
                                    anchors.verticalCenter: parent.verticalCenter
                                    Image {
                                        anchors.fill: parent
                                        source: parent.parent.legendIcon
                                        visible: status === Image.Ready
                                        sourceSize.width: parent.width * 2
                                        sourceSize.height: parent.height * 2
                                        mipmap: true; smooth: true; asynchronous: true
                                        fillMode: Image.PreserveAspectFit
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: parent.width * 0.7; height: width
                                        radius: width / 2
                                        color: bar.commColor(modelData)
                                        visible: parent.parent.legendIcon === ""
                                    }
                                }
                                Text {
                                    text: modelData
                                    color: monPopup.fg
                                    font.pixelSize: isPrimary ? 11 : 9
                                    font.family: bar.fontFamily
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                    Text {
                        visible: monPopup.graphDual
                        text: monPopup.bigVal
                        color: monPopup.fg
                        font.pixelSize: isPrimary ? 11 : 9
                        font.family: bar.fontFamily
                        font.bold: true
                    }
                    Item {
                        visible: monPopup.graphDual
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        readonly property real iconPx: isPrimary ? 20 : 16
                        MonGraph {
                            id: popupGraphA
                            anchors.fill: parent
                            data: monPopup.graphData
                            dual: monPopup.graphDual
                            seriesPick: "a"
                            fixedMax: 0
                            stroke: monPopup.fg
                        }
                        Repeater {
                            model: monPopup.graphDual && popupGraphA.data ? popupGraphA.data.length : 0
                            delegate: Item {
                                id: aIcon
                                required property int index
                                readonly property var sample: popupGraphA.data && index < popupGraphA.data.length ? popupGraphA.data[index] : null
                                readonly property real val: sample ? (sample.a || 0) : 0
                                readonly property string app: sample ? (sample.aApp || "") : ""
                                readonly property int n: popupGraphA.data ? popupGraphA.data.length : 0
                                readonly property real stepX: popupGraphA.width / (bar.ioHistLen - 1)
                                readonly property real x0: popupGraphA.width - (n - 1) * stepX
                                readonly property real span: popupGraphA.height - 2
                                readonly property real iconPx: parent.iconPx
                                readonly property string resolvedIcon: bar.strictIconPath(app)
                                width: iconPx; height: iconPx
                                x: x0 + index * stepX - iconPx / 2
                                y: Math.max(0, popupGraphA.height - (val / Math.max(1, bar.monGraphAutoMax(popupGraphA.data, true, 0, "a"))) * span - 1 - iconPx)
                                visible: val > 0 && app !== "" && app !== "-"
                                Image {
                                    id: aImg
                                    anchors.fill: parent
                                    sourceSize.width: aIcon.iconPx * 2
                                    sourceSize.height: aIcon.iconPx * 2
                                    mipmap: true; smooth: true; asynchronous: true
                                    fillMode: Image.PreserveAspectFit
                                    source: aIcon.resolvedIcon
                                    visible: status === Image.Ready
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width * 0.7
                                    height: width
                                    radius: width / 2
                                    color: bar.commColor(aIcon.app)
                                    visible: !aImg.visible
                                }
                            }
                        }
                    }

                    // Legend for the A series.
                    Flow {
                        visible: monPopup.graphDual && monPopup.allAppsA.length > 0
                        Layout.fillWidth: true
                        spacing: isPrimary ? 10 : 7
                        Repeater {
                            model: monPopup.allAppsA
                            delegate: Row {
                                required property string modelData
                                readonly property string legendIcon: bar.strictIconPath(modelData)
                                readonly property int chipSize: isPrimary ? 14 : 11
                                spacing: isPrimary ? 4 : 3
                                Item {
                                    width: parent.chipSize; height: parent.chipSize
                                    anchors.verticalCenter: parent.verticalCenter
                                    Image {
                                        anchors.fill: parent
                                        source: parent.parent.legendIcon
                                        visible: status === Image.Ready
                                        sourceSize.width: parent.width * 2
                                        sourceSize.height: parent.height * 2
                                        mipmap: true; smooth: true; asynchronous: true
                                        fillMode: Image.PreserveAspectFit
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: parent.width * 0.7; height: width
                                        radius: width / 2
                                        color: bar.commColor(modelData)
                                        visible: parent.parent.legendIcon === ""
                                    }
                                }
                                Text {
                                    text: modelData
                                    color: monPopup.fg
                                    font.pixelSize: isPrimary ? 11 : 9
                                    font.family: bar.fontFamily
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════
    // ══════════════════════════════════════════════
    // LAUNCHER PANEL (fullscreen overlay)
    // ══════════════════════════════════════════════
    PanelWindow {
        id: launcherPanel
        screen: bar.screen
        visible: bar.launcherOpen || launcherShape.liquidProgress > 0.001
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:launcher"
        WlrLayershell.keyboardFocus: bar.launcherOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        onVisibleChanged: if (visible) launcherKeyCatcher.forceActiveFocus()

        // The actual fix for "keyboard is dead after closing the launcher":
        // wlr-layer-shell's keyboard_interactivity (WlrLayershell.keyboardFocus)
        // does NOT restore focus to the previously-focused window when it
        // releases on Hyprland — the keyboard is just left in limbo. Hyprland's
        // own hyprland_focus_grab_v1 protocol is purpose-built for popups and
        // hands focus back to the prior window when the grab ends.
        HyprlandFocusGrab {
            windows: [launcherPanel]
            active: bar.launcherOpen
        }

        readonly property int panelW: isPrimary ? 520 : 420
        readonly property int panelH: isPrimary ? 660 : 540
        readonly property int radius: isPrimary ? 14 : 10
        readonly property int filletR: isPrimary ? 12 : 9
        readonly property int hamW: isPrimary ? 42 : 32

        property string searchText: ""
        property var allApps: []
        property bool appsLoaded: false

        Process {
            id: appListProc
            command: ["bash", "-c",
            "find /usr/share/applications ~/.local/share/applications " +
            "/var/lib/flatpak/exports/share/applications " +
            "~/.local/share/flatpak/exports/share/applications " +
            "-maxdepth 1 -name '*.desktop' 2>/dev/null | while read f; do " +
            "hidden=$(grep -m1 '^NoDisplay=true' \"$f\" 2>/dev/null); " +
            "[ -n \"$hidden\" ] && continue; " +
            "name=$(grep -m1 '^Name=' \"$f\" 2>/dev/null | cut -d= -f2); " +
            "icon=$(grep -m1 '^Icon=' \"$f\" 2>/dev/null | cut -d= -f2); " +
            "exec=$(grep -m1 '^Exec=' \"$f\" 2>/dev/null | cut -d= -f2- | sed 's/ %[a-zA-Z]//g'); " +
            "tryexec=$(grep -m1 '^TryExec=' \"$f\" 2>/dev/null | cut -d= -f2); " +
            "if [ -n \"$tryexec\" ]; then " +
            "  command -v \"$tryexec\" >/dev/null 2>&1 || [ -x \"$tryexec\" ] || continue; " +
            "fi; " +
            "wmclass=$(grep -m1 '^StartupWMClass=' \"$f\" 2>/dev/null | cut -d= -f2); " +
            "desktopId=$(basename \"$f\" .desktop); " +
            "if [ -n \"$icon\" ]; then " +
            "  case \"$icon\" in /*) [ ! -f \"$icon\" ] && icon=$(basename \"$icon\" | sed 's/\\.[^.]*$//');; esac; " +
            "  icon=$(echo \"$icon\" | sed 's/\\.\\(svg\\|png\\|xpm\\|ico\\)$//; s/\.exe[0-9]*$//'); " +
            "fi; " +
            "cmd=$(echo \"$exec\" | sed 's/\"//g' | sed 's/^env [^ =]*=[^ ]* *//' | awk '{print $1}'); " +
            "[ -n \"$name\" ] && [ -n \"$exec\" ] && " +
            "{ command -v \"$cmd\" >/dev/null 2>&1 || [ -x \"$cmd\" ]; } && " +
            "echo \"$name|$icon|$exec|$wmclass|$desktopId\"; " +
            "done | sort -t'|' -k1,1 -f -u | head -200"
            ]
            running: true
            stdout: StdioCollector {
                onStreamFinished: {
                    var apps = []
                    var lines = this.text.trim().split("\n")
                    for (var i = 0; i < lines.length; i++) {
                        var parts = lines[i].split("|")
                        if (parts.length >= 3) {
                            var wmclass = parts.length >= 5 ? parts[parts.length - 2] : ""
                            var desktopId = parts.length >= 5 ? parts[parts.length - 1] : ""
                            var execParts = parts.length >= 5 ? parts.slice(2, parts.length - 2) : parts.slice(2)
                            var icon = parts[1]
                            // Strip .exe and trailing digits
                            icon = icon.replace(/\.exe\d*$/, "")
                            // Strip image extensions
                            icon = icon.replace(/\.(svg|png|xpm|ico)$/, "")
                            // Absolute paths that don't exist: use basename without extension
                            if (icon.indexOf("/") === 0) {
                                var base = icon.substring(icon.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "")
                                icon = base
                            }
                            apps.push({ name: parts[0], icon: icon, exec: execParts.join("|"), wmclass: wmclass, desktopId: desktopId })
                        }
                    }
                    launcherPanel.allApps = apps
                    launcherPanel.appsLoaded = true
                }
            }
        }

        readonly property var filteredApps: {
            if (!appsLoaded) return []
            if (searchText === "") return allApps
            var q = searchText.toLowerCase()
            var result = []
            for (var i = 0; i < allApps.length; i++) {
                if (allApps[i].name.toLowerCase().indexOf(q) >= 0)
                    result.push(allApps[i])
            }
            return result
        }

        // Fullscreen click catcher + keyboard handler
        Rectangle {
            id: launcherKeyCatcher
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.01)
            focus: true

            Connections {
                target: bar
                function onLauncherOpenChanged() {
                    if (bar.launcherOpen) launcherKeyCatcher.forceActiveFocus()
                }
            }

            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                    bar.closeLauncher()
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (launcherPanel.filteredApps.length > 0) {
                        Hyprland.dispatch("exec " + launcherPanel.filteredApps[0].exec)
                        bar.closeLauncher()
                    }
                    event.accepted = true
                } else if (event.key === Qt.Key_Backspace) {
                    if (launcherPanel.searchText.length > 0)
                        launcherPanel.searchText = launcherPanel.searchText.substring(0, launcherPanel.searchText.length - 1)
                    event.accepted = true
                } else if (event.text && event.text.length > 0 && event.key !== Qt.Key_Tab && event.key !== Qt.Key_Shift) {
                    launcherPanel.searchText += event.text
                    event.accepted = true
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: bar.closeLauncher()
            }
        }

        // Launcher content — paints up from the bar like the other popups
        Item {
            id: launcherShape
            visible: bar.launcherOpen || liquidProgress > 0.001
            x: bar.hm
            y: parent.height - bar.implicitHeight + bar.vm - launcherPanel.panelH
            width: launcherPanel.panelW
            height: launcherPanel.panelH

            property real liquidProgress: bar.launcherOpen ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 460; easing.type: Easing.InOutQuint } }

            readonly property color bodyColor: bar.solidify(bar.lerpColor(0.0))
            readonly property color fg: bar.contrastText(bodyColor)
            readonly property color rowBg: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
            readonly property color rowHover: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
            readonly property color placeholderCol: Qt.rgba(fg.r, fg.g, fg.b, 0.5)
            readonly property color trackCol: Qt.rgba(fg.r, fg.g, fg.b, 0.18)

            // Body — opaque Shape, drippy top edge rises with liquidProgress.
            // Bottom-left is square (blr 0) — it sits flush on the hamburger
            // pill, which flattens its top corners to match.
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: launcherShape.bodyColor
                    PathSvg {
                        path: bar.dripPath(launcherPanel.panelW, launcherPanel.panelH,
                                           launcherPanel.radius, launcherShape.liquidProgress, 53.0, 0)
                    }
                }
            }

            // Right fillet — concave joint from the panel down into the
            // hamburger pill's right edge (left side needs none: it's flush).
            Shape {
                visible: launcherShape.liquidProgress > 0.02
                x: launcherPanel.hamW - bar.rad
                y: launcherPanel.panelH
                width: launcherPanel.filletR + bar.rad
                height: launcherPanel.filletR
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: launcherShape.bodyColor
                    PathSvg {
                        readonly property int f: launcherPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0"
                            + " A " + f + "," + f + " 0 0 0 " + r + "," + f
                            + " L 0," + f + " L 0,0 Z"
                    }
                }
            }

            // Eat clicks so they don't fall through to the close-catcher
            MouseArea { anchors.fill: parent; onClicked: {} }

            // Content — fades + slides up as the paint rises
            Item {
                id: launcherInner
                anchors.fill: parent
                anchors.margins: isPrimary ? 12 : 8
                readonly property real reveal: launcherShape.liquidProgress > 0.45
                    ? (launcherShape.liquidProgress - 0.45) / 0.55 : 0.0
                visible: reveal > 0.001
                opacity: reveal
                transform: Translate { y: (1.0 - launcherInner.reveal) * 18 }

            Column {
                anchors.fill: parent
                spacing: isPrimary ? 10 : 6

                Rectangle {
                    width: parent.width; height: isPrimary ? 36 : 28
                    radius: height / 2; color: launcherShape.rowBg

                    Row {
                        anchors.fill: parent; anchors.leftMargin: isPrimary ? 12 : 8; anchors.rightMargin: isPrimary ? 12 : 8; spacing: isPrimary ? 8 : 5
                        Text { anchors.verticalCenter: parent.verticalCenter; text: String.fromCodePoint(0xF002D); color: launcherShape.placeholderCol; font.pixelSize: isPrimary ? 16 : 12; font.family: bar.fontFamily }
                        Text {
                            id: searchDisplay
                            width: parent.width - (isPrimary ? 30 : 22)
                            anchors.verticalCenter: parent.verticalCenter
                            text: launcherPanel.searchText
                            color: launcherPanel.searchText.length > 0 ? launcherShape.fg : launcherShape.placeholderCol
                            font.pixelSize: isPrimary ? 14 : 11; font.family: bar.fontFamily
                            elide: Text.ElideRight
                            Component.onCompleted: { if (launcherPanel.searchText === "") text = "Search apps..." }
                        }
                    }

                    Connections {
                        target: launcherPanel
                        function onSearchTextChanged() {
                            searchDisplay.text = launcherPanel.searchText.length > 0 ? launcherPanel.searchText : "Search apps..."
                            searchDisplay.color = launcherPanel.searchText.length > 0 ? launcherShape.fg : launcherShape.placeholderCol
                        }
                    }
                }

                // ── Quick settings ──
                Column {
                    width: parent.width
                    spacing: isPrimary ? 6 : 4

                    // Per-monitor brightness sliders — auto-detected via
                    // `ddcutil detect` (no hardcoded outputs/buses). One row per
                    // DDC/CI-capable monitor, so any monitor count works.
                    Repeater {
                        model: bar.ddcMonitors
                        Rectangle {
                            id: brDelegate
                            property int liveBrightness: modelData.brightness
                            property int monBus: modelData.bus
                            width: parent.width; height: isPrimary ? 32 : 24
                            radius: height / 2; color: launcherShape.rowBg
                            Row {
                                anchors.centerIn: parent; spacing: isPrimary ? 8 : 5
                                Text { text: String.fromCodePoint(0xF00DE); color: launcherShape.fg; font.pixelSize: isPrimary ? 14 : 11; font.family: bar.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: modelData.name; color: launcherShape.fg; font.pixelSize: isPrimary ? 10 : 8; font.family: bar.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                                Rectangle {
                                    width: isPrimary ? 180 : 130; height: isPrimary ? 6 : 4; radius: 3
                                    color: launcherShape.trackCol; anchors.verticalCenter: parent.verticalCenter
                                    Rectangle { width: parent.width * brDelegate.liveBrightness / 100; height: parent.height; radius: 3; color: launcherShape.fg; Behavior on width { NumberAnimation { duration: 80 } } }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onPressed: function(mouse) { brDelegate.liveBrightness = Math.max(5, Math.min(100, Math.round(mouse.x / parent.width * 100))) }
                                        onPositionChanged: function(mouse) { if (pressed) { brDelegate.liveBrightness = Math.max(5, Math.min(100, Math.round(mouse.x / parent.width * 100))) } }
                                        onReleased: { Hyprland.dispatch("exec ddcutil setvcp 10 " + brDelegate.liveBrightness + " --bus " + brDelegate.monBus); if (bar.ddcMonitors[index]) bar.ddcMonitors[index].brightness = brDelegate.liveBrightness }
                                    }
                                }
                                Text { text: brDelegate.liveBrightness + "%"; color: launcherShape.fg; font.pixelSize: isPrimary ? 10 : 8; font.family: bar.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                    }
                }

                Flickable {
                    id: appFlick
                    width: parent.width; height: parent.height - (isPrimary ? 130 : 100)
                    clip: true; contentHeight: appGrid.height
                    flickableDirection: Flickable.VerticalFlick; boundsBehavior: Flickable.StopAtBounds
                    pressDelay: 120

                    NumberAnimation {
                        id: appScrollAnim
                        target: appFlick; property: "contentY"
                        duration: 180; easing.type: Easing.OutCubic
                    }
                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: function(ev) {
                            var maxY = Math.max(0, appFlick.contentHeight - appFlick.height)
                            var target = (appScrollAnim.running ? appScrollAnim.to : appFlick.contentY)
                                        - ev.angleDelta.y * 1.6
                            appScrollAnim.to = Math.max(0, Math.min(maxY, target))
                            appScrollAnim.restart()
                            ev.accepted = true
                        }
                    }

                    Grid {
                        id: appGrid; width: parent.width; columns: 4; spacing: isPrimary ? 6 : 4

                        Repeater {
                            model: launcherPanel.filteredApps.length
                            delegate: Rectangle {
                                id: appItem
                                required property int index
                                readonly property var app: launcherPanel.filteredApps[index]
                                width: (appGrid.width - appGrid.spacing * (appGrid.columns - 1)) / appGrid.columns
                                height: isPrimary ? 80 : 64; radius: isPrimary ? 8 : 6
                                color: appMouse.containsMouse ? launcherShape.rowHover : "transparent"
                                Behavior on color { ColorAnimation { duration: 80 } }

                                Column {
                                    anchors.centerIn: parent; spacing: isPrimary ? 6 : 4
                                    Image {
                                        id: appGridIcon; anchors.horizontalCenter: parent.horizontalCenter
                                        width: isPrimary ? 36 : 28; height: width
                                        sourceSize.width: 128; sourceSize.height: 128; mipmap: true; smooth: true
                                        source: {
                                            if (!appItem.app) return ""
                                            void bar.iconCacheReady; void bar.steamIconVersion
                                            var r = ""
                                            if (appItem.app.desktopId && appItem.app.desktopId !== "") {
                                                r = bar.resolveAppIcon(appItem.app.desktopId, appItem.app.name)
                                                if (r !== "") return r
                                            }
                                            if (appItem.app.wmclass && appItem.app.wmclass !== "") {
                                                r = bar.resolveAppIcon(appItem.app.wmclass, appItem.app.name)
                                                if (r !== "") return r
                                            }
                                            if (appItem.app.icon && appItem.app.icon !== "") {
                                                r = bar.resolveAppIcon(appItem.app.icon, appItem.app.name)
                                                if (r !== "") return r
                                                r = Quickshell.iconPath(appItem.app.icon, true)
                                                if (r !== "") return r
                                                return Quickshell.iconPath(appItem.app.icon, false)
                                            }
                                            r = Quickshell.iconPath(appItem.app.name.toLowerCase().replace(/ /g, "-"), true)
                                            if (r !== "") return r
                                            // Generic fallback icons
                                            r = Quickshell.iconPath("application-x-executable", true)
                                            if (r !== "") return r
                                            r = Quickshell.iconPath("application-x-executable", false)
                                            if (r !== "") return r
                                            return Quickshell.iconPath("application-default-icon", true)
                                        }
                                        visible: status === Image.Ready
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter; visible: !appGridIcon.visible
                                        text: appItem.app ? appItem.app.name[0].toUpperCase() : "?"
                                        color: launcherShape.fg; font.pixelSize: isPrimary ? 22 : 18; font.family: bar.fontFamily; font.bold: true
                                    }
                                    Text {
                                        width: appItem.width - 8; anchors.horizontalCenter: parent.horizontalCenter
                                        text: appItem.app ? appItem.app.name : ""; color: launcherShape.fg
                                        font.pixelSize: isPrimary ? 10 : 8; font.family: bar.fontFamily
                                        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
                                    }
                                }
                                MouseArea {
                                    id: appMouse; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; hoverEnabled: true
                                    onClicked: { if (appItem.app) { Hyprland.dispatch("exec " + appItem.app.exec); bar.closeLauncher() } }
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }

    // ── Volume right-click menu (slide-up) ──
    function openVolMenu() {
        if (bar.volMenuOpen) { bar.closeVolMenu(); return }
        var p = volPill.mapToItem(null, volPill.width / 2, 0)
        volMenuPanel.anchorX = Math.round(p.x)
        bar.volMenuOpen = true
    }
    function closeVolMenu() {
        bar.volMenuOpen = false
    }

    PanelWindow {
        id: volMenuPanel
        screen: bar.screen
        visible: bar.volMenuOpen || volMenuShape.liquidProgress > 0.001
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:volmenu"
        exclusionMode: ExclusionMode.Ignore

        readonly property int padding: isPrimary ? 10 : 7
        readonly property int btnH: isPrimary ? 32 : 26
        readonly property int rowH: isPrimary ? 44 : 36
        readonly property int rowSpacing: isPrimary ? 6 : 4
        readonly property int menuW: isPrimary ? 320 : 260
        readonly property int sinkCount: Math.max(1, bar.audioSinks.length)
        readonly property int menuH: padding * 2 + btnH + rowSpacing + (rowH * sinkCount + rowSpacing * (sinkCount - 1))
        readonly property int radius: isPrimary ? 14 : 10
        readonly property int filletR: isPrimary ? 12 : 9

        readonly property color txt: bar.contrastText(bar.borderVol)
        readonly property color dim: bar.contrastDim(bar.borderVol)
        readonly property color hover: {
            var lum = 0.299 * bar.borderVol.r + 0.587 * bar.borderVol.g + 0.114 * bar.borderVol.b
            return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.10) : Qt.rgba(1, 1, 1, 0.14)
        }
        readonly property color rowBg: {
            var lum = 0.299 * bar.borderVol.r + 0.587 * bar.borderVol.g + 0.114 * bar.borderVol.b
            return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(1, 1, 1, 0.07)
        }

        property int anchorX: 0

        MouseArea {
            anchors.fill: parent
            onClicked: bar.closeVolMenu()
        }

        // Paint-up menu — opaque body Shape with an animated drippy top edge
        Item {
            id: volMenuShape
            visible: bar.volMenuOpen || liquidProgress > 0.001

            readonly property int fullH: volMenuPanel.menuH + volMenuPanel.filletR
            property real liquidProgress: bar.volMenuOpen ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 460; easing.type: Easing.InOutQuint } }

            x: Math.max(8, Math.min(volMenuPanel.anchorX - width / 2, volMenuPanel.width - width - 8))
            width: volMenuPanel.menuW
            height: fullH
            y: (volMenuPanel.height - bar.implicitHeight + bar.vm + volMenuPanel.filletR) - fullH

            // Body — opaque Shape, drippy top edge rises with liquidProgress
            Shape {
                width: volMenuPanel.menuW
                height: volMenuPanel.menuH
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: bar.solidify(bar.borderVol)
                    PathSvg {
                        path: bar.dripPath(volMenuPanel.menuW, volMenuPanel.menuH,
                                           volMenuPanel.radius, volMenuShape.liquidProgress, 17.0)
                    }
                }
            }

            // Left fillet — pops in at the pill as the paint starts
            Shape {
                visible: volMenuShape.liquidProgress > 0.02
                x: (volMenuPanel.anchorX - volPill.width / 2) - volMenuShape.x - volMenuPanel.filletR
                y: volMenuPanel.menuH
                width: volMenuPanel.filletR + bar.rad
                height: volMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: bar.solidify(bar.borderVol)
                    PathSvg {
                        readonly property int f: volMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0 L " + (f + r) + "," + f + " L " + f + "," + f
                            + " A " + f + "," + f + " 0 0 0 0,0 Z"
                    }
                }
            }

            // Right fillet — mirror
            Shape {
                visible: volMenuShape.liquidProgress > 0.02
                x: (volMenuPanel.anchorX + volPill.width / 2) - volMenuShape.x - bar.rad
                y: volMenuPanel.menuH
                width: volMenuPanel.filletR + bar.rad
                height: volMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: bar.solidify(bar.borderVol)
                    PathSvg {
                        readonly property int f: volMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0"
                            + " A " + f + "," + f + " 0 0 0 " + r + "," + f
                            + " L 0," + f + " L 0,0 Z"
                    }
                }
            }

            // Interactive overlay — fades + slides up as the paint rises
            Item {
                id: volContent
                anchors.fill: parent
                anchors.margins: volMenuPanel.padding
                anchors.bottomMargin: volMenuPanel.padding + volMenuPanel.filletR
                readonly property real reveal: volMenuShape.liquidProgress > 0.45
                    ? (volMenuShape.liquidProgress - 0.45) / 0.55 : 0.0
                visible: reveal > 0.001
                opacity: reveal
                transform: Translate { y: (1.0 - volContent.reveal) * 16 }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: volMenuPanel.rowSpacing

                    // ── Open pavucontrol ──
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: volMenuPanel.btnH
                        radius: isPrimary ? 8 : 6
                        color: pavuBtn.containsMouse ? volMenuPanel.hover : volMenuPanel.rowBg

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                text: String.fromCodePoint(0xF027)
                                color: volMenuPanel.txt
                                font.pixelSize: bar.fs
                                font.family: bar.fontFamily
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Open pavucontrol"
                                color: volMenuPanel.txt
                                font.pixelSize: bar.fs
                                font.family: bar.fontFamily
                            }
                        }

                        MouseArea {
                            id: pavuBtn
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pavucontrolLauncher.running = true
                                bar.closeVolMenu()
                            }
                        }
                    }

                    // ── Per-sink rows ──
                    Repeater {
                        model: bar.audioSinks
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: volMenuPanel.rowH
                            radius: isPrimary ? 8 : 6
                            color: volMenuPanel.rowBg

                            readonly property var sink: modelData
                            readonly property bool isDefault: sink === bar.audioSink

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                anchors.topMargin: 4
                                anchors.bottomMargin: 4
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    // Radio button — selects which sink the bar slider drives
                                    Rectangle {
                                        Layout.preferredWidth: isPrimary ? 16 : 12
                                        Layout.preferredHeight: isPrimary ? 16 : 12
                                        radius: width / 2
                                        color: "transparent"
                                        border.color: volMenuPanel.txt
                                        border.width: isPrimary ? 2 : 1

                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: parent.width * 0.5
                                            height: parent.height * 0.5
                                            radius: width / 2
                                            color: volMenuPanel.txt
                                            visible: isDefault
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            hoverEnabled: true
                                            onClicked: { if (sink) { bar.userPickedSink = true; bar.barControlledSink = sink } }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: bar.sinkLabel(sink)
                                        color: volMenuPanel.txt
                                        font.pixelSize: bar.fs - 2
                                        font.family: bar.fontFamily
                                        font.bold: isDefault
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: sink && sink.audio ? Math.round(sink.audio.volume * 100) + "%" : "—"
                                        color: volMenuPanel.dim
                                        font.pixelSize: bar.fs - 3
                                        font.family: bar.fontFamily
                                    }
                                }

                                // Slider track
                                Rectangle {
                                    id: sinkTrack
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: isPrimary ? 6 : 5
                                    radius: 3
                                    color: volMenuPanel.dim

                                    Rectangle {
                                        width: parent.width * (sink && sink.audio ? Math.min(sink.audio.volume, 1.0) : 0)
                                        height: parent.height
                                        radius: 3
                                        color: volMenuPanel.txt
                                        Behavior on width { NumberAnimation { duration: 80 } }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onPressed: function(mouse) {
                                            if (!sink || !sink.audio) return
                                            var v = mouse.x / parent.width
                                            sink.audio.volume = Math.max(0, Math.min(1, v))
                                        }
                                        onPositionChanged: function(mouse) {
                                            if (!pressed || !sink || !sink.audio) return
                                            var v = mouse.x / parent.width
                                            sink.audio.volume = Math.max(0, Math.min(1, v))
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

    // ── Clock calendar popup ──
    PanelWindow {
        id: clockMenuPanel
        screen: bar.screen
        visible: bar.clockMenuOpen || clockMenuShape.liquidProgress > 0.001
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:clockmenu"
        exclusionMode: ExclusionMode.Ignore

        readonly property int cellSize: isPrimary ? 38 : 30
        readonly property int padding: isPrimary ? 14 : 10
        readonly property int headerH: isPrimary ? 28 : 22
        readonly property int weekdayH: isPrimary ? 22 : 18
        readonly property int rowSpacing: isPrimary ? 4 : 3
        readonly property int menuW: cellSize * 7 + padding * 2
        readonly property int menuH: padding * 2 + headerH + rowSpacing + weekdayH + rowSpacing + cellSize * 6
        readonly property int radius: isPrimary ? 14 : 10
        readonly property int filletR: isPrimary ? 12 : 9

        readonly property color fill: bar.solidify(bar.borderClock)
        readonly property color txt: bar.contrastText(bar.borderClock)
        readonly property color dim: bar.contrastDim(bar.borderClock)
        readonly property color hover: bar.contrastHover(bar.borderClock)

        property int anchorX: 0

        readonly property var monthNames: ["January","February","March","April","May","June","July","August","September","October","November","December"]
        readonly property var weekdayNames: ["Su","Mo","Tu","We","Th","Fr","Sa"]

        MouseArea {
            anchors.fill: parent
            onClicked: bar.closeClockMenu()
        }

        // Paint-up menu — opaque body Shape with an animated drippy top edge
        Item {
            id: clockMenuShape
            visible: bar.clockMenuOpen || liquidProgress > 0.001

            readonly property int fullH: clockMenuPanel.menuH + clockMenuPanel.filletR
            property real liquidProgress: bar.clockMenuOpen ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 460; easing.type: Easing.InOutQuint } }

            x: Math.max(8, Math.min(clockMenuPanel.anchorX - width / 2, clockMenuPanel.width - width - 8))
            width: clockMenuPanel.menuW
            height: fullH
            y: (clockMenuPanel.height - bar.implicitHeight + bar.vm + clockMenuPanel.filletR) - fullH

            // Body — opaque Shape, drippy top edge rises with liquidProgress
            Shape {
                width: clockMenuPanel.menuW
                height: clockMenuPanel.menuH
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: clockMenuPanel.fill
                    PathSvg {
                        path: bar.dripPath(clockMenuPanel.menuW, clockMenuPanel.menuH,
                                           clockMenuPanel.radius, clockMenuShape.liquidProgress, 41.0)
                    }
                }
            }

            // Left fillet — pops in at the pill as the paint starts
            Shape {
                visible: clockMenuShape.liquidProgress > 0.02
                x: (clockMenuPanel.anchorX - clockPill.width / 2) - clockMenuShape.x - clockMenuPanel.filletR
                y: clockMenuPanel.menuH
                width: clockMenuPanel.filletR + bar.rad
                height: clockMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: clockMenuPanel.fill
                    PathSvg {
                        readonly property int f: clockMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0 L " + (f + r) + "," + f + " L " + f + "," + f
                            + " A " + f + "," + f + " 0 0 0 0,0 Z"
                    }
                }
            }

            // Right fillet
            Shape {
                visible: clockMenuShape.liquidProgress > 0.02
                x: (clockMenuPanel.anchorX + clockPill.width / 2) - clockMenuShape.x - bar.rad
                y: clockMenuPanel.menuH
                width: clockMenuPanel.filletR + bar.rad
                height: clockMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: clockMenuPanel.fill
                    PathSvg {
                        readonly property int f: clockMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0"
                            + " A " + f + "," + f + " 0 0 0 " + r + "," + f
                            + " L 0," + f + " L 0,0 Z"
                    }
                }
            }

            // Interactive overlay — fades + slides up as the paint rises
            Item {
                id: clockContent
                anchors.fill: parent
                anchors.margins: clockMenuPanel.padding
                anchors.bottomMargin: clockMenuPanel.padding + clockMenuPanel.filletR
                readonly property real reveal: clockMenuShape.liquidProgress > 0.45
                    ? (clockMenuShape.liquidProgress - 0.45) / 0.55 : 0.0
                visible: reveal > 0.001
                opacity: reveal
                transform: Translate { y: (1.0 - clockContent.reveal) * 16 }

                ColumnLayout {
                    id: calCol
                    anchors.fill: parent
                    spacing: clockMenuPanel.rowSpacing

                // Header: prev | month year | next
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Rectangle {
                        Layout.preferredWidth: isPrimary ? 28 : 22
                        Layout.preferredHeight: isPrimary ? 28 : 22
                        radius: width / 2
                        color: prevHover.containsMouse ? clockMenuPanel.hover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "‹"
                            color: clockMenuPanel.txt
                            font.pixelSize: isPrimary ? 20 : 16
                            font.family: bar.fontFamily
                        }
                        MouseArea {
                            id: prevHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bar.calStep(-1)
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: clockMenuPanel.monthNames[bar.calMonth] + " " + bar.calYear
                        color: clockMenuPanel.txt
                        font.pixelSize: bar.fs
                        font.family: bar.fontFamily
                        font.bold: true
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bar.calToday()
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: isPrimary ? 28 : 22
                        Layout.preferredHeight: isPrimary ? 28 : 22
                        radius: width / 2
                        color: nextHover.containsMouse ? clockMenuPanel.hover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "›"
                            color: clockMenuPanel.txt
                            font.pixelSize: isPrimary ? 20 : 16
                            font.family: bar.fontFamily
                        }
                        MouseArea {
                            id: nextHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bar.calStep(1)
                        }
                    }
                }

                // Weekday header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        model: clockMenuPanel.weekdayNames
                        Text {
                            Layout.preferredWidth: clockMenuPanel.cellSize
                            Layout.preferredHeight: isPrimary ? 22 : 18
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: modelData
                            color: clockMenuPanel.dim
                            font.pixelSize: bar.fs - 2
                            font.family: bar.fontFamily
                            font.bold: true
                        }
                    }
                }

                // Day grid (6 rows × 7 cols)
                Grid {
                    Layout.alignment: Qt.AlignHCenter
                    rows: 6; columns: 7
                    rowSpacing: 0; columnSpacing: 0

                    Repeater {
                        model: 42
                        Item {
                            width: clockMenuPanel.cellSize
                            height: clockMenuPanel.cellSize

                            readonly property int offset: {
                                var firstDay = new Date(bar.calYear, bar.calMonth, 1)
                                return firstDay.getDay()
                            }
                            readonly property var cellDate: new Date(bar.calYear, bar.calMonth, index - offset + 1)
                            readonly property bool inMonth: cellDate.getMonth() === bar.calMonth
                            readonly property bool isToday: {
                                var n = new Date()
                                return cellDate.getFullYear() === n.getFullYear()
                                    && cellDate.getMonth() === n.getMonth()
                                    && cellDate.getDate() === n.getDate()
                            }

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                radius: 6
                                color: isToday ? clockMenuPanel.txt : "transparent"
                            }
                            Text {
                                anchors.centerIn: parent
                                text: cellDate.getDate()
                                color: isToday ? clockMenuPanel.fill
                                                : (inMonth ? clockMenuPanel.txt : clockMenuPanel.dim)
                                font.pixelSize: bar.fs
                                font.family: bar.fontFamily
                                font.bold: isToday
                            }
                        }
                    }
                }
                }
            }
        }
    }

    // ── Notification tray menu (slide-up) ──
    PanelWindow {
        id: notifMenuPanel
        screen: bar.screen
        visible: bar.notifMenuOpen || notifMenuShape.liquidProgress > 0.001
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:notifmenu"
        exclusionMode: ExclusionMode.Ignore

        readonly property int padding: isPrimary ? 12 : 9
        readonly property int rowH: isPrimary ? 64 : 50
        readonly property int rowSpacing: isPrimary ? 6 : 4
        readonly property int listSpacing: isPrimary ? 10 : 7
        readonly property int tabsH: isPrimary ? 30 : 24
        readonly property int menuW: isPrimary ? 460 : 350
        readonly property int iconSize: isPrimary ? 36 : 28
        readonly property int maxRowsVisible: 6
        readonly property int activeCount: bar.notifLog ? bar.notifLog.length : 0
        // Only show silenced apps that have at least one audit-log entry —
        // empty rows are noise. Apps with no recent suppressed activity can
        // still be unsilenced once another notification from them arrives and
        // gets logged.
        readonly property var silencedKeys: {
            void bar.suppressedApps
            var arr = []
            var s = bar.silencedApps || {}
            var supp = bar.suppressedApps || {}
            for (var k in s) {
                if ((supp[k] || []).length > 0) arr.push(k)
            }
            return arr
        }
        readonly property int silencedCount: silencedKeys.length
        readonly property int silencedRowH: Math.round(rowH * 0.7)
        readonly property int subRowH: isPrimary ? 26 : 21
        readonly property int subRowSpacing: 2
        readonly property int subRowPadTop: 6
        readonly property int footerH: isPrimary ? 32 : 26
        readonly property int footerTopMargin: isPrimary ? 16 : 12
        readonly property int suppressedTotalCount: {
            void bar.suppressedApps
            var s = bar.suppressedApps || {}
            var n = 0
            for (var k in s) n += (s[k] || []).length
            return n
        }
        readonly property bool showFooter: (bar.notifMenuTab === 0 && activeCount > 0)
                                           || (bar.notifMenuTab === 1 && suppressedTotalCount > 0)
        // footerExtra also accounts for the ColumnLayout gap between body and
        // footer (one extra rowSpacing) — without this the body shrinks by
        // 6px and the last card's bottom rounded corners get clipped.
        readonly property int footerExtra: showFooter
            ? footerH + footerTopMargin + rowSpacing : 0

        // Height of one silenced row, taking expansion into account.
        function silencedHeightFor(key) {
            if (bar.expandedSilenced[key] !== true) return silencedRowH
            var supp = (bar.suppressedApps || {})[key] || []
            var subs = Math.max(1, supp.length)
            return silencedRowH + subRowPadTop
                   + subs * subRowH + Math.max(0, subs - 1) * subRowSpacing
        }

        readonly property int activeListH: {
            var r = Math.max(1, Math.min(maxRowsVisible, activeCount))
            return r * rowH + Math.max(0, r - 1) * listSpacing
        }
        readonly property int silencedListH: {
            // Force re-eval when these change
            void bar.expandedSilenced
            void bar.suppressedApps
            void bar.silencedApps
            var keys = silencedKeys
            if (keys.length === 0) return silencedRowH
            var cap = Math.min(maxRowsVisible, keys.length)
            var total = 0
            for (var i = 0; i < cap; i++) {
                total += silencedHeightFor(keys[i])
                if (i < cap - 1) total += listSpacing
            }
            return total
        }
        readonly property int listH: bar.notifMenuTab === 0 ? activeListH : silencedListH
        readonly property int computedMenuH: padding * 2 + tabsH + rowSpacing + listH + footerExtra
        // Sticky floor — during a single open session the panel never shrinks
        // (no jarring resize when switching tabs). Reset to 0 when the panel
        // closes so the next open starts fresh and grows dynamically.
        property int sessionFloorH: 0
        readonly property int menuH: Math.max(computedMenuH, sessionFloorH)
        onComputedMenuHChanged: {
            if (computedMenuH > sessionFloorH) sessionFloorH = computedMenuH
        }
        Connections {
            target: bar
            function onNotifMenuOpenChanged() {
                if (!bar.notifMenuOpen) notifMenuPanel.sessionFloorH = 0
            }
        }
        readonly property int radius: isPrimary ? 14 : 10
        readonly property int filletR: isPrimary ? 12 : 9

        readonly property color fill: bar.solidify(bar.borderNotif)
        readonly property color txt: bar.contrastText(bar.borderNotif)
        readonly property color dim: bar.contrastDim(bar.borderNotif)
        readonly property color hover: bar.contrastHover(bar.borderNotif)
        // Denser than bar.contrastRow so cards visibly pop against the tray fill.
        readonly property color rowBg: {
            var lum = 0.299 * bar.borderNotif.r + 0.587 * bar.borderNotif.g + 0.114 * bar.borderNotif.b
            return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.20) : Qt.rgba(1, 1, 1, 0.18)
        }

        property int anchorX: 0

        MouseArea {
            anchors.fill: parent
            onClicked: bar.closeNotifMenu()
        }

        Item {
            id: notifMenuShape
            visible: bar.notifMenuOpen || liquidProgress > 0.001
            readonly property int fullH: notifMenuPanel.menuH + notifMenuPanel.filletR
            property real liquidProgress: bar.notifMenuOpen ? 1.0 : 0.0
            Behavior on liquidProgress { NumberAnimation { duration: 460; easing.type: Easing.InOutQuint } }

            x: Math.max(8, Math.min(notifMenuPanel.anchorX - width / 2, notifMenuPanel.width - width - 8))
            width: notifMenuPanel.menuW
            height: fullH
            y: (notifMenuPanel.height - bar.implicitHeight + bar.vm + notifMenuPanel.filletR) - fullH

            Shape {
                width: notifMenuPanel.menuW
                height: notifMenuPanel.menuH
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0
                    fillColor: notifMenuPanel.fill
                    PathSvg {
                        path: bar.dripPath(notifMenuPanel.menuW, notifMenuPanel.menuH,
                                           notifMenuPanel.radius, notifMenuShape.liquidProgress, 23.0)
                    }
                }
            }
            Shape {
                visible: notifMenuShape.liquidProgress > 0.02
                x: (notifMenuPanel.anchorX - notifPill.width / 2) - notifMenuShape.x - notifMenuPanel.filletR
                y: notifMenuPanel.menuH
                width: notifMenuPanel.filletR + bar.rad
                height: notifMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: notifMenuPanel.fill
                    PathSvg {
                        readonly property int f: notifMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0 L " + (f + r) + "," + f + " L " + f + "," + f
                            + " A " + f + "," + f + " 0 0 0 0,0 Z"
                    }
                }
            }
            Shape {
                visible: notifMenuShape.liquidProgress > 0.02
                x: (notifMenuPanel.anchorX + notifPill.width / 2) - notifMenuShape.x - bar.rad
                y: notifMenuPanel.menuH
                width: notifMenuPanel.filletR + bar.rad
                height: notifMenuPanel.filletR
                ShapePath {
                    strokeWidth: 0
                    fillColor: notifMenuPanel.fill
                    PathSvg {
                        readonly property int f: notifMenuPanel.filletR
                        readonly property int r: bar.rad
                        path: "M 0,0 L " + (f + r) + ",0"
                            + " A " + f + "," + f + " 0 0 0 " + r + "," + f
                            + " L 0," + f + " L 0,0 Z"
                    }
                }
            }

            Item {
                id: notifContent
                anchors.fill: parent
                anchors.margins: notifMenuPanel.padding
                anchors.bottomMargin: notifMenuPanel.padding + notifMenuPanel.filletR
                readonly property real reveal: notifMenuShape.liquidProgress > 0.45
                    ? (notifMenuShape.liquidProgress - 0.45) / 0.55 : 0.0
                visible: reveal > 0.001
                opacity: reveal
                transform: Translate { y: (1.0 - notifContent.reveal) * 16 }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: notifMenuPanel.rowSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: notifMenuPanel.tabsH
                        spacing: notifMenuPanel.rowSpacing

                        Repeater {
                            model: [
                                { label: "Active",   tabIdx: 0, count: notifMenuPanel.activeCount },
                                { label: "Silenced", tabIdx: 1, count: notifMenuPanel.silencedCount }
                            ]
                            delegate: Rectangle {
                                id: tabRect
                                required property var modelData
                                readonly property bool sel: bar.notifMenuTab === modelData.tabIdx
                                Layout.fillWidth: true
                                Layout.preferredHeight: notifMenuPanel.tabsH
                                radius: 6
                                color: tabRect.sel ? notifMenuPanel.rowBg
                                       : (tabHover.containsMouse ? notifMenuPanel.hover : "transparent")
                                border.color: tabRect.sel ? notifMenuPanel.txt : "transparent"
                                border.width: tabRect.sel ? 1 : 0
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 6
                                    Text {
                                        text: tabRect.modelData.label
                                        color: notifMenuPanel.txt
                                        font.pixelSize: bar.fs
                                        font.family: bar.fontFamily
                                        font.bold: tabRect.sel
                                    }
                                    Rectangle {
                                        visible: tabRect.modelData.count > 0
                                        Layout.preferredWidth: cntT.implicitWidth + 10
                                        Layout.preferredHeight: cntT.implicitHeight + 4
                                        radius: height / 2
                                        // Inverted pill: solid txt color background, fill color text.
                                        // Maximum contrast against the tab — looks like a clean chip.
                                        color: notifMenuPanel.txt
                                        Text {
                                            id: cntT
                                            anchors.centerIn: parent
                                            text: tabRect.modelData.count
                                            color: notifMenuPanel.fill
                                            font.pixelSize: bar.fs - 2
                                            font.bold: true
                                            font.family: bar.fontFamily
                                        }
                                    }
                                }
                                MouseArea {
                                    id: tabHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bar.notifMenuTab = tabRect.modelData.tabIdx
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "transparent"

                        Text {
                            anchors.centerIn: parent
                            visible: (bar.notifMenuTab === 0 ? notifMenuPanel.activeCount
                                                              : notifMenuPanel.silencedCount) === 0
                            text: bar.notifMenuTab === 0 ? "No new notifications" : "No silenced apps"
                            color: notifMenuPanel.dim
                            font.pixelSize: bar.fs
                            font.family: bar.fontFamily
                        }

                        // Active list
                        ListView {
                            id: activeList
                            anchors.fill: parent
                            visible: bar.notifMenuTab === 0 && notifMenuPanel.activeCount > 0
                            clip: true
                            spacing: notifMenuPanel.listSpacing
                            model: bar.notifLog || []
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Rectangle {
                                id: actRow
                                required property var modelData
                                required property int index
                                width: activeList.width
                                height: notifMenuPanel.rowH
                                radius: 6
                                color: notifMenuPanel.rowBg

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 6
                                    spacing: 10

                                    Item {
                                        Layout.preferredWidth: notifMenuPanel.iconSize
                                        Layout.preferredHeight: notifMenuPanel.iconSize
                                        Layout.alignment: Qt.AlignVCenter
                                        Image {
                                            id: notifIconImg
                                            anchors.fill: parent
                                            sourceSize.width: notifMenuPanel.iconSize * 2
                                            sourceSize.height: notifMenuPanel.iconSize * 2
                                            mipmap: true
                                            smooth: true
                                            fillMode: Image.PreserveAspectFit
                                            visible: status === Image.Ready
                                            source: {
                                                void bar.iconCacheReady
                                                void bar.steamIconVersion
                                                return bar.notifIcon(actRow.modelData)
                                            }
                                        }
                                        Rectangle {
                                            anchors.fill: parent
                                            visible: !notifIconImg.visible
                                            radius: width / 2
                                            color: Qt.rgba(notifMenuPanel.txt.r, notifMenuPanel.txt.g, notifMenuPanel.txt.b, 0.15)
                                            Text {
                                                anchors.centerIn: parent
                                                text: ((actRow.modelData.display || actRow.modelData.key || "?") + "").charAt(0).toUpperCase()
                                                color: notifMenuPanel.txt
                                                font.pixelSize: Math.round(notifMenuPanel.iconSize * 0.5)
                                                font.bold: true
                                                font.family: bar.fontFamily
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 1
                                        Text {
                                            Layout.fillWidth: true
                                            text: (actRow.modelData.display || actRow.modelData.key || "(unknown)")
                                            color: notifMenuPanel.txt
                                            font.pixelSize: bar.fs - 1
                                            font.family: bar.fontFamily
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: actRow.modelData.summary || ""
                                            color: notifMenuPanel.txt
                                            font.pixelSize: bar.fs - 1
                                            font.family: bar.fontFamily
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            visible: text.length > 0
                                            text: actRow.modelData.body || ""
                                            color: notifMenuPanel.txt
                                            font.pixelSize: bar.fs - 1
                                            font.family: bar.fontFamily
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }
                                    }

                                    Rectangle {
                                        Layout.preferredWidth: notifMenuPanel.tabsH
                                        Layout.preferredHeight: notifMenuPanel.tabsH
                                        Layout.alignment: Qt.AlignVCenter
                                        radius: width / 2
                                        color: silHov.containsMouse ? notifMenuPanel.hover : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: String.fromCodePoint(0xF1F7)
                                            color: notifMenuPanel.txt
                                            font.pixelSize: isPrimary ? 14 : 11
                                            font.family: bar.fontFamily
                                        }
                                        MouseArea {
                                            id: silHov
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: bar.silenceApp(
                                                actRow.modelData.key,
                                                actRow.modelData.display || actRow.modelData.key,
                                                actRow.modelData.app_name || "",
                                                actRow.modelData.desktop_entry || "")
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: Qt.PointingHandCursor
                                    z: -1
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            bar.silenceApp(
                                                actRow.modelData.key,
                                                actRow.modelData.display || actRow.modelData.key,
                                                actRow.modelData.app_name || "",
                                                actRow.modelData.desktop_entry || "")
                                        } else {
                                            bar.activateNotif(actRow.modelData.id, actRow.modelData.key || "")
                                        }
                                    }
                                }
                            }
                        }

                        // Silenced list
                        ListView {
                            id: silencedList
                            anchors.fill: parent
                            visible: bar.notifMenuTab === 1 && notifMenuPanel.silencedCount > 0
                            clip: true
                            spacing: notifMenuPanel.listSpacing
                            model: notifMenuPanel.silencedKeys
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Item {
                                id: silRow
                                required property string modelData
                                required property int index
                                width: silencedList.width
                                readonly property var entry: (bar.silencedApps || {})[modelData] || ({})
                                readonly property var suppressed: {
                                    void bar.suppressedApps
                                    return (bar.suppressedApps || {})[modelData] || []
                                }
                                readonly property bool expanded: bar.expandedSilenced[modelData] === true
                                height: notifMenuPanel.silencedHeightFor(modelData)
                                Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                                Rectangle {
                                    id: silHeader
                                    anchors.top: parent.top
                                    width: parent.width
                                    height: notifMenuPanel.silencedRowH
                                    radius: 6
                                    color: silHeaderHov.containsMouse
                                        ? notifMenuPanel.hover : notifMenuPanel.rowBg

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 8
                                        spacing: 8

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            Layout.preferredWidth: implicitWidth
                                            text: silRow.expanded ? "▾" : "▸"
                                            color: notifMenuPanel.txt
                                            font.pixelSize: bar.fs - 1
                                            font.family: bar.fontFamily
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            text: silRow.entry.display || silRow.modelData
                                            color: notifMenuPanel.txt
                                            font.pixelSize: bar.fs - 1
                                            font.family: bar.fontFamily
                                            elide: Text.ElideRight
                                        }
                                        Rectangle {
                                            visible: silRow.suppressed.length > 0
                                            Layout.alignment: Qt.AlignVCenter
                                            Layout.preferredWidth: suppCntT.implicitWidth + 10
                                            Layout.preferredHeight: suppCntT.implicitHeight + 4
                                            radius: height / 2
                                            color: notifMenuPanel.dim
                                            Text {
                                                id: suppCntT
                                                anchors.centerIn: parent
                                                text: silRow.suppressed.length
                                                color: notifMenuPanel.txt
                                                font.pixelSize: bar.fs - 2
                                                font.family: bar.fontFamily
                                            }
                                        }
                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            Layout.preferredWidth: enableT.implicitWidth + 16
                                            Layout.preferredHeight: notifMenuPanel.tabsH - 6
                                            radius: height / 2
                                            color: enHov.containsMouse ? notifMenuPanel.hover : "transparent"
                                            border.color: notifMenuPanel.txt
                                            border.width: 1
                                            Text {
                                                id: enableT
                                                anchors.centerIn: parent
                                                text: "Enable"
                                                color: notifMenuPanel.txt
                                                font.pixelSize: bar.fs - 2
                                                font.family: bar.fontFamily
                                            }
                                            MouseArea {
                                                id: enHov
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: bar.unsilenceApp(silRow.modelData)
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: silHeaderHov
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        z: -1
                                        onClicked: bar.toggleSilencedExpand(silRow.modelData)
                                    }
                                }

                                Column {
                                    id: suppCol
                                    anchors.top: silHeader.bottom
                                    anchors.topMargin: notifMenuPanel.subRowPadTop
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: 14
                                    spacing: notifMenuPanel.subRowSpacing
                                    visible: silRow.expanded
                                    opacity: silRow.expanded ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 140 } }

                                    Repeater {
                                        model: silRow.suppressed
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: suppCol.width
                                            height: notifMenuPanel.subRowH
                                            radius: 4
                                            color: Qt.rgba(notifMenuPanel.txt.r, notifMenuPanel.txt.g,
                                                           notifMenuPanel.txt.b, 0.08)
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 10
                                                anchors.rightMargin: 8
                                                spacing: 6
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: {
                                                        var s = modelData.summary || "(no summary)"
                                                        var b = modelData.body || ""
                                                        return b.length > 0 ? s + " — " + b : s
                                                    }
                                                    color: notifMenuPanel.txt
                                                    font.pixelSize: bar.fs - 2
                                                    font.family: bar.fontFamily
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    text: {
                                                        var diff = Math.max(0, Math.floor(Date.now()/1000) - (modelData.ts || 0))
                                                        if (diff < 60)    return diff + "s"
                                                        if (diff < 3600)  return Math.floor(diff/60) + "m"
                                                        if (diff < 86400) return Math.floor(diff/3600) + "h"
                                                        return Math.floor(diff/86400) + "d"
                                                    }
                                                    color: notifMenuPanel.dim
                                                    font.pixelSize: bar.fs - 3
                                                    font.family: bar.fontFamily
                                                }
                                            }
                                        }
                                    }
                                    // Empty state when nothing suppressed yet
                                    Rectangle {
                                        visible: silRow.suppressed.length === 0
                                        width: suppCol.width
                                        height: notifMenuPanel.subRowH
                                        radius: 4
                                        color: "transparent"
                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "(nothing suppressed since silencing)"
                                            color: notifMenuPanel.dim
                                            font.pixelSize: bar.fs - 2
                                            font.italic: true
                                            font.family: bar.fontFamily
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Clear-all footer — visible on either tab when that tab
                    // has something to clear. Active wipes counts+log+popups;
                    // Silenced wipes the per-app audit log but leaves apps
                    // silenced (use per-row Enable to unsilence).
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: notifMenuPanel.showFooter ? notifMenuPanel.footerH : 0
                        Layout.topMargin: notifMenuPanel.showFooter ? notifMenuPanel.footerTopMargin : 0
                        visible: notifMenuPanel.showFooter

                        Rectangle {
                            anchors.centerIn: parent
                            width: clearAllText.implicitWidth + (isPrimary ? 26 : 18)
                            height: notifMenuPanel.footerH
                            radius: height / 2
                            color: clearAllHov.containsMouse ? notifMenuPanel.hover : notifMenuPanel.rowBg
                            border.color: notifMenuPanel.txt
                            border.width: 1
                            Text {
                                id: clearAllText
                                anchors.centerIn: parent
                                text: bar.notifMenuTab === 0 ? "Clear all" : "Clear audit log"
                                color: notifMenuPanel.txt
                                font.pixelSize: bar.fs - 1
                                font.bold: true
                                font.family: bar.fontFamily
                            }
                            MouseArea {
                                id: clearAllHov
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (bar.notifMenuTab === 0) bar.clearAllNotifs()
                                    else bar.clearAllSuppressed()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Brightness tracking — DDC/CI monitors auto-detected at startup.
    // Each entry: { name: "DP-1", bus: 7, brightness: 50 }. No hardcoded buses,
    // so this works on any machine with any number of DDC-capable monitors.
    property var ddcMonitors: []

    function readAllBrightness() {
        if (!ddcMonitors.length) return
        var buses = ddcMonitors.map(function (m) { return m.bus }).join(" ")
        brightnessReadAll.command = ["bash", "-c",
            "for b in " + buses + "; do v=$(ddcutil getvcp 10 --bus $b --brief 2>/dev/null | awk '{print $4}'); echo \"$b $v\"; done"]
        brightnessReadAll.running = true
    }

    // Discover DDC monitors: parse `ddcutil detect` into { connector, bus } pairs.
    Process {
        id: ddcDetectProc
        command: ["bash", "-c",
            "ddcutil detect --brief 2>/dev/null | awk '" +
            "/^Display/{if(bus!=\"\"){print conn\"\\t\"bus}; bus=\"\"; conn=\"\"} " +
            "/I2C bus:/{n=$NF; sub(/.*i2c-/,\"\",n); bus=n} " +
            "/DRM connector:/{c=$NF; sub(/^card[0-9]+-/,\"\",c); conn=c} " +
            "END{if(bus!=\"\"){print conn\"\\t\"bus}}'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var out = this.text.trim()
                var mons = []
                if (out) {
                    var lines = out.split("\n")
                    for (var i = 0; i < lines.length; i++) {
                        var parts = lines[i].split("\t")
                        if (parts.length < 2) continue
                        var busNum = parseInt(parts[1])
                        if (isNaN(busNum)) continue
                        // Carry over the last-known brightness for this bus. The
                        // detect re-runs on every menu open; without this, each
                        // open rebuilt the list at 50% and the sliders flashed to
                        // 50 before the (slow) getvcp re-read corrected them. A
                        // genuinely new monitor starts at 50 until its first read.
                        var carried = 50
                        for (var k = 0; k < bar.ddcMonitors.length; k++) {
                            if (bar.ddcMonitors[k].bus === busNum) { carried = bar.ddcMonitors[k].brightness; break }
                        }
                        mons.push({ name: parts[0] || ("bus " + busNum), bus: busNum, brightness: carried })
                    }
                }
                bar.ddcMonitors = mons
                bar.readAllBrightness()
            }
        }
    }

    // Read each detected monitor's current brightness in one batched call.
    Process {
        id: brightnessReadAll
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n")
                var map = {}
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim().split(/\s+/)
                    if (p.length < 2) continue
                    var b = parseInt(p[0]); var v = parseInt(p[1])
                    if (!isNaN(b) && !isNaN(v)) map[b] = v
                }
                var mons = bar.ddcMonitors.slice()
                for (var j = 0; j < mons.length; j++) {
                    if (map[mons[j].bus] !== undefined) mons[j].brightness = map[mons[j].bus]
                }
                bar.ddcMonitors = mons
            }
        }
    }

    // Close launcher when clicking elsewhere on the bar
    MouseArea {
        anchors.fill: parent
        visible: bar.launcherOpen
        z: 100
        propagateComposedEvents: true
        onClicked: function(mouse) {
            bar.closeLauncher()
            mouse.accepted = false
        }
    }

    // ══════════════════════════════════════════════
    // RIGHT SIDE
    // ══════════════════════════════════════════════
    RowLayout {
        id: rightSection
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        spacing: bar.hm

        // Minimized Windows Tray (macOS-style stash)
        Rectangle {
            Layout.preferredWidth: minimizedRow.implicitWidth + (isPrimary ? 16 : 10)
            Layout.preferredHeight: parent.height - bar.vm * 2
            Layout.alignment: Qt.AlignVCenter
            color: Qt.rgba(0, 0, 0, 0.65); radius: bar.rad
            visible: bar.minimizedWindows.length > 0

            RowLayout {
                id: minimizedRow; anchors.centerIn: parent; spacing: isPrimary ? 6 : 4
                Repeater {
                    model: bar.minimizedWindows.length
                    delegate: Item {
                        id: minDelegate
                        required property int index
                        readonly property var winData: bar.minimizedWindows[index]
                        Layout.preferredWidth: isPrimary ? 30 : 22
                        Layout.preferredHeight: isPrimary ? 30 : 22

                        Image {
                            id: minIcon; anchors.centerIn: parent
                            width: isPrimary ? 22 : 16; height: width
                            sourceSize.width: 64; sourceSize.height: 64
                            mipmap: true; smooth: true
                            fillMode: Image.PreserveAspectFit
                            visible: status === Image.Ready
                            opacity: minMouse.containsMouse ? 1.0 : 0.65
                            source: {
                                void bar.iconCacheReady; void bar.steamIconVersion
                                if (!minDelegate.winData) return ""
                                return bar.resolveAppIcon(minDelegate.winData.appId || "", minDelegate.winData.title || "")
                            }
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                        Text {
                            anchors.centerIn: parent; visible: !minIcon.visible
                            text: minDelegate.winData && minDelegate.winData.appId ? minDelegate.winData.appId[0].toUpperCase() : "?"
                            color: bar.colText
                            font.pixelSize: isPrimary ? 12 : 9; font.family: bar.fontFamily; font.bold: true
                            opacity: minMouse.containsMouse ? 1.0 : 0.65
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            id: minMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                if (minDelegate.winData && minDelegate.winData.address) {
                                    Hyprland.dispatch("exec " + bar.homeDir + "/.config/hypr/minimize-restore.sh " + minDelegate.winData.address)
                                    // Refresh immediately rather than waiting for the next 800ms tick
                                    minimizedProc.running = true
                                }
                            }
                        }

                        // Notification badge for this minimized app
                        Rectangle {
                            readonly property string minCls: minDelegate.winData ? (minDelegate.winData.appId || "") : ""
                            readonly property int badgeCount: bar.effectiveBadgeCount(minCls)
                            readonly property bool badgeMuted: bar.effectiveBadgeMuted(minCls)
                            visible: badgeCount > 0
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: isPrimary ? -2 : -1
                            anchors.rightMargin: isPrimary ? -2 : -1
                            width: Math.max(minBadgeText.implicitWidth + (isPrimary ? 6 : 4), isPrimary ? 16 : 12)
                            height: isPrimary ? 14 : 11
                            radius: height / 2
                            color: badgeMuted ? Qt.rgba(0.42, 0.44, 0.5, 0.92) : bar.gradientEnd
                            border.color: Qt.rgba(0, 0, 0, 0.6); border.width: 1
                            z: 2
                            Text {
                                id: minBadgeText
                                anchors.centerIn: parent
                                text: parent.badgeCount > 99 ? "99+" : parent.badgeCount.toString()
                                color: bar.contrastText(parent.color)
                                font.pixelSize: isPrimary ? 9 : 7
                                font.bold: true
                                font.family: bar.fontFamily
                            }
                        }
                    }
                }
            }
        }

        // System Tray
        Rectangle {
            Layout.preferredWidth: trayRow.implicitWidth + (isPrimary ? 16 : 10)
            Layout.preferredHeight: parent.height - bar.vm * 2
            Layout.alignment: Qt.AlignVCenter
            color: Qt.rgba(0, 0, 0, 0.65); radius: bar.rad
            visible: SystemTray.items.values.length > 0
            RowLayout {
                id: trayRow; anchors.centerIn: parent; spacing: isPrimary ? 6 : 4
                Repeater {
                    model: SystemTray.items
                    delegate: Item {
                        id: trayDelegate
                        required property var modelData
                        readonly property var trayItem: modelData
                        Layout.preferredWidth: isPrimary ? 30 : 22
                        Layout.preferredHeight: isPrimary ? 30 : 22
                        Image { anchors.centerIn: parent; width: isPrimary ? 22 : 16; height: width; source: trayDelegate.trayItem.icon; smooth: true }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function(mouse) {
                                if (mouse.button === Qt.RightButton || trayDelegate.trayItem.onlyMenu) {
                                    if (trayDelegate.trayItem.hasMenu) {
                                        var pos = trayDelegate.mapToItem(null, mouse.x, mouse.y)
                                        trayDelegate.trayItem.display(bar, pos.x, pos.y)
                                    }
                                } else {
                                    trayDelegate.trayItem.activate()
                                }
                            }
                        }
                    }
                }
            }
        }

        // Volume
        Pill {
            id: volPill
            borderColor: bar.borderVol; filled: true
            flatTop: bar.volMenuOpen
            readonly property color txt: bar.contrastText(bar.borderVol)
            readonly property color dim: bar.contrastDim(bar.borderVol)
            Layout.preferredWidth: volRow.implicitWidth + (isPrimary ? 20 : 14)
            Layout.preferredHeight: parent.height - bar.vm * 2

            // Bottom layer: catches right-clicks anywhere on the pill (children handle left)
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) bar.openVolMenu()
                }
            }

            RowLayout {
                id: volRow; anchors.centerIn: parent; spacing: isPrimary ? 6 : 4
                Text {
                    text: bar.audioMuted ? String.fromCodePoint(0xF026) : String.fromCodePoint(0xF028)
                    color: volPill.txt; font.pixelSize: bar.fs; font.family: bar.fontFamily
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { if (bar.audioSink && bar.audioSink.audio) bar.audioSink.audio.muted = !bar.audioSink.audio.muted }
                    }
                }
                Text {
                    text: bar.audioMuted ? "MUTE" : bar.pad3(bar.volumePercent) + "%"
                    color: volPill.txt; font.pixelSize: bar.fs; font.family: bar.fontFamily
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: bar.openVolMenu()
                    }
                }
                Rectangle {
                    Layout.preferredWidth: isPrimary ? 60 : 40; Layout.preferredHeight: isPrimary ? 6 : 4
                    Layout.alignment: Qt.AlignVCenter; radius: 3; color: volPill.dim
                    Rectangle { width: parent.width * Math.min(bar.volumePercent / 100, 1.0); height: parent.height; radius: 3; color: volPill.txt
                        Behavior on width { NumberAnimation { duration: 100 } }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onPressed: function(mouse) { var v = mouse.x / parent.width; v = Math.max(0, Math.min(1, v)); if (bar.audioSink && bar.audioSink.audio) bar.audioSink.audio.volume = v }
                        onPositionChanged: function(mouse) { if (pressed) { var v = mouse.x / parent.width; v = Math.max(0, Math.min(1, v)); if (bar.audioSink && bar.audioSink.audio) bar.audioSink.audio.volume = v } }
                    }
                }
            }
        }

        // Clock
        Pill {
            id: clockPill
            borderColor: bar.borderClock; filled: true
            flatTop: bar.clockMenuOpen
            Layout.preferredWidth: clockLabel.implicitWidth + (isPrimary ? 24 : 16)
            Layout.preferredHeight: parent.height - bar.vm * 2
            Text { id: clockLabel; anchors.centerIn: parent; text: bar.clockText; color: bar.contrastText(bar.borderClock); font.pixelSize: bar.fs; font.family: bar.fontFamily }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.openClockMenu()
            }
        }

        // Notification tray — width locked to "icon + 99+" so the pill never
        // resizes as the count changes.
        Pill {
            id: notifPill
            borderColor: bar.borderNotif; filled: true
            flatTop: bar.notifMenuOpen
            readonly property color txt: bar.contrastText(bar.borderNotif)
            readonly property int activeCount: bar.notifLog ? bar.notifLog.length : 0
            Layout.preferredWidth: notifPillSizer.implicitWidth + (isPrimary ? 20 : 14)
            Layout.preferredHeight: parent.height - bar.vm * 2
            RowLayout {
                id: notifPillSizer
                visible: false
                spacing: isPrimary ? 6 : 4
                Text {
                    text: String.fromCodePoint(0xF0F3)
                    font.pixelSize: isPrimary ? 16 : 13
                    font.family: bar.fontFamily
                }
                Text {
                    text: "99+"
                    font.pixelSize: bar.fs
                    font.family: bar.fontFamily
                }
            }
            // Icon + count, centered as a group. Pill width is locked above so
            // the group just shifts left/right as the count appears/disappears.
            RowLayout {
                anchors.centerIn: parent
                spacing: isPrimary ? 6 : 4
                Text {
                    text: String.fromCodePoint(notifPill.activeCount > 0 ? 0xF0F3 : 0xF0A2)
                    color: notifPill.txt
                    font.pixelSize: isPrimary ? 16 : 13
                    font.family: bar.fontFamily
                }
                Text {
                    visible: notifPill.activeCount > 0
                    text: notifPill.activeCount > 99 ? "99+" : notifPill.activeCount.toString()
                    color: notifPill.txt
                    font.pixelSize: bar.fs
                    font.family: bar.fontFamily
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.openNotifMenu()
            }
        }

        // Power
        Pill {
            borderColor: bar.borderPower; filled: true
            Layout.preferredWidth: isPrimary ? 46 : 36
            Layout.preferredHeight: parent.height - bar.vm * 2
            Layout.rightMargin: bar.hm
            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF011); color: bar.contrastText(bar.borderPower); font.pixelSize: isPrimary ? 16 : 13; font.family: bar.fontFamily }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: wlogoutLauncher.running = true }
        }
    }
}
