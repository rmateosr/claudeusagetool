# Claude Usage Monitor

If you juggle multiple Claude accounts, you've probably lost track of how much usage you have left on each one. This little Windows tool sits in the corner of your screen and tells you at a glance.

It's just a PowerShell script — no installers, no binaries, nothing phoning home. You can read every line of `claude-usage-monitor.ps1` yourself.

## Getting started

You'll need Google Chrome installed. That's the only dependency.

1. Double-click `Claude_Usage_Monitor.bat`
2. Hit **Add Account** for each Claude account you want to track
3. A Chrome window opens — log in, then click OK
4. Hit **Start Monitoring**

That's it. A small always-on-top window shows your usage, color-coded green/orange/red so you can tell at a glance if you're running low. It refreshes every 30 seconds.

Want to add or remove accounts later? Click **Settings** in the monitor window.

## How it works

Behind the scenes, it opens isolated Chrome profiles (one per account) and reads the usage data from your Claude settings page. Nothing clever, nothing fragile — just browser automation with PowerShell.

## Files

- **`claude-usage-monitor.ps1`** — the actual tool, fully auditable
- **`Claude_Usage_Monitor.bat`** — double-click launcher that handles PowerShell's ExecutionPolicy so you don't have to
