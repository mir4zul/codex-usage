import datetime
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


class ActivityTests(unittest.TestCase):
    def test_deltas_cache_and_append(self):
        import datetime
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)/'sessions'; root.mkdir()
            cache = Path(d)/'cache.json'
            path = root/'session.jsonl'
            def token(total):
                return json.dumps({'timestamp': '2026-09-08T12:00:00Z', 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': total}}}})+'\n'
            path.write_text(json.dumps({'type': 'turn_context', 'payload': {'model': 'test-model'}})+'\n'+token(100)+token(100)+token(150))
            today = datetime.date(2026, 9, 8)
            first = usage.activity(root, cache, today)
            self.assertEqual(first['today'], 150)
            self.assertEqual(first['models'], [{'name': 'test-model', 'tokens': 150}])
            self.assertEqual(usage.activity(root, cache, today), first)
            with path.open('a') as stream: stream.write(token(180))
            self.assertEqual(usage.activity(root, cache, today)['today'], 180)

    def test_empty_activity(self):
        with tempfile.TemporaryDirectory() as d:
            stats = usage.activity(Path(d))
            self.assertEqual(stats['week'], 0)
            self.assertEqual(len(stats['daily']), 7)
            self.assertEqual(stats['models'], [])


class ModernTests(unittest.TestCase):
    def test_windows_breakdown_and_cache(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'sessions';root.mkdir()
            def row(day,total,inp,out,cached):
                return json.dumps({'timestamp':day+'T12:00:00+06:00','payload':{'type':'token_count','info':{'total_token_usage':{'total_tokens':total,'input_tokens':inp,'output_tokens':out,'cached_input_tokens':cached}}}})+'\n'
            p=root/'s.jsonl'
            p.write_text(row('2026-08-09',10,8,2,4)+row('2026-08-10',30,24,6,12)+row('2026-08-26',60,48,12,24)+row('2026-09-08',160,128,32,64)+row('2026-09-08',160,128,32,64))
            cache=Path(d)/'cache.json'
            a=usage.activity(root,cache,datetime.date(2026,9,8))
            self.assertEqual(len(a['daily30']),30)
            self.assertEqual(a['daily30'][0]['date'],'2026-08-10')
            self.assertEqual(a['week'],100)
            self.assertEqual(a['previous_week'],30)
            self.assertEqual(a['month'],150)
            self.assertEqual(a['breakdown_week'],{'input_tokens':80,'output_tokens':20,'cached_input_tokens':40})
            self.assertEqual(a,usage.activity(root,cache,datetime.date(2026,9,8)))
            with p.open('a') as f:f.write(row('2026-09-08',180,144,36,72))
            self.assertEqual(usage.activity(root,cache,datetime.date(2026,9,8))['breakdown_week']['input_tokens'],96)
    def test_empty(self):
        with tempfile.TemporaryDirectory() as d:
            a=usage.activity(Path(d))
            self.assertEqual(len(a['daily30']),30)
            self.assertEqual(a['breakdown_week'],{})
            self.assertEqual(a['previous_week'],0)

if __name__ == '__main__':
    unittest.main()
