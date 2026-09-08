#!/usr/bin/env python3
"""Read quota snapshots only; never read credentials or contact a service."""
import datetime
import json
import os
from pathlib import Path


def snapshots(root):
    files = sorted(root.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)
    newest = None
    for path in files:
        if newest and path.stat().st_mtime < newest[0].timestamp():
            continue
        try:
            with path.open('rb') as stream:
                stream.seek(0, 2)
                size = stream.tell()
                pos = size
                pending = b''
                found = False
                while pos > 0 and not found:
                    start = max(0, pos - 65536)
                    stream.seek(start)
                    parts = (stream.read(pos-start) + pending).split(b'\n')
                    pending = parts[0]
                    lines = parts[1:]
                    if start == 0:
                        lines.insert(0, pending)
                    for line in reversed(lines):
                        if b'"rate_limits"' not in line:
                            continue
                        try:
                            row = json.loads(line)
                            payload = row.get('payload', {})
                            limits = payload.get('rate_limits') or {}
                            if payload.get('type') != 'token_count' or limits.get('limit_id') not in (None, 'codex'):
                                continue
                            if not (limits.get('primary') or limits.get('secondary')):
                                continue
                            stamp = datetime.datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00'))
                            if newest is None or stamp > newest[0]:
                                newest = (stamp, limits)
                            found = True
                            break
                        except (ValueError, KeyError, TypeError):
                            continue
                    pos = start
        except OSError:
            continue
    return newest


def activity(root, cache_path=None, today=None):
    """Aggregate positive cumulative-token deltas; repeated quota events add zero."""
    today = today or datetime.datetime.now().astimezone().date()
    cutoff = (today - datetime.timedelta(days=29)).isoformat()
    try:
        cache = json.loads(cache_path.read_text()) if cache_path else {}
    except (OSError, ValueError):
        cache = {}
    updated = {}
    days = {}
    models = {}
    sessions = set()
    week_start = (today - datetime.timedelta(days=6)).isoformat()
    for path in root.rglob('*.jsonl'):
        try:
            stat = path.stat()
            key = str(path)
            signature = [stat.st_size, stat.st_mtime_ns]
            saved = cache.get(key, {})
            if saved.get('signature') != signature:
                entries = {}
                previous = 0
                model = 'Unknown'
                with path.open() as stream:
                    for line in stream:
                        try:
                            row = json.loads(line)
                            payload = row.get('payload', {})
                            if row.get('type') == 'turn_context':
                                model = payload.get('model') or model
                            if payload.get('type') != 'token_count':
                                continue
                            info = payload.get('info') or {}
                            total = (info.get('total_token_usage') or {}).get('total_tokens')
                            if not isinstance(total, (int, float)) or total < 0:
                                continue
                            delta = max(0, total - previous)
                            previous = total
                            day = datetime.datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00')).astimezone().date().isoformat()
                            if day < cutoff or not delta:
                                continue
                            entry = day + '|' + model
                            entries[entry] = entries.get(entry, 0) + delta
                        except (ValueError, KeyError, TypeError, AttributeError):
                            continue
                saved = {'signature': signature, 'entries': entries}
            updated[key] = saved
            for entry, count in saved.get('entries', {}).items():
                day, model = entry.split('|', 1)
                if cutoff <= day <= today.isoformat():
                    days[day] = days.get(day, 0) + count
                    if day >= week_start:
                        models[model] = models.get(model, 0) + count
                        sessions.add(key)
        except OSError:
            continue
    if cache_path:
        try:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            temp = cache_path.with_suffix('.tmp')
            temp.write_text(json.dumps(updated))
            temp.replace(cache_path)
        except OSError:
            pass
    daily = []
    for offset in range(6, -1, -1):
        day = today - datetime.timedelta(days=offset)
        daily.append({'day': day.strftime('%a'), 'tokens': days.get(day.isoformat(), 0)})
    return {'today': days.get(today.isoformat(), 0), 'week': sum(d['tokens'] for d in daily),
            'month': sum(days.values()), 'daily': daily, 'sessions': len(sessions),
            'models': [{'name': name, 'tokens': count} for name, count in sorted(models.items(), key=lambda v: v[1], reverse=True)[:4]]}


def emit(key, value):
    print(f'{key}={str(value).replace(chr(10), " ").replace(chr(13), " ")}')


def main():
    root = Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex'))) / 'sessions'
    cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home()/'.cache'))) / 'codexUsage/activity-v1.json'
    emit('STATS', json.dumps(activity(root, cache), separators=(',', ':')))
    snapshot = snapshots(root)
    emit('GROUPS', '')
    emit('LOGGED_IN', 'false')
    if not snapshot:
        return
    stamp, limits = snapshot
    buckets = [(key, limits.get(key)) for key in ('primary', 'secondary') if limits.get(key)]
    emit('GROUPS', ','.join(key for key, _ in buckets))
    emit('LOGGED_IN', 'true')
    emit('PLAN', str(limits.get('plan_type') or 'Codex').title())
    emit('UPDATED_AT', stamp.isoformat())
    for key, value in buckets:
        prefix = f'BUCKET_{key}_'
        minutes = value.get('window_minutes')
        label = {300: 'Five Hour Limit', 10080: 'Weekly Limit'}.get(minutes, f'{minutes} minute limit' if minutes else key.title())
        emit(prefix+'GROUP', 'Codex')
        emit(prefix+'GROUP_DESC', 'Last recorded usage · refreshes every 30 seconds')
        emit(prefix+'LABEL', label)
        emit(prefix+'REMAINING', 1-max(0,min(100,float(value['used_percent'])))/100)
        reset = value.get('resets_at')
        emit(prefix+'RESET', datetime.datetime.fromtimestamp(reset, datetime.timezone.utc).isoformat() if reset else '')

if __name__ == '__main__':
    main()
