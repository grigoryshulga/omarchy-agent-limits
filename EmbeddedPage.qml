import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Shared native Dashboard and Side Panel page. Hosted pages cannot rely on the
// target plugin's scoped service, so they read the same secret-free snapshot.
Item {
  id: root
  property var settings: ({})
  property string pluginId: ""
  property bool active: true
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/agent-limits/data.json"
  property var cache: Model.emptyCache()
  property double nowMs: Date.now()
  readonly property bool syncing: syncProcess.running

  function initialize(context) {
    settings = context && context.settings ? context.settings : ({})
    pluginId = context && context.pluginId ? String(context.pluginId) : ""
    active = true
    nowMs = Date.now()
    refresh()
  }
  function initializeDashboard(context) { initialize(context) }
  function initializeSidePanel(context) { initialize(context) }
  function activate() { active = true; nowMs = Date.now(); refresh(); flick.forceActiveFocus() }
  function dashboardActivate(context) { activate() }
  function sidePanelActivate(context) { activate() }
  function dashboardFocus() { flick.forceActiveFocus() }
  function sidePanelFocus() { flick.forceActiveFocus() }
  function deactivate() { active = false }
  function dashboardDeactivate(reason) { deactivate() }
  function sidePanelDeactivate(reason) { deactivate() }
  function refresh() { if (!syncProcess.running) syncProcess.running = true }

  FileView {
    id: cacheView
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.cache = Model.parseCache(text())
    onLoadFailed: root.cache = Model.emptyCache()
  }
  Process {
    id: syncProcess
    command: [root.pluginDir + "bin/omarchy-agent-limits-sync", "sync"]
    // The cache is written through a temporary file and renamed into place, so
    // an inotify watch follows the old inode and stops reporting changes.
    // Reading the file again as soon as the writer exits keeps the view current.
    onExited: cacheView.reload()
  }
  Timer {
    interval: Math.max(60, Math.min(3600, Number(root.settings.refreshIntervalSec || 300))) * 1000
    running: root.active
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer { interval: 60000; running: root.active; repeat: true; onTriggered: root.nowMs = Date.now() }

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
      syncing: root.syncing
      warningPercent: Number(root.settings.warningPercent || 80)
      criticalPercent: Number(root.settings.criticalPercent || 95)
      onRefreshRequested: root.refresh()
    }
  }
}
