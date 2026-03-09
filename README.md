# Claude Usage Tool

A compact always-on-top popup that shows real-time Claude usage stats (session and weekly limits) for multiple Claude accounts simultaneously.

---

## One-time setup

**1. Allow PowerShell scripts to run:**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**2. Run the setup wizard:**
```powershell
cd "$env:USERPROFILE\Documents\claudeusagetool"
.\setup.ps1
```

The wizard will:
- Ask how many Claude accounts you want to track (1–9)
- Launch a Chrome window for each account so you can log in
- Save your configuration to `config.json`

You only need to do this once. Chrome sessions are saved — you won't need to log in again.

---

## Every time you want to use it

```powershell
cd "$env:USERPROFILE\Documents\claudeusagetool"
.\claude-usage-popup.ps1
```

This launches a small always-on-top popup in the corner of your screen showing live usage stats for each account. It refreshes automatically every 30 seconds and has a manual Refresh button.

---

## Troubleshooting

- Chrome must be installed at `C:\Program Files\Google\Chrome\Application\chrome.exe` — if yours is elsewhere, re-run `setup.ps1` and enter the correct path when prompted
- If an account shows "Not logged in", re-run `setup.ps1` and log in again for that account
