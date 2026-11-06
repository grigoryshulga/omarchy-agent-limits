import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root
  property var providers: []
  property string error: ""
  property bool saving: false
  property string editingId: ""
  property string secretDraft: ""
  property string regionDraft: "global"
  readonly property bool busy: process.running
  readonly property string collector: Qt.resolvedUrl("bin/omarchy-agent-limits-sync").toString().replace("file://", "")
  signal changed()
  spacing: Style.space(12)
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function reload() {
    if (process.running) return
    saving = false
    process.command = [collector, "providers"]
    process.running = true
  }
  function change(providerId, action) {
    if (process.running) return
    error = ""
    saving = true
    process.command = [collector, "configure", providerId, action]
    process.running = true
  }
  function edit(provider) {
    editingId = provider.id
    secretDraft = provider.secretName
    regionDraft = provider.region
  }
  function connect() {
    if (process.running || !/^[A-Za-z_][A-Za-z0-9_.-]{0,99}$/.test(secretDraft)) return
    error = ""
    saving = true
    process.command = [collector, "configure", editingId, "connect", "--secret-name", secretDraft, "--region", regionDraft]
    process.running = true
  }
  Component.onCompleted: reload()
  onVisibleChanged: if (visible) reload()
  Process {
    id: process
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.providers = JSON.parse(text).providers || [] }
        catch (e) { root.error = strings.t("settings.failed") }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.error = strings.t("settings.failed")
      else if (root.saving) { root.editingId = ""; root.changed() }
      root.saving = false
    }
  }
  PlainText {
    width: parent.width
    text: strings.t("settings.description")
    color: Commons.Color.foreground
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }
  PlainText {
    visible: root.error !== ""
    width: parent.width
    text: root.error
    color: Commons.Color.urgent
    wrapMode: Text.WordWrap
  }
  Repeater {
    model: root.providers
    BorderSurface {
      id: card
      required property var modelData
      required property int index
      width: root.width
      implicitHeight: content.implicitHeight + Style.space(18)
      color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.04)
      radius: Style.cornerRadius
      Column {
        id: content
        x: Style.space(9); y: Style.space(9)
        width: parent.width - Style.space(18)
        spacing: Style.space(6)
        PlainText {
          width: parent.width
          text: card.modelData.name
          color: Commons.Color.foreground
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        PlainText {
          width: parent.width
          text: strings.t("settings.connect." + card.modelData.id)
          color: Qt.darker(Commons.Color.foreground, 1.55)
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Row {
          spacing: Style.space(6)
          Button {
            text: strings.t(card.modelData.enabled ? "settings.disable" : (card.modelData.secretName ? "settings.connect" : "settings.add"))
            selected: card.modelData.enabled
            fontSize: Style.font.caption
            focusable: true
            enabled: !root.busy
            onClicked: {
              if (!card.modelData.enabled && card.modelData.secretName) root.edit(card.modelData)
              else root.change(card.modelData.id, card.modelData.enabled ? "disable" : "enable")
            }
          }
          PanelActionButton {
            visible: card.modelData.secretName !== ""
            iconText: "󰒓"
            tooltipText: Model.escapeMarkup(strings.t("settings.connection"))
            focusable: true
            enabled: !root.busy
            onClicked: root.edit(card.modelData)
          }
          PanelActionButton {
            iconText: "↑"
            tooltipText: Model.escapeMarkup(strings.t("settings.up"))
            focusable: true
            enabled: !root.busy && card.index > 0
            onClicked: root.change(card.modelData.id, "up")
          }
          PanelActionButton {
            iconText: "↓"
            tooltipText: Model.escapeMarkup(strings.t("settings.down"))
            focusable: true
            enabled: !root.busy && card.index < root.providers.length - 1
            onClicked: root.change(card.modelData.id, "down")
          }
        }
        Column {
          visible: root.editingId === card.modelData.id
          width: parent.width
          spacing: Style.space(7)
          PlainText {
            width: parent.width
            text: strings.t("settings.secretName")
            color: Commons.Color.foreground
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          TextField {
            width: parent.width
            text: root.secretDraft
            maximumLength: 100
            enabled: !root.busy
            onTextEdited: root.secretDraft = text
            onAccepted: root.connect()
          }
          Row {
            visible: ["zai", "moonshot", "kimi-code", "minimax"].indexOf(card.modelData.id) >= 0
            spacing: Style.space(6)
            Button {
              text: strings.t("settings.global")
              selected: root.regionDraft === "global"
              fontSize: Style.font.caption
              focusable: true
              enabled: !root.busy
              onClicked: root.regionDraft = "global"
            }
            Button {
              text: strings.t("settings.china")
              selected: root.regionDraft === "cn"
              fontSize: Style.font.caption
              focusable: true
              enabled: !root.busy
              onClicked: root.regionDraft = "cn"
            }
          }
          PlainText {
            width: parent.width
            text: strings.t("settings.secretHelp")
            color: Qt.darker(Commons.Color.foreground, 1.55)
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Row {
            spacing: Style.space(6)
            Button {
              text: strings.t("settings.saveConnect")
              fontSize: Style.font.caption
              focusable: true
              enabled: !root.busy && /^[A-Za-z_][A-Za-z0-9_.-]{0,99}$/.test(root.secretDraft)
              onClicked: root.connect()
            }
            Button {
              text: strings.t("settings.cancel")
              fontSize: Style.font.caption
              focusable: true
              enabled: !root.busy
              onClicked: root.editingId = ""
            }
          }
        }
      }
    }
  }
}
