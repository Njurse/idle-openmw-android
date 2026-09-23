# tools/dev/desktop/shot.ps1
# Screenshot the OpenMW window, so the console UI can actually be looked at.
#
# Why a window capture rather than the whole screen: the dev box has other
# windows, and we want exactly the game. We focus the window first (so it is not
# occluded), read its client rectangle, then blit that region.
#
# Usage (from bash):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/dev/desktop/shot.ps1 \
#       -Process openmw -Out build/desktop/shot.png
#
# Exits non-zero if no window was found, so the caller can tell the engine is not
# running rather than silently saving a picture of the desktop.

param(
    [string]$Process = "openmw",
    [string]$Out = "build/desktop/shot.png"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

$proc = Get-Process -Name $Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) {
    Write-Error "no '$Process' process with a window is running"
    exit 2
}

$hwnd = $proc.MainWindowHandle
[void][Win]::ShowWindow($hwnd, 9)          # SW_RESTORE
[void][Win]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 600              # let it paint

# Client area = just the rendered pixels, no title bar.
$client = New-Object Win+RECT
[void][Win]::GetClientRect($hwnd, [ref]$client)
$origin = New-Object Win+POINT
[void][Win]::ClientToScreen($hwnd, [ref]$origin)

$width  = $client.Right - $client.Left
$height = $client.Bottom - $client.Top
if ($width -le 0 -or $height -le 0) {
    Write-Error "window '$Process' has no client area yet (still loading?)"
    exit 3
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$bmp = New-Object System.Drawing.Bitmap($width, $height)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bmp.Size)
$bmp.Save((Resolve-Path -LiteralPath $dir).Path + "\" + (Split-Path -Leaf $Out),
          [System.Drawing.Imaging.ImageFormat]::Png)
$gfx.Dispose(); $bmp.Dispose()

Write-Output ("captured {0}x{1} of '{2}' (pid {3}) -> {4}" -f $width, $height, $Process, $proc.Id, $Out)
