# ABOUTME: One-time setup wizard that configures Chrome profiles per Claude account
# ABOUTME: Launches Chrome for each account login, then writes config.json next to this script

param(
    [string]$ChromePath   = "C:\Program Files\Google\Chrome\Application\chrome.exe",
    [string]$ProfilesRoot = "$env:LOCALAPPDATA\ClaudeProfiles"
)

$configPath = Join-Path $PSScriptRoot "config.json"

if (Test-Path $configPath) {
    $resp = Read-Host "config.json already exists. Reconfigure from scratch? (y/n)"
    if ($resp -notmatch '^y') {
        Write-Host "Setup cancelled."
        exit
    }
}

if (-not (Test-Path $ChromePath)) {
    $ChromePath = Read-Host "Chrome not found at '$ChromePath'. Enter full path to chrome.exe"
    if (-not (Test-Path $ChromePath)) {
        Write-Error "Chrome not found. Aborting."
        exit 1
    }
}

$count = 0
while ($count -lt 1 -or $count -gt 9) {
    $raw = Read-Host "How many Claude accounts do you want to track? (1-9)"
    if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le 9) {
        $count = [int]$raw
    } else {
        Write-Host "Please enter a number between 1 and 9."
    }
}

$accounts      = @()
$launchedPids  = [System.Collections.Generic.List[int]]::new()

for ($i = 1; $i -le $count; $i++) {
    $port   = 9221 + $i
    $folder = "Account$i"
    $dir    = "$ProfilesRoot\$folder"

    Write-Host "`n--- Account $i of $count ---"
    Write-Host "Launching Chrome. Log into your Claude account, then come back here and press Enter."

    $proc = Start-Process $ChromePath -PassThru -ArgumentList `
        "--user-data-dir=`"$dir`"",
        "--remote-debugging-port=$port",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-session-crashed-bubble",
        "--hide-crash-restore-bubble",
        "https://claude.ai"
    $launchedPids.Add($proc.Id)

    Read-Host "Press Enter when logged in"

    $name = Read-Host "Display name for this account (default: Account$i)"
    if (-not $name) { $name = "Account$i" }

    $accounts += [ordered]@{ name = $name; folder = $folder; port = $port }
}

Write-Host "`nClosing Chrome windows..."
foreach ($pid in $launchedPids) {
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
}

$config = [ordered]@{
    chromePath   = $ChromePath
    profilesRoot = $ProfilesRoot
    accounts     = $accounts
}

$config | ConvertTo-Json -Depth 3 | Out-File $configPath -Encoding utf8

Write-Host "`nSetup complete. Run claude-usage-popup.ps1 to start."
