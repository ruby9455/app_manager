#Requires -Version 7.0
<#
.SYNOPSIS
Quick start helper for the app manager (PowerShell twin of start.sh).

.DESCRIPTION
Default mode launches both the interactive manager and landing page server side by side in a tuios session.

.EXAMPLE
./start.ps1              # Start manager and landing page in tuios panes
./start.ps1 all          # Start all apps
./start.ps1 attach       # Attach to tuios session
./start.ps1 stop         # Stop all apps
./start.ps1 list         # List tuios windows
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

function Show-Help {
    $name = Split-Path -Leaf $PSCommandPath
    Write-Host 'App Manager - Quick Start'
    Write-Host ''
    Write-Host "Usage: $name [command]"
    Write-Host ''
    Write-Host 'Commands:'
    Write-Host '  (none)    Start manager and landing page (default)'
    Write-Host '  all       Start all apps immediately'
    Write-Host '  attach    Attach to tuios session'
    Write-Host '  stop      Stop all running apps'
    Write-Host '  list      List tuios windows'
    Write-Host '  manager   Start only the interactive manager'
    Write-Host '  landing   Start only the landing page server'
    Write-Host '  help      Show this help'
    Write-Host ''
}

switch -CaseSensitive ($Command) {
    'all' { Write-Host 'Starting all apps...' -ForegroundColor Cyan; & $manager -All; break }
    { $_ -in @('attach', 'a') } { Write-Host 'Attaching to tuios session...' -ForegroundColor Cyan; & $manager -Attach; break }
    { $_ -in @('stop', 's') } {
        Write-Host 'Stopping all apps...' -ForegroundColor Cyan
        Import-Module (Join-Path $modules 'TuiosHelpers.psm1') -Force
        Stop-AllTuiosWindows
        break
    }
    { $_ -in @('list', 'l') } { Import-Module (Join-Path $modules 'TuiosHelpers.psm1') -Force; Show-TuiosWindows; break }
    'manager' { Write-Host 'Starting interactive manager...' -ForegroundColor Cyan; & $manager; break }
    'landing' { Write-Host 'Starting landing page server on port 1111...' -ForegroundColor Cyan; & $landing; break }
    { $_ -in @('help', 'h', '-h', '--help') } { Show-Help; break }
    '' {
        # Default: launch both manager and landing page side by side in a tuios session
        Write-Host 'Launching App Manager with Landing Page...' -ForegroundColor Cyan
        Import-Module (Join-Path $modules 'AppHelpers.psm1') -Force
        Import-Module (Join-Path $modules 'TuiosHelpers.psm1') -Force

        $networkUrl = Get-NetworkUrlPrefix
        $externalUrl = Get-ExternalUrlPrefix
        Write-Host 'Network configuration:' -ForegroundColor Blue
        Write-Host "  Network:  ${networkUrl}:1111"
        Write-Host "  External: ${externalUrl}:1111"
        Write-Host ''

        $tuios = $null
        try { $tuios = Get-TuiosCommand } catch {}
        if (-not $tuios) {
            Write-Host 'tuios is not installed. Running manager and landing page sequentially.' -ForegroundColor Yellow
            Write-Host 'To use panes, install tuios: https://github.com/Gaurav-Gosain/tuios' -ForegroundColor Cyan
            # Run landing page in background, manager in foreground
            $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
            $landingProcess = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-File', $landing) -PassThru -NoNewWindow -RedirectStandardInput ([IO.Path]::GetTempFileName())
            Write-Host "Landing page server started in background (PID: $($landingProcess.Id))" -ForegroundColor Green
            Write-Host 'Starting interactive manager...' -ForegroundColor Green
            try { & $manager } finally { Stop-Process -Id $landingProcess.Id -ErrorAction SilentlyContinue }
            break
        }

        # Create a new tuios session with two panes
        $sessionName = "app-manager-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        # The bare name: a Store install's full pwsh path fails when tuios starts it (see Get-PwshPath)
        $pwsh = 'pwsh'

        # Create the session headless; it opens with one shell window, closed below
        $null = & $tuios new $sessionName --detach --cwd $PSScriptRoot
        if ($LASTEXITCODE -ne 0) { throw "Unable to create tuios session '$sessionName'." }
        $firstIds = @()
        try { $firstIds = @((@(& $tuios list-windows -s $sessionName --json 2>$null) -join "`n" | ConvertFrom-Json).windows | ForEach-Object { $_.window_id }) } catch {}

        # Manager in the first pane, landing page beside it (new panes are tiled)
        $managerId = (& $tuios new-window -s $sessionName manager --cwd $PSScriptRoot --print-id -- $pwsh -NoLogo -NoProfile -File $manager | Select-Object -Last 1)
        $null = & $tuios new-window -s $sessionName landing --cwd $PSScriptRoot --no-focus -- $pwsh -NoLogo -NoProfile -File $landing
        foreach ($id in $firstIds) { $null = & $tuios close-window -s $sessionName $id 2>$null }
        if ($managerId) { $null = & $tuios focus-window -s $sessionName ([string]$managerId).Trim() 2>$null }

        # Attach to the session (switch to it when already inside tuios)
        if ($env:TUIOS_SESSION) { & $tuios switch-session $sessionName } else { & $tuios attach $sessionName }
        break
    }
    default { Write-Host "Starting app: $Command" -ForegroundColor Cyan; & $manager -AppName $Command }
}
