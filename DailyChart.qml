import QtQuick

// Daily bars. A bar per day reads better than a line for spend/usage because
// every value is an independent bucket, not a continuous quantity.
Item {
  id: root
  property var points: []
  property color barColor: "white"
  property color gridColor: Qt.rgba(barColor.r, barColor.g, barColor.b, 0.14)
  property real maxBarWidth: 26
  property real barGap: 2
  // Optional {index, label} ticks under the plot, used by the hourly view.
  property var ticks: []
  // Optional colour lookup so a bucket can be split into per-provider segments.
  property var colorFor: null
  readonly property real labelHeight: ticks.length > 0 ? 12 : 0
  property color tickColor: Qt.rgba(barColor.r, barColor.g, barColor.b, 0.45)
  readonly property real slot: width / Math.max(1, points.length)
  readonly property real peak: {
    var value = 0
    for (var i = 0; i < points.length; i++) value = Math.max(value, Number(points[i].value || 0))
    return Math.max(1, value)
  }
  implicitHeight: 70

  Item {
    id: plot
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.max(1, root.height - root.labelHeight)

    Repeater {
      model: 4
      Rectangle {
        required property int index
        width: plot.width
        height: 1
        y: Math.round(plot.height * index / 3)
        color: root.gridColor
      }
    }

    Repeater {
      model: root.points
      Rectangle {
        id: bar
        required property var modelData
        required property int index
        readonly property var parts: modelData.parts && modelData.parts.length > 0
          ? modelData.parts
          : [{ id: "", value: modelData.value }]
        readonly property real total: Math.max(1e-9, Number(modelData.value || 0))
        // A single bucket (the "Today" preset) is centred instead of stretching
        // one bar across the whole width.
        readonly property real ratio: Math.max(0, Math.min(1, total / root.peak))
        anchors.bottom: plot.bottom
        x: root.slot * index + (root.slot - width) / 2
        width: Math.min(root.maxBarWidth, Math.max(1, root.slot - root.barGap))
        // A non-zero bucket never disappears into the baseline.
        height: ratio <= 0 ? 0 : Math.max(2, plot.height * ratio)
        color: "transparent"
        clip: true
        // Segments are stacked from the baseline up: each one's offset is the
        // sum of the parts under it, so no layout container is involved and a
        // one-pixel rounding error can only ever hide inside clip.
        Repeater {
          model: bar.parts
          Rectangle {
            required property var modelData
            required property int index
            readonly property real below: {
              var sum = 0
              for (var i = 0; i < index; i++) sum += Number(bar.parts[i].value || 0)
              return sum
            }
            readonly property real span: Number(modelData.value || 0) / bar.total
            x: 0
            width: bar.width
            height: Math.max(1, bar.height * span)
            y: Math.max(0, bar.height - bar.height * (below / bar.total + span))
            color: root.colorFor !== null && String(modelData.id) !== ""
              ? root.colorFor(String(modelData.id))
              : root.barColor
            radius: index === bar.parts.length - 1 ? Math.min(2, width / 2) : 0
          }
        }
      }
    }
  }

  Repeater {
    model: root.ticks
    PlainText {
      required property var modelData
      anchors.bottom: parent.bottom
      x: Math.max(0, Math.min(root.width - root.slot, root.slot * modelData.index))
      width: root.slot
      horizontalAlignment: Text.AlignHCenter
      text: String(modelData.label)
      color: root.tickColor
      font.pixelSize: 10
    }
  }
}
