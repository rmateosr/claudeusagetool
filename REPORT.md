# claudeusagetool — Development Report

## What this tool does

Compact always-on-top WinForms popup that shows Claude usage stats (session %, weekly %, reset time) for 3 Claude Pro accounts. Auto-refreshes every 30s. Replaces the original `claude-usage.ps1` which opened 3 full Chrome windows side-by-side.

---

## Files

| File | Purpose |
|------|---------|
| `claude-usage.ps1` | Original script — opens 3 Chrome windows. Kept for reference, do not run alongside popup. |
| `claude-usage-popup.ps1` | Active script — compact popup via Chrome DevTools Protocol. |
| `usage site html info.txt` | Saved HTML of claude.ai/settings/usage. Useless — it's a Next.js SPA, all data is client-side. |
| `README.md` | Setup instructions for the original script. |

---

## How claude-usage-popup.ps1 works

1. Checks if debug ports 9222/9223/9224 are already active — reuses if so.
2. If not: kills existing Chrome for each profile, relaunches with `--remote-debugging-port=922X`.
3. Waits 8s for pages to load, then minimizes the Chrome windows.
4. Connects via Chrome DevTools Protocol (CDP) WebSocket.
5. Calls `Runtime.evaluate` → `document.body.innerText` to extract page text.
6. Parses text with regex for `% used`, `Resets {day} at {time}`, limit/extra-usage states.
7. Displays in a dark WinForms popup (top-right corner, always on top).
8. Auto-refreshes every 30s. Kills managed Chrome instances on close.

---

## Account mapping

Chrome profiles are fixed — do not reorder `$Script:Ports`.

| Account folder | Port | Display name |
|---------------|------|-------------|
| Account1 | 9222 | claudeN-rmateosr |
| Account2 | 9223 | claudeA-raulnmateos |
| Account3 | 9224 | claudeB-rmateos.1 |

**Display order in popup** (top to bottom):
1. claudeA-raulnmateos (Account2, port 9223)
2. claudeB-rmateos.1 (Account3, port 9224)
3. claudeN-rmateosr (Account1, port 9222)

This is why there are two separate port arrays:
- `$Script:Ports = @(9222, 9223, 9224)` — used by `Start-DebugChrome`, indexed by AccountN
- `$Script:DisplayPorts = @(9223, 9224, 9222)` — used by `Invoke-Refresh`, drives display row order

**Do NOT merge or reorder `$Script:Ports`** — it would break Chrome launch and kill logic.

---

## Color coding

Based on Session % only:

| Condition | Color |
|-----------|-------|
| Session < 50% | Green |
| Session >= 50% | Orange |
| Session >= 90% | Red |
| Session = 100% or limit hit | Gray |

---

## Run

```powershell
cd "$env:USERPROFILE\Documents\claudeusagetool"
.\claude-usage-popup.ps1
```

---

## Diagnostic log

Written to `%TEMP%\claude-popup.log` (UTF-16 LE).

Read from WSL:
```bash
python3 -c "print(open('/mnt/c/Users/Raul/AppData/Local/Temp/claude-popup.log', encoding='utf-16').read())"
```

---

## CRITICAL: File encoding

PowerShell 5.1 requires UTF-8 BOM. After every WSL edit, re-save with:

```python
python3 -c "
content = open('/mnt/c/Users/Raul/Documents/claudeusagetool/claude-usage-popup.ps1', encoding='utf-8-sig').read()
with open('/mnt/c/Users/Raul/Documents/claudeusagetool/claude-usage-popup.ps1', 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(content)
"
```

All non-ASCII characters (·, —, ─) must be replaced with ASCII equivalents — PS 5.1 chokes on them silently.

---

## Bugs fixed

### Non-ASCII chars break PowerShell 5.1
Characters like `·`, `—`, `─` cause cryptic parse errors (`Unexpected token '$base'`).
**Fix:** Write from WSL with `encoding='utf-8-sig', newline='\r\n'` and replace all non-ASCII with ASCII equivalents.

### `$Var:` parsed as PowerShell drive reference
`"text $Idx: more text"` fails — PS treats `$Idx:` like `$env:` (a drive path).
**Fix:** Use `${Idx}:` to delimit the variable name.

### `wmic` not found on Windows 11
`wmic` was removed.
**Fix:** Use `Get-WmiObject Win32_Process` — supports WQL `LIKE` filters, unlike `Get-CimInstance`.

### Chrome kill via WMI LIKE filter returned 0 results
`Get-WmiObject -Filter "Name='chrome.exe' and CommandLine like '%Account1%'"` silently returned nothing.
**Fix:** Enumerate via `Get-Process -Name chrome`, then query each PID individually: `Get-WmiObject Win32_Process -Filter "ProcessId=$id"` to check CommandLine.

### `localhost` resolves to IPv6 — Chrome binds to IPv4 only
`Invoke-RestMethod "http://localhost:9222/json"` always timed out. Chrome confirmed running with debug port active.
**Root cause:** `localhost` resolves to `::1` (IPv6) on this machine; Chrome's `--remote-debugging-port` binds to `127.0.0.1` only.
**Fix:** Use `http://127.0.0.1:$port/json` everywhere. This was the final blocker.

### Accounts 2 and 3 falsely showing "Extra usage"
`$Text -match "extra usage"` matched general UI text present on all accounts ("Turn on extra usage", "Extra usage must be enabled for fast mode").
**Fix:** Use `$Text -match "You.re now using extra usage"` — the active-state string only.

---

## Parsing reference

| Data | Regex / keyword |
|------|----------------|
| Session/weekly % | `(\d+)%\s*(?:of\s+capacity)?\s+used` with surrounding context |
| Reset time | `Resets (\w+) at ([\d:]+ [AP]M)` |
| Weekly limit hit | `"You've hit your weekly limit"` |
| Extra usage active | `"You're now using extra usage"` |
| Not logged in | `Sign in\|Log in\|Create account` (and no `\d+% used`) |
