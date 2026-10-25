const model = require("../Model.js")

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

const cache = model.parseCache(JSON.stringify({
  schemaVersion: 1,
  syncedAt: 1000,
  providers: [
    { id: "claude", name: "Claude Pro", limits: [{ label: "Weekly (7-day)", percent: 96, resetsAt: new Date(Date.now() + 90 * 60000).toISOString() }], total: { tokens: 2000000, cost: 12, requests: 5, sessions: 2 }, today: { tokens: 10, cost: 1 }, week: { tokens: 20, cost: 2 }, days: [{ date: "2026-10-24", tokens: 20, cost: 2 }] },
    { id: "zai", name: "Z.AI", limits: [{ label: "Session (5-hour)", percent: 20 }], total: { tokens: 1000000, cost: 3, requests: 3, sessions: 1 }, today: { tokens: 5, cost: 0.5 }, week: { tokens: 10, cost: 1 }, days: [{ date: "2026-10-24", tokens: 10, cost: 1 }] }
  ]
}))
assert(model.remainingPercent(cache.providers) === 4, "highest pressure should drive the bar")
assert(model.tokens(cache.providers, "total") === 3000000, "tokens should aggregate")
assert(model.cost(cache.providers, "week") === 3, "cost should aggregate")
assert(model.daily(cache, "tokens")[0].value === 30, "daily values should aggregate")
assert(model.escapeMarkup("<img src=x>") === "&lt;img src=x&gt;", "tooltip markup must be neutralized")
assert(model.parseCache("not json").providers.length === 0, "bad input should produce an empty cache")

const tightest = model.tightestWindow(cache.providers)
assert(tightest.percent === 96 && tightest.provider === "Claude Pro" && tightest.label === "Weekly (7-day)", "tightest window should name provider and window")
assert(model.tightestWindow([]) === null, "no providers means no tightest window")

const strings = {
  t: (key) => ({
    "time.hoursMinutes": "%1h %2m",
    "time.daysHours": "%1d %2h",
    "time.minutes": "%1m",
    "time.now": "now",
    "status.justNow": "Updated just now",
    "status.minutesAgo": "Updated %1 min ago"
  })[key] || key
}
assert(/^1h \d+m$/.test(model.resetLabel(cache.providers[0].limits[0].resetsAt, Date.now(), strings)), "reset labels should be localized and substituted")
assert(model.resetLabel("", Date.now(), strings) === "", "missing reset time should render nothing")
assert(model.updatedLabel(cache, cache.syncedAt + 5 * 60000, false, strings) === "Updated 5 min ago", "age labels should substitute the minute count")
assert(model.format("%1 of %2", [3, 7]) === "3 of 7", "placeholder substitution should be positional")
// Stacked series: each bucket keeps its per-provider parts, and empty parts are
// dropped so a sparse day does not draw zero-height segments.
const stacked = model.stackedDaily(cache, "tokens", "week")
assert(stacked.length === 1, "one day of data means one bucket")
assert(stacked[0].value === 30, "bucket total should aggregate providers")
assert(stacked[0].parts.length === 2, "both providers should be a part of the bucket")
assert(stacked[0].parts[0].id === "claude" && stacked[0].parts[0].value === 20, "parts keep provider identity")

const hourlyCache = model.parseCache(JSON.stringify({
  schemaVersion: 1,
  syncedAt: 1000,
  providers: [
    { id: "zai", name: "Z.AI", hours: [{ hour: 0, tokens: 0, cost: 0 }, { hour: 1, tokens: 40, cost: 4 }] },
    { id: "deepseek", name: "DeepSeek API", hours: [{ hour: 0, tokens: 0, cost: 0 }, { hour: 1, tokens: 60, cost: 6 }] }
  ]
}))
const hours = model.stackedHourly(hourlyCache, "cost")
assert(hours.length === 24, "hourly series always spans a day")
assert(hours[1].value === 10, "hourly bucket should aggregate providers")
assert(hours[1].parts.length === 2, "hourly bucket should keep provider parts")
assert(hours[0].parts.length === 0, "an empty hour should have no parts")

const now = Date.now()
assert(model.elapsedLabel(now - 30 * 1000, now, strings) === "now", "a fresh measurement reads as now")
assert(model.elapsedLabel(now - 5 * 60 * 1000, now, strings) === "5m", "minutes-old measurements keep their minutes")
assert(model.elapsedLabel(now - 95 * 60 * 1000, now, strings) === "1h 35m", "hours keep the leftover minutes")
assert(model.elapsedLabel(now - 27 * 3600 * 1000, now, strings) === "1d 3h", "days keep the leftover hours")
assert(model.elapsedLabel(0, now, strings) === "", "an unmeasured provider says nothing")

console.log("model tests passed")
