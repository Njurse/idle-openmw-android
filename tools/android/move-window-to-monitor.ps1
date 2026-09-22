# tools/android/move-window-to-monitor.ps1
#
# Move a window onto a chosen monitor. Handy for parking the Android emulator on
# the screen that is *not* running your game, which is the whole point.
#
#   powershell -File tools/android/move-window-to-monitor.ps1 -ProcessName emulator -Monitor 2
#
# -Monitor is 1-based, in the order Windows enumerates screens. -Monitor 0 (the
# default) means "the first non-primary screen", which is usually what you want.

param(
  [string]$ProcessName = "emulator",
  [int]$Monitor = 0,
  [switch]$Maximize,
  [int]$TimeoutSeconds = 90
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Move {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@

$screens = [System.Windows.Forms.Screen]::AllScreens
if ($screens.Count -lt 2) {
  Write-Host "Only one monitor detected; nothing to move."
  exit 0
}

# pick the target screen
if ($Monitor -gt 0) {
  $target = $screens[$Monitor - 1]
} else {
  $target = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
}
Write-Host ("target monitor: {0} at {1},{2} ({3}x{4})" -f $target.DeviceName, $target.Bounds.X, $target.Bounds.Y, $target.Bounds.Width, $target.Bounds.Height)

# wait for the window to appear
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$handle = [IntPtr]::Zero
while ((Get-Date) -lt $deadline -and $handle -eq [IntPtr]::Zero) {
  $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($proc) { $handle = $proc.MainWindowHandle } else { Start-Sleep -Seconds 2 }
}

if ($handle -eq [IntPtr]::Zero) {
  Write-Host "no window for process '$ProcessName' after ${TimeoutSeconds}s"
  exit 1
}

if ($Maximize) { [Win32Move]::ShowWindow($handle, 3) | Out-Null }  # SW_MAXIMIZE

$b = $target.Bounds
# land a phone-shaped window sensibly: keep the emulator's aspect, use the full
# height of the target screen and centre it horizontally on that screen.
$height = [int]($b.Height * 0.95)
$width  = [int]($height * (1080.0 / 2340.0))
if ($width -lt 400) { $width = [int]($b.Width * 0.45) }
$x = $b.X + [int](($b.Width - $width) / 2)
$y = $b.Y + [int](($b.Height - $height) / 2)

[Win32Move]::MoveWindow($handle, $x, $y, $width, $height, $true) | Out-Null
[Win32Move]::SetForegroundWindow($handle) | Out-Null

Write-Host ("moved '{0}' to {1}x{2} at {3},{4}" -f $ProcessName, $width, $height, $x, $y)
