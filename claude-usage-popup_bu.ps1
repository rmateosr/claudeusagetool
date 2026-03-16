# ABOUTME: Compact always-on-top popup showing Claude usage stats for 3 accounts
# ABOUTME: Manages Chrome via DevTools Protocol to extract data from logged-in profiles

param(
    [string]$ChromePath   = "C:\Program Files\Google\Chrome\Application\chrome.exe",
    [string]$ProfilesRoot = "$env:LOCALAPPDATA\ClaudeProfiles",
    [int]$RefreshSeconds  = 30,
    [string]$Url          = "https://claude.ai/settings/usage"
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

$Script:Ports      = @(9222, 9223, 9224)
$Script:OwnedProcs = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$Script:LogFile    = "$env:TEMP\claude-popup.log"
"" | Out-File $Script:LogFile

function Write-Log {
    param([string]$Msg)
    "$(Get-Date -Format 'HH:mm:ss')  $Msg" | Out-File $Script:LogFile -Append
}

# ------------ Chrome management ------------

function Kill-ChromeForProfile {
    param([int]$Idx)
    $killed = 0
    # Enumerate via Get-Process (reliable) then query each PID via WMI for CommandLine
    $chromeProcs = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    Write-Log "Kill scan: $($chromeProcs.Count) chrome.exe processes running"
    foreach ($p in $chromeProcs) {
        try {
            $wmi = Get-WmiObject Win32_Process -Filter "ProcessId=$($p.Id)"
            $cmd = $wmi.CommandLine
            $short = if ($cmd) { $cmd.Substring(0, [Math]::Min(200, $cmd.Length)) } else { 'NULL' }
            Write-Log "  PID $($p.Id) title='$($p.MainWindowTitle)' cmd=$short"
            if ($cmd -and $cmd -like "*Account$Idx*") {
                Write-Log "  -> killing PID $($p.Id)"
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                $killed++
            }
        } catch { Write-Log "  PID $($p.Id) query error: $_" }
    }
    Write-Log "Kill scan done: killed $killed process(es) for Account${Idx}"
    return $killed
}

function Start-DebugChrome {
    param([int]$Idx)
    $port = $Script:Ports[$Idx - 1]
    $dir  = "$ProfilesRoot\Account$Idx"

    # Reuse if a debug-enabled Chrome is already running on this port
    try {
        Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 1 -ErrorAction Stop | Out-Null
        Write-Log "Account${Idx}: debug port $port already active - reusing"
        return
    } catch {
        Write-Log "Account${Idx}: port $port not active, will kill and relaunch"
    }

    Kill-ChromeForProfile -Idx $Idx | Out-Null
    Start-Sleep -Milliseconds 1000

    $proc = Start-Process $ChromePath -PassThru -ArgumentList `
        "--user-data-dir=`"$dir`"",
        "--remote-debugging-port=$port",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-session-crashed-bubble",
        "--hide-crash-restore-bubble",
        $Url
    Write-Log "Account${Idx}: launched Chrome PID $($proc.Id) on debug port $port"
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
        # Page not on usage URL yet - get any page and navigate to it
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
        $js    = "var b = document.evaluate(""/html/body/div[2]/div/div[2]/div[3]/main/div/div/div/section[1]/div[5]/div/button"", document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue; if (b) { b.click(); 'clicked' } else { 'not found' }"
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
    param([string]$Text, [int]$Num)

    $names = @("claudeA-raulnmateos", "claudeB-rmateos.1", "claudeN-rmateosr")
    $base  = $names[$Num - 1]

    if (-not $Text) {
        return @{ Header = "$base"; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = [Drawing.Color]::DimGray }
    }

    if ($Text -match '(Sign in|Log in|Create account)' -and $Text -notmatch '\d+% used') {
        return @{ Header = "$base  -  Not logged in"; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = [Drawing.Color]::OrangeRed }
    }

    if ($Text -notmatch '\d+%') {
        return @{ Header = "$base  -  Loading..."; Session = ""; Weekly = ""; SessionReset = ""; WeeklyReset = ""; Color = [Drawing.Color]::Gray }
    }

    # Extract all "X% used" / "X% of capacity used" matches with surrounding context
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
    # Fallback: if only one value found, treat as weekly
    if ($weekly -and -not $session) { <# already set #> }
    elseif (-not $weekly -and $session) { $weekly = $session; $session = "" }
    elseif (-not $weekly -and -not $session) {
        # Try a plain % match
        if ($Text -match '(\d+)%') { $weekly = "$($Matches[1])%" }
    }

    # Reset times — both session and weekly can use countdown format ("Resets in X hr Y min")
    # when the reset is < 24h away; otherwise weekly shows day+time ("Resets Fri 1:00 PM")
    $sessionReset = ""
    $weeklyReset  = ""
    # Find positions of section headers to assign resets correctly
    $weeklyPos = -1
    $sessionPos = -1
    $wm = [regex]::Match($Text, '(?i)weekly\s+(limit|usage)')
    if ($wm.Success) { $weeklyPos = $wm.Index }
    $sm = [regex]::Match($Text, '(?i)session\s+(limit|usage|capacity)')
    if ($sm.Success) { $sessionPos = $sm.Index }
    # Match all "Resets ..." lines (both countdown and day+time formats)
    $allResetMatches = [regex]::Matches($Text, 'Resets\s+(in\s+[\d\w\s]+(?:hr|min)[^\n\r]*|(?!in\b)[^\n\r]+)')
    foreach ($rm in $allResetMatches) {
        $resetText = "Resets $($rm.Groups[1].Value.Trim())"
        $pos = $rm.Index
        # Assign to weekly or session based on which section header precedes this match
        if ($weeklyPos -ge 0 -and $pos -gt $weeklyPos -and ($sessionPos -lt 0 -or $weeklyPos -gt $sessionPos -or $pos -lt $sessionPos)) {
            if (-not $weeklyReset) { $weeklyReset = $resetText }
        } elseif ($sessionPos -ge 0 -and $pos -gt $sessionPos -and ($weeklyPos -lt 0 -or $sessionPos -gt $weeklyPos -or $pos -lt $weeklyPos)) {
            if (-not $sessionReset) { $sessionReset = $resetText }
        } else {
            # Fallback: if we can't determine section, assign first to session, rest to weekly
            if (-not $sessionReset) { $sessionReset = $resetText }
            elseif (-not $weeklyReset) { $weeklyReset = $resetText }
        }
    }

    # Status and color
    $color  = [Drawing.Color]::LimeGreen
    $status = ""
    if ($Text -match "You.ve hit your weekly limit") {
        $status = "Limit reached"
        $color  = [Drawing.Color]::OrangeRed
    } elseif ($Text -match "You.re now using extra usage") {
        $status = "Extra usage"
        $color  = [Drawing.Color]::Orange
    } elseif ($session -or $weekly) {
        $p = if ($session) { [int]($session -replace '%', '') } else { 0 }
        $color = if ($p -eq 100)   { [Drawing.Color]::Gray }
                 elseif ($p -ge 90) { [Drawing.Color]::OrangeRed }
                 elseif ($p -ge 50) { [Drawing.Color]::Orange }
                 else               { [Drawing.Color]::LimeGreen }
    }

    $header = if ($status) { "$base  -  $status" } else { $base }
    return @{ Header = $header; Session = $session; Weekly = $weekly; SessionReset = $sessionReset; WeeklyReset = $weeklyReset; Color = $color }
}

# ------------ UI layout ------------

$PAD   = 12
$ROW_H = 76
$W     = 290

$form = [Windows.Forms.Form]@{
    Text            = "Claude Usage"
    FormBorderStyle = 'FixedSingle'
    MaximizeBox     = $false
    TopMost         = $true
    BackColor       = [Drawing.Color]::FromArgb(22, 22, 22)
    ForeColor       = [Drawing.Color]::White
    StartPosition   = 'Manual'
}
$form.ClientSize = [Drawing.Size]::new($W, $PAD + 3 * $ROW_H + 8 + 28 + $PAD)
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = [Drawing.Point]::new($wa.Right - $W - 10, $wa.Top + 10)

$Rows = @()
$AccountNames = @("claudeA-raulnmateos", "claudeB-rmateos.1", "claudeN-rmateosr")
$Script:DisplayPorts = @(9223, 9224, 9222)

for ($i = 0; $i -lt 3; $i++) {
    $y = $PAD + $i * $ROW_H

    $lH = [Windows.Forms.Label]@{
        Size     = [Drawing.Size]::new($W - 2*$PAD, 22)
        Location = [Drawing.Point]::new($PAD, $y)
        Font     = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
        Text     = "$($AccountNames[$i])  -  Starting..."
    }

    $lS = [Windows.Forms.Label]@{
        Size      = [Drawing.Size]::new($W - 2*$PAD, 17)
        Location  = [Drawing.Point]::new($PAD, $y + 24)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = [Drawing.Color]::Silver
        Text      = ""
    }

    $lW = [Windows.Forms.Label]@{
        Size      = [Drawing.Size]::new($W - 2*$PAD, 17)
        Location  = [Drawing.Point]::new($PAD, $y + 42)
        Font      = [Drawing.Font]::new("Segoe UI", 9)
        ForeColor = [Drawing.Color]::Silver
        Text      = ""
    }

    $lR = [Windows.Forms.Label]@{
        Size      = [Drawing.Size]::new($W - 2*$PAD, 14)
        Location  = [Drawing.Point]::new($PAD, $y + 60)
        Font      = [Drawing.Font]::new("Segoe UI", 7.5)
        ForeColor = [Drawing.Color]::FromArgb(100, 100, 100)
        Text      = ""
    }

    foreach ($c in @($lH, $lS, $lW, $lR)) { $form.Controls.Add($c) }

    if ($i -lt 2) {
        $sep = [Windows.Forms.Panel]@{
            Size      = [Drawing.Size]::new($W - 2*$PAD, 1)
            Location  = [Drawing.Point]::new($PAD, $y + $ROW_H - 2)
            BackColor = [Drawing.Color]::FromArgb(42, 42, 42)
        }
        $form.Controls.Add($sep)
    }

    $Rows += @{ H = $lH; S = $lS; W = $lW; R = $lR }
}

$yBot = $PAD + 3 * $ROW_H + 8

$btnRefresh = [Windows.Forms.Button]@{
    Text      = "Refresh"
    Size      = [Drawing.Size]::new(80, 24)
    Location  = [Drawing.Point]::new($PAD, $yBot)
    FlatStyle = 'Flat'
    BackColor = [Drawing.Color]::FromArgb(48, 48, 48)
    ForeColor = [Drawing.Color]::White
    Font      = [Drawing.Font]::new("Segoe UI", 8)
}
$form.Controls.Add($btnRefresh)

$lblStatus = [Windows.Forms.Label]@{
    Size      = [Drawing.Size]::new($W - $PAD - 96, 24)
    Location  = [Drawing.Point]::new($PAD + 88, $yBot + 4)
    Font      = [Drawing.Font]::new("Segoe UI", 7.5)
    ForeColor = [Drawing.Color]::DimGray
    Text      = ""
}
$form.Controls.Add($lblStatus)

# ------------ Refresh logic ------------

function Invoke-Refresh {
    $lblStatus.Text = "Refreshing..."
    $form.Refresh()
    for ($i = 0; $i -lt 3; $i++) {
        $pg = Get-UsagePage -Port $Script:DisplayPorts[$i]
        if (-not $pg) {
            $Rows[$i].H.Text      = "$($AccountNames[$i])  -  Chrome not ready"
            $Rows[$i].H.ForeColor = [Drawing.Color]::DimGray
            $Rows[$i].S.Text = ""; $Rows[$i].W.Text = ""; $Rows[$i].R.Text = ""
            continue
        }
        Click-RefreshButton -WsUrl $pg.webSocketDebuggerUrl
        Start-Sleep -Seconds 3
        $txt  = Read-PageText -WsUrl $pg.webSocketDebuggerUrl
        Write-Log "Account $($i+1) text (first 500): $($txt.Substring(0, [Math]::Min(500, $txt.Length)))"
        $info = Parse-AccountInfo -Text $txt -Num ($i + 1)

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
    $lblStatus.Text = "$(Get-Date -Format 'HH:mm:ss')  -  auto ${RefreshSeconds}s"
}

# ------------ Timers ------------

$autoTimer = [Windows.Forms.Timer]@{ Interval = $RefreshSeconds * 1000 }
$autoTimer.Add_Tick({ Invoke-Refresh })

# Fires once after startup to do the first data fetch
$initTimer = [Windows.Forms.Timer]@{ Interval = 8000 }
$initTimer.Add_Tick({
    $initTimer.Stop()
    foreach ($p in $Script:OwnedProcs) {
        try { [WinApi]::Minimize([uint32]$p.Id) } catch {}
    }
    Invoke-Refresh
    $autoTimer.Start()
})

$btnRefresh.Add_Click({ Invoke-Refresh })

$form.Add_Shown({
    $lblStatus.Text = "Starting Chrome..."
    $form.Refresh()
    1..3 | ForEach-Object { Start-DebugChrome -Idx $_ }
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
