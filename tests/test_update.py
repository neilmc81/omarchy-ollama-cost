import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import update  # noqa: E402


class ParseBalanceTest(unittest.TestCase):
    def test_usd_shape(self):
        b = update.parse_balance({"included": {
            "allowance_usd": 60, "balance_usd": 58.75,
            "period": {"from": "2026-10-16T13:59:04Z", "until": "2026-11-16T13:59:04Z"},
        }})
        self.assertEqual(b["allowance"], 60.0)
        self.assertEqual(b["balance"], 58.75)
        self.assertAlmostEqual(b["used"], 1.25)
        self.assertEqual(b["period_from"], datetime(2026, 10, 16, 13, 59, 4, tzinfo=timezone.utc))
        self.assertEqual(b["period_until"], "2026-11-16T13:59:04Z")

    def test_usd_shape_without_balance(self):
        b = update.parse_balance({"included": {"allowance_usd": 60}})
        self.assertEqual(b["allowance"], 60.0)
        self.assertIsNone(b["used"])
        self.assertIsNone(b["balance"])
        self.assertIsNone(b["period_from"])
        self.assertIsNone(b["period_until"])

    def test_legacy_weekly_shape(self):
        b = update.parse_balance({"included": {
            "session": {"remaining_percent": 90, "resets_at": "2026-10-21T18:00:00Z"},
            "weekly": {"remaining_percent": 70, "resets_at": "2026-10-27T00:00:00Z"},
        }})
        self.assertEqual(b["allowance"], 100.0)
        self.assertEqual(b["balance"], 70.0)
        self.assertEqual(b["used"], 30.0)
        self.assertIsNone(b["period_from"])
        self.assertEqual(b["period_until"], "2026-10-27T00:00:00Z")

    def test_missing_or_empty(self):
        empty = {"allowance": None, "used": None, "balance": None,
                 "period_from": None, "period_until": None}
        for bal in (None, {}, [], "nope", {"included": None}, {"included": {}}):
            with self.subTest(bal=bal):
                self.assertEqual(update.parse_balance(bal), empty)


class RequestsInPeriodTest(unittest.TestCase):
    usage = {
        "totals": {"usage_usd": 3.0, "request_count": 60},
        "buckets": [
            {"from": "2026-10-14T00:00:00+00:00", "request_count": 10},
            {"from": "2026-10-15T00:00:00+00:00", "request_count": 20},
            {"from": "2026-10-16T00:00:00+00:00", "request_count": 5},
            {"from": "2026-10-17T00:00:00+00:00", "request_count": 25},
            {"from": None, "request_count": 99},
        ],
    }

    def test_only_buckets_inside_period(self):
        start = datetime(2026, 10, 16, tzinfo=timezone.utc)
        self.assertEqual(update.requests_in_period(self.usage, start), 30)

    def test_no_period_uses_totals(self):
        self.assertEqual(update.requests_in_period(self.usage, None), 60)


class LoadKeysTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        keyfile = os.path.join(self.tmp.name, "key")
        hermes = os.path.join(self.tmp.name, ".env")
        with open(keyfile, "w") as f:
            f.write("k-file\n")
        with open(hermes, "w") as f:
            f.write("# comment\nOLLAMA_API_KEY=\"k-env\"\nOTHER=x\n")
        for p in (mock.patch.object(update, "KEYFILE", keyfile),
                  mock.patch.object(update, "HERMES_ENV", hermes),
                  mock.patch.dict(os.environ, {"OLLAMA_API_KEY": "k-env"})):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("OLLAMA_KEY", None)

    def test_dedupe_keeps_first_label(self):
        keys = update.load_keys({"api_keys": ["k-a", "k-env", "k-file"], "names": ["A", "Dup"]})
        self.assertEqual(keys, [
            ("env:OLLAMA_API_KEY", "k-env"),
            ("A", "k-a"),
            ("key3", "k-file"),
        ])

    def test_no_keys(self):
        os.environ.pop("OLLAMA_API_KEY")
        os.remove(update.KEYFILE)
        os.remove(update.HERMES_ENV)
        self.assertEqual(update.load_keys({}), [])


if __name__ == "__main__":
    unittest.main()
