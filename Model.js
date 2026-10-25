function emptyCache() {
  return { schemaVersion: 1, state: "loading", syncedAt: 0, providers: [], error: "" }
}

function parseCache(text) {
  try {
    var value = JSON.parse(String(text || ""))
    if (value && typeof value === "object" && Array.isArray(value.providers)) {
      value.providers = value.providers.slice(0, 20)
      return value
    }
  } catch (_) {}
  return emptyCache()
}

function number(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : (fallback === undefined ? 0 : fallback)
}

// %1..%9 substitution. Catalog strings carry placeholders; translations are
// substituted here instead of relying on QML's String.prototype.arg, so the
// same code works in plain JS tests.
function format(template, values) {
  var text = String(template === undefined || template === null ? "" : template)
  var list = values || []
  for (var index = 0; index < list.length; index++)
    text = text.split("%" + (index + 1)).join(String(list[index]))
  return text
}

function sum(providers, section, field) {
  var result = 0
  for (var i = 0; i < (providers || []).length; i++) {
    var metrics = providers[i][section]
    if (metrics) result += number(metrics[field])
  }
  return result
}

function sessions(providers) { return sum(providers, "total", "sessions") }
function requests(providers) { return sum(providers, "total", "requests") }
function tokens(providers, section) { return sum(providers, section || "total", "tokens") }
function cost(providers, section) { return sum(providers, section || "total", "cost") }

function formatTokens(value) {
  var count = number(value)
  if (count >= 1e9) return (count / 1e9).toFixed(count >= 1e10 ? 1 : 2) + "B"
  if (count >= 1e6) return (count / 1e6).toFixed(count >= 1e8 ? 0 : 1) + "M"
  if (count >= 1e3) return (count / 1e3).toFixed(count >= 1e5 ? 0 : 1) + "K"
  return String(Math.round(count))
}

// Grouped integer for counts that must stay exact (requests, sessions).
function count(value) {
  var digits = String(Math.round(number(value)))
  var grouped = ""
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) grouped += " "
    grouped += digits.charAt(i)
  }
  return grouped
}

function formatMoney(value, currency) {
  var symbol = currency === "CNY" ? "¥" : "$"
  var amount = number(value)
  return symbol + (Math.abs(amount) >= 1000 ? amount.toLocaleString(undefined, { maximumFractionDigits: 0 }) : amount.toFixed(2))
}

function highestPressure(providers) {
  var maximum = -1
  for (var i = 0; i < (providers || []).length; i++) {
    var limits = providers[i].limits || []
    for (var j = 0; j < limits.length; j++) maximum = Math.max(maximum, number(limits[j].percent))
  }
  return maximum
}

// The provider and window that sit closest to their ceiling — what the bar
// widget and the panel headline report.
function tightestWindow(providers) {
  var best = null
  for (var i = 0; i < (providers || []).length; i++) {
    var limits = providers[i].limits || []
    for (var j = 0; j < limits.length; j++) {
      var percent = number(limits[j].percent)
      if (best && percent <= best.percent) continue
      best = { provider: String(providers[i].name || providers[i].id || ""), label: String(limits[j].label || ""), percent: percent }
    }
  }
  return best
}

function remainingPercent(providers) {
  var pressure = highestPressure(providers)
  return pressure < 0 ? -1 : Math.max(0, Math.round(100 - pressure))
}

function resetLabel(value, now, strings) {
  var timestamp = new Date(String(value || "")).getTime()
  if (!isFinite(timestamp) || timestamp <= 0) return ""
  var minutes = Math.floor((timestamp - number(now, Date.now())) / 60000)
  if (minutes <= 0) return strings ? strings.t("time.now") : "now"
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return strings ? format(strings.t("time.daysHours"), [days, hours % 24]) : days + "d " + (hours % 24) + "h"
  if (hours > 0) return strings ? format(strings.t("time.hoursMinutes"), [hours, minutes % 60]) : hours + "h " + (minutes % 60) + "m"
  var remaining = Math.max(1, minutes)
  return strings ? format(strings.t("time.minutes"), [remaining]) : remaining + "m"
}

function elapsedLabel(momentMs, now, strings) {
  var moment = number(momentMs)
  if (moment <= 0) return ""
  var minutes = Math.floor((number(now, Date.now()) - moment) / 60000)
  if (minutes < 1) return strings ? strings.t("time.now") : "now"
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return strings ? format(strings.t("time.daysHours"), [days, hours % 24]) : days + "d " + (hours % 24) + "h"
  if (hours > 0) return strings ? format(strings.t("time.hoursMinutes"), [hours, minutes % 60]) : hours + "h " + (minutes % 60) + "m"
  return strings ? format(strings.t("time.minutes"), [minutes]) : minutes + "m"
}

function updatedLabel(cache, now, refreshing, strings) {
  if (refreshing) return strings.t("status.refreshing")
  if (!cache || !cache.syncedAt) return "—"
  var minutes = Math.max(0, Math.floor((number(now, Date.now()) - number(cache.syncedAt)) / 60000))
  return minutes < 1 ? strings.t("status.justNow") : format(strings.t("status.minutesAgo"), [minutes])
}

function daily(cache, field) {
  var result = []
  var providers = cache.providers || []
  var length = 0
  for (var i = 0; i < providers.length; i++) length = Math.max(length, (providers[i].days || []).length)
  for (var day = 0; day < length; day++) {
    var total = 0
    var date = ""
    for (var j = 0; j < providers.length; j++) {
      var item = (providers[j].days || [])[day]
      if (item) { total += number(item[field]); date = item.date }
    }
    result.push({ date: date, value: total })
  }
  return result.slice(-30)
}

// A time preset is a window over the 30-day series, so the headline, the chart
// and the per-provider rows always describe the same slice of history.
function windowSize(range) {
  if (range === "today") return 1
  if (range === "week") return 7
  return 30
}

function windowSeries(cache, field, range) {
  return daily(cache, field).slice(-windowSize(range))
}

function windowTotal(cache, field, range) {
  var series = windowSeries(cache, field, range)
  var total = 0
  for (var i = 0; i < series.length; i++) total += number(series[i].value)
  return total
}

function providerWindow(provider, field, range) {
  var days = (provider.days || []).slice(-windowSize(range))
  var total = 0
  for (var i = 0; i < days.length; i++) total += number(days[i][field])
  return total
}

// Hourly buckets for the current day: the "Today" preset plots these instead of
// the daily series. Providers whose records carry no timestamps (native Claude/
// Codex usage files) contribute nothing here, which providersWithoutHours()
// reports instead of silently flattening them to zero.
function hourly(cache, field) {
  var providers = cache.providers || []
  var result = []
  for (var hour = 0; hour < 24; hour++) {
    var total = 0
    for (var i = 0; i < providers.length; i++) {
      var bucket = (providers[i].hours || [])[hour]
      if (bucket) total += number(bucket[field])
    }
    result.push({ hour: hour, value: total })
  }
  return result
}

function hourlyTotal(cache, field) {
  var series = hourly(cache, field)
  var total = 0
  for (var i = 0; i < series.length; i++) total += number(series[i].value)
  return total
}

function providersWithoutHours(cache) {
  var names = []
  var providers = cache.providers || []
  for (var i = 0; i < providers.length; i++) {
    var provider = providers[i]
    if (number((provider.today || {}).tokens) <= 0) continue
    var hours = provider.hours || []
    var tracked = 0
    for (var j = 0; j < hours.length; j++) tracked += number(hours[j].tokens)
    if (tracked <= 0) names.push(String(provider.name || provider.id || ""))
  }
  return names
}

// Stacked variants of the two series above: every bucket keeps its per-provider
// parts so the chart can show who spent the tokens instead of one anonymous bar.
function stackedDaily(cache, field, range) {
  var providers = cache.providers || []
  var length = 0
  for (var i = 0; i < providers.length; i++) length = Math.max(length, (providers[i].days || []).length)
  var rows = []
  for (var day = 0; day < length; day++) {
    var parts = []
    var total = 0
    var date = ""
    for (var j = 0; j < providers.length; j++) {
      var item = (providers[j].days || [])[day]
      if (!item) continue
      date = item.date
      var value = number(item[field])
      if (value <= 0) continue
      parts.push({ id: String(providers[j].id || ""), name: String(providers[j].name || ""), value: value })
      total += value
    }
    rows.push({ date: date, value: total, parts: parts })
  }
  return rows.slice(-windowSize(range))
}

function stackedHourly(cache, field) {
  var providers = cache.providers || []
  var rows = []
  for (var hour = 0; hour < 24; hour++) {
    var parts = []
    var total = 0
    for (var i = 0; i < providers.length; i++) {
      var bucket = (providers[i].hours || [])[hour]
      if (!bucket) continue
      var value = number(bucket[field])
      if (value <= 0) continue
      parts.push({ id: String(providers[i].id || ""), name: String(providers[i].name || ""), value: value })
      total += value
    }
    rows.push({ hour: hour, value: total, parts: parts })
  }
  return rows
}

function dayLabel(value) {
  var parsed = new Date(String(value || "") + "T00:00:00")
  if (isNaN(parsed.getTime())) return ""
  return String(parsed.getDate())
}

function escapeMarkup(value) {
  return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    emptyCache, parseCache, number, sum, sessions, requests, tokens, cost,
    formatTokens, formatMoney, count, format, highestPressure, tightestWindow, remainingPercent, resetLabel,
    updatedLabel, elapsedLabel, daily, dayLabel, escapeMarkup, windowSize, windowSeries, windowTotal, providerWindow,
    hourly, hourlyTotal, providersWithoutHours, stackedDaily, stackedHourly
  }
}
