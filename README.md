# Agent Limits for Omarchy

A compact, theme-aware monitor for **OpenCode Go, Z.AI Coding Plan, Claude Pro,
ChatGPT Plus/Codex, DeepSeek API, OpenRouter, Kimi Code, Moonshot API, MiniMax
Token Plan, OpenAI API, and Google Gemini API**. It provides the same three views in the
Omarchy bar, Omarchy Dashboard, and Omarchy Side Panel:

1. **Limits** — remaining quota and reset times for every provider; DeepSeek's
   real balance appears in the same view.
2. **Usage** — today, seven days, all-time local totals, a 30-day trend, and
   provider/model breakdowns.
3. **Cost** — API-equivalent estimated value, not actual subscription charges.
   Models without configured prices are explicitly marked **Unpriced** and are
   never silently priced as another model.

Every provider's quota is asked for directly, so the plugin never shows a number
that a hook had not refreshed yet:

* **Claude** — `GET https://api.anthropic.com/api/oauth/usage` with the OAuth
  token from `~/.claude/.credentials.json` and the `oauth-2025-04-20` beta
  header, the same endpoint Claude Code's own `/usage` reads.
* **ChatGPT/Codex** — `codex app-server` over JSON-RPC, method
  `account/rateLimits/read`; the plan comes from the same reply.
* **OpenCode Go, Z.AI** — their live quota endpoints.
* **DeepSeek** — its documented balance endpoint.

Token statistics come from the logs the tools themselves keep, so they move
without any hook of ours: `~/.claude/projects/**/*.jsonl` for Claude Code,
`~/.codex/sessions/**/rollout-*.jsonl` for Codex, `~/.pi/agent/sessions` and the
OpenCode database for the API providers. Omarchy's
`~/.local/state/omarchy/agents/usage/*.json` records are still read, but only as
a **fallback**: their limits when a probe fails, and their usage when a CLI log
is missing. The cache marks which limit source was used in `limitsSource`
(`live` or `record`), and a card showing a fallback labels its plan
`Pro · cached`, so an unrefreshed number never looks freshly measured.

Probes are not free, so each answer is kept for a few minutes (5 for Claude, 4
for Codex) and a failure is remembered for 10 minutes, extended by any
`Retry-After` the provider names — Anthropic rate-limits its usage endpoint
readily, and a plugin that retried on every refresh would keep it locked. DeepSeek publishes **no usage API** (only
`GET /user/balance` answers with an API key), so its requests, tokens and cost
come from the harness session logs under `~/.pi/agent/sessions` that actually
made the calls, together with local OpenCode assistant messages. Both are added
up, never merged from the same traffic.

Only harnesses that bill a tracked account directly are read
(`deepseek`, `zai`, `opencode-go` in pi's records). A harness fronting a shared
proxy (`litellm`) or a subscription Omarchy's own records already cover
(`claude-bridge`, `openai-codex`) is deliberately ignored so a request is never
counted twice. No prompts, session text, credentials, or API responses are
written to the UI cache; only aggregate token counts and costs leave the logs.

When a provider shows quota pressure but no readable log (OpenCode Go today),
its breakdown row prints `—` with `no local usage log` instead of a false
`0 requests / $0.00`.

## Provider settings

Open the gear button in the popup, Dashboard tile, or Side Panel page. The
same menu lists all eleven supported providers. **Add / enable** restores a
provider, **Disable** hides it and stops its quota/credential probes, and the
up/down arrows set card order across all views. Settings are saved immediately
to `~/.config/omarchy/agent-limits.json` (`providers.<id>.enabled` and
`providerOrder`); other configuration, including custom pricing, is preserved.
The original five providers remain enabled by default. New catalog entries are
disabled until you connect or enable them.

Adding uses an existing login or secret, as described in the menu. Claude and
Codex need their CLI login; API providers use OpenCode authentication or
Bitwarden Secrets Manager. A missing login/key appears as an error on the
enabled card. Disabling keeps connection parameters for enabling later.

For scripts, `bin/omarchy-agent-limits-sync providers` returns only the public
catalog and enabled state. `configure <id> <enable|disable|up|down>` saves a
change under the sync lock; run `sync` afterwards to refresh measurements.

### Connecting a catalog provider

Choose **Connect**, enter the **name** of its Bitwarden Secrets Manager secret,
and select Global or China where offered. **Save and connect** stores only that
reference and region, enables the card, and refreshes the snapshot. The existing
OpenCode authentication and environment lookup still take priority. Connection
settings can be edited with the small gear next to each API provider.

| Provider | Data shown | Default secret name |
|---|---|---|
| OpenRouter | API key budget; an unlimited key has no quota percentage | `OPENROUTER_API_KEY` |
| Kimi Code | Code subscription quota windows | `KIMI_CODE_API_KEY` |
| Kimi / Moonshot API | Available account balance, USD globally or CNY in China | `MOONSHOT_API_KEY` |
| MiniMax Token Plan | Readable text-model 5-hour and weekly quotas | `MINIMAX_API_KEY` |
| OpenAI API | Local OpenCode/pi usage and recorded or configured cost | No remote credentials needed |
| Google Gemini API | Local OpenCode/pi usage and recorded or configured cost | No remote credentials needed |

Kimi Code and Moonshot API have separate keys. MiniMax requires a subscription
key, not a pay-as-you-go key. MiniMax responses containing zero quota totals
are reported as unavailable, rather than guessed to mean full or empty.
OpenAI API and Gemini cards collect local API traffic only; Codex and Gemini CLI
subscription traffic is excluded. Models absent from the pricing table remain
unpriced unless their log records a cost. Local usage does not represent the
account's global billed spend.

The collectors follow the official [OpenRouter key API](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key),
[Moonshot balance API](https://platform.kimi.ai/docs/api/balance),
[Kimi Code usage implementation](https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-usage.ts),
and [MiniMax quota endpoint](https://platform.minimax.io/docs/m-plan/faq).
MiniMax count-based parsing treats `current_interval_usage_count` as remaining,
as described in the [provider issue](https://github.com/MiniMax-AI/MiniMax-M2/issues/99).
New remote probes cache successful aggregate results for five minutes and back
off failures for at least ten minutes, honoring longer `Retry-After` values.
Changing a connection clears its probe cache.

CLI equivalent: `configure openrouter connect --secret-name OPENROUTER_API_KEY`.
Regional providers also accept `--region global` or `--region cn`.

## How it works

The plugin is two halves and one file between them. Nothing else couples them:
the QML never calls a provider, and the collector never renders.

```text
bin/omarchy-agent-limits-sync  ──▶  ~/.local/state/omarchy/agent-limits/data.json  ──▶  QML views
  collect · price · roll             aggregates only, mode 0600                 bar · panel · pages
```

### The collector

One run of `sync`:

1. `load_config()` merges `~/.config/omarchy/agent-limits.json` over
   `config.example.json`, so a missing or partial config still yields a complete
   one.
2. `credentials()` resolves each provider independently — process environment,
   then OpenCode's `auth.json`, then the private runtime cache, then Bitwarden.
   A provider that cannot be resolved takes its own error with it.
3. API provider checks run in a three-thread pool; Claude and Codex use the
   native probe cache described above.
4. Local ledgers are read and **added**: `opencode_ledger()` reads the OpenCode
   database, `pi_ledger()` reads pi's session logs, `claude_ledger()` and
   `codex_ledger()` read the CLIs' own session logs; `merge_ledger()` sums them
   per provider, day, hour and model. A CLI log with data replaces Omarchy's
   aggregated record for that provider rather than adding to it.
5. `price_model()`/`price_metrics()` price each model against `pricing`;
   recorded costs win where the harness stored one.
6. `finalize_provider()` derives `today`/`week`/`total` from the day buckets,
   builds the `days`, `hours` and `models` series, and ends by rolling any limit
   whose window already reset.
7. `atomic_json()` writes the cache through a temporary file, so a reader never
   sees half a file.

A run is single-instance: it takes a non-blocking `flock` on
`$XDG_STATE_HOME/omarchy/agent-limits/sync.lock` and a second invocation exits
quietly, which makes it safe to call from several surfaces at once.
`snapshot` prints the cache and touches no network.

### The cache

`data.json` is the only contract between the halves. Per provider:

| Field | Contents |
|---|---|
| `limits[]` | `label`, `percent` (0–100, never a fraction), `remaining`, `exhausted`, `resetsAt` (ISO UTC, empty when unknown) |
| `limitsSource` | `live` (probed now) or `record` (Omarchy's snapshot, shown as `cached`) |
| `balance[]` | Real account balance strings `{currency, total}`; DeepSeek also supplies `granted` and `toppedUp` |
| `today` / `week` / `total` | `tokens`, `input`, `output`, `cacheRead`, `cacheWrite`, `cost`, `priced`, `requests`, `sessions` |
| `days[]` / `hours[]` | 30 daily and 24 hourly buckets with the same metric keys |
| `models[]` | Top 20 model rows, already priced and sorted |
| `status` / `error` / `stale` / `syncedAt` | Honest per-provider state; one provider never blanks another |

No prompt text, session content, credential, or raw API response is ever stored
— only aggregates, plan names and rate-limit state.

### The views

- `Service.qml` is the always-on half: it watches the cache with `FileView` and
  runs the collector on a timer. `Panel.qml` reads it through
  `bar.shell.serviceFor()`.
- `EmbeddedPage.qml` serves **both** hosts. It declares `initializeDashboard`,
  `dashboardActivate`, `dashboardDeactivate`, `dashboardFocus` and the
  `sidePanel…` equivalents, so no host has to adapt it.
- `Dashboard.qml` and `DailyChart.qml` are pure presentation over `cache`.
- `Model.js` holds the helpers they share — formatting, window sums, stacking,
  parse/cap of the cache. It imports no QML type, which is why it can be unit
  tested by `node`.
- `Panel.qml` owns the widget text (remaining percentage of the tightest
  window), the popup shell and the plugin's IPC handler.

### Failure model

Every provider is settled on its own: a failed remote check keeps the previous
limits via `preserve_on_error()`, sets `error` and `stale`, and never throws
into QML. A run that dies entirely leaves the previous cache in place and only
flips `state` to `error` with a fixed, credential-free message.

## Install

For local development:

```bash
ln -s ~/projects/personal/omarchy-agent-limits ~/.config/omarchy/plugins/gshulga.agent-limits
omarchy-shell shell rescanPlugins
omarchy plugin enable gshulga.agent-limits
```

`omarchy plugin validate` refuses symlinked plugin folders, so validate the
repository path instead (`omarchy plugin validate .` from the repo).

The widget is placed on the right by default. Dashboard discovers the declared
`dashboardPage`; Side Panel discovers `sidePanelPage`. Add **Agent Limits** as a
normal tile/page in either host. No adapted window or duplicate IPC handler is
created.

QML changes need a full shell restart — the shell runs with its file watcher
disabled, and a stale compiled cache survives `rescanPlugins`:

```bash
rm -rf ~/.cache/quickshell/qmlcache/* ~/.cache/quickshell/qtpipelinecache-*
omarchy-restart-shell
```

## Configuration

Configuration is optional. Defaults enable all five providers and read secret
names `OPENCODE_GO_API_KEY`, `ZAI_API_KEY`, and `DEEPSEEK_API_KEY`. To customize
them, copy `config.example.json` to:

```text
~/.config/omarchy/agent-limits.json
```

Only the keys you need are required. For a China-region Z.AI account, set
`"region": "cn"`. Set `enabled: false` for providers you do not use.

### Bitwarden Secrets Manager

The collector first checks existing provider environment variables and
OpenCode's own `auth.json`. Missing credentials are resolved through BWS using
your existing machine account. The BWS environment is read from the current
process or the first available values in:

```text
~/.config/omarchy/jira.env
~/.config/omarchy/litellm.env
~/.config/omarchy/agent-limits.env
```

Every env file that exists must have mode `0600`:

```bash
chmod 600 ~/.config/omarchy/agent-limits.env
```

```bash
BWS_ACCESS_TOKEN=...
# Optional self-hosted instance:
BWS_SERVER_URL=https://bitwarden.example.com
```

API keys are cached only under `/run/user/$UID/omarchy-agent-limits/` with
private permissions. The aggregate display cache is
`~/.local/state/omarchy/agent-limits/data.json`, also mode `0600`.

Secret names are matched against a small alias list, so a key filed under an
older or vendor-specific name is still found — the first candidate is the
configured `secretKey`, then e.g. `OPENCODE_ZEN_API_KEY`/
`READ_ONLY_OPENCODE_API_KEY` for OpenCode Go, `ZHIPUAI_API_KEY`/`GLM_API_KEY`
for Z.AI. A provider whose secret is missing reports only its own error; it
never blanks the providers that did resolve.

### Prices

`pricing` maps exact model IDs to USD per million tokens:

```json
{
  "pricing": {
    "my-model": { "input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 1.25 }
  }
}
```

Recorded positive OpenCode costs win over estimates. Every other turn is priced
turn by turn against this table, so Claude and Codex costs follow their own logs
rather than a daily average. The one averaged case left is a provider whose only
source is Omarchy's aggregated record (no CLI log found): that record publishes
daily token totals only, so the cost is the all-time model cost spread over
all-time tokens and applied per day — the shape of the trend is exact, the
per-token rate is an average. Update prices when providers change them. Fixed
subscription fees are intentionally not mixed into the API-equivalent total. The
exact prices currently configured are documented in `config.example.json`
(OpenAI Standard short-context, and Fast mode = 2 × Standard).

## Provider marks

Each provider card and each "By provider" row shows the provider's brand mark,
resolved by convention the same way Omarchy's own agent panel does it:

```text
assets/<provider-id>.svg          # mark for a dark surface
assets/<provider-id>-light.svg    # optional mark for a light surface
```

`<provider-id>` is the provider id used in the cache (`opencode-go`, `zai`,
`claude`, `codex`, `deepseek`), so adding a provider needs no QML change. The
surface is classified by the luminance of `Commons.Color.background`; the
`-light` file is only tried on light themes and the plain file is the fallback.
A missing asset degrades to the plugin's bar glyph, never to an empty box.

Provenance: the Claude and DeepSeek paths come from Simple Icons (CC0), the
Codex paths and `codex-light.svg` are Omarchy's own copies, and `zai.svg` is the
mark published by z.ai. They are used for identification only.

## Time ranges and charts

The Usage and Cost tabs share one preset: `Today`, `7d` or `30d`. It drives the
stat tiles, the chart and the provider rows at once, so the three never
disagree.

Charts are stacked bars: every bucket is split by provider, in the order the
providers appear in the list below. That list is also the legend — each row's
underline uses the provider's own chart colour. The palette is derived from the
theme accent (lightened toward the foreground, deepened for the alternate
steps), so it follows the theme instead of hardcoding brand colours.

`Today` switches the plot to 24 hourly buckets with tick labels. Every log that
records per-turn timestamps (pi sessions, the OpenCode database, Claude Code and
Codex rollouts) can be split by hour. Only a provider falling back to Omarchy's
aggregated daily record cannot, so the chart names it with
`no hourly detail: <provider>` instead of silently flattening its share to zero.

## Reset rollover

A limit whose `resetsAt` is already in the past describes the previous window,
not the current one. A live probe is already truthful, but a record that the
updater did not refresh can sit at 96% for a day after it rolled over; the same
rule protects the cache when a probe is skipped or fails. The sync advances
such a window in whole periods taken from its label (`5-hour`/`session` → 5 h,
`7-day`/`weekly` → 7 d, `monthly` → 30 d), resets its usage to zero and keeps
the original phase, so the displayed reset time is the next real one. A label
with no known period clears the reset time instead of inventing one.

## Interactions

- **Left click:** open the panel; **middle click:** refresh.
- **Refresh** reruns the whole collector — local logs are re-read and re-priced
  every time. Remote limits are served from the probe cache (5 min Claude, 4
  min Codex, 10 min after a failure), so two clicks within a minute honestly
  return the same number. Hovering the refresh icon lists when each
  provider's limit was last measured, which separates a slow-moving quota
  from a number that is not being read.
- **R / Enter:** refresh; **1 / 2 / 3:** Limits / Usage / Cost.
- **Left / Right:** switch tabs; **Up / Down:** scroll; **Esc:** close.
- The bar percentage is the amount left in the most pressured quota window; its
tooltip names that provider and window.
- Scripting: `omarchy-shell gshulga.agent-limits open|close|toggle|refresh`.

Refresh defaults to five minutes and can be changed in plugin settings along
with warning/critical thresholds. Hosted pages refresh only while active.

## CLI and development

```bash
bin/omarchy-agent-limits-sync sync
bin/omarchy-agent-limits-sync snapshot | jq .
tests/all.sh
```

The sync command is single-instance and safe to invoke from multiple surfaces.
Network calls use fixed HTTPS hosts, 15-second timeouts, a 1 MB response cap,
strict schema checks, and no credential-forwarding redirects. Failed remote
checks retain last-known limits with an error/stale indication.
