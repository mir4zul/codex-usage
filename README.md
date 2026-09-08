# Codex Usage for Dank Material Shell

Your Codex limits, one glance away.

A compact DankBar widget with two progress rings: **five-hour usage on top, weekly usage below**. Click to see both limit bars, remaining percentages, reset countdowns, and the timestamp of the latest local snapshot.

![Codex Usage widget and popout](assets/screenshot.png)

## Features

- Two stacked progress rings for vertical bars; labeled percentages for horizontal bars.
- Five-hour and weekly usage shown together in the popout.
- Theme-aware colors that change as a limit fills up.
- Reset countdowns and the snapshot timestamp.
- Theme-adaptive quota cards with large progress rings.
- Local token totals for today, the last 7 days, and the last 30 days.
- A seven-day activity chart and the top four models by local token usage.
- Reads local Codex session logs every 30 seconds. No API calls or additional sign-in.
- Python standard library only.

## Requirements

- Dank Material Shell with plugin support.
- Python 3.9 or newer, available as `python3`.
- Codex CLI that records `token_count` rate-limit snapshots in its local session logs.
- A Codex session with recorded subscription quota information.

Tested on Hyprland. The widget uses DMS components; other compositors have not been tested.

## Install

```sh
git clone https://github.com/mir4zul/codex-usage.git ~/.config/DankMaterialShell/plugins/codexUsage
```

The directory name must be `codexUsage`. In DMS Settings → Plugins, enable **Codex Usage**, then add it to your DankBar widgets. Restart DMS if it does not discover the new plugin.

Registry submission is pending. Once accepted, search for **Codex Usage** in Settings → Plugins → Browse.

## Record your usage

If necessary, run `codex login` and finish the browser sign-in. Use Codex for a task so it records a quota snapshot. The widget will pick it up on its next refresh.

The top ring is the five-hour limit; the bottom ring is the weekly limit. Percentages show **used**, not remaining, quota.

## How it works and limitations

The helper reads `~/.codex/sessions/**/*.jsonl`, or `$CODEX_HOME/sessions` when `CODEX_HOME` is set in the DMS process environment. It selects the newest Codex quota snapshot and ignores separate premium-limit snapshots.

These are **last recorded values**, not a live account query. Usage from another device or an idle session will not appear until Codex records a new local snapshot. After a reset, old percentages remain until a fresh snapshot arrives. Check the “Updated” timestamp before relying on a number. Countdown text is computed locally and refreshed every minute.

Token activity is a local estimate from positive cumulative-token deltas, including cached input tokens. Repeated unchanged totals add no tokens. Days use the system timezone; 7/30-day totals are rolling calendar-day windows. Forked or copied session histories can overlap, and missing logs cannot be counted. These figures are not billing amounts or account-wide totals. Parsed per-file token aggregates are cached under `$XDG_CACHE_HOME/codexUsage` (normally `~/.cache/codexUsage`); no conversation text is cached.

This does not show general ChatGPT conversation usage. API-key sessions or Codex versions without compatible quota logs may show “No usage recorded”. The local log format can change between Codex versions.

The helper does not read authentication files, refresh tokens, contact a server, or upload session content. Each installation reads its own user's local logs.

## Troubleshooting

Run the helper directly:

```sh
python3 ~/.config/DankMaterialShell/plugins/codexUsage/get-codex-usage.py
```

`LOGGED_IN=false` means no compatible local quota snapshot was found; it is not a check of your current authentication status. Use Codex and check the log location. If DMS was started before setting `CODEX_HOME`, update its environment and restart it.

## Development

```sh
python3 -m unittest discover -s tests -v
```

The screenshot shows the real widget on Hyprland. Its usage values are an example snapshot, not values bundled into the plugin.

## Credits and license

MIT licensed. Adapted from Feiko Wielsma's Antigravity Usage plugin, itself based on Nicolas Bellamy's [Claude Code Usage plugin](https://github.com/titeya/dms-claudecode). Original copyright notices are preserved in [LICENSE](LICENSE).

Community plugin; not affiliated with or endorsed by OpenAI or the DMS maintainers.
