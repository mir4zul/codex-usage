import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('usage', Path(__file__).resolve().parents[1] / 'get-codex-usage.py')
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


def event(stamp, limit='codex', percent=20):
    return json.dumps({'timestamp': stamp, 'payload': {'type': 'token_count', 'rate_limits': {
        'limit_id': limit, 'primary': {'used_percent': percent, 'window_minutes': 300},
        'secondary': {'used_percent': 35, 'window_minutes': 10080}}}})


class SnapshotTests(unittest.TestCase):
    def test_empty_history(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(usage.snapshots(Path(d)))

    def test_skips_premium_and_incomplete_tail(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'session.jsonl').write_text(event('2026-09-08T01:00:00Z')+'\n'+event('2026-09-08T02:00:00Z', 'premium', 99)+'\n{"rate_limits":')
            result = usage.snapshots(root)
            self.assertEqual(result[1]['primary']['used_percent'], 20)
            self.assertEqual(result[1]['secondary']['used_percent'], 35)

    def test_newest_timestamp_across_sessions_and_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'newer.jsonl').write_text(event('2026-09-08T02:00:00Z', percent=42)+'\n'+(' ' * 140000))
            (root/'older.jsonl').write_text(event('2026-09-08T01:00:00Z', percent=10)+'\n')
            self.assertEqual(usage.snapshots(root)[1]['primary']['used_percent'], 42)


if __name__ == '__main__':
    unittest.main()
