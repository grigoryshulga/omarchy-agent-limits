# Working on Agent Limits

Omarchy shell plugin `gshulga.agent-limits`: bar widget, panel popup, Dashboard
tile and Side Panel page showing LLM subscription limits, local token usage and
API-equivalent cost. See `README.md` for what it shows and where each number
comes from; this file is about changing it without breaking the shell.

## Ground rules

- Read `/usr/share/omarchy/shell/**` and `/home/gshulga/omarchy/bin/*` as
  reference only. They belong to the system; changes here live in this repo.
- Credentials come from Bitwarden Secrets Manager through `bws`. Read them into
  memory, keep them out of files, commits, logs and agent output, and print only
  shapes ("secret names found: …"), never values.
- The UI cache carries aggregates. Prompts, session text, tokens and raw
  responses stay out of `data.json`.
- `i18n/en.json` and `i18n/ru.json` move together; a key added to one is added
  to the other in the same commit.
- The cache speaks in percentages `0..100` and ISO-8601 UTC timestamps. Convert
  at the edge, never in a view.

## First move

```bash
tests/all.sh                     # python tests, node model tests, qmllint, plugin validate
bin/omarchy-agent-limits-sync sync
bin/omarchy-agent-limits-sync snapshot | jq '.providers[] | {id, plan, limitsSource, error}'
```

`tests/all.sh` must end with `OK`, `model tests passed`, a `qmllint warnings: N`
line, and no validate failure. That is the completion criterion for every
change; a screenshot proves the rendering, the suite proves it did not regress.

## The dev loop

1. **Collector change** (`bin/omarchy-agent-limits-sync`): run `sync`, then
   `snapshot` and read the affected provider — `limits`, `limitsSource`,
   `error`, `today`/`week`/`total`. Confirm the number before touching any QML.
2. **View change**: iterate in the probe (below) until it renders, then check it
   once in the live shell. The probe is a separate quickshell instance, so a
   mistake costs nothing.
3. **Both**: run `tests/all.sh` last, and add the test that would have caught the
   bug (see Testing).

Never reload the live shell per iteration: a restart takes ~14 s and drops the
bar. The probe takes two.

## Probe harness (renders the real QML, no shell restart)

```bash
mkdir -p /tmp/probe && cd /tmp/probe
ln -sfn /usr/share/omarchy/shell/Ui /tmp/probe/Ui
ln -sfn /usr/share/omarchy/shell/Commons /tmp/probe/Commons
cp ~/projects/personal/omarchy-agent-limits/{Dashboard,DailyChart,PlainText}.qml .
cp ~/projects/personal/omarchy-agent-limits/Model.js .
rm -rf i18n assets && cp -r ~/projects/personal/omarchy-agent-limits/{i18n,assets} .
```

Write `/tmp/probe/shell.qml` with the plugin's own snapshot embedded, so the
probe renders real data:

```qml
import Quickshell
ShellRoot {
  PanelWindow {
    anchors { top: true; left: true }
    implicitWidth: 430; implicitHeight: 660
    color: "black"
    Dashboard { width: 430; height: 660; tab: "cost"; range: "week"; cache: <snapshot json> }
  }
}
```

Generate the cache with `bin/omarchy-agent-limits-sync snapshot`, then run
`quickshell -n -p /tmp/probe` and capture with `grim /tmp/shot.png` +
`convert /tmp/shot.png -crop 430x660+0+0 +repage -resize 200% out.png` (use
`magick` if `convert` complains).

Gotchas: a leftover probe holds quickshell's single-instance slot and the new
run exits after "Configuration Loaded" while `grim` captures the old window —
kill the old pid first. `cp -r i18n /tmp/probe/i18n` into an existing directory
nests a second `i18n/`, which renders raw keys like `time.hoursMinutes`.
`EmbeddedPage.pluginDir` is `Qt.resolvedUrl(".")` **without** a trailing slash,
so probing it needs `ln -sfn ~/projects/personal/omarchy-agent-limits/bin /tmp/probebin`.

## Live shell verification

```bash
rm -rf ~/.cache/quickshell/qmlcache/* ~/.cache/quickshell/qtpipelinecache-*
omarchy-restart-shell
sleep 14                                        # IPC is "Target not found." before this
omarchy-shell gshulga.agent-limits toggle
```

The shell runs with its file watcher disabled and keeps compiled QML, so the
cache purge is mandatory — `rescanPlugins` alone shows the old file. Screenshot
the result (`grim`, crop the bar corner or the popup) rather than trusting the
journal. A popup screenshot can race the focus handoff; if the picture shows no
popup, retry with `(sleep 1; grim /tmp/x.png) & omarchy-shell gshulga.agent-limits toggle`.
For the Dashboard, `omarchy-shell shell summon gshulga.dashboard '{}'` on an
empty workspace, then `omarchy-shell shell hide gshulga.dashboard`.

### Plugin registration trap

If the widget disappears from the bar, check
`omarchy-shell shell listPlugins` and `~/.config/omarchy/shell.json`. A leftover
`{"id": "gshulga.agent-limits"}` in `shell.json` `plugins[]` makes
`setEnabled` skip the bar insertion while still reporting success. Repair with
`omarchy-shell shell enablePlugin gshulga.agent-limits '{"section":"right"}'`
then `omarchy-shell shell moveBarWidget gshulga.agent-limits '{"before":"omarchy.power"}'`,
after backing the file up. Diff the config structurally before and after any
`omarchy plugin enable/disable` round-trip — it also injects entries.

## Testing

- Python: `tests/test_sync.py` loads the extensionless script through
  `importlib.machinery.SourceFileLoader` and patches `MODULE.<name>`; state paths
  (`CACHE`, `LIVE_LIMITS_STATE`, `AGENT_RECORDS`) are redirected to a
  `tempfile.TemporaryDirectory` so tests never read the real state. Patch
  `MODULE.subprocess` for the `bws` CLI and the Codex RPC.
- Node: `tests/model.test.js` does `require("../Model.js")` and asserts on plain
  objects; keep `Model.js` free of QML types so it stays testable.
- Add a test for the parsing or fallback rule you just changed, and one for the
  negative case (missing secret, 429, unpriced model, expired window).
- `qmllint` in `tests/all.sh` fails only on `Error:`. The ~110 warnings are
  expected: unqualified singleton access (the shell's own style) and the entry
  point shadowing `qs.Ui.Panel`. A jump in the count is worth a look, not a fix
  spree.

## Validation

- `omarchy plugin validate .` — run it on the **repository path**; it refuses a
  symlinked plugin folder, which is exactly how this plugin is installed.
- Use `/usr/lib/qt6/bin/qmllint`. `/usr/bin/qmllint` is Qt 5 and cannot parse
  this QML at all (exit 255); `tests/all.sh` picks the Qt6 binary by version.
- A QML type error surfaces only at load time, so the probe or a real shell
  restart is the only real validation for a view change.

## QML facts worth knowing before you edit

- `import qs.Ui` shadows Qt Quick Controls names. `qs.Ui.Button` is a
  `BorderSurface`-based button with `text`, `selected`, `foreground`, `accent`,
  `fontFamily`, `fontSize`, `horizontalPadding`, and `clicked()` — it has no
  `font`, `checked`, `contentItem` or `background`.
- `qs.Ui.BorderSurface` is a `Rectangle`: `color` and `radius` are valid, plus
  `borderSpec`/`padding`. `qs.Ui.PanelHero`, `PanelActionButton`, `PanelSeparator`,
  `KeyboardPanel`, `PanelKeyCatcher` are the usual building blocks.
- Built-in inline components (`component Foo: Item { … root.bar … }`) may
  reference outer ids freely in this Qt build — that is how `Meter`,
  `Stat`, `ProviderMark` and `BreakdownRow` work.
- No `Column.reversed` (it does not exist) and no `Behavior on width` on a
  binding inside a `Flickable`: the animation re-triggers itself and pins the
  value, which is why meter fills once stuck at ~10%.
- `Commons.Translations` exposes `t(key, fallback)` and `tn(key, count,
  fallback)`; the second argument is a fallback, not a substitution. Interpolate
  with `Model.format("%1 of %2", [...])` (`%1`-style), and keep `%` signs outside
  the catalog string.
- Strings go through `PlainText.qml` (`textFormat: Text.PlainText`); markup is
  escaped with `Model.escapeMarkup` for tooltips.
- Percentage colouring: `urgent` at or above `criticalPercent`, a tint between
  `warningPercent` and it, muted foreground below.

## Collector conventions

- Network access goes through `request_json()`: host allowlist
  (`opencode.ai`, `api.z.ai`, `open.bigmodel.cn`, `api.deepseek.com`,
  `api.anthropic.com`), 15 s timeout, 1 MB cap, redirects refused.
- Anything echoed into the cache passes `bounded_text(..., 180)`; numbers pass
  `number()`/`integer()` so a provider's string or null cannot poison a sum.
- Failures are values, not exceptions: a provider returns `(limits, plan)` or
  raises `SyncError`, and `sync()` turns that into `error` + `stale` while
  `preserve_on_error()` keeps the last known limits.
- Live probes are cached under `/run/user/$UID/omarchy-agent-limits/`
  (`LIVE_LIMITS_TTL`, `LIVE_LIMITS_BACKOFF`, honouring `Retry-After`). Keep the
  cadence conservative: Anthropic answers 429 within minutes.
- Every limit that describes a finished window is rolled forward by
  `roll_expired_limits()` in whole periods, so the card never shows a stale
  percentage next to an elapsed reset time.

## Commits

Private repo `git@github.com:grigoryshulga/omarchy-agent-limits.git`, branch
`main`. One concern per commit, imperative subject, and a body that says why the
change was needed. Run `tests/all.sh` before committing; never commit
`config.json`, `data.json`, keys or a snapshot of them.
