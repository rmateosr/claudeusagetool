# Claude Usage Monitor

Tracks Claude AI usage across multiple accounts in a compact always-on-top popup.

**Requires:** Google Chrome installed on Windows.

## Quick start

1. Double-click `Claude_Usage_Monitor.bat`
2. Click **Add Account** for each Claude account you want to track
3. Log in when Chrome opens, then click OK
4. Click **Start Monitoring** — usage stats refresh every 30 seconds

## What it does

- Launches isolated Chrome profiles (one per account) to scrape usage data from `claude.ai/settings/usage`
- Displays session and weekly usage percentages in a small always-on-top window
- Color-coded status: green (low usage), orange (moderate), red (near limit)
- Auto-refreshes every 30 seconds

## Files

| File | Purpose |
|------|---------|
| `claude-usage-monitor.ps1` | The tool (auditable PowerShell source) |
| `Claude_Usage_Monitor.bat` | Double-click launcher (handles ExecutionPolicy) |

No binaries, no installers, no dependencies beyond Chrome. Read the `.ps1` to see exactly what it does.
