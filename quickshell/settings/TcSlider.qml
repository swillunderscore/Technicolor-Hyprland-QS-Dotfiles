import QtQuick

// Track + fill + draggable knob. moved() fires live while dragging, committed()
// on release. The owner binds `value` and updates its own state in onMoved —
// never assign sl.value from outside, or the binding breaks.
Item {
    id: sl
    property real from: 0
    property real to: 1
    property real value: 0.5
    signal moved(real v)
    signal committed(real v)
    implicitHeight: 26
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.right: parent.right
        height: 6; radius: 3; color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.18)
        Rectangle {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            height: parent.height; radius: 3; color: ST.fg; opacity: 0.55
            width: parent.width * Math.max(0, Math.min(1, (sl.value - sl.from) / (sl.to - sl.from)))
        }
    }
    Rectangle {
        width: 18; height: 18; radius: 9; color: ST.fg
        anchors.verticalCenter: parent.verticalCenter
        x: (sl.width - width) * Math.max(0, Math.min(1, (sl.value - sl.from) / (sl.to - sl.from)))
    }
    MouseArea {
        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
        // Every slider lives inside a scrolling page, and a Flickable STEALS the
        // mouse grab the moment a drag looks vertical — the slider used to stop
        // dead as soon as the pointer wandered off the track. preventStealing
        // keeps the grab here for the whole press.
        preventStealing: true
        function emit(mx) { sl.moved(sl.from + Math.max(0, Math.min(1, mx / sl.width)) * (sl.to - sl.from)) }
        onPressed: (m) => emit(m.x)
        onPositionChanged: (m) => { if (pressed) emit(m.x) }
        onReleased: sl.committed(sl.value)
    }
}
