import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "gshulga.agent-limits"
  ipcTarget: "gshulga.agent-limits"
  manageIpc: false
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor(root.moduleName) : null
  readonly property var cache: service ? service.cache : Model.emptyCache()
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int remaining: Model.remainingPercent(cache.providers || [])
  readonly property var tightest: Model.tightestWindow(cache.providers || [])
  property double nowMs: Date.now()
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string tooltip: {
    if (root.remaining < 0) return strings.t("hero.title") + "\n" + strings.t("tooltip.empty")
    var window = root.tightest ? root.tightest.provider + " · " + root.tightest.label : strings.t("hero.pressure")
    return strings.t("hero.title") + "\n" + Model.format(strings.t("tooltip.pressure"), [root.remaining + "%", window]) + "\n" + strings.t("tooltip.refresh")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { if (service) service.refresh() }
  onOpenedChanged: if (opened) { nowMs = Date.now(); refresh(); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩 " + (root.remaining >= 0 ? root.remaining + "%" : "—")
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.remaining >= 0 && root.remaining <= 20
    activeColor: root.remaining >= 0 && root.remaining <= 5 ? root.urgent : Commons.Color.accent
    tooltipText: Model.escapeMarkup(root.tooltip)
    onPressed: function(buttonCode) { if (buttonCode === Qt.MiddleButton) root.refresh(); else root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(680))
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) body.tab = dx > 0 ? (body.tab === "limits" ? "usage" : "cost") : (body.tab === "cost" ? "usage" : "limits")
        if (dy !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(60)))
      }
      onActivateRequested: root.refresh()
      onTextKey: function(value) {
        if (value === "r" || value === "R") root.refresh()
        else if (value === "1") body.tab = "limits"
        else if (value === "2") body.tab = "usage"
        else if (value === "3") body.tab = "cost"
      }
      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        Dashboard {
          id: body
          width: flick.width
          cache: root.cache
          nowMs: root.nowMs
          syncing: root.service ? root.service.syncing : false
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          warningPercent: Number(root.setting("warningPercent", 80))
          criticalPercent: Number(root.setting("criticalPercent", 95))
          onRefreshRequested: root.refresh()
        }
      }
    }
  }
}
