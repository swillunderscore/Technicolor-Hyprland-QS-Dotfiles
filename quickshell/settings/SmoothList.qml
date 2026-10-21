import QtQuick
import QtQuick.Controls

// Built-in scrollable container. ScrollView handles the mouse wheel (both
// directions), touch and the scrollbar natively — no custom handler. contentWidth
// is pinned to availableWidth so it only scrolls vertically; each usage supplies
// contentHeight + a single Column child (whose width binds to parent.width).
ScrollView {
    id: sfl
    clip: true
    contentWidth: availableWidth
    // Always sized from outside (anchors, a Loader, explicit width/height).
    // ScrollView's own implicitWidth is derived from contentWidth, which is
    // derived from width, so as a Loader's item it reported a binding loop.
    implicitWidth: 0
    implicitHeight: 0
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical.policy: ScrollBar.AsNeeded
    ScrollBar.vertical.background: null      // remove the default track/groove
    ScrollBar.vertical.minimumSize: 0.08     // a 300-font list otherwise gets a 5 px dot
    // The desktop style (Breeze) gives the bar its own width, ~20 px, and
    // stretches the content item to it: draw a 5 px thumb on its right edge.
    ScrollBar.vertical.contentItem: Item {
        implicitWidth: 5
        Rectangle {
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 5; radius: 3
            color: ST.fg
            opacity: sfl.ScrollBar.vertical.pressed ? 0.6 : (sfl.ScrollBar.vertical.hovered ? 0.42 : 0.26)
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }
    }
}
