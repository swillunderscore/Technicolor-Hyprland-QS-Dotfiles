import QtQuick
import QtQuick.Effects

// A picture that refreshes without blinking, cut to a rounded rectangle.
// Image clears itself while a new source loads, so each new source loads into
// the hidden one of two Images, which is then raised on top once it's ready.
// Both stay fully opaque: a crossfade made each half-transparent mid-fade and
// the color behind showed through on every refresh. `clip` only cuts to the
// bounding box, so with a radius the corners are masked instead (the mask is a
// texture the size of the picture).
Item {
    id: pi
    property string source: ""
    property int fillMode: Image.PreserveAspectCrop
    property real radius: 0
    readonly property bool ready: a.status === Image.Ready || b.status === Image.Ready
    property bool aFront: true
    onSourceChanged: (pi.aFront ? b : a).source = pi.source

    Item {
        id: stack
        anchors.fill: parent
        layer.enabled: pi.radius > 0
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: roundMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
        Image {
            id: a
            anchors.fill: parent
            cache: false; asynchronous: true; smooth: true; mipmap: true
            fillMode: pi.fillMode
            z: pi.aFront ? 1 : 0
            onStatusChanged: if (status === Image.Ready && !pi.aFront && source.toString() === pi.source) pi.aFront = true
        }
        Image {
            id: b
            anchors.fill: parent
            cache: false; asynchronous: true; smooth: true; mipmap: true
            fillMode: pi.fillMode
            z: pi.aFront ? 0 : 1
            onStatusChanged: if (status === Image.Ready && pi.aFront && source.toString() === pi.source) pi.aFront = false
        }
    }
    Rectangle {
        id: roundMask
        anchors.fill: parent
        radius: pi.radius
        visible: false
        layer.enabled: true
        layer.smooth: true
    }
}
