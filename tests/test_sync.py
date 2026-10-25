import importlib.util
import importlib.machinery
import json
import tempfile
import unittest
from pathlib import Path
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
LOADER = importlib.machinery.SourceFileLoader("agent_limits", str(ROOT / "bin/omarchy-agent-limits-sync"))
SPEC = importlib.util.spec_from_loader("agent_limits", LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProviderParsingTests(unittest.TestCase):
    def test_opencode_percent_and_exhaustion_status(self):
        payload = {"usage": {"rolling": {"status": "rate-limited", "percent": 99, "resetsAt": "2026-10-24T18:00:00Z"},
                             "weekly": {"status": "ok", "percent": 42, "resetsAt": None}}}
        with patch.object(MODULE, "request_json", return_value=payload):
            limits, plan = MODULE.collect_opencode("secret")
        self.assertEqual(plan, "Go")
        self.assertEqual(limits[0]["percent"], 99)
        self.assertTrue(limits[0]["exhausted"])
        self.assertEqual(limits[1]["remaining"], 58)
        self.assertNotIn("monthly", [item["label"] for item in limits])

    def test_zai_credit_windows_are_mapped_by_window_not_order(self):
        payload = {"success": True, "data": {"level": "pro", "limits": [
            {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 10000, "currentValue": 5207,
             "remaining": 4793, "percentage": 52, "nextResetTime": 1788784466996},
            {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 2000, "currentValue": 402,
             "remaining": 1598, "percentage": 20, "nextResetTime": 1788351145586},
            {"type": "UNKNOWN", "unit": 9, "number": 9, "percentage": 90}
        ]}}
        with patch.object(MODULE, "request_json", return_value=payload):
            limits, plan = MODULE.collect_zai("secret", "global")
        self.assertEqual(plan, "pro")
        self.assertEqual([item["label"] for item in limits], ["Weekly (7-day)", "Session (5-hour)"])
        self.assertEqual(limits[0]["unit"], "credits")
        self.assertEqual(len(limits), 2)

    def test_zai_http_200_business_failure_is_not_zero_usage(self):
        with patch.object(MODULE, "request_json", return_value={"success": False, "code": 1001}):
            with self.assertRaises(MODULE.SyncError):
                MODULE.collect_zai("secret", "global")

    def test_deepseek_preserves_currency_and_decimal_strings(self):
        payload = {"is_available": True, "balance_infos": [
            {"currency": "USD", "total_balance": "10.01", "granted_balance": "0.01", "topped_up_balance": "10.00"},
            {"currency": "CNY", "total_balance": "20.00", "granted_balance": "0.00", "topped_up_balance": "20.00"}
        ]}
        with patch.object(MODULE, "request_json", return_value=payload):
            balances, available = MODULE.collect_deepseek("secret")
        self.assertTrue(available)
        self.assertEqual(balances[0]["total"], "10.01")
        self.assertEqual(balances[1]["currency"], "CNY")

    def test_unknown_model_is_unpriced(self):
        usage = {"inputTokens": 1000, "outputTokens": 1000}
        self.assertEqual(MODULE.price_model("new-model", usage, {}), -1)

    def test_pricing_includes_cache_components(self):
        usage = {"inputTokens": 1_000_000, "outputTokens": 1_000_000,
                 "cacheReadInputTokens": 1_000_000, "cacheCreationInputTokens": 1_000_000}
        rates = {"model": {"input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 1.25}}
        self.assertAlmostEqual(MODULE.price_model("model", usage, rates), 4.35)

    def test_error_preserves_remote_limits_but_not_credentials(self):
        fresh = MODULE.empty_provider("zai")
        previous = MODULE.empty_provider("zai")
        previous["limits"] = [{"label": "Weekly", "percent": 40}]
        previous["syncedAt"] = 123
        MODULE.preserve_on_error(fresh, previous, "network unavailable")
        self.assertEqual(fresh["limits"], previous["limits"])
        self.assertTrue(fresh["stale"])
        serialized = json.dumps(fresh)
        self.assertNotIn("Authorization", serialized)
        self.assertNotIn("secret", serialized)


class CredentialTests(unittest.TestCase):
    @staticmethod
    def _bws(secrets, fail_get=()):
        """Stand-in for the bws CLI: list ids, then serve secret get by id."""

        def run(argv, **kwargs):
            class Result:
                returncode = 0
                stderr = ""

            result = Result()
            if argv[1:3] == ["secret", "list"]:
                result.stdout = json.dumps({"data": [
                    {"key": key, "id": f"id-{key}"} for key in secrets
                ]})
                return result
            name = str(argv[3])[3:]
            if name in fail_get:
                result.returncode = 2
                result.stdout = ""
                return result
            result.stdout = json.dumps({"value": secrets[name]})
            return result

        return run

    def test_missing_secret_only_blames_its_own_provider(self):
        env = {"BWS_ACCESS_TOKEN": "token"}
        fake = self._bws({"ZAI_API_KEY": "zai-value", "DEEPSEEK_API_KEY": "deep-value"})
        with patch.dict(MODULE.os.environ, env, clear=False), \
                patch.object(MODULE, "bws_environment", return_value={}), \
                patch.object(MODULE, "subprocess") as subprocess:
            subprocess.run.side_effect = fake
            subprocess.TimeoutExpired = TimeoutError
            found, errors = MODULE.fetch_bws_keys({
                "opencode-go": ("OPENCODE_GO_API_KEY", "READ_ONLY_OPENCODE_API_KEY"),
                "zai": ("ZAI_API_KEY",),
                "deepseek": ("DEEPSEEK_API_KEY",),
            })
        self.assertEqual(errors, {"opencode-go": "secret OPENCODE_GO_API_KEY was not found in Bitwarden"})
        self.assertEqual(found["zai"], ("ZAI_API_KEY", "zai-value"))
        self.assertEqual(found["deepseek"], ("DEEPSEEK_API_KEY", "deep-value"))

    def test_alias_secret_name_is_accepted(self):
        fake = self._bws({"READ_ONLY_OPENCODE_API_KEY": "go-value"})
        with patch.dict(MODULE.os.environ, {"BWS_ACCESS_TOKEN": "token"}, clear=False), \
                patch.object(MODULE, "bws_environment", return_value={}), \
                patch.object(MODULE, "subprocess") as subprocess:
            subprocess.run.side_effect = fake
            subprocess.TimeoutExpired = TimeoutError
            found, errors = MODULE.fetch_bws_keys({
                "opencode-go": MODULE.secret_names({"providers": {"opencode-go": {}}}, "opencode-go"),
            })
        self.assertEqual(errors, {})
        self.assertEqual(found["opencode-go"], ("READ_ONLY_OPENCODE_API_KEY", "go-value"))

    def test_unreadable_secret_does_not_drop_other_secrets(self):
        fake = self._bws({"ZAI_API_KEY": "zai-value", "DEEPSEEK_API_KEY": "deep-value"}, fail_get=("ZAI_API_KEY",))
        with patch.dict(MODULE.os.environ, {"BWS_ACCESS_TOKEN": "token"}, clear=False), \
                patch.object(MODULE, "bws_environment", return_value={}), \
                patch.object(MODULE, "subprocess") as subprocess:
            subprocess.run.side_effect = fake
            subprocess.TimeoutExpired = TimeoutError
            found, errors = MODULE.fetch_bws_keys({
                "zai": ("ZAI_API_KEY",), "deepseek": ("DEEPSEEK_API_KEY",),
            })
        self.assertEqual(list(errors), ["zai"])
        self.assertEqual(found, {"deepseek": ("DEEPSEEK_API_KEY", "deep-value")})

    def test_secret_names_put_the_configured_key_first(self):
        config = {"providers": {"zai": {"secretKey": "MY_ZAI"}}}
        self.assertEqual(MODULE.secret_names(config, "zai")[0], "MY_ZAI")
        self.assertIn("ZAI_API_KEY", MODULE.secret_names(config, "zai"))
        self.assertEqual(len(MODULE.secret_names(config, "zai")), len(set(MODULE.secret_names(config, "zai"))))


class NativePricingTests(unittest.TestCase):
    """Native agent records carry daily token totals only, so day and week cost
    must be estimated from the all-time model aggregate instead of staying zero."""

    def _provider(self, record):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "claude.json").write_text(json.dumps(record))
            with patch.object(MODULE, "AGENT_RECORDS", Path(tmp)):
                return MODULE.native_provider("claude", {"pricing": {
                    "claude-sonnet-5-5": {"input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite": 2.5}}})

    def test_days_and_today_carry_estimated_cost(self):
        today = MODULE.dt.date.today().isoformat()
        yesterday = (MODULE.dt.date.today() - MODULE.dt.timedelta(days=1)).isoformat()
        provider = self._provider({
            "tierLabel": "Pro", "limitsFetchedAt": 1, "totalPrompts": 10, "totalSessions": 2,
            "recentDays": [{"date": yesterday, "messageCount": 1_000_000}, {"date": today, "messageCount": 1_000_000}],
            "modelUsage": {"claude-sonnet-5-5": {"inputTokens": 1_000_000, "outputTokens": 1_000_000}},
            "todayTotalTokens": 1_000_000, "todayPrompts": 4, "todaySessions": 1})
        self.assertTrue(provider["week"]["priced"])
        self.assertGreater(provider["week"]["cost"], 0)
        self.assertTrue(provider["today"]["priced"])
        self.assertGreater(provider["today"]["cost"], 0)
        self.assertEqual(provider["today"]["requests"], 4)
        # All-time cost stays the exact model aggregate, not the day estimate.
        self.assertAlmostEqual(provider["total"]["cost"], 12.0, places=6)

    def test_unpriced_models_keep_days_unpriced(self):
        today = MODULE.dt.date.today().isoformat()
        provider = self._provider({
            "tierLabel": "Pro", "limitsFetchedAt": 1, "totalPrompts": 1, "totalSessions": 1,
            "recentDays": [{"date": today, "messageCount": 500}],
            "modelUsage": {"some-unlisted-model": {"inputTokens": 500}},
            "todayTotalTokens": 500, "todayPrompts": 1, "todaySessions": 1})
        self.assertFalse(provider["week"]["priced"])
        self.assertFalse(provider["today"]["priced"])



class WindowRolloverTests(unittest.TestCase):
    """A recorded window that already reset must not keep reporting last period."""

    def _provider(self, label, percent, resets_at):
        provider = MODULE.empty_provider("claude")
        provider["limits"].append({"label": label, "percent": percent, "remaining": 100 - percent,
                                   "resetsAt": resets_at, "exhausted": percent >= 100})
        return provider

    def test_passed_weekly_window_rolls_forward_a_week(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Weekly (7-day)", 96.0, "2026-10-24T17:00:00+00:00")
        MODULE.roll_expired_limits(provider, now)
        limit = provider["limits"][0]
        self.assertEqual(limit["percent"], 0.0)
        self.assertEqual(limit["remaining"], 100.0)
        self.assertFalse(limit["exhausted"])
        self.assertEqual(MODULE.parse_moment(limit["resetsAt"]), MODULE.dt.datetime(2026, 10, 31, 17, 0, tzinfo=MODULE.dt.timezone.utc))
        self.assertEqual(limit["rolledWindows"], 1)

    def test_passed_session_window_rolls_forward_five_hours(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Session (5-hour)", 100.0, "2026-10-25T01:30:00Z")
        MODULE.roll_expired_limits(provider, now)
        limit = provider["limits"][0]
        self.assertEqual(limit["percent"], 0.0)
        self.assertEqual(MODULE.parse_moment(limit["resetsAt"]), now + MODULE.dt.timedelta(hours=2, minutes=30))

    def test_multiple_periods_are_skipped_at_once(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Monthly", 40.0, "2026-08-01T00:00:00Z")
        MODULE.roll_expired_limits(provider, now)
        limit = provider["limits"][0]
        self.assertEqual(MODULE.parse_moment(limit["resetsAt"]), MODULE.dt.datetime(2026, 10, 30, tzinfo=MODULE.dt.timezone.utc))
        self.assertEqual(limit["rolledWindows"], 3)

    def test_future_window_is_left_alone(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Weekly (7-day)", 96.0, "2026-10-31T02:56:59+00:00")
        MODULE.roll_expired_limits(provider, now)
        limit = provider["limits"][0]
        self.assertEqual(limit["percent"], 96.0)
        self.assertEqual(limit["resetsAt"], "2026-10-31T02:56:59+00:00")
        self.assertNotIn("rolledWindows", limit)

    def test_unknown_period_clears_the_reset_instead_of_guessing(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Credits", 100.0, "2026-10-01T00:00:00Z")
        MODULE.roll_expired_limits(provider, now)
        limit = provider["limits"][0]
        self.assertEqual(limit["percent"], 0.0)
        self.assertEqual(limit["resetsAt"], "")

    def test_empty_reset_is_not_a_window(self):
        now = MODULE.dt.datetime(2026, 10, 25, 4, 0, tzinfo=MODULE.dt.timezone.utc)
        provider = self._provider("Session (5-hour)", 0.0, "")
        MODULE.roll_expired_limits(provider, now)
        self.assertEqual(provider["limits"][0]["resetsAt"], "")


class PiLedgerTests(unittest.TestCase):
    """DeepSeek publishes no usage API, so its requests and spend come from the
    harness session logs that made the calls."""

    def _ledger(self, turns, pricing=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, lines in turns.items():
                (root / name).write_text("\n".join(json.dumps(line) for line in lines) + "\n")
            with patch.object(MODULE, "PI_SESSIONS", root):
                return MODULE.pi_ledger({"pricing": pricing or {}})

    def _turn(self, timestamp, provider="deepseek", model="deepseek-flash", tokens=1000, cost=None, **usage):
        entry = {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": tokens}
        if cost is not None:
            entry["cost"] = {"total": cost}
        entry.update(usage)
        return {"type": "message", "timestamp": timestamp,
                "message": {"role": "assistant", "provider": provider, "model": model, "usage": entry}}

    def test_recorded_cost_and_tokens_are_attributed(self):
        ledger = self._ledger({"s1.jsonl": [self._turn("2026-10-24T10:00:00.000Z", tokens=2000, cost=0.5)]})
        deepseek = ledger["deepseek"]
        self.assertEqual(deepseek["total"]["tokens"], 2000)
        self.assertEqual(deepseek["total"]["requests"], 1)
        self.assertEqual(deepseek["total"]["sessions"], 1)
        self.assertTrue(deepseek["total"]["priced"])
        self.assertAlmostEqual(deepseek["total"]["cost"], 0.5, places=6)
        self.assertEqual(list(deepseek["models"]), ["deepseek-flash"])

    def test_unpriced_turn_falls_back_to_the_pricing_table(self):
        ledger = self._ledger(
            {"s1.jsonl": [self._turn("2026-10-24T10:00:00.000Z", model="deepseek-v4-pro", tokens=1000)]},
            pricing={"deepseek-v4-pro": {"input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 1}})
        self.assertTrue(ledger["deepseek"]["total"]["priced"])
        self.assertAlmostEqual(ledger["deepseek"]["total"]["cost"], 0.001, places=9)

    def test_unknown_model_stays_unpriced(self):
        ledger = self._ledger({"s1.jsonl": [self._turn("2026-10-24T10:00:00.000Z", model="mystery-model")]})
        self.assertFalse(ledger["deepseek"]["total"]["priced"])

    def test_shared_proxy_and_subscription_harnesses_are_ignored(self):
        ledger = self._ledger({"s1.jsonl": [
            self._turn("2026-10-24T10:00:00.000Z", provider="litellm", model="deepseek-v4-flash-vision-exp", cost=9.0),
            self._turn("2026-10-24T11:00:00.000Z", provider="claude-bridge", model="claude-opus-5-5", cost=9.0),
            self._turn("2026-10-24T12:00:00.000Z", provider="openai-codex", model="gpt-6-luna", cost=9.0),
        ]})
        for provider_id in ("deepseek", "zai", "opencode-go"):
            self.assertEqual(ledger[provider_id]["total"]["requests"], 0)
            self.assertEqual(ledger[provider_id]["total"]["cost"], 0)

    def test_zai_plan_usage_is_attributed_from_pi(self):
        ledger = self._ledger({"s1.jsonl": [self._turn("2026-10-24T10:00:00.000Z", provider="zai", model="glm-5.3", cost=0.25)]})
        self.assertEqual(ledger["zai"]["total"]["requests"], 1)
        self.assertAlmostEqual(ledger["zai"]["total"]["cost"], 0.25, places=6)
        self.assertEqual(ledger["deepseek"]["total"]["requests"], 0)

    def test_empty_turns_are_not_requests(self):
        ledger = self._ledger({"s1.jsonl": [{"type": "message", "timestamp": "2026-10-24T10:00:00.000Z",
                                             "message": {"role": "assistant", "provider": "deepseek",
                                                         "model": "deepseek-flash", "usage": {"totalTokens": 0}}}]})
        self.assertEqual(ledger["deepseek"]["total"]["requests"], 0)


if __name__ == "__main__":
    unittest.main()


class ClaudeLimitsTests(unittest.TestCase):
    def test_payload_percentages_are_percent_scaled(self):
        payload = {"five_hour": {"utilization": 37.0, "resets_at": "2026-10-25T12:00:00Z"},
                   "seven_day": {"utilization": 96.0, "resets_at": "2026-10-31T17:00:00Z"}}
        limits = MODULE.claude_limits(payload)
        self.assertEqual([item["label"] for item in limits], ["Session (5-hour)", "Weekly (7-day)"])
        self.assertAlmostEqual(limits[0]["percent"], 37.0)
        self.assertAlmostEqual(limits[1]["remaining"], 4.0)

    def test_fractional_payload_is_read_as_fractions(self):
        # No value reaches 1, so the payload is fractional: 0.96 is 96%.
        payload = {"five_hour": {"utilization": 0.37}, "seven_day": {"utilization": 0.96}}
        limits = MODULE.claude_limits(payload)
        self.assertAlmostEqual(limits[0]["percent"], 37.0)
        self.assertAlmostEqual(limits[1]["percent"], 96.0)
        self.assertEqual(limits[1]["remaining"], 4.0)

    def test_unit_payload_is_percent_scaled(self):
        # Any value at or above 1 settles the convention for the whole payload,
        # so this is 1% and 0.5%, matching Anthropic's own reading.
        payload = {"five_hour": {"utilization": 1.0}, "seven_day": {"utilization": 0.5}}
        limits = MODULE.claude_limits(payload)
        self.assertAlmostEqual(limits[0]["percent"], 1.0)
        self.assertFalse(limits[0]["exhausted"])
        self.assertAlmostEqual(limits[1]["percent"], 0.5)

    def test_scoped_model_window_is_its_own_row(self):
        payload = {"seven_day": {"utilization": 20},
                   "limits": [{"kind": "weekly_scoped", "percent": 88,
                               "resets_at": "2026-10-31T17:00:00Z",
                               "scope": {"model": {"display_name": "Opus 5"}}}]}
        limits = MODULE.claude_limits(payload)
        self.assertEqual([item["label"] for item in limits], ["Weekly (7-day)", "Opus 5 Weekly"])
        self.assertAlmostEqual(limits[1]["percent"], 88.0)
        self.assertEqual(MODULE.window_period("Opus 5 Weekly").days, 7)

    def test_oauth_apps_weekly_window_wins_over_the_plain_one(self):
        payload = {"seven_day": {"utilization": 10}, "seven_day_oauth_apps": {"utilization": 70}}
        limits = MODULE.claude_limits(payload)
        self.assertAlmostEqual(limits[0]["percent"], 70.0)

    def test_plan_label_reads_the_subscription_and_multiplier(self):
        self.assertEqual(MODULE.claude_plan({"subscriptionType": "pro"}), "Pro")
        self.assertEqual(MODULE.claude_plan({"subscriptionType": "max", "rateLimitTier": "max_20x"}), "Max 20x")

    def test_missing_login_is_an_error_not_an_empty_card(self):
        with patch.object(MODULE, "read_json", return_value={}):
            with self.assertRaises(MODULE.SyncError):
                MODULE.collect_claude_limits()


class CodexLimitsTests(unittest.TestCase):
    def test_weekly_and_session_windows_are_named_by_their_length(self):
        limits = MODULE.codex_limits({
            "primary": {"usedPercent": 81, "windowDurationMins": 10080, "resetsAt": 1793410.0},
            "secondary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1792000.0},
        })
        self.assertEqual([item["label"] for item in limits], ["Weekly (7-day)", "5h window"])
        self.assertAlmostEqual(limits[0]["percent"], 81.0)
        self.assertEqual(MODULE.window_period("5h window").seconds, 5 * 3600)

    def test_spend_limit_uses_the_amounts_not_the_rounded_share(self):
        limits = MODULE.codex_limits({"individualLimit": {"limit": 200, "used": 50, "remainingPercent": 75}})
        self.assertEqual(limits[0]["label"], "Spend limit")
        self.assertAlmostEqual(limits[0]["percent"], 25.0)

    def test_window_without_used_percent_is_skipped(self):
        self.assertEqual(MODULE.codex_limits({"primary": {"windowDurationMins": 10080}}), [])

    def test_rpc_failure_keeps_the_record_limits_available(self):
        record = {"limits": [{"label": "Weekly (7-day)", "percent": 0.55, "resetsAt": "2026-10-31T02:56:59+00:00"}]}
        rows = MODULE.record_limits(record)
        self.assertAlmostEqual(rows[0]["percent"], 55.0)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(MODULE, "LIVE_LIMITS_STATE", Path(directory) / "live-limits.json"):
                with patch.object(MODULE, "collect_codex_limits", side_effect=MODULE.SyncError("Codex did not answer the limits check")):
                    limits, plan, error = MODULE.native_limits("codex")
        self.assertEqual(limits, [])
        self.assertEqual(plan, "")
        self.assertEqual(error, "Codex did not answer the limits check")


class LiveLimitsCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name) / "live-limits.json"
        self.patch = patch.object(MODULE, "LIVE_LIMITS_STATE", self.state)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def _answer(self, fetched_at=1000.0):
        MODULE.remember_live_limits("codex", {"fetchedAt": fetched_at, "plan": "Plus",
                                              "limits": [{"label": "Weekly (7-day)", "percent": 83.0}]})

    def test_recent_answer_is_reused(self):
        self._answer()
        limits, plan, error, cached = MODULE.cached_live_limits("codex", now=1100.0)
        self.assertTrue(cached)
        self.assertEqual(error, "")
        self.assertEqual(plan, "Plus")
        self.assertAlmostEqual(limits[0]["percent"], 83.0)

    def test_stale_answer_is_not(self):
        self._answer()
        self.assertEqual(MODULE.cached_live_limits("codex", now=1000.0 + MODULE.LIVE_LIMITS_TTL["codex"] + 1), ([], "", "", False))

    def test_a_failure_is_remembered_longer_than_an_answer(self):
        MODULE.remember_live_limits("claude", {"failedAt": 1000.0, "error": "provider rate-limited the usage check"})
        limits, plan, error, cached = MODULE.cached_live_limits("claude", now=1000.0 + MODULE.LIVE_LIMITS_BACKOFF - 1)
        self.assertTrue(cached)
        self.assertEqual(limits, [])
        self.assertIn("rate-limited", error)

    def test_the_collector_is_skipped_while_the_answer_is_fresh(self):
        self._answer(fetched_at=time.time())
        with patch.object(MODULE, "collect_codex_limits", side_effect=AssertionError("probe must not run")):
            limits, plan, error = MODULE.native_limits("codex")
        self.assertEqual(error, "")
        self.assertEqual(plan, "Plus")
        self.assertEqual(len(limits), 1)

    def test_a_probe_that_runs_is_what_gets_cached(self):
        with patch.object(MODULE, "collect_codex_limits", return_value=([{"label": "Weekly (7-day)", "percent": 40.0}], "Plus")):
            limits, plan, error = MODULE.native_limits("codex")
        self.assertEqual(error, "")
        self.assertEqual(len(limits), 1)
        cached_limits, cached_plan, _, cached = MODULE.cached_live_limits("codex")
        self.assertTrue(cached)
        self.assertEqual(cached_plan, "Plus")
        self.assertAlmostEqual(cached_limits[0]["percent"], 40.0)


class RateLimitBackoffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.patch = patch.object(MODULE, "LIVE_LIMITS_STATE", Path(self.directory.name) / "live-limits.json")
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_retry_after_is_carried_out_of_the_http_layer(self):
        error = MODULE.SyncError("provider rate-limited the usage check", 124)
        self.assertEqual(error.retry_after, 124.0)

    def test_a_named_wait_outlasts_the_default_backoff(self):
        MODULE.remember_live_limits("claude", {"failedAt": 1000.0, "error": "rate limited", "retryAfter": 3600})
        _, _, error, cached = MODULE.cached_live_limits("claude", now=1000.0 + MODULE.LIVE_LIMITS_BACKOFF + 60)
        self.assertTrue(cached)
        self.assertEqual(error, "rate limited")

    def test_the_default_backoff_survives_a_short_provider_wait(self):
        # 120s is Anthropic's usual Retry-After; the default backoff is longer,
        # so the probe does not come back early into another refusal.
        MODULE.remember_live_limits("claude", {"failedAt": 1000.0, "error": "rate limited", "retryAfter": 120})
        _, _, error, cached = MODULE.cached_live_limits("claude", now=1000.0 + 130)
        self.assertTrue(cached)
        self.assertEqual(error, "rate limited")

    def test_the_wait_expires(self):
        MODULE.remember_live_limits("claude", {"failedAt": 1000.0, "error": "rate limited", "retryAfter": 120})
        self.assertEqual(MODULE.cached_live_limits("claude", now=1000.0 + MODULE.LIVE_LIMITS_BACKOFF + 1), ([], "", "", False))

class HarnessLedgerTests(unittest.TestCase):
    """Claude Code and Codex log their own turns, which keeps usage moving
    without waiting for Omarchy's updater to run."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.pricing = {"pricing": {
            "claude-sonnet-5-5": {"input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite": 2.5},
            "gpt-6-astra": {"input": 10, "output": 50, "cacheRead": 1, "cacheWrite": 12.5},
        }}
        self.now = MODULE.dt.datetime.now().astimezone()

    def _stamp(self, moment=None):
        moment = moment or self.now
        return moment.astimezone(MODULE.dt.timezone.utc).isoformat().replace("+00:00", "Z")

    def _claude_line(self, role="assistant", model="claude-sonnet-5-5", usage=None, stamp=None):
        return json.dumps({"type": role, "sessionId": "session-one", "timestamp": stamp or self._stamp(),
                           "message": {"role": role, "model": model,
                                       "usage": usage if usage is not None else {
                                           "input_tokens": 100, "output_tokens": 50,
                                           "cache_read_input_tokens": 1000,
                                           "cache_creation_input_tokens": 400}}})

    def _claude(self, lines):
        path = self.root / "claude" / "projects" / "project-one" / "session-one.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        with patch.object(MODULE, "CLAUDE_PROJECTS", self.root / "claude" / "projects"):
            return MODULE.claude_ledger(self.pricing)["claude"]

    def test_claude_turn_is_counted_and_priced(self):
        bucket = self._claude([self._claude_line()])
        total = bucket["total"]
        self.assertEqual(total["tokens"], 1550)
        self.assertEqual((total["input"], total["output"], total["cacheRead"], total["cacheWrite"]), (100, 50, 1000, 400))
        self.assertEqual((total["requests"], total["sessions"]), (1, 1))
        self.assertTrue(total["priced"])
        self.assertAlmostEqual(total["cost"], (100 * 2 + 50 * 10 + 1000 * 0.1 + 400 * 2.5) / 1_000_000)
        self.assertIn(self.now.date().isoformat(), bucket["days"])
        self.assertIn(self.now.hour, bucket["hours"])

    def test_claude_placeholders_and_prompts_are_not_requests(self):
        bucket = self._claude([
            self._claude_line(model="<synthetic>", usage={"input_tokens": 0, "output_tokens": 0}),
            self._claude_line(role="user", usage={"input_tokens": 900, "output_tokens": 0}),
            self._claude_line(usage={"input_tokens": 0, "output_tokens": 0}),
        ])
        self.assertEqual(bucket["total"]["requests"], 0)
        self.assertEqual(bucket["total"]["tokens"], 0)

    def test_claude_unknown_model_stays_unpriced(self):
        bucket = self._claude([self._claude_line(model="claude-unlisted-9")])
        self.assertEqual(bucket["total"]["tokens"], 1550)
        self.assertFalse(bucket["total"]["priced"])

    def _codex(self, lines, name="rollout-one.jsonl"):
        path = self.root / "codex" / "2026" / "10" / "25" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        with patch.object(MODULE, "CODEX_SESSIONS", self.root / "codex"):
            return MODULE.codex_ledger(self.pricing)["codex"]

    def _codex_usage(self, input_tokens=1000, cached=800, output=100, write=0, stamp=None):
        return json.dumps({"type": "token_usage_record", "timestamp": stamp or self._stamp(),
                           "payload": {"usage": {"input_tokens": input_tokens, "cached_input_tokens": cached,
                                                 "cache_write_input_tokens": write, "output_tokens": output}}})

    def _codex_model(self, model="gpt-6-astra", stamp=None):
        return json.dumps({"type": "turn_context", "timestamp": stamp or self._stamp(),
                           "payload": {"model": model}})

    def test_codex_cached_input_is_not_billed_twice(self):
        bucket = self._codex([self._codex_model(), self._codex_usage()])
        total = bucket["total"]
        self.assertEqual((total["input"], total["cacheRead"], total["output"]), (200, 800, 100))
        self.assertEqual(total["tokens"], 1100)
        self.assertEqual(total["requests"], 1)
        self.assertAlmostEqual(total["cost"], (200 * 10 + 100 * 50 + 800 * 1) / 1_000_000)
        self.assertIn("gpt-6-astra", bucket["models"])

    def test_codex_model_comes_from_the_turn_context(self):
        bucket = self._codex([self._codex_model("gpt-6.1-sol"), self._codex_usage()])
        self.assertIn("gpt-6.1-sol", bucket["models"])
        self.assertFalse(bucket["total"]["priced"])

    def test_a_codex_session_without_a_turn_context_still_counts(self):
        bucket = self._codex([self._codex_usage()])
        self.assertEqual(bucket["total"]["tokens"], 1100)
        self.assertIn("codex-unknown", bucket["models"])

    def test_native_provider_prefers_the_ledger_over_the_record(self):
        records = self.root / "agents"
        records.mkdir()
        (records / "claude.json").write_text(json.dumps({
            "tierLabel": "Pro", "recentDays": [{"date": self.now.date().isoformat(), "messageCount": 0}],
            "todayTotalTokens": 0, "modelUsage": {}, "totalPrompts": 1, "totalSessions": 1}))
        bucket = self._claude([self._claude_line()])
        with patch.object(MODULE, "AGENT_RECORDS", records):
            with patch.object(MODULE, "native_limits", return_value=([], "", "rate limited")):
                provider = MODULE.native_provider("claude", self.pricing, bucket)
        self.assertEqual(provider["total"]["tokens"], 1550)
        self.assertEqual(provider["today"]["tokens"], 1550)
        self.assertEqual(provider["status"], "ready")
