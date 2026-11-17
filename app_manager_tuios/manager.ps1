#Requires -Version 7.0
<#
.SYNOPSIS
Interactive app manager using tuios (PowerShell 7: Windows, Linux and macOS).

.DESCRIPTION
The PowerShell twin of manager.sh, with the same behaviour as app_manager_tmux. Launch and manage Streamlit, Django,
Dash, Flask and Custom (own start command) apps from apps.json. Each app runs in a named window of the tuios session
'app_manager' (APP_MANAGER_TUIOS_SESSION overrides it) that can be stopped/restarted.

.EXAMPLE
./manager.ps1                     # Interactive menu
./manager.ps1 -AppName 'My App'   # Start specific app
./manager.ps1 -All                # Start all apps
./manager.ps1 -DryRun -All        # Preview what would run
./manager.ps1 -Attach             # Attach to tuios session
./manager.ps1 -NoLanding          # Start without dashboard
#>
[CmdletBinding()]
param(
    [Alias('App')][string]$AppName,
    [switch]$All,
    [switch]$DryRun,
    [switch]$Attach,
    [switch]$NoLanding,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$modules = Join-Path $PSScriptRoot 'Modules'
Import-Module (Join-Path $modules 'AppHelpers.psm1') -Force
Import-Module (Join-Path $modules 'TuiosHelpers.psm1') -Force

# Landing page configuration
$script:LandingPageEnabled = $true      # Set to $false to disable auto-start
$script:LandingPagePort = 1111          # Default port for landing page
$script:LandingPageWindowName = '_Dashboard'

$script:Apps = @()
$script:AppsJsonPath = $null
$script:SkipLandingPage = [bool]$NoLanding
$script:NetworkUrl = ''
$script:ExternalUrl = ''
$script:GenericUrl = ''

function Show-Usage {
    $name = Split-Path -Leaf $PSCommandPath
@"
Usage: $name [OPTIONS]

Launch and manage Python web apps (Streamlit, Django, Dash, Flask, or Custom with its own start command) using tuios.

OPTIONS:
    -AppName NAME       Start a specific app by name
    -All                Start all apps
    -DryRun             Show what would be executed without running
    -Attach             Attach to the tuios session
    -NoLanding          Skip auto-starting the landing page dashboard
    -Help               Show this help message

EXAMPLES:
    $name                       # Interactive menu
    $name -AppName "My App"     # Start specific app
    $name -All                  # Start all apps
    $name -DryRun -All          # Preview what would run
    $name -Attach               # Attach to tuios session
    $name -NoLanding            # Start without dashboard

INTERACTIVE COMMANDS:
    Dashboard:
        D           Toggle landing page dashboard
    Manage apps:
        [number(s)] Start app(s) by index (e.g., 1,2,3) (0 for all)
        [name]      Start app by name
        s [num(s)]  Stop app(s) by index (e.g., 1,2,3) (0 for all)
        r [num(s)]  Restart app(s) by index (e.g., 1,2,3) (0 for all)
        u [num(s)]  Update app(s) from repo (e.g., 1,2,3) (0 for all)
    Edit apps.json:
        aa          Add a new app (incl. Custom: any start command + port)
        ap          Add a new process (custom command)
        e [num]     Edit by index
        d [num(s)]  Delete app(s) by index (e.g., 1,2,3)
    tuios:
        l           List tuios windows
        t           Attach to tuios session
        t [num]     Attach and switch to app window
    Other:
        R           Refresh list
        q           Quit

DASHBOARD:
    The landing page dashboard runs automatically on port $script:LandingPagePort.
    Use -NoLanding to skip auto-start, or set `$script:LandingPageEnabled = `$false in manager.ps1.

"@ | Write-Host
}

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
}

function Wait-Enter { Write-Host ''; Read-Host 'Press Enter to continue...' | Out-Null }

# Check dependencies
function Assert-Dependencies {
    $missing = @()
    try { $null = Get-TuiosCommand } catch { $missing += 'tuios' }
    if (-not (Get-Command python3 -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue) -and
        -not (Get-Command py -ErrorAction SilentlyContinue)) { $missing += 'python3' }
    if ($missing.Count -gt 0) {
        Write-Host "Error: Missing required dependencies: $($missing -join ' ')" -ForegroundColor Red
        Write-Host ''
        Write-Host 'Install with:'
        if ($missing -contains 'tuios') {
            Write-Host '  tuios:  brew install tuios (macOS/Linux), yay -S tuios-bin (Arch),'
            Write-Host '          or a release binary from https://github.com/Gaurav-Gosain/tuios/releases (Windows)'
        }
        if ($missing -contains 'python3') { Write-Host '  python:  https://www.python.org/downloads/ (or winget install Python.Python.3.12)' }
        exit 1
    }
}

# Load apps from JSON
function Import-AppsJson {
    try {
        $jsonPath = Get-TuiosAppsPath -ScriptRoot $PSScriptRoot
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    if (-not $jsonPath) {
        # apps.json not found - try to create from example
        $examplePath = Join-Path $PSScriptRoot 'apps_example.json'
        $targetPath = Join-Path $PSScriptRoot 'apps.json'
        if (Test-Path -LiteralPath $examplePath) {
            Write-Host 'apps.json not found. Creating from apps_example.json...' -ForegroundColor Yellow
            Copy-Item -LiteralPath $examplePath -Destination $targetPath
            Write-Host "Created: $targetPath" -ForegroundColor Green
            Write-Host 'Please edit apps.json with your actual app configurations.' -ForegroundColor Cyan
            Write-Host ''
            $jsonPath = $targetPath
        } else {
            Write-Host 'Error: Could not find apps.json or apps_example.json' -ForegroundColor Red
            Write-Host "Please create apps.json in: $PSScriptRoot"
            exit 1
        }
    }

    Write-Host "Loading apps from: $jsonPath" -ForegroundColor Cyan
    # Add/edit/delete save back to the same file
    $script:AppsJsonPath = $jsonPath
    $script:Apps = @(Get-SupportedApps @(Read-AppsFile $jsonPath))
    if ($script:Apps.Count -eq 0) { Write-Host 'No supported apps found in apps.json' -ForegroundColor Yellow }
    Write-Host "Found $($script:Apps.Count) supported apps" -ForegroundColor Green
}

# The app at a 1-based index, $null when out of range
function Get-AppAtIndex {
    param([string]$Index)
    if ($Index -notmatch '^\d+$') { return $null }
    $i = [int]$Index
    if ($i -lt 1 -or $i -gt $script:Apps.Count) { return $null }
    return $script:Apps[$i - 1]
}

function Get-AppPort {
    param([object]$App)
    $port = [string](Get-AppField $App 'Port')
    if ($port -match '^\d+$' -and [int]$port -gt 0) { return [int]$port }
    return $null
}

# Start the landing page dashboard as a tuios window
function Start-LandingPage {
    if ($script:SkipLandingPage -or -not $script:LandingPageEnabled) { return }
    $windowName = $script:LandingPageWindowName

    # Check if already running
    if (Test-TuiosWindow $windowName) {
        if (-not (Test-PortInUse $script:LandingPagePort)) {
            Write-Host 'Removing stale dashboard window...' -ForegroundColor Yellow
            Remove-TuiosWindow $windowName
        } else {
            Write-Host 'Dashboard already running' -ForegroundColor Cyan
            return
        }
    }

    # Also check if port is in use
    if (Test-PortInUse $script:LandingPagePort) {
        Write-Host "Dashboard port $script:LandingPagePort already in use" -ForegroundColor Cyan
        return
    }

    if ($DryRun) {
        Write-Host "[DRY RUN] Would start landing page dashboard on port $script:LandingPagePort" -ForegroundColor Yellow
        return
    }

    Write-Host "Starting landing page dashboard on port $script:LandingPagePort..." -ForegroundColor Green

    $landingScript = Join-Path $PSScriptRoot 'landing_page.ps1'
    if (-not (Test-Path -LiteralPath $landingScript)) {
        Write-Host 'Warning: landing_page.ps1 not found' -ForegroundColor Yellow
        return
    }

    try {
        $run = "& $(ConvertTo-PsLiteral $landingScript) -Port $script:LandingPagePort"
        New-TuiosWindow -Name $windowName -WorkingDirectory $PSScriptRoot -EncodedCommand (New-TuiosEncodedCommand $PSScriptRoot 'Dashboard' $run) -Workspace 1
    } catch {
        Write-Host "Warning: could not create the dashboard tuios window: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-PortInUse $script:LandingPagePort) {
            Write-Host "Dashboard running at http://localhost:$script:LandingPagePort" -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "Dashboard window started, but port $script:LandingPagePort is not listening. Check the dashboard tuios window for errors." -ForegroundColor Yellow
}

# Stop the landing page dashboard
function Stop-LandingPage {
    if ($DryRun) { Write-Host '[DRY RUN] Would stop landing page dashboard' -ForegroundColor Yellow; return }
    $stopped = $false

    # Stop tuios window if it exists (this gracefully stops the process)
    if (Test-TuiosWindow $script:LandingPageWindowName) {
        Write-Host 'Stopping landing page dashboard...' -ForegroundColor Cyan
        Stop-TuiosApp $script:LandingPageWindowName
        $stopped = $true
        # Give it a moment to release the port
        Start-Sleep -Seconds 2
    }

    # Only kill port if the tuios window didn't exist but port is still in use (an orphaned process); a normal stop only
    if (-not $stopped -and (Test-PortInUse $script:LandingPagePort)) {
        Write-Host "Killing orphaned process on port $script:LandingPagePort..." -ForegroundColor Cyan
        foreach ($processId in @(Get-PortPids $script:LandingPagePort)) { Stop-ProcessById $processId }
        $stopped = $true
    }

    if ($stopped) { Write-Host 'Dashboard stopped' -ForegroundColor Green }
}

function Test-LandingPageRunning {
    return (Test-TuiosWindow $script:LandingPageWindowName) -or (Test-PortInUse $script:LandingPagePort)
}

# Check if an app is running (by tuios window or port)
function Test-AppRunning {
    param([object]$App)
    if (Test-TuiosWindow ([string](Get-AppField $App 'Name'))) { return $true }
    $port = Get-AppPort $App
    return ($null -ne $port) -and (Test-PortInUse $port)
}

# Display apps table
function Show-Apps {
    Write-Header 'Available Apps'
    Write-Host '────┬────────────────────────────────┬────────────┬────────┬────┬──────────' -ForegroundColor Magenta
    Write-Host ('  # │ {0,-30} │ {1,-10} │ {2,-6} │ {3,-2} │ Status' -f 'Name', 'Type', 'Port', 'WS') -ForegroundColor Magenta
    Write-Host '────┼────────────────────────────────┼────────────┼────────┼────┼──────────' -ForegroundColor Magenta
    # One window listing for the whole table: window name -> workspace
    $workspaces = @{}
    foreach ($window in @(Get-TuiosWindows)) {
        if ($window.PSObject.Properties['custom_name'] -and $window.custom_name) { $workspaces[[string]$window.custom_name] = $window.workspace }
    }
    for ($i = 0; $i -lt $script:Apps.Count; $i++) {
        $app = $script:Apps[$i]
        $name = [string](Get-AppField $app 'Name'); if (-not $name) { $name = 'Unknown' }
        $port = Get-AppPort $app
        $windowName = ConvertTo-TuiosWindowName $name
        $workspace = if ($workspaces.ContainsKey($windowName)) { $workspaces[$windowName] } else { '-' }
        $running = $workspaces.ContainsKey($windowName) -or (($null -ne $port) -and (Test-PortInUse $port))
        Write-Host ('{0,3}' -f ($i + 1)) -ForegroundColor Blue -NoNewline
        Write-Host (' │ {0,-30} │ {1,-10} │ {2,-6} │ {3,-2} │ ' -f $name, (Get-AppDisplayType $app), $(if ($null -ne $port) { $port } else { 'N/A' }), $workspace) -NoNewline
        if ($running) { Write-Host '● running' -ForegroundColor Green } else { Write-Host '○ stopped' -ForegroundColor Red }
    }
    Write-Host '────┴────────────────────────────────┴────────────┴────────┴────┴──────────' -ForegroundColor Magenta
}

# Start a single app
function Start-App {
    param([object]$App)
    $name = [string](Get-AppField $App 'Name')
    $appPath = [string](Get-AppField $App 'AppPath')
    $type = [string](Get-AppField $App 'Type')
    $port = Get-AppPort $App
    $indexPath = [string](Get-AppField $App 'IndexPath')

    # Validate app
    if (-not $name) { Write-Host 'Error: App missing Name' -ForegroundColor Red; return }
    if (-not $appPath -or -not (Test-Path -LiteralPath $appPath -PathType Container)) { Write-Host "Error: AppPath not found: $appPath" -ForegroundColor Red; return }

    # Check if index file exists for web apps
    if ($type -in @('Streamlit', 'Flask', 'Dash') -and $indexPath) {
        $fullIndexPath = if ([IO.Path]::IsPathRooted($indexPath)) { $indexPath } else { Join-Path $appPath $indexPath }
        if (-not (Test-Path -LiteralPath $fullIndexPath -PathType Leaf)) { Write-Host "Error: IndexPath not found: $fullIndexPath" -ForegroundColor Red; return }
    }

    # Resolve working directory
    $workingDir = (Resolve-Path -LiteralPath $appPath).Path

    # Build run command
    try { $runCommand = Get-AppRunCommand -App $App -WorkingDirectory $workingDir }
    catch { Write-Host "Error: Could not build run command for ${name}: $($_.Exception.Message)" -ForegroundColor Red; return }

    if ($DryRun) {
        Write-Host "[DRY RUN] Would start '$name' in '$workingDir'" -ForegroundColor Yellow
        Write-Host "  Command: $runCommand" -ForegroundColor Cyan
        $group = [string](Get-AppField $App 'Group')
        if ($group) { Write-Host "  Placement: $(Format-TuiosPlacement (Get-TuiosGroupPlacement -Apps $script:Apps -App $App)) (group '$group')" -ForegroundColor Cyan }
        return
    }

    # Check if already running
    if (Test-TuiosWindow $name) {
        Write-Host "Warning: '$name' already has a tuios window" -ForegroundColor Yellow
        if (-not (Confirm-Action 'Kill existing window and restart?')) { Write-Host "Skipping $name"; return }
        Remove-TuiosWindow $name
        Start-Sleep -Seconds 1
    } elseif (($null -ne $port) -and (Test-PortInUse $port)) {
        Write-Host "Warning: Port $port already in use" -ForegroundColor Yellow
        if (-not (Confirm-Action "Kill process on port $port and start?")) { Write-Host "Skipping $name"; return }
        $null = Stop-PortProcesses $port
        $null = Wait-PortFree $port 5
    }

    Write-Host "Starting '$name' in tuios..." -ForegroundColor Green

    # Launch in tuios window, on its group's workspace
    try {
        Start-TuiosAppWindow -Apps $script:Apps -App $App -Name $name -WorkingDirectory $workingDir -EncodedCommand (New-TuiosEncodedCommand $workingDir $name $runCommand)
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    Write-Host "Launched '$name' in tuios window" -ForegroundColor Green
}

# Stop a single app
function Stop-App {
    param([object]$App)
    $name = [string](Get-AppField $App 'Name')
    $port = Get-AppPort $App
    if ($DryRun) { Write-Host "[DRY RUN] Would stop '$name'" -ForegroundColor Yellow; return }

    $stopped = $false
    # Stop tuios window first (sends Ctrl+C and closes the window)
    if (Test-TuiosWindow $name) {
        Write-Host "Stopping '$name' tuios window..." -ForegroundColor Cyan
        Stop-TuiosApp $name
        $stopped = $true
    }
    # Also kill any process on the port
    if (($null -ne $port) -and (Test-PortInUse $port)) {
        Write-Host "Killing process on port $port..." -ForegroundColor Cyan
        $null = Stop-PortProcesses $port
        $stopped = $true
    }

    if ($stopped) { Write-Host "Stopped '$name'" -ForegroundColor Green } else { Write-Host "'$name' was not running" -ForegroundColor Yellow }
}

# Restart a single app
function Restart-App {
    param([object]$App)
    $name = [string](Get-AppField $App 'Name')
    if ($DryRun) { Write-Host "[DRY RUN] Would restart '$name'" -ForegroundColor Yellow; return }
    Write-Host "Restarting '$name'..." -ForegroundColor Cyan
    Stop-App $App
    $port = Get-AppPort $App
    if ($null -ne $port) { $null = Wait-PortFree $port 5 }
    Start-App $App
}

# Update a single app (git pull + sync venv + restart)
function Update-App {
    param([object]$App)
    $name = [string](Get-AppField $App 'Name')
    $appPath = [string](Get-AppField $App 'AppPath')
    $packageManager = [string](Get-AppField $App 'PackageManager')
    if ($DryRun) { Write-Host "[DRY RUN] Would update '$name'" -ForegroundColor Yellow; return }

    Write-Host "===== Updating '$name' =====" -ForegroundColor Cyan

    # Stop the app first
    Stop-App $App
    $port = Get-AppPort $App
    if ($null -ne $port) { $null = Wait-PortFree $port 5 }

    if (-not $appPath -or -not (Test-Path -LiteralPath $appPath -PathType Container)) {
        Write-Host "Error: AppPath not found: $appPath" -ForegroundColor Red
        return
    }

    Push-Location -LiteralPath $appPath
    try {
        # Git pull
        if (Test-Path -LiteralPath '.git') {
            Write-Host 'Pulling latest changes from git...' -ForegroundColor Cyan
            git pull
            if ($LASTEXITCODE -eq 0) { Write-Host 'Git pull successful' -ForegroundColor Green } else { Write-Host 'Git pull failed or no changes' -ForegroundColor Yellow }
        } else {
            Write-Host "No git repository found in '$appPath'" -ForegroundColor Yellow
        }

        # Update virtual environment
        if (-not $packageManager) { $packageManager = Get-PackageManager $appPath }
        Write-Host "Updating dependencies with $packageManager..." -ForegroundColor Cyan
        if ($packageManager -eq 'uv') {
            uv sync
            if ($LASTEXITCODE -eq 0) { Write-Host 'Dependencies updated with uv sync' -ForegroundColor Green } else { Write-Host 'Failed to update dependencies' -ForegroundColor Yellow }
        } else {
            # pip - look for requirements.txt
            $requirements = @('requirements.txt', 'requirements/base.txt') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($requirements) {
                $pip = 'pip'
                $venvPath = [string](Get-AppField $App 'VenvPath')
                foreach ($venv in @($venvPath, '.venv', 'venv')) {
                    if (-not $venv) { continue }
                    $candidate = foreach ($relative in @('Scripts/pip.exe', 'bin/pip')) { $path = Join-Path $venv $relative; if (Test-Path -LiteralPath $path) { $path; break } }
                    if ($candidate) { $pip = $candidate; break }
                }
                & $pip install -r $requirements
                if ($LASTEXITCODE -eq 0) { Write-Host 'Dependencies updated with pip' -ForegroundColor Green } else { Write-Host 'Failed to update dependencies' -ForegroundColor Yellow }
            } else {
                Write-Host 'No requirements file found' -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "Update step failed: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }

    # Restart the app
    Write-Host "Starting '$name'..." -ForegroundColor Cyan
    Start-App $App
    Write-Host "Update complete for '$name'" -ForegroundColor Green
}

# Start apps by selection: comma-separated numbers (1-based, 0 for all) or names (ignoring case)
function Start-SelectedApps {
    param([string]$Selection)
    foreach ($item in ($Selection -split ',')) {
        $item = $item.Trim()
        if (-not $item) { continue }
        if ($item -eq '0') {
            foreach ($app in $script:Apps) { Start-App $app; Start-Sleep -Milliseconds 500 }
            return
        }
        $app = if ($item -match '^\d+$') { Get-AppAtIndex $item } else { $script:Apps | Where-Object { ([string](Get-AppField $_ 'Name')) -ieq $item } | Select-Object -First 1 }
        if ($app) { Start-App $app; Start-Sleep -Milliseconds 500 } else { Write-Host "Warning: Could not find app: $item" -ForegroundColor Yellow }
    }
}

# Stop all running apps
function Stop-AllApps {
    if ($DryRun) { Write-Host '[DRY RUN] Would stop all apps' -ForegroundColor Yellow; return }
    Write-Host 'Stopping all apps...' -ForegroundColor Cyan
    foreach ($app in $script:Apps) { if (Test-AppRunning $app) { Stop-App $app } }
    Write-Host 'All apps stopped' -ForegroundColor Green
}

# Run an action on comma-separated indices; 0 runs it on every app
function Invoke-OnSelection {
    param([string]$Target, [scriptblock]$Action, [scriptblock]$AllAction, [string]$Usage)
    if ($Target -notmatch '^[0-9,]+$') { Write-Host $Usage -ForegroundColor Yellow; return }
    foreach ($item in ($Target -split ',')) {
        $item = $item.Trim()
        if (-not $item) { continue }
        if ($item -eq '0') { & $AllAction; continue }
        $app = Get-AppAtIndex $item
        if ($app) { & $Action $app } else { Write-Host "Invalid index: $item" -ForegroundColor Red }
    }
}

function Expand-HomePath {
    param([string]$Path)
    if ($Path -eq '~' -or $Path -match '^~[\\/]') { return $HOME + $Path.Substring(1) }
    return $Path
}

# Add a new app interactively
function Add-NewApp {
    $jsonFile = $script:AppsJsonPath
    Write-Header 'Add New App'

    $appPath = Read-Host 'Enter app path (absolute path)'
    if (-not $appPath -or $appPath -eq 'back') { Write-Host 'Cancelled.'; return }
    $appPath = Expand-HomePath $appPath
    if (-not (Test-Path -LiteralPath $appPath -PathType Container)) { Write-Host "Error: Directory does not exist: $appPath" -ForegroundColor Red; return }
    $appPath = (Resolve-Path -LiteralPath $appPath).Path

    # Get app name (default to directory name)
    $defaultName = Split-Path -Leaf $appPath
    $name = Read-Host "Enter app name [$defaultName]"
    if (-not $name) { $name = $defaultName }
    if (Test-AppNameExists $jsonFile $name) { Write-Host "Error: An app named '$name' already exists" -ForegroundColor Red; return }

    # Detect app type
    $detectedType = Get-DetectedAppType $appPath
    Write-Host "Detected type: $detectedType" -ForegroundColor Cyan
    if ($detectedType -eq 'Unknown') {
        $type = Read-AppType 'Streamlit'
    } else {
        $useDetected = Read-Host "Use detected type '$detectedType'? [Y/n]"
        $type = if (-not $useDetected -or $useDetected -match '^(?i:y|yes)$') { $detectedType } else { Read-AppType $detectedType }
    }
    Write-Host "App type: $type" -ForegroundColor Cyan

    $packageManager = Get-PackageManager $appPath
    Write-Host "Detected package manager: $packageManager" -ForegroundColor Cyan
    $venvPath = Find-Venv $appPath
    if ($venvPath) { Write-Host "Found venv: $venvPath" -ForegroundColor Cyan }

    # Get index path for web apps
    $indexPath = ''
    if ($type -in @('Streamlit', 'Flask', 'Dash')) {
        Write-Host 'Select the main/index Python file:' -ForegroundColor Cyan
        $indexPath = Select-IndexFile $appPath
        if (-not $indexPath) { $indexPath = Read-Host 'Enter index file path (relative to app)' }
    }

    $port = Read-PortNumber

    # Custom apps: the start command
    $customCommand = ''
    if ($type -eq 'Custom') {
        $customCommand = Read-CustomCommand -Port $port
        if (-not $customCommand) { Write-Host 'Error: A Custom app needs a start command' -ForegroundColor Red; return }
    }

    # Workspace layout: entries in one group share a tuios workspace
    $layout = Read-LayoutFields -Group (Get-GroupForAppPath $jsonFile $appPath)

    $newApp = New-AppEntry -Name $name -Type $type -Port $port -AppPath $appPath -IndexPath $indexPath -VenvPath $venvPath -PackageManager $packageManager -CustomCommand $customCommand
    $newApp = Add-LayoutFields $newApp $layout
    Write-Host ''
    Write-Host 'New app configuration:' -ForegroundColor Cyan
    Write-Host (Format-AppJson $newApp)
    Write-Host ''
    $confirm = Read-Host 'Save this app? [Y/n]'
    if (-not $confirm -or $confirm -match '^(?i:y|yes)$') {
        Add-AppToFile $jsonFile $newApp
        Write-Host "App '$name' added successfully!" -ForegroundColor Green
    } else {
        Write-Host 'Cancelled.'
    }
}

# Add a new process (custom command) interactively
function Add-NewProcess {
    $jsonFile = $script:AppsJsonPath
    Write-Header 'Add New Process (Custom Command)'
    Write-Host 'Examples:'
    Write-Host '  - Django mgmt cmd: continuous_cache_update'
    Write-Host '  - Python module: python -m app.db.backup.local_cache_scheduler'
    Write-Host '  - Any script: python scripts/my_task.py'
    Write-Host '  - With settings: TZ=Europe/London python -m app.scheduler'
    Write-Host "  (A web app with a port: use 'aa' and pick Custom)"
    Write-Host ''

    $appPath = Read-Host 'Enter working directory path (absolute path)'
    if (-not $appPath -or $appPath -eq 'back') { Write-Host 'Cancelled.'; return }
    $appPath = Expand-HomePath $appPath
    if (-not (Test-Path -LiteralPath $appPath -PathType Container)) { Write-Host "Error: Directory does not exist: $appPath" -ForegroundColor Red; return }
    $appPath = (Resolve-Path -LiteralPath $appPath).Path

    $defaultName = Split-Path -Leaf $appPath
    $name = Read-Host "Enter process name [$defaultName]"
    if (-not $name) { $name = $defaultName }
    if (Test-AppNameExists $jsonFile $name) { Write-Host "Error: A process/app named '$name' already exists" -ForegroundColor Red; return }

    $customCommand = Read-Host 'Enter command to run'
    if (-not $customCommand) { Write-Host 'Error: Command is required' -ForegroundColor Red; return }

    $packageManager = Get-PackageManager $appPath
    Write-Host "Detected package manager: $packageManager" -ForegroundColor Cyan
    $venvPath = Find-Venv $appPath
    if ($venvPath) { Write-Host "Found venv: $venvPath" -ForegroundColor Cyan }

    # Workspace layout: by default a process joins the app in its folder, in a pane below it
    $folderGroup = Get-GroupForAppPath $jsonFile $appPath
    $folderApp = Get-AppNameForAppPath $jsonFile $appPath
    $defaultGroup = if ($folderGroup) { $folderGroup } else { $folderApp }
    $layout = if ($defaultGroup) { Read-LayoutFields -Group $defaultGroup -PaneSide 'down' -PaneRatio '30' } else { Read-LayoutFields }

    $newApp = New-ProcessEntry -Name $name -AppPath $appPath -CustomCommand $customCommand -VenvPath $venvPath -PackageManager $packageManager
    $newApp = Add-LayoutFields $newApp $layout
    Write-Host ''
    Write-Host 'New process configuration:' -ForegroundColor Cyan
    Write-Host (Format-AppJson $newApp)
    Write-Host ''
    $confirm = Read-Host 'Save this process? [Y/n]'
    if (-not $confirm -or $confirm -match '^(?i:y|yes)$') {
        Add-AppToFile $jsonFile $newApp
        Write-Host "Process '$name' added successfully!" -ForegroundColor Green
        # The group is named after the app in the folder: put that app in it too, so they share the workspace
        if (-not $folderGroup -and $folderApp -and $layout.Group -ceq $folderApp) {
            $confirm = Read-Host "Put '$folderApp' in group '$($layout.Group)' too? [Y/n]"
            if (-not $confirm -or $confirm -match '^(?i:y|yes)$') {
                Set-AppGroupInFile $jsonFile $folderApp $layout.Group
                Write-Host "App '$folderApp' is in group '$($layout.Group)'" -ForegroundColor Green
            }
        }
    } else {
        Write-Host 'Cancelled.'
    }
}

# Prompt for a field, keeping the current value on an empty answer
function Read-Field {
    param([string]$Label, [object]$Current)
    $value = Read-Host "$Label [$Current]"
    if ($value) { return $value }
    return [string]$Current
}

# Edit an existing app or process
function Edit-App {
    param([string]$Target)
    $jsonFile = $script:AppsJsonPath
    if ($Target -notmatch '^\d+$') { Write-Host 'Usage: e <number>' -ForegroundColor Yellow; return }
    $app = Get-AppAtIndex $Target
    if (-not $app) { Write-Host "Invalid index: $Target" -ForegroundColor Red; return }

    $currentName = [string](Get-AppField $app 'Name')
    $currentType = [string](Get-AppField $app 'Type')
    $customCommand = [string](Get-AppField $app 'CustomCommand')

    # A process has a CustomCommand and no Type; Custom (and Django) apps keep their CustomCommand as an app field
    if (-not $currentType -and $customCommand) {
        Write-Header "Edit Process: $currentName"
        Write-Host 'Current configuration:'
        Write-Host (Format-AppJson $app)
        Write-Host ''
        $newName = Read-Field 'Name' $currentName
        $newAppPath = Read-Field 'AppPath' (Get-AppField $app 'AppPath')
        $newCommand = Read-Field 'CustomCommand' $customCommand
        $newVenv = Read-Field 'VenvPath' (Get-AppField $app 'VenvPath')
        $newPackageManager = Read-Field 'PackageManager' (Get-AppField $app 'PackageManager')
        $layout = Read-LayoutFields -Group (Get-AppField $app 'Group') -PaneSide (Get-AppField $app 'PaneSide') -PaneRatio (Get-AppField $app 'PaneRatio') -PaneBeside (Get-AppField $app 'PaneBeside')

        # Build updated process (fields this editor does not ask about, e.g. Port, are kept)
        $updated = New-ProcessEntry -Name $newName -AppPath $newAppPath -CustomCommand $newCommand -VenvPath $newVenv -PackageManager $newPackageManager
        $updated = Add-LayoutFields $updated $layout
        $updated = Merge-UnmanagedFields -Old $app -New $updated -Managed @('Name', 'AppPath', 'CustomCommand', 'VenvPath', 'PackageManager', 'Group', 'PaneSide', 'PaneRatio', 'PaneBeside')
        $label = 'Process'
    } else {
        Write-Header "Edit App: $currentName"
        Write-Host 'Current configuration:'
        Write-Host (Format-AppJson $app)
        Write-Host ''
        $newName = Read-Field 'Name' $currentName
        $newType = Read-Field 'Type (Streamlit/Django/Flask/Dash/Custom)' $currentType
        $newPort = Read-Field 'Port' (Get-AppField $app 'Port')
        $newAppPath = Read-Field 'AppPath' (Get-AppField $app 'AppPath')
        $newIndex = ''
        if ($newType -in @('Streamlit', 'Flask', 'Dash')) { $newIndex = Read-Field 'IndexPath' (Get-AppField $app 'IndexPath') }

        # Custom apps: start command. Django keeps an existing CustomCommand (management command) unchanged.
        $newCommand = ''
        if ($newType -eq 'Custom') {
            $newCommand = Read-CustomCommand -Port $newPort -Current $customCommand
            if (-not $newCommand) { Write-Host 'Error: A Custom app needs a start command' -ForegroundColor Red; return }
        } elseif ($newType -eq 'Django') {
            $newCommand = $customCommand
        }

        $newVenv = Read-Field 'VenvPath' (Get-AppField $app 'VenvPath')
        $newPackageManager = Read-Field 'PackageManager' (Get-AppField $app 'PackageManager')
        $newNginx = Read-Field 'NginxPath (leave empty if none)' (Get-AppField $app 'NginxPath')
        $layout = Read-LayoutFields -Group (Get-AppField $app 'Group') -PaneSide (Get-AppField $app 'PaneSide') -PaneRatio (Get-AppField $app 'PaneRatio') -PaneBeside (Get-AppField $app 'PaneBeside')

        # Build updated app (fields this editor does not ask about, e.g. BasePath, are kept)
        $updated = New-AppEntry -Name $newName -Type $newType -Port $newPort -AppPath $newAppPath -IndexPath $newIndex -VenvPath $newVenv -PackageManager $newPackageManager -NginxPath $newNginx -CustomCommand $newCommand
        $updated = Add-LayoutFields $updated $layout
        $updated = Merge-UnmanagedFields -Old $app -New $updated -Managed @('Name', 'Type', 'Port', 'AppPath', 'IndexPath', 'VenvPath', 'PackageManager', 'NginxPath', 'CustomCommand', 'Group', 'PaneSide', 'PaneRatio', 'PaneBeside')
        $label = 'App'
    }

    Write-Host ''
    Write-Host 'Updated configuration:' -ForegroundColor Cyan
    Write-Host (Format-AppJson $updated)
    Write-Host ''
    $confirm = Read-Host 'Save changes? [Y/n]'
    if (-not $confirm -or $confirm -match '^(?i:y|yes)$') {
        Update-AppInFile $jsonFile $currentName $updated
        Write-Host "$label '$newName' updated successfully!" -ForegroundColor Green
    } else {
        Write-Host 'Cancelled.'
    }
}

# Delete an app
function Remove-App {
    param([string]$Target)
    $jsonFile = $script:AppsJsonPath
    if ($Target -notmatch '^\d+$') { Write-Host 'Usage: d <number>' -ForegroundColor Yellow; return }
    $app = Get-AppAtIndex $Target
    if (-not $app) { Write-Host "Invalid index: $Target" -ForegroundColor Red; return }

    $name = [string](Get-AppField $app 'Name')
    Write-Host "About to delete app: $name" -ForegroundColor Yellow
    Write-Host (Format-AppJson $app)
    Write-Host ''
    $confirm = Read-Host 'Are you sure you want to delete this app? [y/N]'
    if ($confirm -match '^(?i:y|yes)$') {
        # Stop the app if running
        if (Test-TuiosWindow $name) { Stop-TuiosApp $name }
        Remove-AppFromFile $jsonFile $name
        Write-Host "App '$name' deleted successfully!" -ForegroundColor Green
    } else {
        Write-Host 'Cancelled.'
    }
}

# Display network configuration URLs
function Show-NetworkUrls {
    Write-Host ''
    Write-Host 'Detecting network configuration...' -ForegroundColor Cyan
    Write-Host "  Network URL:  $script:NetworkUrl"
    Write-Host "  External URL: $script:ExternalUrl"
    Write-Host "  Generic URL:  $script:GenericUrl"
    if (Test-LandingPageRunning) {
        Write-Host '  Dashboard:    ' -ForegroundColor Green -NoNewline; Write-Host "http://localhost:$script:LandingPagePort " -NoNewline; Write-Host '(running)' -ForegroundColor Green
        Write-Host '  Dashboard:    ' -ForegroundColor Green -NoNewline; Write-Host "${script:NetworkUrl}:$script:LandingPagePort " -NoNewline; Write-Host '(running)' -ForegroundColor Green
        Write-Host '  Dashboard:    ' -ForegroundColor Green -NoNewline; Write-Host "$script:NetworkUrl/app_dashboard/ " -NoNewline; Write-Host '(running)' -ForegroundColor Green
    } else {
        Write-Host '  Dashboard:    ' -ForegroundColor Yellow -NoNewline; Write-Host 'Not running (press D to start)'
    }
}

function Connect-Session {
    Write-Host 'Attaching to tuios session... (Ctrl+B, D to detach)' -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    Connect-TuiosSession
}

# Interactive menu
function Show-InteractiveMenu {
    while ($true) {
        Import-AppsJson
        Show-NetworkUrls
        Show-Apps

        Write-Host ''
        Write-Host 'Commands:' -ForegroundColor Cyan
        Write-Host '  Dashboard'
        Write-Host '    D         - Toggle dashboard (start/stop)'
        Write-Host '  Manage apps'
        Write-Host '    [number(s)] - Start app(s) by index (e.g., 1,2,3) (0 for all)'
        Write-Host '    [name]      - Start app by name'
        Write-Host '    s [num(s)]  - Stop app(s) by index (e.g., 1,2,3) (0 for all)'
        Write-Host '    r [num(s)]  - Restart app(s) by index (e.g., 1,2,3) (0 for all)'
        Write-Host '    u [num(s)]  - Update app(s) from repo (e.g., 1,2,3) (0 for all)'
        Write-Host '  Edit apps.json'
        Write-Host '    aa          - Add a new app (incl. Custom: any start command + port)'
        Write-Host '    ap          - Add a new process (custom command)'
        Write-Host '    e [num]     - Edit by index'
        Write-Host '    d [num(s)]  - Delete app(s) by index (e.g., 1,2,3)'
        Write-Host '  tuios'
        Write-Host '    l           - List tuios windows'
        Write-Host '    t           - Attach to tuios session'
        Write-Host '    t [num]     - Attach and switch to app window'
        Write-Host '  Other'
        Write-Host '    R           - Refresh list'
        Write-Host '    q           - Quit'
        Write-Host ''

        $userInput = Read-Host 'Enter selection'

        # Case-sensitive commands first (before lowercasing)
        if ($userInput -ceq 'D') {
            if (Test-LandingPageRunning) { Stop-LandingPage } else { $script:SkipLandingPage = $false; Start-LandingPage }
            Wait-Enter
            continue
        }
        if ($userInput -ceq 'R') { continue }

        $lower = $userInput.ToLowerInvariant()
        # The argument of a one-letter command: "s 1,2" and "s1,2" both give "1,2"
        $target = if ($lower -match '^[a-z] ') { $userInput.Substring(2) } else { $userInput.Substring([Math]::Min(1, $userInput.Length)) }

        switch -Regex ($lower) {
            '^(q|quit|exit)$' { Write-Host 'Goodbye!'; exit 0 }
            '^(aa|add)$' { Add-NewApp; break }
            '^(ap|process)$' { Add-NewProcess; break }
            '^(l|list)$' { Show-TuiosWindows; break }
            '^t( .*|[0-9].*)$' {
                # Attach and switch to app window by index
                if ($target -match '^\d+$') {
                    $app = Get-AppAtIndex $target
                    if ($app) {
                        $name = [string](Get-AppField $app 'Name')
                        if (Test-TuiosWindow $name) { $null = Select-TuiosWindow $name; Connect-Session }
                        else { Write-Host "Window for '$name' is not running" -ForegroundColor Yellow }
                    } else {
                        Write-Host "Invalid index: $target" -ForegroundColor Red
                    }
                } else {
                    Write-Host 'Usage: t <number>' -ForegroundColor Yellow
                }
                break
            }
            '^(t|attach)$' { Connect-Session; break }
            '^s$' { Write-Host 'Usage: s <number> (0 for all)' -ForegroundColor Yellow; break }
            '^e( .*|[0-9].*)$' { Edit-App $target; break }
            '^d( .*|[0-9].*)$' {
                if ($target -match '^[0-9,]+$') { foreach ($item in ($target -split ',')) { if ($item.Trim()) { Remove-App $item.Trim() } } }
                else { Remove-App $target }
                break
            }
            '^s( .*|[0-9].*)$' {
                if ($target -eq '0') { Stop-AllApps }
                else { Invoke-OnSelection $target { param($a) Stop-App $a } { Stop-AllApps } 'Usage: s <number(s)> (e.g., 1,2,3) (0 for all)' }
                break
            }
            '^r( .*|[0-9].*)$' {
                $restartAll = { Write-Host 'Restarting all apps...' -ForegroundColor Cyan; foreach ($a in $script:Apps) { Restart-App $a } }
                if ($target -eq '0') { & $restartAll }
                else { Invoke-OnSelection $target { param($a) Restart-App $a } $restartAll 'Usage: r <number(s)> (e.g., 1,2,3) (0 for all)' }
                break
            }
            '^u( .*|[0-9].*)$' {
                # Update command (git pull + sync venv + restart)
                $updateAll = { Write-Host 'Updating all apps...' -ForegroundColor Cyan; foreach ($a in $script:Apps) { Update-App $a } }
                if ($target -eq '0') { & $updateAll }
                else { Invoke-OnSelection $target { param($a) Update-App $a } $updateAll 'Usage: u <number(s)> (e.g., 1,2,3) or u 0 for all' }
                break
            }
            default { if ($userInput) { Start-SelectedApps $userInput } }
        }

        Wait-Enter
    }
}

# Main execution
if ($Help) { Show-Usage; exit 0 }

# Handle attach mode first
if ($Attach) { Connect-TuiosSession; exit 0 }

Write-Header 'App Manager (tuios)'
Assert-Dependencies

# Detect URL prefixes
Write-Host 'Detecting network configuration...' -ForegroundColor Cyan
$script:NetworkUrl = Get-NetworkUrlPrefix
$script:ExternalUrl = Get-ExternalUrlPrefix
$script:GenericUrl = Get-GenericUrlPrefix
Write-Host "  Network URL:  $script:NetworkUrl"
Write-Host "  External URL: $script:ExternalUrl"
Write-Host "  Generic URL:  $script:GenericUrl"
Write-Host ''

Import-AppsJson

# Handle landing page dashboard
if ($script:SkipLandingPage) {
    # Stop any existing dashboard if -NoLanding was specified
    if (Test-LandingPageRunning) { Stop-LandingPage }
} elseif ($script:LandingPageEnabled) {
    # Auto-start landing page dashboard if enabled
    Start-LandingPage
}

if ($All) {
    Write-Host 'Starting all apps...' -ForegroundColor Cyan
    Start-SelectedApps '0'
} elseif ($AppName) {
    Write-Host "Starting app: $AppName" -ForegroundColor Cyan
    Start-SelectedApps $AppName
} else {
    Show-InteractiveMenu
}
