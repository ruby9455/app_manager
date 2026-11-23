#Requires -Version 7.0
<#
.SYNOPSIS
Quick start helper for the app manager (Windows Terminal).

.DESCRIPTION
Default mode opens the interactive manager and the landing page side by side in a new tab: of this Windows Terminal
window when run in one, else of the window 'app_manager' (APP_MANAGER_WT_SESSION overrides it). The apps then open as
tabs of that same window.

.EXAMPLE
./start.ps1              # Start manager and landing page in Windows Terminal panes
./start.ps1 all          # Start all apps
./start.ps1 attach       # Bring the app windows to the front
./start.ps1 stop         # Stop all apps
./start.ps1 list         # List panes
./start.ps1 manager      # Start only the manager (interactive)
./start.ps1 landing      # Start only the landing page server
./start.ps1 help         # Show this help
./start.ps1 "My App"     # Start one app by name
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$Command = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manager = Join-Path $PSScriptRoot 'manager.ps1'
$landing = Join-Path $PSScriptRoot 'landing_page.ps1'
$modules = Join-Path $PSScriptRoot 'Modules'
$landingPort = 1111

function Show-Help {
    $name = Split-Path -Leaf $PSCommandPath
    Write-Host 'App Manager - Quick Start'
    Write-Host ''
    Write-Host "Usage: $name [command]"
    Write-Host ''
    Write-Host 'Commands:'
    Write-Host '  (none)    Start manager and landing page (default)'
    Write-Host '  all       Start all apps immediately'
    Write-Host '  attach    Bring the app windows to the front'
    Write-Host '  stop      Stop all running apps'
    Write-Host '  list      List panes'
    Write-Host '  manager   Start only the interactive manager'
    Write-Host '  landing   Start only the landing page server'
    Write-Host '  help      Show this help'
    Write-Host ''
}

switch -CaseSensitive ($Command) {
    'all' { Write-Host 'Starting all apps...' -ForegroundColor Cyan; & $manager -All; break }
    { $_ -in @('attach', 'a') } { & $manager -Attach; break }
    { $_ -in @('stop', 's') } {
        Write-Host 'Stopping all apps...' -ForegroundColor Cyan
        Import-Module (Join-Path $modules 'WtHelpers.psm1') -Force
        Stop-AllWtPanes
        break
    }
    { $_ -in @('list', 'l') } { Import-Module (Join-Path $modules 'WtHelpers.psm1') -Force; Show-WtPanes; break }
    'manager' { Write-Host 'Starting interactive manager...' -ForegroundColor Cyan; & $manager; break }
    'landing' { Write-Host "Starting landing page server on port $landingPort..." -ForegroundColor Cyan; & $landing; break }
    { $_ -in @('help', 'h', '-h', '--help') } { Show-Help; break }
    '' {
        # Default: manager and landing page side by side in a new tab of this window (or the session's window)
        Write-Host 'Launching App Manager with Landing Page...' -ForegroundColor Cyan
        Import-Module (Join-Path $modules 'AppHelpers.psm1') -Force
        Import-Module (Join-Path $modules 'WtHelpers.psm1') -Force

        $networkUrl = Get-NetworkUrlPrefix
        $externalUrl = Get-ExternalUrlPrefix
        Write-Host 'Network configuration:' -ForegroundColor Blue
        Write-Host "  Network:  ${networkUrl}:$landingPort"
        Write-Host "  External: ${externalUrl}:$landingPort"
        Write-Host ''

        try { $null = Get-WtCommand } catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
        $inTerminal = [bool](Initialize-WtHome)
        $target = Get-WtHomeTarget
        $pwsh = Get-PwshPath
        $managerPane = @('--title', 'Manager', '--suppressApplicationTitle', '-d', $PSScriptRoot, '--',
            $pwsh, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manager)

        if ((Test-WtPane '_Dashboard') -or (Test-PortInUse $landingPort)) {
            # The dashboard is already running: just the manager, in a new tab
            Write-Host "Dashboard already running on port $landingPort" -ForegroundColor Cyan
            Invoke-WtTarget $target (@('new-tab') + $managerPane)
        } else {
            # The dashboard first, as a pane the manager can stop (D), so the manager finds it running. Then the
            # manager splits it, and the two swap: the manager on the left (60%), the dashboard on the right (40%).
            $run = "& $(ConvertTo-PsLiteral $landing) -Port $landingPort"
            Start-WtPane -Name '_Dashboard' -WorkingDirectory $PSScriptRoot -RunCommand $run -Mode tab -Target $target -Where 'beside manager'
            Invoke-WtTarget $target (@('split-pane', '-V', '-s', '0.4') + $managerPane + @(';', 'swap-pane', 'left'))
        }
        if ($inTerminal) { Write-Host 'Opened the manager in a new tab of this Windows Terminal window' -ForegroundColor Green }
        else { Write-Host "Opened the manager in Windows Terminal window '$($target.Name)'" -ForegroundColor Green }
        break
    }
    default { Write-Host "Starting app: $Command" -ForegroundColor Cyan; & $manager -AppName $Command }
}
