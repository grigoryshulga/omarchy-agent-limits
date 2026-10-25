# Agent Limits for Omarchy

A compact, theme-aware monitor for **OpenCode Go, Z.AI Coding Plan, Claude Pro,
ChatGPT Plus/Codex, and DeepSeek API**. It provides the same three views in the
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

Omarchy's `~/.local/state/omarchy/agents/usage/*.json` records are still read for
local token statistics, and their limits remain a **fallback** for when a probe
fails; the cache marks which one was used in `limitsSource` (`live` or
`record`). A card showing a fallback labels its plan `Pro · cached`, so an
unrefreshed number never looks freshly measured.

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

Recorded positive OpenCode costs win over estimates. For native Claude/Codex
records, costs are calculated from token totals and this table; because those
records only publish daily *token* totals, the daily/weekly cost is the all-time
model cost spread over all-time tokens and applied per day — the shape of the
trend is exact, the per-token rate is an average. Update prices when providers
change them. Fixed subscription fees are intentionally not mixed into the
API-equivalent total. The exact prices currently configured are documented in
`config.example.json` (OpenAI Standard short-context, and Fast mode = 2 ×
Standard).

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

`Today` switches the plot to 24 hourly buckets with tick labels. Only harnesses
that record per-turn timestamps (pi sessions, the OpenCode database) can be
split by hour; providers whose usage comes from Omarchy's daily agent records
(Claude, ChatGPT) cannot, so the chart says `no hourly detail: <provider>`
rather than silently flattening their share to zero. Their *limits* are read
live, but their token counts are still daily figures.

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
