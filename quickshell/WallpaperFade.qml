// WallpaperFade.qml — GPU wallpaper-transition overlay (one per screen).
//
// The old transition CPU-composited 21 static frames and pushed each through
// `awww img`, which froze both animations to ~14fps resamples, stretched
// mismatched aspect ratios, spiked the CPU, and could stall up to 2s at the
// handoff while awww cold-decoded NEW. This replaces all of that:
//
//   - awww keeps playing OLD untouched underneath (native cadence — never
//     re-created, never estimated).
//   - NEW plays here as an AnimatedImage (native cadence, GPU nearest-neighbor
//     upscale, PreserveAspectCrop = the same centered cover-crop awww uses).
//   - A fragment shader (wallfade.frag) reveals NEW per-pixel from the rank
//     map wallpaper-fade-map.py generates — same 11 modes, same pacing.
//   - At reveal end the shell root applies NEW to awww UNDER this (fully
//     opaque) overlay, so cache-cold decode time is invisible; the overlay
//     then drops exactly when awww's animation clock matches ours.
//
// Idle cost is zero: the window is only mapped while shell.wfActive.
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: win
    required property var modelData      // the screen (from Variants)
    property var shell                   // the ShellRoot
    // One overlay drives the shared handoff logic; the others just render.
    property bool isDriver: false

    screen: modelData
    visible: shell ? shell.wfActive : false
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Bottom          // above awww (Background), below windows
    WlrLayershell.namespace: "quickshell:wallfade"
    exclusionMode: ExclusionMode.Ignore            // span the full screen, bar included
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}                                // input passes straight through

    // NEW at native resolution; texture provider for the shader. smooth:false
    // keeps the pixel-art upscale nearest-neighbor, matching --filter Nearest.
    AnimatedImage {
        id: img
        visible: false
        source: (shell && shell.wfNew) ? "file://" + shell.wfNew : ""
        // Starts false so the entry frame can be seeked before playback — a
        // currentFrame write is IGNORED once playing (and pause-set-resume
        // freezes outright); the binding is attached after the seek.
        playing: false
        smooth: false
        mipmap: false
        cache: true
        // Enter NEW mid-loop at a wall-clock-derived phase — as if it had been
        // playing in the background all along — instead of opening every
        // transition on the loop's "beginning moment". The handoff doesn't
        // care: the restart apply fires on whichever frame-0 wrap comes next.
        // Seek + play are imperative because a currentFrame write is ignored
        // once playing; called from BOTH hooks below since Ready-vs-wfActive
        // order is race-prone (a Qt-cached image is Ready DURING the source
        // assignment, before wfStart sets wfActive — gating on one order left
        // the overlay frozen on frame 0).
        function syncStart() {
            if (frameCount > 1 && shell.wfAvgMs > 0)
                currentFrame = Math.floor(Date.now() / shell.wfAvgMs) % frameCount
            playing = true
        }
        onStatusChanged: {
            if (status === Image.Error && win.isDriver && shell) shell.wfImageError()
            if (status === Image.Ready && shell && shell.wfActive) syncStart()
        }
        Connections {
            target: win.shell
            function onWfActiveChanged() {
                if (win.shell.wfActive) {
                    if (img.status === Image.Ready) img.syncStart()
                } else {
                    img.playing = false   // idle: stop decode entirely
                }
            }
        }
        // The root's 20ms alignment poll (wfAlign) reads this to find the
        // moment our frame == awww's modeled frame, then drops the overlay.
        onCurrentFrameChanged: if (win.isDriver && shell) shell.wfOverlayFrame = currentFrame
    }

    // Reveal-rank map (960x540, regenerated each transition at the same path —
    // cache:false so Qt's pixmap cache never serves a stale one).
    Image {
        id: fmap
        visible: false
        source: (shell && shell.wfMap) ? "file://" + shell.wfMap : ""
        smooth: true
        cache: false
    }

    ShaderEffect {
        anchors.fill: parent
        visible: img.status === Image.Ready && fmap.status === Image.Ready
        property variant source: img
        property variant fadeMap: fmap
        property real progress: shell ? shell.wfProgress : 0
        property real fadeFrac: 0.195   // FADE_DURATION 0.30s / TOTAL 1.54s
        property real imgAspect: img.implicitHeight > 0 ? img.implicitWidth / img.implicitHeight : 1.7778
        property real scrAspect: win.height > 0 ? win.width / win.height : 1.7778
        fragmentShader: Qt.resolvedUrl("wallfade.frag.qsb")
    }
}
