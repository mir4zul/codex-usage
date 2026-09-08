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


def emit(key, value):
    print(f'{key}={str(value).replace(chr(10), " ").replace(chr(13), " ")}')


def main():
    root = Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex'))) / 'sessions'
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
