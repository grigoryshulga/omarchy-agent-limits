import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root
  property var cache: Model.emptyCache()
  property double nowMs: Date.now()
  property bool syncing: false
  property int warningPercent: 80
  property int criticalPercent: 95
  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color accent: Commons.Color.accent
  property color muted: Qt.darker(foreground, 1.55)
  property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  property string fontFamily: Style.font.family
  property string tab: "limits"
  // Time preset shared by the Usage and Cost tabs: it drives the headline, the
  // stat tiles, the chart and the per-provider rows at once.
  property string range: "week"
  signal refreshRequested()

  readonly property var providers: cache.providers || []
  readonly property string rangeLabel: strings.t("range." + range)
  readonly property string field: tab === "usage" ? "tokens" : "cost"
  readonly property real windowValue: Model.windowTotal(cache, field, range)
  readonly property var noHourly: Model.providersWithoutHours(cache)
  // Hour ticks only make sense on a 24-bucket plot; days stay unlabelled
  // because a 30-bar axis cannot hold readable dates.
  readonly property var chartTicks: {
    if (range !== "today") return []
    var ticks = []
    for (var hour = 0; hour < 24; hour += 6) ticks.push({ index: hour, label: (hour < 10 ? "0" : "") + hour })
    return ticks
  }
  function formatWindow(value) { return tab === "usage" ? Model.formatTokens(value) : Model.formatMoney(value) }

  spacing: Style.space(13)
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // One stable colour per provider for the stacked chart. A single-hue ramp off
  // the theme accent (mixed toward the foreground) reads as one palette on any
  // theme, and the provider rows below carry the same colour as their underline,
  // so that list doubles as the chart's legend.
  readonly property var providerOrder: {
    var ids = []
    for (var i = 0; i < providers.length; i++) ids.push(String(providers[i].id || ""))
    return ids
  }
  // Two ramps interleaved around the accent: lightening toward the foreground
  // and deepening toward a darker accent. A purely sequential ramp leaves two
  // adjacent light steps indistinguishable in a tall stacked bar.
  readonly property var providerRamp: [
    { toward: "foreground", amount: 0 },
    { toward: "foreground", amount: 0.55 },
    { toward: "deep", amount: 0.6 },
    { toward: "foreground", amount: 0.85 },
    { toward: "deep", amount: 1 }
  ]
  function mixColor(from, to, amount) {
    return Qt.rgba(
      from.r + (to.r - from.r) * amount,
      from.g + (to.g - from.g) * amount,
      from.b + (to.b - from.b) * amount,
      1)
  }
  function providerColor(providerId) {
    var index = root.providerOrder.indexOf(String(providerId || ""))
    if (index < 0) return root.accent
    var step = root.providerRamp[Math.min(index, root.providerRamp.length - 1)]
    var target = step.toward === "deep" ? Qt.darker(root.accent, 1.8) : root.foreground
    return root.mixColor(root.accent, target, step.amount)
  }
  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }
  function clamp(value) { return Math.max(0, Math.min(1, value)) }
  function channelLuminance(channel) { return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4) }
  function luminance(color) { return 0.2126 * channelLuminance(color.r) + 0.7152 * channelLuminance(color.g) + 0.0722 * channelLuminance(color.b) }

  // Provider marks resolve by convention, like the first-party agent panel:
  // assets/<id>.svg, plus a -light variant so a white mark stays visible when
  // the theme's surface is light.
  readonly property bool lightSurface: luminance(Commons.Color.background) >= 0.5
  function markCandidates(providerId) {
    var id = String(providerId || "")
    if (id === "") return []
    var candidates = []
    if (root.lightSurface) candidates.push(Qt.resolvedUrl("assets/" + id + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + id + ".svg"))
    return candidates
  }
  function meterColor(percent) { return percent >= criticalPercent ? urgent : percent >= warningPercent ? Qt.tint(alpha(accent, 0.75), alpha(urgent, 0.5)) : alpha(foreground, 0.55) }
  // "38% left · ↻ 3d 4h" — the countdown only when the provider reports a reset.
  // A plan that came from a cached/record fallback says so, so a number the
  // probe could not refresh is never read as one it just measured.
  function planText(provider) {
    var plan = String(provider.plan || "")
    if (provider.stale !== true || !(provider.limits || []).length)
      return plan
    var cached = strings.t ? strings.t("label.cached") : "cached"
    return plan ? plan + " · " + cached : cached
  }

  function limitText(limit) {
    var percent = Math.max(0, Math.round(100 - Model.number(limit.percent)))
    var label = limit.exhausted ? strings.t("label.exhausted") : percent + "% " + strings.t("label.left")
    var reset = Model.resetLabel(limit.resetsAt, root.nowMs, strings)
    return reset ? label + " · ↻ " + reset : label
  }

  // A limit that looks frozen is usually a limit that was measured a while ago,
  // so the refresh control says when each number was last read.
  readonly property string limitsTooltip: {
    var lines = [strings.t("action.refresh")]
    var list = root.cache.providers || []
    for (var i = 0; i < list.length; i++) {
      var provider = list[i]
      var checked = Model.number(provider.limitsCheckedAt)
      if (checked <= 0 || !(provider.limits || []).length) continue
      lines.push(String(provider.name || provider.id) + " · " + Model.elapsedLabel(checked, root.nowMs, strings))
    }
    return lines.join("\n")
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(titleText.implicitHeight, refreshButton.implicitHeight)
    PlainText {
      id: titleText
      text: strings.t("hero.title")
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    // The sync timestamp belongs with the control that triggers a sync.
    PlainText {
      text: Model.updatedLabel(root.cache, root.nowMs, root.syncing, strings)
      color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      anchors.right: refreshButton.left
      anchors.rightMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - titleText.implicitWidth - refreshButton.width - Style.space(24))
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
    PanelActionButton {
      id: refreshButton
      anchors.top: parent.top
      anchors.right: parent.right
      iconText: "󰑐"
      tooltipText: Model.escapeMarkup(root.limitsTooltip)
      foreground: root.foreground
      hoverColor: root.accent
      fontFamily: root.fontFamily
      enabled: !root.syncing
      onClicked: root.refreshRequested()
    }
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(tabs.implicitHeight, presets.implicitHeight)
    Row {
      id: tabs
      anchors.verticalCenter: parent.verticalCenter
      // Centred while there is room, pushed left when the preset row needs it,
      // so the two rows never overlap on a narrow dashboard tile.
      x: Math.max(0, Math.min((parent.width - tabs.implicitWidth) / 2,
                              parent.width - (presets.visible ? presets.width + Style.space(12) : 0) - tabs.implicitWidth))
      spacing: Style.space(2)
      Repeater {
        model: ["limits", "usage", "cost"]
        // qs.Ui.Button, not QtQuick.Controls: same type name, system styling.
        Button {
          required property string modelData
          text: strings.t("tab." + modelData)
          selected: root.tab === modelData
          foreground: root.tab === modelData ? root.foreground : root.muted
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(9)
          verticalPadding: Style.space(3)
          onClicked: root.tab = modelData
        }
      }
    }
    Row {
      id: presets
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      visible: root.tab !== "limits"
      Repeater {
        model: ["today", "week", "month"]
        Button {
          required property string modelData
          text: strings.t("range." + modelData)
          selected: root.range === modelData
          foreground: root.range === modelData ? root.foreground : root.muted
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(2)
          onClicked: root.range = modelData
        }
      }
    }
  }

  PanelSeparator { foreground: root.foreground }

  PlainText {
    visible: root.providers.length === 0
    width: parent.width
    text: root.cache.error || strings.t("summary.noData")
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // Limits are deliberately first and remain compact enough for a Dashboard tile.
  Column {
    visible: root.tab === "limits"
    width: parent.width
    spacing: Style.space(11)
    Repeater {
      model: root.providers
      BorderSurface {
        id: providerCard
        required property var modelData
        width: parent.width
        implicitHeight: cardColumn.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: root.alpha(root.foreground, 0.035)
        borderSpec: Border.flat(root.alpha(root.foreground, 0.1), 1)
        Column {
          id: cardColumn
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(6)
          Item {
            width: parent.width
            implicitHeight: Math.max(providerMark.implicitHeight, providerName.implicitHeight, providerPlan.implicitHeight)
            ProviderMark {
              id: providerMark
              providerId: String(providerCard.modelData.id || "")
              size: Style.font.title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            PlainText { id: providerName; text: providerCard.modelData.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; anchors.left: providerMark.right; anchors.leftMargin: Style.space(7); anchors.right: providerPlan.left; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight }
            PlainText { id: providerPlan; text: root.planText(providerCard.modelData); color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
          }
          Repeater {
            model: providerCard.modelData.limits || []
            Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(3)
              Item {
                width: parent.width
                implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)
                PlainText { id: limitLabel; text: modelData.label; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.left: parent.left }
                PlainText { id: limitValue; text: root.limitText(modelData); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right }
              }
              Meter { width: parent.width; value: Model.number(modelData.percent) / 100; fillColor: modelData.exhausted === true ? root.urgent : root.meterColor(Model.number(modelData.percent)) }
            }
          }
          Repeater {
            model: providerCard.modelData.balance || []
            Item {
              required property var modelData
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)
              PlainText { id: balanceLabel; text: strings.t("label.balance"); color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; anchors.left: parent.left }
              PlainText { id: balanceValue; text: Model.formatMoney(modelData.total, modelData.currency) + " " + modelData.currency; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; anchors.right: parent.right }
            }
          }
          PlainText {
            visible: String(providerCard.modelData.error || "") !== ""
            width: parent.width
            text: String(providerCard.modelData.error || "")
            color: root.urgent
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          PlainText {
            visible: (providerCard.modelData.limits || []).length === 0 && (providerCard.modelData.balance || []).length === 0 && String(providerCard.modelData.error || "") === ""
            text: strings.t("label.noquota")
            color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Usage / Cost share a dense breakdown and a 30-day trend.
  Column {
    visible: root.tab !== "limits" && root.providers.length > 0
    width: parent.width
    spacing: Style.space(13)
    Row {
      width: parent.width
      spacing: Style.space(8)
      Stat { width: (parent.width - parent.spacing * 2) / 3; label: root.rangeLabel; value: root.formatWindow(root.windowValue) }
      Stat { width: (parent.width - parent.spacing * 2) / 3; label: strings.t("label.requests"); value: Model.count(Model.windowTotal(root.cache, "requests", root.range)) }
      Stat { width: (parent.width - parent.spacing * 2) / 3; label: strings.t("label.perDay"); value: root.formatWindow(root.windowValue / Math.max(1, Model.windowSize(root.range))) }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)
      SectionTitle {
        title: root.range === "today"
          ? (root.tab === "usage" ? strings.t("label.hourlyTokens") : strings.t("label.hourlyCost"))
          : (root.tab === "usage" ? strings.t("label.dailyTokens") : strings.t("label.dailyCost"))
        value: root.rangeLabel
      }
      DailyChart {
        width: parent.width
        height: Style.space(62)
        points: root.range === "today"
          ? Model.stackedHourly(root.cache, root.field)
          : Model.stackedDaily(root.cache, root.field, root.range)
        ticks: root.chartTicks
        barColor: root.accent
        tickColor: root.alpha(root.foreground, 0.45)
        colorFor: function (providerId) { return root.providerColor(providerId) }
        gridColor: root.alpha(root.foreground, 0.12)
      }
      // Only shown when a provider with usage today has no timestamps to plot.
      PlainText {
        visible: root.range === "today" && root.noHourly.length > 0
        width: parent.width
        text: strings.t("label.noHourly") + ": " + root.noHourly.join(", ")
        color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(5)
      SectionTitle { title: strings.t("label.byProvider"); value: root.providers.length + " · " + Model.count(Model.sessions(root.providers)) + " " + strings.t("label.sessions").toLowerCase() }
      Repeater {
        model: root.providers
        BreakdownRow {
          required property var modelData
          // A provider can burn quota without leaving a log we can read (OpenCode
          // Go today). Showing "$0.00 / 0 requests" there would be a false zero,
          // so say plainly that there is no local log instead.
          readonly property bool quotaActivity: {
            var limits = modelData.limits || []
            for (var i = 0; i < limits.length; i++) {
              if (Model.number(limits[i].percent) > 0) return true
            }
            return false
          }
          readonly property bool measured: Model.number(modelData.total.tokens) > 0 || Model.number(modelData.total.requests) > 0
          width: parent.width
          providerId: String(modelData.id || "")
          name: modelData.name
          readonly property real windowTokens: Model.providerWindow(modelData, "tokens", root.range)
          readonly property real windowCost: Model.providerWindow(modelData, "cost", root.range)
          readonly property real windowRequests: Model.providerWindow(modelData, "requests", root.range)
          value: measured || !quotaActivity ? root.formatWindow(root.tab === "usage" ? windowTokens : windowCost) : "—"
          // Native records carry no per-day prompt counts, so a provider with
          // tokens but no request log shows the other measure, never a false 0.
          // "no local usage log" is about the provider, not about this window: a
          // silent day is just a silent day.
          detail: windowRequests > 0
            ? Model.count(windowRequests) + " " + strings.t("label.requests").toLowerCase()
            : !measured && quotaActivity
              ? strings.t("label.nolog")
              : windowTokens > 0 || windowCost > 0
                ? (root.tab === "usage" ? Model.formatMoney(windowCost) : Model.formatTokens(windowTokens))
                : "0 " + strings.t("label.requests").toLowerCase()
          ratio: root.tab === "usage" ? windowTokens / Math.max(1, root.windowValue) : windowCost / Math.max(0.00001, root.windowValue)
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(5)
      SectionTitle { title: strings.t("label.byModel"); value: strings.t("label.total") }
      Repeater {
        model: {
          var rows = []
          for (var i = 0; i < root.providers.length; i++) {
            var models = root.providers[i].models || []
            for (var j = 0; j < models.length && rows.length < 30; j++) rows.push(models[j])
          }
          rows.sort(function(a, b) { return root.tab === "usage" ? Model.number(b.tokens) - Model.number(a.tokens) : Model.number(b.cost) - Model.number(a.cost) })
          return rows.slice(0, 10)
        }
        BreakdownRow {
          required property var modelData
          width: parent.width
          name: modelData.name
          value: root.tab === "usage" ? Model.formatTokens(modelData.tokens) : (modelData.priced || Model.number(modelData.tokens) === 0 ? Model.formatMoney(modelData.cost) : strings.t("label.unpriced"))
          detail: root.tab === "usage" ? (modelData.priced ? Model.formatMoney(modelData.cost) : Model.formatTokens(modelData.tokens)) : Model.formatTokens(modelData.tokens)
          ratio: root.tab === "usage" ? Model.number(modelData.tokens) / Math.max(1, Model.tokens(root.providers, "total")) : Model.number(modelData.cost) / Math.max(0.00001, Model.cost(root.providers, "total"))
        }
      }
    }

    PlainText {
      visible: root.tab === "cost"
      width: parent.width
      text: strings.t("cost.note")
      color: root.muted
      font.family: root.fontFamily; font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component Meter: Item {
    id: meter
    property real value: 0
    property color fillColor: root.foreground
    readonly property real ratio: root.clamp(value)
    implicitHeight: Style.space(5)
    Rectangle { id: trackRect; anchors.fill: parent; radius: height / 2; color: root.track }
    Rectangle {
      // A visible nub for tiny but non-zero values, nothing at all for zero.
      width: meter.ratio <= 0 ? 0 : Math.max(trackRect.height, trackRect.width * meter.ratio)
      height: trackRect.height
      radius: trackRect.radius
      color: meter.fillColor
    }
  }

  component Stat: BorderSurface {
    id: stat
    property string label: ""
    property string value: "—"
    implicitHeight: statColumn.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: root.alpha(root.foreground, 0.04)
    borderSpec: Border.flat(root.alpha(root.foreground, 0.08), 1)
    Column {
      id: statColumn
      anchors.fill: parent; anchors.margins: Style.space(6); spacing: Style.space(2)
      PlainText { text: stat.label; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      PlainText { width: parent.width; text: stat.value; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
    }
  }

  component SectionTitle: Item {
    property string title: ""
    property string value: ""
    width: parent.width
    implicitHeight: Style.font.body + Style.space(5)
    PanelSectionHeader { text: title; foreground: root.foreground; fontFamily: root.fontFamily; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
    PlainText { text: value; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
  }

  // A provider's brand mark, falling back to the plugin glyph when an asset is
  // missing. Advancing the candidate list from inside Image.statusChanged trips
  // the binding-loop detector, so the step is deferred one tick.
  component ProviderMark: Item {
    id: mark
    property string providerId: ""
    property real size: Style.font.bodySmall
    readonly property var candidates: root.markCandidates(providerId)
    readonly property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    onCandidatesKeyChanged: candidateIndex = 0

    width: size
    height: size

    Image {
      id: markImage
      anchors.fill: parent
      source: mark.candidateIndex < mark.candidates.length ? mark.candidates[mark.candidateIndex] : ""
      sourceSize.width: mark.size * 2
      sourceSize.height: mark.size * 2
      fillMode: Image.PreserveAspectFit
      visible: status === Image.Ready
      onStatusChanged: if (status === Image.Error && mark.candidateIndex < mark.candidates.length)
        Qt.callLater(function() { mark.candidateIndex++ })
    }

    PlainText {
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      text: "󰚩"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: mark.size
    }
  }

  component BreakdownRow: Item {
    id: row
    property string providerId: ""
    property string name: ""
    property string value: ""
    property string detail: ""
    property real ratio: 0
    implicitHeight: rowText.implicitHeight + Style.space(8)
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.space(2); color: root.track }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width * root.clamp(row.ratio); height: Style.space(2); color: row.providerId !== "" ? root.providerColor(row.providerId) : root.alpha(root.accent, 0.75) }
    Item {
      id: rowText
      width: parent.width
      implicitHeight: Math.max(rowMark.implicitHeight, nameText.implicitHeight, valueText.implicitHeight)
      ProviderMark { id: rowMark; providerId: row.providerId; visible: row.providerId !== ""; size: Style.font.bodySmall; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
      PlainText { id: nameText; text: row.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; anchors.left: row.providerId !== "" ? rowMark.right : parent.left; anchors.leftMargin: row.providerId !== "" ? Style.space(7) : 0; anchors.right: detailText.left; anchors.rightMargin: Style.space(8); elide: Text.ElideRight }
      PlainText { id: detailText; text: row.detail; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: valueText.left; anchors.rightMargin: Style.space(12) }
      PlainText { id: valueText; text: row.value; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; anchors.right: parent.right }
    }
  }
}
