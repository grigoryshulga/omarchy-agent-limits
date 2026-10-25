import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  visible: false
  property var settings: ({})
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/agent-limits/data.json"
  property var cache: Model.emptyCache()
  property string lastError: ""
  readonly property bool syncing: syncProcess.running
  readonly property int refreshIntervalSeconds: Math.max(60, Math.min(3600, Number(settings.refreshIntervalSec || 300)))

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
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastError = String(text || "").trim().slice(0, 300)
    }
  }
  Timer {
    interval: root.refreshIntervalSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
