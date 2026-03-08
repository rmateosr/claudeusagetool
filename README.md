# Claude Usage Tool

Opens 3 Chrome windows side-by-side, each logged into a different Claude account, each pointing to the usage page.

---

## One-time setup

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then run the script and log into a different Claude account in each window. Sessions are saved — you never need to log in again.

---

## Every time you want to use it

```powershell
cd "$env:USERPROFILE\Documents\claudeusagetool"
.\claude-usage.ps1
```

---

## Troubleshooting

- If a window doesn't auto-position, just drag it manually
- Chrome must be installed at `C:\Program Files\Google\Chrome\Application\chrome.exe` — edit the script if yours is elsewhere
