# ABOUTME: Unified Claude usage monitor — launcher for account management + always-on-top usage popup
# ABOUTME: Manages Chrome profiles via DevTools Protocol to scrape usage data from claude.ai

param(
    [int]$RefreshSeconds = 30,
    [string]$Url         = "https://claude.ai/settings/usage"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinApi {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);
    public static void Minimize(uint pid) {
        EnumWindows(delegate(IntPtr hWnd, IntPtr lp) {
            uint w; GetWindowThreadProcessId(hWnd, out w);
            if (w == pid && IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                ShowWindow(hWnd, 6); return false;
            }
            return true;
        }, IntPtr.Zero);
    }
}
"@

# ------------ Shared state ------------

$Script:ConfigPath    = Join-Path $PSScriptRoot "config.json"
$Script:DefaultChrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$Script:ProfilesRoot  = "$env:LOCALAPPDATA\ClaudeProfiles"
$Script:LogFile       = "$env:TEMP\claude-monitor.log"
$Script:ChromePath    = $Script:DefaultChrome
$Script:Accounts      = @()
$Script:OwnedProcs    = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$Script:Settings      = $null
$Script:Theme         = $null

"" | Out-File $Script:LogFile

# ------------ Theme infrastructure ------------

$Script:DefaultSettings = @{
    mode           = "dark"
    colorPreset    = "default"
    refreshSeconds = 30
    customColors   = @{
        low       = "#32CD32"
        mid       = "#FFA500"
        high      = "#FF4500"
        exhausted = "#808080"
    }
}

$Script:ColorPresets = @{
    default = @{
        low       = [Drawing.Color]::LimeGreen
        mid       = [Drawing.Color]::Orange
        high      = [Drawing.Color]::OrangeRed
        exhausted = [Drawing.Color]::Gray
    }
    colorblind = @{
        low       = [Drawing.Color]::DodgerBlue
        mid       = [Drawing.Color]::Gold
        high      = [Drawing.Color]::DarkOrange
        exhausted = [Drawing.Color]::Gray
    }
}

function Color-FromHex {
    param([string]$Hex)
    $Hex = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($Hex.Substring(0,2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2,2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4,2), 16)
    return [Drawing.Color]::FromArgb($r, $g, $b)
}

function Color-ToHex {
    param([Drawing.Color]$Color)
    return "#{0:X2}{1:X2}{2:X2}" -f $Color.R, $Color.G, $Color.B
}

function Copy-DefaultSettings {
    $d = $Script:DefaultSettings
    return @{
        mode           = $d.mode
        colorPreset    = $d.colorPreset
        refreshSeconds = $d.refreshSeconds
        customColors   = @{
            low       = $d.customColors.low
            mid       = $d.customColors.mid
            high      = $d.customColors.high
            exhausted = $d.customColors.exhausted
        }
    }
}

function Build-Theme {
    param([hashtable]$Settings)
    if ($Settings.mode -eq "light") {
        $chrome = @{
            FormBg        = [Drawing.Color]::FromArgb(240, 240, 240)
            PanelBg       = [Drawing.Color]::White
            ButtonBg      = [Drawing.Color]::FromArgb(220, 220, 220)
            InputBg       = [Drawing.Color]::White
            SeparatorBg   = [Drawing.Color]::FromArgb(200, 200, 200)
            TextPrimary   = [Drawing.Color]::FromArgb(20, 20, 20)
            TextSecondary = [Drawing.Color]::FromArgb(80, 80, 80)
            TextDim       = [Drawing.Color]::FromArgb(140, 140, 140)
            TextMuted     = [Drawing.Color]::FromArgb(160, 160, 160)
            StartButtonBg = [Drawing.Color]::FromArgb(0, 140, 90)
            StartButtonFg = [Drawing.Color]::White
        }
    } else {
        $chrome = @{
            FormBg        = [Drawing.Color]::FromArgb(22, 22, 22)
            PanelBg       = [Drawing.Color]::FromArgb(36, 36, 36)
            ButtonBg      = [Drawing.Color]::FromArgb(48, 48, 48)
            InputBg       = [Drawing.Color]::FromArgb(48, 48, 48)
            SeparatorBg   = [Drawing.Color]::FromArgb(42, 42, 42)
            TextPrimary   = [Drawing.Color]::White
            TextSecondary = [Drawing.Color]::Silver
            TextDim       = [Drawing.Color]::DimGray
            TextMuted     = [Drawing.Color]::FromArgb(100, 100, 100)
            StartButtonBg = [Drawing.Color]::FromArgb(0, 120, 80)
            StartButtonFg = [Drawing.Color]::White
        }
    }

    $preset = $Settings.colorPreset
    if ($preset -eq "custom") {
        $cc = $Settings.customColors
        $usage = @{
            low       = Color-FromHex $cc.low
            mid       = Color-FromHex $cc.mid
            high      = Color-FromHex $cc.high
            exhausted = Color-FromHex $cc.exhausted
        }
    } elseif ($Script:ColorPresets.ContainsKey($preset)) {
        $usage = $Script:ColorPresets[$preset]
    } else {
        $usage = $Script:ColorPresets['default']
    }

    $theme = @{}
    foreach ($k in $chrome.Keys) { $theme[$k] = $chrome[$k] }
    $theme['UsageLow']     = $usage.low
    $theme['UsageMid']     = $usage.mid
    $theme['UsageHigh']    = $usage.high
    $theme['UsageExhaust'] = $usage.exhausted
    return $theme
}

function Apply-Settings {
    $Script:Theme = Build-Theme -Settings $Script:Settings
}

# ------------ Logging ------------

function Write-Log {
    param([string]$Msg)
    "$(Get-Date -Format 'HH:mm:ss')  $Msg" | Out-File $Script:LogFile -Append
}

# ------------ Config management ------------

function Load-Config {
    if (Test-Path $Script:ConfigPath) {
        $raw = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
        $Script:ChromePath   = $raw.chromePath
        $Script:ProfilesRoot = $raw.profilesRoot
        $Script:Accounts     = @($raw.accounts)
        if ($raw.settings) {
            $s = $raw.settings
            $Script:Settings = @{
                mode           = if ($s.mode) { $s.mode } else { "dark" }
                colorPreset    = if ($s.colorPreset) { $s.colorPreset } else { "default" }
                refreshSeconds = if ($s.refreshSeconds) { [int]$s.refreshSeconds } else { 30 }
                customColors   = @{
                    low       = if ($s.customColors -and $s.customColors.low) { $s.customColors.low } else { "#32CD32" }
                    mid       = if ($s.customColors -and $s.customColors.mid) { $s.customColors.mid } else { "#FFA500" }
                    high      = if ($s.customColors -and $s.customColors.high) { $s.customColors.high } else { "#FF4500" }
                    exhausted = if ($s.customColors -and $s.customColors.exhausted) { $s.customColors.exhausted } else { "#808080" }
                }
            }
        } else {
            $Script:Settings = Copy-DefaultSettings
        }
    } else {
        $Script:ChromePath   = $Script:DefaultChrome
        $Script:ProfilesRoot = "$env:LOCALAPPDATA\ClaudeProfiles"
        $Script:Accounts     = @()
        $Script:Settings     = Copy-DefaultSettings
    }
    Apply-Settings
}

function Save-Config {
    $cfg = [ordered]@{
        chromePath   = $Script:ChromePath
        profilesRoot = $Script:ProfilesRoot
        accounts     = @($Script:Accounts)
        settings     = [ordered]@{
            mode           = $Script:Settings.mode
            colorPreset    = $Script:Settings.colorPreset
            refreshSeconds = $Script:Settings.refreshSeconds
            customColors   = [ordered]@{
                low       = $Script:Settings.customColors.low
                mid       = $Script:Settings.customColors.mid
                high      = $Script:Settings.customColors.high
                exhausted = $Script:Settings.customColors.exhausted
            }
        }
    }
    $cfg | ConvertTo-Json -Depth 5 | Out-File $Script:ConfigPath -Encoding utf8
}

function Get-NextPort {
    if ($Script:Accounts.Count -eq 0) { return 9222 }
    $maxPort = ($Script:Accounts | ForEach-Object { $_.port } | Measure-Object -Maximum).Maximum
    return [int]$maxPort + 1
}

function Get-NextFolder {
    $existing = @($Script:Accounts | ForEach-Object { $_.folder })
    $n = 1
    while ($existing -contains "Account$n") { $n++ }
    return "Account$n"
}

# ------------ Chrome management ------------

function Kill-ChromeForProfile {
    param([string]$Folder)
    $killed = 0
    $chromeProcs = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    Write-Log "Kill scan: $($chromeProcs.Count) chrome.exe processes running"
    foreach ($p in $chromeProcs) {
        try {
            $wmi = Get-WmiObject Win32_Process -Filter "ProcessId=$($p.Id)"
            $cmd = $wmi.CommandLine
            $short = if ($cmd) { $cmd.Substring(0, [Math]::Min(200, $cmd.Length)) } else { 'NULL' }
            Write-Log "  PID $($p.Id) title='$($p.MainWindowTitle)' cmd=$short"
            if ($cmd -and $cmd -like "*$Folder*") {
                Write-Log "  -> killing PID $($p.Id)"
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                $killed++
            }
        } catch { Write-Log "  PID $($p.Id) query error: $_" }
    }
    Write-Log "Kill scan done: killed $killed process(es) for $Folder"
    return $killed
}

function Start-DebugChrome {
    param([PSCustomObject]$Account)
    $port = $Account.port
    $dir  = "$Script:ProfilesRoot\$($Account.folder)"

    try {
        Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 1 -ErrorAction Stop | Out-Null
        Write-Log "$($Account.folder): debug port $port already active - reusing"
        return
    } catch {
        Write-Log "$($Account.folder): port $port not active, will kill and relaunch"
    }

    Kill-ChromeForProfile -Folder $Account.folder | Out-Null
    Start-Sleep -Milliseconds 1000

    $proc = Start-Process $Script:ChromePath -PassThru -ArgumentList `
        "--user-data-dir=`"$dir`"",
        "--remote-debugging-port=$port",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-session-crashed-bubble",
        "--hide-crash-restore-bubble",
        $Url
    Write-Log "$($Account.folder): launched Chrome PID $($proc.Id) on debug port $port"
    $Script:OwnedProcs.Add($proc)
}

# ------------ CDP helpers ------------

function Get-UsagePage {
    param([int]$Port)
    try {
        $list = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2 -ErrorAction Stop
        Write-Log "Port ${Port}: found $($list.Count) targets: $(($list | Select-Object -ExpandProperty url) -join ' | ')"
        $pg = ($list | Where-Object { $_.type -eq "page" -and $_.url -like "*settings/usage*" })[0]
        if ($pg) { return $pg }
        $pg = ($list | Where-Object { $_.type -eq "page" })[0]
        if (-not $pg) { Write-Log "Port ${Port}: no page-type target found"; return $null }
        Write-Log "Port ${Port}: navigating '$($pg.url)' to usage URL"
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new(4000)
        try {
            $ws.ConnectAsync([Uri]$pg.webSocketDebuggerUrl, $cts.Token).Wait()
            $nav   = "{`"id`":1,`"method`":`"Page.navigate`",`"params`":{`"url`":`"$Url`"}}"
            $bytes = [Text.Encoding]::UTF8.GetBytes($nav)
            $ws.SendAsync([ArraySegment[byte]]$bytes, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
            $buf = [byte[]]::new(4096)
            $ws.ReceiveAsync([ArraySegment[byte]]$buf, $cts.Token).GetAwaiter().GetResult() | Out-Null
        } finally {
            try { $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [Threading.CancellationToken]::None).Wait(500) | Out-Null } catch {}
            $ws.Dispose(); $cts.Dispose()
        }
        return $pg
    } catch {
        Write-Log "Port ${Port}: HTTP request failed - $_"
        return $null
    }
}

function Click-RefreshButton {
    param([string]$WsUrl)
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new(5000)
    try {
        $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).Wait()
        $js    = "var b = document.querySelector('button[aria-label=""Refresh usage limits""]'); if (b) { b.click(); 'clicked' } else { 'not found' }"
        $req   = "{`"id`":1,`"method`":`"Runtime.evaluate`",`"params`":{`"expression`":`"$($js -replace '"','\"')`"}}"
        $bytes = [Text.Encoding]::UTF8.GetBytes($req)
        $ws.SendAsync([ArraySegment[byte]]$bytes, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
        $buf  = [byte[]]::new(4096)
        $recv = $ws.ReceiveAsync([ArraySegment[byte]]$buf, $cts.Token).GetAwaiter().GetResult()
        $resp = [Text.Encoding]::UTF8.GetString($buf, 0, $recv.Count)
        Write-Log "Click-RefreshButton response: $resp"
    } catch { Write-Log "Click-RefreshButton failed: $_" }
    finally {
        try { $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [Threading.CancellationToken]::None).Wait(1000) | Out-Null } catch {}
        $ws.Dispose(); $cts.Dispose()
    }
}

function Read-PageText {
    param([string]$WsUrl)
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new(7000)
    try {
        $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).Wait()
        $req   = '{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.body.innerText","returnByValue":true}}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($req)
        $ws.SendAsync([ArraySegment[byte]]$bytes, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
        $buf  = [byte[]]::new(131072)
        $recv = $ws.ReceiveAsync([ArraySegment[byte]]$buf, $cts.Token).GetAwaiter().GetResult()
        return ([Text.Encoding]::UTF8.GetString($buf, 0, $recv.Count) | ConvertFrom-Json).result.result.value
    } catch { return $null }
    finally {
        try { $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [Threading.CancellationToken]::None).Wait(1000) | Out-Null } catch {}
        $ws.Dispose(); $cts.Dispose()
    }
}

# ------------ Data parsing ------------

function Parse-AccountInfo {
    param([string]$Text, [string]$Name)

    $T    = $Script:Theme
    $base = $Name

    if (-not $Text) {
        return @{ Header = "$base"; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = $T.TextDim }
    }

    if ($Text -match '(Sign in|Log in|Create account)' -and $Text -notmatch '\d+% used') {
        return @{ Header = "$base  -  Not logged in"; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = $T.UsageHigh }
    }

    if ($Text -notmatch '\d+%') {
        return @{ Header = "$base  -  Loading..."; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = $T.UsageExhaust }
    }

    $session = ""
    $weekly  = ""
    $allMatches = [regex]::Matches($Text, '(?si)(.{0,60})(\d+)%(?:\s+of\s+capacity)?\s+used')
    foreach ($m in $allMatches) {
        $ctx = $m.Groups[1].Value
        $pct = "$($m.Groups[2].Value)%"
        if ($ctx -match 'session|capacity|context|current') {
            if (-not $session) { $session = $pct }
        } else {
            if (-not $weekly) { $weekly = $pct }
        }
    }
    if ($weekly -and -not $session) { <# already set #> }
    elseif (-not $weekly -and $session) { $weekly = $session; $session = "" }
    elseif (-not $weekly -and -not $session) {
        if ($Text -match '(\d+)%') { $weekly = "$($Matches[1])%" }
    }

    $sessionReset = ""
    $weeklyReset  = ""
    $weeklyPos  = -1
    $sessionPos = -1
    $wm = [regex]::Match($Text, '(?i)weekly\s+(limit|usage)')
    if ($wm.Success) { $weeklyPos = $wm.Index }
    $sm = [regex]::Match($Text, '(?i)session\s+(limit|usage|capacity)')
    if ($sm.Success) { $sessionPos = $sm.Index }
    $allResetMatches = [regex]::Matches($Text, 'Resets\s+(in\s+[\d\w\s]+(?:hr|min)[^\n\r]*|(?!in\b)[^\n\r]+)')
    foreach ($rm in $allResetMatches) {
        $resetText = "Resets $($rm.Groups[1].Value.Trim())"
        $pos = $rm.Index
        if ($weeklyPos -ge 0 -and $pos -gt $weeklyPos -and ($sessionPos -lt 0 -or $weeklyPos -gt $sessionPos -or $pos -lt $sessionPos)) {
            if (-not $weeklyReset) { $weeklyReset = $resetText }
        } elseif ($sessionPos -ge 0 -and $pos -gt $sessionPos -and ($weeklyPos -lt 0 -or $sessionPos -gt $weeklyPos -or $pos -lt $weeklyPos)) {
            if (-not $sessionReset) { $sessionReset = $resetText }
        } else {
            if (-not $sessionReset) { $sessionReset = $resetText }
            elseif (-not $weeklyReset) { $weeklyReset = $resetText }
        }
    }

    $color  = $T.UsageLow
    $status = ""
    if ($Text -match "You.ve hit your weekly limit") {
        $status = "Limit reached"
        $color  = $T.UsageHigh
    } elseif ($Text -match "You.re now using extra usage") {
        $status = "Extra usage"
        $color  = $T.UsageMid
    } elseif ($session -or $weekly) {
        $p = if ($session) { [int]($session -replace '%', '') } else { 0 }
        $color = if ($p -eq 100)   { $T.UsageExhaust }
                 elseif ($p -ge 90) { $T.UsageHigh }
                 elseif ($p -ge 50) { $T.UsageMid }
                 else               { $T.UsageLow }
    }

    $header = if ($status) { "$base  -  $status" } else { $base }
    return @{ Header = $header; Session = $session; Weekly = $weekly; SessionReset = $sessionReset; WeeklyReset = $weeklyReset; Color = $color }
}

# ------------ Input dialog helper ------------

function Show-InputDialog {
    param(
        [string]$Title,
        [string]$Prompt,
        [string]$Default = ""
    )
    $T = $Script:Theme
    $dlg = [Windows.Forms.Form]@{
        Text            = $Title
        FormBorderStyle = 'FixedDialog'
        MaximizeBox     = $false
        MinimizeBox     = $false
        StartPosition   = 'CenterScreen'
        BackColor       = $T.FormBg
        ForeColor       = $T.TextPrimary
        ClientSize      = [Drawing.Size]::new(350, 130)
    }
    $lbl = [Windows.Forms.Label]@{
        Text     = $Prompt
        Location = [Drawing.Point]::new(12, 12)
        Size     = [Drawing.Size]::new(326, 20)
        Font     = [Drawing.Font]::new("Segoe UI", 9)
    }
    $txt = [Windows.Forms.TextBox]@{
        Text      = $Default
        Location  = [Drawing.Point]::new(12, 38)
        Size      = [Drawing.Size]::new(326, 24)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        BackColor = $T.InputBg
        ForeColor = $T.TextPrimary
    }
    $btnOk = [Windows.Forms.Button]@{
        Text         = "OK"
        DialogResult = [Windows.Forms.DialogResult]::OK
        Location     = [Drawing.Point]::new(178, 90)
        Size         = [Drawing.Size]::new(75, 28)
        FlatStyle    = 'Flat'
        BackColor    = $T.ButtonBg
        ForeColor    = $T.TextPrimary
    }
    $btnCancel = [Windows.Forms.Button]@{
        Text         = "Cancel"
        DialogResult = [Windows.Forms.DialogResult]::Cancel
        Location     = [Drawing.Point]::new(263, 90)
        Size         = [Drawing.Size]::new(75, 28)
        FlatStyle    = 'Flat'
        BackColor    = $T.ButtonBg
        ForeColor    = $T.TextPrimary
    }
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    foreach ($c in @($lbl, $txt, $btnOk, $btnCancel)) { $dlg.Controls.Add($c) }

    $result = $dlg.ShowDialog()
    $value  = $txt.Text
    $dlg.Dispose()

    if ($result -eq [Windows.Forms.DialogResult]::OK -and $value) { return $value }
    return $null
}

# ------------ Settings dialog ------------

function Show-Settings {
    # Returns $true if settings were changed, $false otherwise
    $T = $Script:Theme

    $dlg = [Windows.Forms.Form]@{
        Text            = "Settings"
        FormBorderStyle = 'FixedDialog'
        MaximizeBox     = $false
        MinimizeBox     = $false
        StartPosition   = 'CenterScreen'
        BackColor       = $T.FormBg
        ForeColor       = $T.TextPrimary
        ClientSize      = [Drawing.Size]::new(320, 420)
    }

    # --- Mode section ---
    $y = 14
    $lblMode = [Windows.Forms.Label]@{
        Text     = "Mode"
        Location = [Drawing.Point]::new(12, $y)
        Size     = [Drawing.Size]::new(296, 20)
        Font     = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    }
    $y += 24

    $modePanel = [Windows.Forms.Panel]@{
        Location  = [Drawing.Point]::new(12, $y)
        Size      = [Drawing.Size]::new(296, 26)
        BackColor = $T.FormBg
    }
    $rbDark = [Windows.Forms.RadioButton]@{
        Text      = "Dark"
        Location  = [Drawing.Point]::new(8, 2)
        Size      = [Drawing.Size]::new(80, 22)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextPrimary
        Checked   = ($Script:Settings.mode -eq "dark")
    }
    $rbLight = [Windows.Forms.RadioButton]@{
        Text      = "Light"
        Location  = [Drawing.Point]::new(100, 2)
        Size      = [Drawing.Size]::new(80, 22)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextPrimary
        Checked   = ($Script:Settings.mode -eq "light")
    }
    $modePanel.Controls.Add($rbDark)
    $modePanel.Controls.Add($rbLight)
    $y += 36

    # --- Refresh Interval section ---
    $lblRefresh = [Windows.Forms.Label]@{
        Text     = "Refresh Interval"
        Location = [Drawing.Point]::new(12, $y)
        Size     = [Drawing.Size]::new(296, 20)
        Font     = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    }
    $y += 24

    $txtRefresh = [Windows.Forms.TextBox]@{
        Text      = "$($Script:Settings.refreshSeconds)"
        Location  = [Drawing.Point]::new(20, $y)
        Size      = [Drawing.Size]::new(60, 24)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        BackColor = $T.InputBg
        ForeColor = $T.TextPrimary
    }
    $lblRefreshUnit = [Windows.Forms.Label]@{
        Text      = "seconds  (minimum: 10)"
        Location  = [Drawing.Point]::new(86, $y + 3)
        Size      = [Drawing.Size]::new(220, 20)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextSecondary
    }
    $y += 36

    # --- Color Preset section ---
    $lblPreset = [Windows.Forms.Label]@{
        Text     = "Color Preset"
        Location = [Drawing.Point]::new(12, $y)
        Size     = [Drawing.Size]::new(296, 20)
        Font     = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    }
    $y += 24

    $presetPanel = [Windows.Forms.Panel]@{
        Location  = [Drawing.Point]::new(12, $y)
        Size      = [Drawing.Size]::new(296, 52)
        BackColor = $T.FormBg
    }
    $rbDefault = [Windows.Forms.RadioButton]@{
        Text      = "Default"
        Location  = [Drawing.Point]::new(8, 2)
        Size      = [Drawing.Size]::new(90, 22)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextPrimary
        Checked   = ($Script:Settings.colorPreset -eq "default")
    }
    $rbColorblind = [Windows.Forms.RadioButton]@{
        Text      = "Colorblind-safe"
        Location  = [Drawing.Point]::new(100, 2)
        Size      = [Drawing.Size]::new(140, 22)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextPrimary
        Checked   = ($Script:Settings.colorPreset -eq "colorblind")
    }
    $rbCustom = [Windows.Forms.RadioButton]@{
        Text      = "Custom"
        Location  = [Drawing.Point]::new(8, 28)
        Size      = [Drawing.Size]::new(90, 22)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextPrimary
        Checked   = ($Script:Settings.colorPreset -eq "custom")
    }
    $presetPanel.Controls.Add($rbDefault)
    $presetPanel.Controls.Add($rbColorblind)
    $presetPanel.Controls.Add($rbCustom)
    $y += 62

    # --- Custom Colors section ---
    $lblCustom = [Windows.Forms.Label]@{
        Text      = "Custom Colors"
        Location  = [Drawing.Point]::new(12, $y)
        Size      = [Drawing.Size]::new(296, 20)
        Font      = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
        ForeColor = if ($rbCustom.Checked) { $T.TextPrimary } else { $T.TextDim }
    }
    $y += 24

    $colorEntries = @(
        @{ key = "low";       label = "Low usage (<50%)" }
        @{ key = "mid";       label = "Mid usage (50-89%)" }
        @{ key = "high";      label = "High usage (>=90%)" }
        @{ key = "exhausted"; label = "Exhausted (100%)" }
    )

    $colorButtons = @{}
    $colorLabels  = @{}
    foreach ($entry in $colorEntries) {
        $initColor = Color-FromHex $Script:Settings.customColors[$entry.key]
        $btn = [Windows.Forms.Button]@{
            Size      = [Drawing.Size]::new(28, 22)
            Location  = [Drawing.Point]::new(20, $y)
            FlatStyle = 'Flat'
            BackColor = $initColor
            Text      = ""
            Enabled   = $rbCustom.Checked
        }
        $btn.FlatAppearance.BorderColor = $T.TextSecondary
        $btn.FlatAppearance.BorderSize  = 1

        $lbl = [Windows.Forms.Label]@{
            Text      = $entry.label
            Location  = [Drawing.Point]::new(56, $y + 3)
            Size      = [Drawing.Size]::new(240, 20)
            Font      = [Drawing.Font]::new("Segoe UI", 9)
            ForeColor = if ($rbCustom.Checked) { $T.TextPrimary } else { $T.TextDim }
        }

        $btn.Add_Click({
            param($sender, $e)
            $cd = [Windows.Forms.ColorDialog]@{ Color = $sender.BackColor; FullOpen = $true }
            if ($cd.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $sender.BackColor = $cd.Color
            }
            $cd.Dispose()
        })

        $colorButtons[$entry.key] = $btn
        $colorLabels[$entry.key]  = $lbl
        $dlg.Controls.Add($btn)
        $dlg.Controls.Add($lbl)
        $y += 28
    }

    # Enable/disable custom color controls when preset changes
    $updateCustomState = {
        $isCustom = $rbCustom.Checked
        $lblCustom.ForeColor = if ($isCustom) { $T.TextPrimary } else { $T.TextDim }
        foreach ($k in @("low", "mid", "high", "exhausted")) {
            $colorButtons[$k].Enabled   = $isCustom
            $colorLabels[$k].ForeColor  = if ($isCustom) { $T.TextPrimary } else { $T.TextDim }
        }
    }
    $rbDefault.Add_CheckedChanged($updateCustomState)
    $rbColorblind.Add_CheckedChanged($updateCustomState)
    $rbCustom.Add_CheckedChanged($updateCustomState)

    $y += 12

    # --- Bottom buttons ---
    $btnRestore = [Windows.Forms.Button]@{
        Text      = "Restore Defaults"
        Location  = [Drawing.Point]::new(12, $y)
        Size      = [Drawing.Size]::new(120, 28)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextPrimary
        Font      = [Drawing.Font]::new("Segoe UI", 9)
    }
    $btnOK = [Windows.Forms.Button]@{
        Text         = "OK"
        DialogResult = [Windows.Forms.DialogResult]::OK
        Location     = [Drawing.Point]::new(163, $y)
        Size         = [Drawing.Size]::new(70, 28)
        FlatStyle    = 'Flat'
        BackColor    = $T.ButtonBg
        ForeColor    = $T.TextPrimary
        Font         = [Drawing.Font]::new("Segoe UI", 9)
    }
    $btnCancel = [Windows.Forms.Button]@{
        Text         = "Cancel"
        DialogResult = [Windows.Forms.DialogResult]::Cancel
        Location     = [Drawing.Point]::new(240, $y)
        Size         = [Drawing.Size]::new(70, 28)
        FlatStyle    = 'Flat'
        BackColor    = $T.ButtonBg
        ForeColor    = $T.TextPrimary
        Font         = [Drawing.Font]::new("Segoe UI", 9)
    }

    $btnRestore.Add_Click({
        $rbDark.Checked    = $true
        $rbDefault.Checked = $true
        $txtRefresh.Text   = "30"
        $def = $Script:DefaultSettings
        $colorButtons['low'].BackColor       = Color-FromHex $def.customColors.low
        $colorButtons['mid'].BackColor       = Color-FromHex $def.customColors.mid
        $colorButtons['high'].BackColor      = Color-FromHex $def.customColors.high
        $colorButtons['exhausted'].BackColor = Color-FromHex $def.customColors.exhausted
    })

    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancel
    foreach ($c in @($lblMode, $modePanel, $lblRefresh, $txtRefresh, $lblRefreshUnit, $lblPreset, $presetPanel, $lblCustom, $btnRestore, $btnOK, $btnCancel)) {
        $dlg.Controls.Add($c)
    }

    $result = $dlg.ShowDialog()

    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        $mode   = if ($rbLight.Checked) { "light" } else { "dark" }
        $preset = if ($rbColorblind.Checked) { "colorblind" }
                  elseif ($rbCustom.Checked) { "custom" }
                  else { "default" }
        $refreshVal = 0
        if ([int]::TryParse($txtRefresh.Text, [ref]$refreshVal)) {
            if ($refreshVal -lt 10) { $refreshVal = 10 }
        } else {
            $refreshVal = 30
        }
        $Script:Settings = @{
            mode           = $mode
            colorPreset    = $preset
            refreshSeconds = $refreshVal
            customColors   = @{
                low       = Color-ToHex $colorButtons['low'].BackColor
                mid       = Color-ToHex $colorButtons['mid'].BackColor
                high      = Color-ToHex $colorButtons['high'].BackColor
                exhausted = Color-ToHex $colorButtons['exhausted'].BackColor
            }
        }
        Save-Config
        Apply-Settings
        $dlg.Dispose()
        return $true
    }

    $dlg.Dispose()
    return $false
}

# ------------ Launcher view ------------

function Show-Launcher {
    # Returns "monitor" if Start clicked, $null if closed

    $Script:LauncherResult = $null
    $T = $Script:Theme

    $form = [Windows.Forms.Form]@{
        Text            = "Claude Usage Monitor"
        FormBorderStyle = 'FixedSingle'
        MaximizeBox     = $false
        StartPosition   = 'CenterScreen'
        BackColor       = $T.FormBg
        ForeColor       = $T.TextPrimary
        ClientSize      = [Drawing.Size]::new(320, 310)
    }

    $lblTitle = [Windows.Forms.Label]@{
        Text     = "Claude Usage Monitor"
        Location = [Drawing.Point]::new(12, 12)
        Size     = [Drawing.Size]::new(296, 28)
        Font     = [Drawing.Font]::new("Segoe UI", 13, [Drawing.FontStyle]::Bold)
    }

    $lblAccounts = [Windows.Forms.Label]@{
        Text      = "Accounts:"
        Location  = [Drawing.Point]::new(12, 48)
        Size      = [Drawing.Size]::new(296, 18)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = $T.TextSecondary
    }

    $listBox = [Windows.Forms.ListBox]@{
        Location    = [Drawing.Point]::new(12, 70)
        Size        = [Drawing.Size]::new(296, 140)
        Font        = [Drawing.Font]::new("Segoe UI", 10)
        BackColor   = $T.PanelBg
        ForeColor   = $T.TextPrimary
        BorderStyle = 'FixedSingle'
    }
    foreach ($acct in $Script:Accounts) { $listBox.Items.Add($acct.name) }

    $btnAdd = [Windows.Forms.Button]@{
        Text      = "Add Account"
        Location  = [Drawing.Point]::new(12, 220)
        Size      = [Drawing.Size]::new(145, 28)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextPrimary
        Font      = [Drawing.Font]::new("Segoe UI", 9)
    }

    $btnRemove = [Windows.Forms.Button]@{
        Text      = "Remove"
        Location  = [Drawing.Point]::new(165, 220)
        Size      = [Drawing.Size]::new(143, 28)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextPrimary
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        Enabled   = $false
    }

    $btnStart = [Windows.Forms.Button]@{
        Text      = "Start Monitoring"
        Location  = [Drawing.Point]::new(12, 264)
        Size      = [Drawing.Size]::new(296, 34)
        FlatStyle = 'Flat'
        BackColor = $T.StartButtonBg
        ForeColor = $T.StartButtonFg
        Font      = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
        Enabled   = ($Script:Accounts.Count -gt 0)
    }

    $listBox.Add_SelectedIndexChanged({
        $btnRemove.Enabled = ($listBox.SelectedIndex -ge 0)
    })

    # --- Add Account ---
    $btnAdd.Add_Click({
        if (-not (Test-Path $Script:ChromePath)) {
            $newPath = Show-InputDialog -Title "Chrome Path" -Prompt "Path to chrome.exe:" -Default $Script:DefaultChrome
            if (-not $newPath) { return }
            if (-not (Test-Path $newPath)) {
                [Windows.Forms.MessageBox]::Show("Chrome not found at that path.", "Error", 'OK', 'Error')
                return
            }
            $Script:ChromePath = $newPath
        }

        $defaultName = "Account$(($Script:Accounts.Count) + 1)"
        $name = Show-InputDialog -Title "Add Account" -Prompt "Display name for this account:" -Default $defaultName
        if (-not $name) { return }

        $port   = Get-NextPort
        $folder = Get-NextFolder
        $dir    = "$Script:ProfilesRoot\$folder"

        $proc = Start-Process $Script:ChromePath -PassThru -ArgumentList `
            "--user-data-dir=`"$dir`"",
            "--remote-debugging-port=$port",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "https://claude.ai"

        $result = [Windows.Forms.MessageBox]::Show(
            "Log into your Claude account in the Chrome window that just opened.`n`nClick OK when done.",
            "Log In - $name",
            'OKCancel',
            'Information'
        )

        try {
            $proc.CloseMainWindow() | Out-Null
            $proc.WaitForExit(5000) | Out-Null
        } catch {}
        Kill-ChromeForProfile -Folder $folder | Out-Null

        if ($result -ne [Windows.Forms.DialogResult]::OK) { return }

        $Script:Accounts += [ordered]@{ name = $name; folder = $folder; port = $port }
        Save-Config

        $listBox.Items.Add($name)
        $btnStart.Enabled = $true
    })

    # --- Remove Account ---
    $btnRemove.Add_Click({
        $idx = $listBox.SelectedIndex
        if ($idx -lt 0) { return }

        $name = $Script:Accounts[$idx].name
        $result = [Windows.Forms.MessageBox]::Show(
            "Remove '$name'?`n`nThis won't delete the Chrome profile data.",
            "Confirm Remove",
            'YesNo',
            'Question'
        )
        if ($result -ne [Windows.Forms.DialogResult]::Yes) { return }

        $newAccounts = @()
        for ($i = 0; $i -lt $Script:Accounts.Count; $i++) {
            if ($i -ne $idx) { $newAccounts += $Script:Accounts[$i] }
        }
        $Script:Accounts = $newAccounts
        Save-Config

        $listBox.Items.RemoveAt($idx)
        $btnRemove.Enabled = $false
        $btnStart.Enabled  = ($Script:Accounts.Count -gt 0)
    })

    # --- Start Monitoring ---
    $btnStart.Add_Click({
        $Script:LauncherResult = "monitor"
        $form.Close()
    })

    foreach ($c in @($lblTitle, $lblAccounts, $listBox, $btnAdd, $btnRemove, $btnStart)) {
        $form.Controls.Add($c)
    }

    [Windows.Forms.Application]::Run($form)
    return $Script:LauncherResult
}

# ------------ Monitor view ------------

function Show-Monitor {
    # Returns $true if user clicked Back (return to launcher), $false if closed

    $Script:ReturnToLauncher = $false
    $Script:OwnedProcs.Clear()
    $Script:LastPageText = @($null) * $Script:Accounts.Count

    $T = $Script:Theme
    $accounts = $Script:Accounts
    $PAD   = 12
    $ROW_H = 76
    $W     = 290

    $form = [Windows.Forms.Form]@{
        Text            = "Claude Usage"
        FormBorderStyle = 'FixedSingle'
        MaximizeBox     = $false
        TopMost         = $true
        BackColor       = $T.FormBg
        ForeColor       = $T.TextPrimary
        StartPosition   = 'Manual'
    }
    $form.ClientSize = [Drawing.Size]::new($W, $PAD + $accounts.Count * $ROW_H + 8 + 28 + 6 + 28 + $PAD)
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = [Drawing.Point]::new($wa.Right - $W - 10, $wa.Top + 10)

    $Rows = @()

    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $y = $PAD + $i * $ROW_H

        $lH = [Windows.Forms.Label]@{
            Size     = [Drawing.Size]::new($W - 2*$PAD, 22)
            Location = [Drawing.Point]::new($PAD, $y)
            Font     = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
            Text     = "$($accounts[$i].name)  -  Starting..."
        }

        $lS = [Windows.Forms.Label]@{
            Size      = [Drawing.Size]::new($W - 2*$PAD, 17)
            Location  = [Drawing.Point]::new($PAD, $y + 24)
            Font      = [Drawing.Font]::new("Segoe UI", 9)
            ForeColor = $T.TextSecondary
            Text      = ""
        }

        $lW = [Windows.Forms.Label]@{
            Size      = [Drawing.Size]::new($W - 2*$PAD, 17)
            Location  = [Drawing.Point]::new($PAD, $y + 42)
            Font      = [Drawing.Font]::new("Segoe UI", 9)
            ForeColor = $T.TextSecondary
            Text      = ""
        }

        $lR = [Windows.Forms.Label]@{
            Size      = [Drawing.Size]::new($W - 2*$PAD, 14)
            Location  = [Drawing.Point]::new($PAD, $y + 60)
            Font      = [Drawing.Font]::new("Segoe UI", 7.5)
            ForeColor = $T.TextMuted
            Text      = ""
        }

        foreach ($c in @($lH, $lS, $lW, $lR)) { $form.Controls.Add($c) }

        if ($i -lt $accounts.Count - 1) {
            $sep = [Windows.Forms.Panel]@{
                Size      = [Drawing.Size]::new($W - 2*$PAD, 1)
                Location  = [Drawing.Point]::new($PAD, $y + $ROW_H - 2)
                BackColor = $T.SeparatorBg
            }
            $form.Controls.Add($sep)
        }

        $Rows += @{ H = $lH; S = $lS; W = $lW; R = $lR }
    }

    $yBot = $PAD + $accounts.Count * $ROW_H + 8

    $btnRefresh = [Windows.Forms.Button]@{
        Text      = "Refresh"
        Size      = [Drawing.Size]::new(80, 24)
        Location  = [Drawing.Point]::new($PAD, $yBot)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextPrimary
        Font      = [Drawing.Font]::new("Segoe UI", 8)
    }
    $form.Controls.Add($btnRefresh)

    $lblStatus = [Windows.Forms.Label]@{
        Size      = [Drawing.Size]::new($W - $PAD - 96, 24)
        Location  = [Drawing.Point]::new($PAD + 88, $yBot + 4)
        Font      = [Drawing.Font]::new("Segoe UI", 7.5)
        ForeColor = $T.TextDim
        Text      = ""
    }
    $form.Controls.Add($lblStatus)

    $yBack = $yBot + 34

    $btnBack = [Windows.Forms.Button]@{
        Text      = [char]0x2190 + " Accounts"
        Size      = [Drawing.Size]::new(96, 24)
        Location  = [Drawing.Point]::new($PAD, $yBack)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextSecondary
        Font      = [Drawing.Font]::new("Segoe UI", 8)
    }
    $form.Controls.Add($btnBack)

    $btnSettings = [Windows.Forms.Button]@{
        Text      = "Settings"
        Size      = [Drawing.Size]::new(80, 24)
        Location  = [Drawing.Point]::new($W - $PAD - 80, $yBack)
        FlatStyle = 'Flat'
        BackColor = $T.ButtonBg
        ForeColor = $T.TextSecondary
        Font      = [Drawing.Font]::new("Segoe UI", 8)
    }
    $form.Controls.Add($btnSettings)

    # --- Refresh logic ---

    $refreshAction = {
        $lblStatus.Text = "Refreshing..."
        $form.Refresh()
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $pg = Get-UsagePage -Port $accounts[$i].port
            if (-not $pg) {
                $Rows[$i].H.Text      = "$($accounts[$i].name)  -  Chrome not ready"
                $Rows[$i].H.ForeColor = $Script:Theme.TextDim
                $Rows[$i].S.Text = ""; $Rows[$i].W.Text = ""; $Rows[$i].R.Text = ""
                continue
            }
            Click-RefreshButton -WsUrl $pg.webSocketDebuggerUrl
            Start-Sleep -Seconds 3
            $txt  = Read-PageText -WsUrl $pg.webSocketDebuggerUrl
            if (-not $txt) {
                Write-Log "$($accounts[$i].name) Read-PageText returned null"
                $Rows[$i].H.Text      = "$($accounts[$i].name)  -  Could not read page"
                $Rows[$i].H.ForeColor = $Script:Theme.TextDim
                $Rows[$i].S.Text = ""; $Rows[$i].W.Text = ""; $Rows[$i].R.Text = ""
                continue
            }
            $Script:LastPageText[$i] = $txt
            Write-Log "$($accounts[$i].name) text (first 500): $($txt.Substring(0, [Math]::Min(500, $txt.Length)))"
            $info = Parse-AccountInfo -Text $txt -Name $accounts[$i].name

            $Rows[$i].H.Text      = $info.Header
            $Rows[$i].H.ForeColor = $info.Color
            $sLine = if ($info.Session) { "Session:  $($info.Session)" } else { "" }
            if ($sLine -and $info.SessionReset) { $sLine += "   $($info.SessionReset)" }
            elseif (-not $sLine -and $info.SessionReset) { $sLine = "Session:  $($info.SessionReset)" }
            $Rows[$i].S.Text = $sLine
            $wLine = if ($info.Weekly) { "Weekly:   $($info.Weekly)" } else { "" }
            if ($wLine -and $info.WeeklyReset) { $wLine += "   $($info.WeeklyReset)" }
            elseif (-not $wLine -and $info.WeeklyReset) { $wLine = "Weekly:   $($info.WeeklyReset)" }
            $Rows[$i].W.Text = $wLine
            $Rows[$i].R.Text = ""
        }
        $lblStatus.Text = "$(Get-Date -Format 'HH:mm:ss')  -  auto $($Script:Settings.refreshSeconds)s"
    }

    # --- Timers ---

    $autoTimer = [Windows.Forms.Timer]@{ Interval = $Script:Settings.refreshSeconds * 1000 }
    $autoTimer.Add_Tick($refreshAction)

    $initTimer = [Windows.Forms.Timer]@{ Interval = 8000 }
    $initTimer.Add_Tick({
        $initTimer.Stop()
        foreach ($p in $Script:OwnedProcs) {
            try { [WinApi]::Minimize([uint32]$p.Id) } catch {}
        }
        & $refreshAction
        $autoTimer.Start()
    })

    $btnRefresh.Add_Click($refreshAction)

    $btnBack.Add_Click({
        $Script:ReturnToLauncher = $true
        $form.Close()
    })

    $btnSettings.Add_Click({
        # Pause auto-refresh while settings dialog is open
        $autoTimer.Stop()

        $changed = Show-Settings
        if ($changed) {
            # Apply new refresh interval
            $autoTimer.Interval = $Script:Settings.refreshSeconds * 1000

            # Re-theme all controls
            $T = $Script:Theme
            $form.BackColor = $T.FormBg
            $form.ForeColor = $T.TextPrimary
            $btnRefresh.BackColor = $T.ButtonBg
            $btnRefresh.ForeColor = $T.TextPrimary
            $btnBack.BackColor = $T.ButtonBg
            $btnBack.ForeColor = $T.TextSecondary
            $btnSettings.BackColor = $T.ButtonBg
            $btnSettings.ForeColor = $T.TextSecondary
            $lblStatus.ForeColor = $T.TextDim
            foreach ($row in $Rows) {
                $row.S.ForeColor = $T.TextSecondary
                $row.W.ForeColor = $T.TextSecondary
                $row.R.ForeColor = $T.TextMuted
            }
            foreach ($ctrl in $form.Controls) {
                if ($ctrl -is [Windows.Forms.Panel] -and $ctrl.Height -eq 1) {
                    $ctrl.BackColor = $T.SeparatorBg
                }
            }

            # Re-color header rows from cached page text (no network needed)
            for ($i = 0; $i -lt $accounts.Count; $i++) {
                $info = Parse-AccountInfo -Text $Script:LastPageText[$i] -Name $accounts[$i].name
                $Rows[$i].H.Text      = $info.Header
                $Rows[$i].H.ForeColor = $info.Color
            }

            # Update status to show new interval
            $lblStatus.Text = "$(Get-Date -Format 'HH:mm:ss')  -  auto $($Script:Settings.refreshSeconds)s"
        }

        # Resume auto-refresh
        $autoTimer.Start()
    })

    $form.Add_Shown({
        $lblStatus.Text = "Starting Chrome..."
        $form.Refresh()
        foreach ($acct in $accounts) { Start-DebugChrome -Account $acct }
        $lblStatus.Text = "Loading pages..."
        $form.Refresh()
        $initTimer.Start()
    })

    $form.Add_FormClosed({
        $autoTimer.Stop()
        $initTimer.Stop()
        foreach ($p in $Script:OwnedProcs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    })

    [Windows.Forms.Application]::Run($form)
    return $Script:ReturnToLauncher
}

# ------------ Entry point ------------

Load-Config

while ($true) {
    $launcherResult = Show-Launcher
    if ($launcherResult -eq "monitor") {
        $shouldReturn = Show-Monitor
        if (-not $shouldReturn) { break }
        Load-Config
    } elseif ($launcherResult -eq "reopen") {
        continue
    } else {
        break
    }
}
