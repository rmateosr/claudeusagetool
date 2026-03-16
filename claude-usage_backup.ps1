# ABOUTME: Opens 3 Chrome windows with separate profiles pointed at Claude usage page
# ABOUTME: Positions all three side-by-side on screen automatically

param(
    [string]$ChromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe",
    [string]$ProfilesRoot = "$env:LOCALAPPDATA\ClaudeProfiles",
    [string]$Url = "https://claude.ai/settings/usage"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static IntPtr FindMainWindowForProcess(uint pid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint windowPid;
            GetWindowThreadProcessId(hWnd, out windowPid);
            if (windowPid == pid && IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                result = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$winWidth = [int]($screen.Width / 3)
$winHeight = $screen.Height

$processes = @()
for ($i = 1; $i -le 3; $i++) {
    $profileDir = "$ProfilesRoot\Account$i"
    $proc = Start-Process -FilePath $ChromePath `
        -ArgumentList "--user-data-dir=`"$profileDir`"", "--new-window", $Url `
        -PassThru
    $processes += $proc
    Start-Sleep -Milliseconds 800
}

Write-Host "Waiting for Chrome windows to open..."
Start-Sleep -Seconds 3

for ($i = 0; $i -lt 3; $i++) {
    $hWnd = [Win32]::FindMainWindowForProcess($processes[$i].Id)
    if ($hWnd -ne [IntPtr]::Zero) {
        $x = $i * $winWidth
        [Win32]::MoveWindow($hWnd, $x, 0, $winWidth, $winHeight, $true) | Out-Null
        Write-Host "Positioned Account $($i + 1)"
    } else {
        Write-Host "Warning: Could not find window for Account $($i + 1) - position it manually"
    }
}

Write-Host "Done. First run: log into each account window."
