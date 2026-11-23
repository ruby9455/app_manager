#Requires -Version 7.0
<#
.SYNOPSIS
What each Windows Terminal pane of app_manager_win_v2 runs: it registers the pane, runs the app, and stops it when the
manager asks.

.DESCRIPTION
The manager writes the pane's registry entry (-StateFile, with the run command) and opens a pane running this script.
It then:
  1. records its process id, start time and Windows Terminal window in the entry, so the manager can tell the pane is
     running and bring its window forward;
  2. watches for <entry>.stop on a background thread: when it appears, Ctrl+C goes to this console (the app and this
     script), and the script exits 0, which makes Windows Terminal close the pane;
  3. runs the app command, as the tuios edition's windows do: a banner, the command, its exit code, then a wait for
     Enter before the pane closes.
A Ctrl+C typed in the pane stops the app and leaves the pane open with its output.
#>
param([Parameter(Mandatory)][string]$StateFile)

# The app command runs in this script's scope: keep this script's own names unusual
$__AppManagerStopFile = [IO.Path]::ChangeExtension($StateFile, '.stop')
$__AppManagerUtf8 = [System.Text.UTF8Encoding]::new($false)

try {
    $__AppManagerPane = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "This pane's entry is gone ($StateFile). Start the app from the manager." -ForegroundColor Yellow
    Read-Host 'Press Enter to close this pane...' | Out-Null
    exit 0
}

if (-not ('AppManagerWt.PaneHost' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
namespace AppManagerWt {
    public static class PaneHost {
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("kernel32.dll")] static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);

        // The Windows Terminal window hosting this console (its pseudo-console window's root owner)
        public static long WindowHandle() { return GetAncestor(GetConsoleWindow(), 3).ToInt64(); }

        // Send Ctrl+C to every process of this console when the file appears, again every 3 s while it stays
        public static void WatchStopFile(string path) {
            var thread = new Thread(() => {
                var sent = DateTime.MinValue;
                while (true) {
                    if (File.Exists(path) && (DateTime.UtcNow - sent).TotalSeconds >= 3) {
                        sent = DateTime.UtcNow;
                        GenerateConsoleCtrlEvent(0, 0);
                    }
                    Thread.Sleep(250);
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }
    }
}
'@
}

function Test-AppManagerPaneOwner {
    $current = $null
    try { $current = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
    return $current -and $current.HostPid -eq $PID
}

# The entry is the manager's record of a running pane; it goes when the app ends
function Unregister-AppManagerPane {
    if (Test-AppManagerPaneOwner) { Remove-Item -LiteralPath $StateFile -ErrorAction SilentlyContinue }
}

# Another pane already runs this app (e.g. Enter pressed in an old pane to run it again): leave that one be
if ($__AppManagerPane.HostPid -and $__AppManagerPane.HostPid -ne $PID) {
    $__AppManagerOther = Get-Process -Id ([int]$__AppManagerPane.HostPid) -ErrorAction SilentlyContinue
    if ($__AppManagerOther -and $__AppManagerOther.StartTime.ToFileTimeUtc() -eq [int64]$__AppManagerPane.HostStart) {
        Write-Host "'$($__AppManagerPane.Name)' is already running in another pane (PID $($__AppManagerPane.HostPid))." -ForegroundColor Yellow
        Read-Host 'Press Enter to close this pane...' | Out-Null
        exit 0
    }
}

# Register: this process (its start time tells it from a later process with the same id) and its window
$__AppManagerPane.HostPid = $PID
$__AppManagerPane.HostStart = (Get-Process -Id $PID).StartTime.ToFileTimeUtc()
$__AppManagerPane.WindowHandle = [AppManagerWt.PaneHost]::WindowHandle()
Remove-Item -LiteralPath $__AppManagerStopFile -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject $__AppManagerPane -Depth 5), $__AppManagerUtf8)
[AppManagerWt.PaneHost]::WatchStopFile($__AppManagerStopFile)

$Host.UI.RawUI.WindowTitle = [string]$__AppManagerPane.Name
Set-Location -LiteralPath ([string]$__AppManagerPane.WorkingDirectory)
Write-Host "=== Starting: $($__AppManagerPane.Name) ===" -ForegroundColor Cyan
Write-Host "Directory: $($__AppManagerPane.WorkingDirectory)"
Write-Host '---'

$__AppManagerCompleted = $false
try {
    $global:LASTEXITCODE = 0
    try {
        . ([scriptblock]::Create([string]$__AppManagerPane.RunCommand))
        $__AppManagerExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        Write-Error $_ -ErrorAction Continue
        $__AppManagerExitCode = 1
    }
    # The app ended by itself (not by Ctrl+C). The pane stays registered while it waits, as a tuios window stays, so
    # a stop or restart from the manager still closes it.
    $__AppManagerCompleted = $true
    Write-Host ''
    Write-Host "=== App exited with code $__AppManagerExitCode ===" -ForegroundColor Yellow
    # Wait for Enter, or for a stop from the manager (Ctrl+C does not interrupt a console read, so poll for both)
    Write-Host 'Press Enter to close this pane...'
    while (-not (Test-Path -LiteralPath $__AppManagerStopFile)) {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Enter) { break }
        Start-Sleep -Milliseconds 200
    }
} finally {
    Unregister-AppManagerPane
    # Exit 0 closes the pane: after the wait for Enter, or when the manager asked to stop
    if ($__AppManagerCompleted -or (Test-Path -LiteralPath $__AppManagerStopFile)) { [Environment]::Exit(0) }
}
