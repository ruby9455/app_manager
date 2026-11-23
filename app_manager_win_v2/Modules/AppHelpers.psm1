#Requires -Version 7.0
<#
.SYNOPSIS
App helpers for app_manager_win_v2: apps.json reading and writing, app type and package manager detection, run
commands, ports and URLs.

.DESCRIPTION
The AppHelpers module of the tuios edition (a PowerShell port of app_manager_tmux/lib/app_helpers.sh and
json_helpers.sh), so this edition behaves the same. Run commands are PowerShell: they run in the pwsh process of a
Windows Terminal pane (Modules/PaneHost.ps1).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppTypes = @('Streamlit', 'Django', 'Dash', 'Flask', 'Custom')
$script:WebIndexTypes = @('Streamlit', 'Flask', 'Dash')

# ---------------------------------------------------------------------------------------------------------------------
# Fields and apps.json
# ---------------------------------------------------------------------------------------------------------------------

function Get-AppField {
    param([object]$App, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $App) { return $null }
    if ($App -is [System.Collections.IDictionary]) { if ($App.Contains($Name)) { return $App[$Name] }; return $null }
    $property = $App.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-HasValue { param([object]$Value) return -not [string]::IsNullOrWhiteSpace([string]$Value) }

# A process is an entry with a CustomCommand and no Type
function Get-AppDisplayType {
    param([object]$App)
    $type = [string](Get-AppField $App 'Type')
    if (-not (Test-HasValue $type) -and (Test-HasValue (Get-AppField $App 'CustomCommand'))) { return 'Process' }
    if (Test-HasValue $type) { return $type }
    return 'Unknown'
}

function Read-AppsFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $text = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Json)
}

function Save-AppsFile {
    param([Parameter(Mandatory)][string]$Path, [object[]]$Apps)
    $json = ConvertTo-Json -InputObject @($Apps) -Depth 10
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

# Supported entries (a known Type, or a CustomCommand), one per name ignoring case, in name order
# (the order jq's unique_by gives the tmux edition, so the numbers match)
function Get-SupportedApps {
    param([object[]]$Apps)
    $byName = @{}
    foreach ($app in @($Apps)) {
        $type = [string](Get-AppField $app 'Type')
        if (-not ($script:AppTypes -ccontains $type) -and -not (Test-HasValue (Get-AppField $app 'CustomCommand'))) { continue }
        $key = ([string](Get-AppField $app 'Name')).ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) { $byName[$key] = $app }
    }
    $keys = [string[]]@($byName.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    return @($keys | ForEach-Object { $byName[$_] })
}

function Test-AppNameExists {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    return [bool](@(Read-AppsFile $Path) | Where-Object { ([string](Get-AppField $_ 'Name')) -ieq $Name } | Select-Object -First 1)
}

function Add-AppToFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$App)
    Save-AppsFile $Path (@(Read-AppsFile $Path) + $App)
}

# Replace the entry with this name (ignoring case)
function Update-AppInFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$App)
    $apps = foreach ($existing in @(Read-AppsFile $Path)) { if (([string](Get-AppField $existing 'Name')) -ieq $Name) { $App } else { $existing } }
    Save-AppsFile $Path @($apps)
}

function Remove-AppFromFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Save-AppsFile $Path @(@(Read-AppsFile $Path) | Where-Object { ([string](Get-AppField $_ 'Name')) -ine $Name })
}

# Build an app entry; optional fields are left out when empty
function New-AppEntry {
    param([string]$Name, [string]$Type, [object]$Port, [string]$AppPath, [string]$IndexPath, [string]$VenvPath,
        [string]$PackageManager, [string]$NginxPath, [string]$CustomCommand)
    $entry = [ordered]@{ Name = $Name; Type = $Type; Port = $(if ([string]$Port -match '^\d+$') { [int]$Port } else { $null }); AppPath = $AppPath }
    if (Test-HasValue $IndexPath) { $entry.IndexPath = $IndexPath }
    if (Test-HasValue $VenvPath) { $entry.VenvPath = $VenvPath }
    if (Test-HasValue $PackageManager) { $entry.PackageManager = $PackageManager }
    if (Test-HasValue $NginxPath) { $entry.NginxPath = $NginxPath }
    if (Test-HasValue $CustomCommand) { $entry.CustomCommand = $CustomCommand }
    return [pscustomobject]$entry
}

# Build a process entry (custom command, no Type)
function New-ProcessEntry {
    param([string]$Name, [string]$AppPath, [string]$CustomCommand, [string]$VenvPath, [string]$PackageManager)
    $entry = [ordered]@{ Name = $Name; AppPath = $AppPath; CustomCommand = $CustomCommand }
    if (Test-HasValue $VenvPath) { $entry.VenvPath = $VenvPath }
    if (Test-HasValue $PackageManager) { $entry.PackageManager = $PackageManager }
    return [pscustomobject]$entry
}

# Keep the fields an editor does not manage (e.g. BasePath, or Port/NginxPath on a process) from the old entry
function Merge-UnmanagedFields {
    param([Parameter(Mandatory)][object]$Old, [Parameter(Mandatory)][object]$New, [Parameter(Mandatory)][string[]]$Managed)
    $merged = [ordered]@{}
    foreach ($property in $Old.PSObject.Properties) { if ($Managed -notcontains $property.Name) { $merged[$property.Name] = $property.Value } }
    foreach ($property in $New.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    return [pscustomobject]$merged
}

function Format-AppJson { param([object]$App) return (ConvertTo-Json -InputObject $App -Depth 10) }

# ---------------------------------------------------------------------------------------------------------------------
# Layout fields (as in the tuios edition): Group, PaneSide, PaneRatio, PaneBeside
#   Group      entries with the same Group open together in one Windows Terminal window
#   PaneSide   left/right/up/down: where the pane goes beside the group's main pane (empty: the main pane, or auto)
#   PaneRatio  1-99: the share in percent it takes of the pane it splits (empty: half)
#   PaneBeside name of the pane of the group to split (empty: the group's app); e.g. for a 2x2 layout
# The other editions ignore these fields and keep them when they edit an entry.
# ---------------------------------------------------------------------------------------------------------------------

# Group of an entry in the same folder, '' when none has one
function Get-GroupForAppPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AppPath)
    $entry = @(Read-AppsFile $Path) | Where-Object { ([string](Get-AppField $_ 'AppPath')) -eq $AppPath -and (Test-HasValue (Get-AppField $_ 'Group')) } | Select-Object -First 1
    if ($entry) { return [string](Get-AppField $entry 'Group') }
    return ''
}

# Name of the web app (an entry with a Type) in the same folder, '' when there is none
function Get-AppNameForAppPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AppPath)
    $entry = @(Read-AppsFile $Path) | Where-Object { ([string](Get-AppField $_ 'AppPath')) -eq $AppPath -and (Test-HasValue (Get-AppField $_ 'Type')) } | Select-Object -First 1
    if ($entry) { return [string](Get-AppField $entry 'Name') }
    return ''
}

# Set the Group of an entry, by name
function Set-AppGroupInFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Group)
    $apps = foreach ($existing in @(Read-AppsFile $Path)) {
        if (([string](Get-AppField $existing 'Name')) -ieq $Name) { $existing | Add-Member -NotePropertyName Group -NotePropertyValue $Group -Force }
        $existing
    }
    Save-AppsFile $Path @($apps)
}

# Interactive: Group, PaneSide, PaneRatio and PaneBeside. An empty answer keeps the value shown; "-" clears it.
# The pane fields are asked only for an entry in a group, and PaneRatio/PaneBeside only with a PaneSide.
# Returns @{ Group; PaneSide; PaneRatio; PaneBeside }.
function Read-LayoutFields {
    param([string]$Group, [string]$PaneSide, [string]$PaneRatio, [string]$PaneBeside)
    $answer = Read-Host "Group (entries in one group share a Windows Terminal window; - for none) [$Group]"
    if ($answer -eq '-') { $Group = '' } elseif ($answer) { $Group = $answer }
    if (-not $Group) { return @{ Group = ''; PaneSide = ''; PaneRatio = ''; PaneBeside = '' } }

    while ($true) {
        $answer = Read-Host "PaneSide beside the group's app (left/right/up/down; - for none, as for the app itself) [$PaneSide]"
        if ($answer -eq '-') { $answer = '' } elseif (-not $answer) { $answer = $PaneSide }
        $answer = ([string]$answer).ToLowerInvariant()
        if (-not $answer -or $answer -in @('left', 'right', 'up', 'down')) { $PaneSide = $answer; break }
        Write-Host 'PaneSide must be left, right, up or down' -ForegroundColor Yellow
    }
    if (-not $PaneSide) { return @{ Group = $Group; PaneSide = ''; PaneRatio = ''; PaneBeside = '' } }

    while ($true) {
        $answer = Read-Host "PaneRatio (percent of the pane it splits, 1-99; - for half) [$PaneRatio]"
        if ($answer -eq '-') { $answer = '' } elseif (-not $answer) { $answer = $PaneRatio }
        if (-not $answer -or ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le 99)) { $PaneRatio = $answer; break }
        Write-Host 'PaneRatio must be a whole number from 1 to 99' -ForegroundColor Yellow
    }
    $answer = Read-Host "PaneBeside (name of the group's pane to split, e.g. for 2x2; - for the group's app) [$PaneBeside]"
    if ($answer -eq '-') { $PaneBeside = '' } elseif ($answer) { $PaneBeside = $answer }
    return @{ Group = $Group; PaneSide = $PaneSide; PaneRatio = $PaneRatio; PaneBeside = $PaneBeside }
}

# Add the layout fields that are set to an entry
function Add-LayoutFields {
    param([Parameter(Mandatory)][object]$App, [hashtable]$Layout)
    if (-not $Layout) { return $App }
    if ($Layout.Group) { $App | Add-Member -NotePropertyName Group -NotePropertyValue $Layout.Group -Force }
    if ($Layout.PaneSide) { $App | Add-Member -NotePropertyName PaneSide -NotePropertyValue $Layout.PaneSide -Force }
    if ($Layout.PaneRatio) { $App | Add-Member -NotePropertyName PaneRatio -NotePropertyValue ([int]$Layout.PaneRatio) -Force }
    if ($Layout.ContainsKey('PaneBeside') -and $Layout.PaneBeside) { $App | Add-Member -NotePropertyName PaneBeside -NotePropertyValue $Layout.PaneBeside -Force }
    return $App
}

# ---------------------------------------------------------------------------------------------------------------------
# Project detection
# ---------------------------------------------------------------------------------------------------------------------

# The PowerShell activation script of a venv (Scripts\ on Windows, bin/ elsewhere)
function Get-VenvActivateScript {
    param([string]$VenvPath)
    if (-not (Test-HasValue $VenvPath)) { return $null }
    foreach ($candidate in @((Join-Path $VenvPath 'Scripts/Activate.ps1'), (Join-Path $VenvPath 'bin/Activate.ps1'))) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Find-Venv {
    param([Parameter(Mandatory)][string]$ProjectDir)
    foreach ($name in @('.venv', 'venv', 'env', '.env')) {
        $venv = Join-Path $ProjectDir $name
        if (Get-VenvActivateScript $venv) { return $venv }
    }
    $found = Get-ChildItem -LiteralPath $ProjectDir -Recurse -Depth 2 -File -Filter 'Activate.ps1' -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -in @('Scripts', 'bin') } | Select-Object -First 1
    if ($found) { return $found.Directory.Parent.FullName }
    return $null
}

function Get-PackageManager {
    param([Parameter(Mandatory)][string]$ProjectDir)
    if ((Test-Path -LiteralPath (Join-Path $ProjectDir 'pyproject.toml')) -and (Get-Command uv -ErrorAction SilentlyContinue)) { return 'uv' }
    return 'pip'
}

# manage.py relative to the project
function Find-ManagePy {
    param([Parameter(Mandatory)][string]$ProjectDir)
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'manage.py')) { return 'manage.py' }
    $found = Get-ChildItem -LiteralPath $ProjectDir -Recurse -Depth 2 -File -Filter 'manage.py' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return [IO.Path]::GetRelativePath($ProjectDir, $found.FullName) }
    return $null
}

function Find-RequirementsFile {
    param([Parameter(Mandatory)][string]$ProjectDir)
    foreach ($candidate in @('requirements.txt', 'requirements/base.txt')) {
        $path = Join-Path $ProjectDir $candidate
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

# Custom = a web app started with its own command (e.g. FastAPI/uvicorn, gunicorn)
function Get-DetectedAppType {
    param([Parameter(Mandatory)][string]$ProjectDir)
    $sources = @()
    $pyproject = Join-Path $ProjectDir 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) { $sources += $pyproject }
    $requirements = Get-ChildItem -LiteralPath $ProjectDir -Recurse -Depth 1 -File -Filter 'requirements.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($requirements) { $sources += $requirements.FullName }
    foreach ($source in $sources) {
        $content = Get-Content -LiteralPath $source -Raw
        if ($content -match '(?i)streamlit') { return 'Streamlit' }
        if ($content -match '(?i)django') { return 'Django' }
        if ($content -match '(?i)flask') { return 'Flask' }
        if ($content -match '(?i)dash') { return 'Dash' }
        if ($content -match '(?i)fastapi|uvicorn|gunicorn') { return 'Custom' }
    }
    return 'Unknown'
}

function Find-PythonFiles {
    param([Parameter(Mandatory)][string]$ProjectDir)
    $files = Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Filter '*.py' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](venv|\.venv|env|\.env|__pycache__|site-packages)[\\/]' } |
        ForEach-Object { $_.FullName }
    $sorted = [string[]]@($files)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

# ---------------------------------------------------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------------------------------------------------

function Read-AppType {
    param([string]$Default = 'Streamlit')
    Write-Host 'Select app type:'
    Write-Host '  1) Streamlit'
    Write-Host '  2) Django'
    Write-Host '  3) Flask'
    Write-Host '  4) Dash'
    Write-Host '  5) Custom (any web app with its own start command, e.g. FastAPI/uvicorn)'
    switch (Read-Host 'Enter choice [1-5]') {
        '1' { return 'Streamlit' }
        '2' { return 'Django' }
        '3' { return 'Flask' }
        '4' { return 'Dash' }
        '5' { return 'Custom' }
        default { return $Default }
    }
}

# The start command of a Custom app
function Read-CustomCommand {
    param([object]$Port, [string]$Current)
    Write-Host "Start command, run in AppPath. {port} is replaced by the app's port ($Port); leading VAR=value" -ForegroundColor Cyan
    Write-Host "settings are set first. With uv, 'uv run' is added unless the command starts with uv. Examples:" -ForegroundColor Cyan
    Write-Host '  uvicorn app.main:app --host 0.0.0.0 --port {port}'
    Write-Host '  TZ=Europe/London python -m myapp.serve --host 0.0.0.0 --port {port}'
    Write-Host '  uv run --directory backend gunicorn -b 0.0.0.0:{port} app:server'
    if (Test-HasValue $Current) {
        $command = Read-Host "CustomCommand [$Current]"
        if (-not (Test-HasValue $command)) { $command = $Current }
    } else {
        $command = Read-Host 'CustomCommand'
    }
    if ((Test-HasValue $command) -and -not $command.Contains('{port}') -and -not $command.Contains([string]$Port)) {
        Write-Host "Note: the command has neither {port} nor $Port; make sure the app listens on port $Port" -ForegroundColor Yellow
    }
    return $command
}

function Select-IndexFile {
    param([Parameter(Mandatory)][string]$ProjectDir)
    $files = @(Find-PythonFiles $ProjectDir)
    if ($files.Count -eq 0) { return '' }
    Write-Host 'Found Python files:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), [IO.Path]::GetRelativePath($ProjectDir, $files[$i])) }
    $selection = Read-Host 'Select index file (number or path)'
    if ($selection -match '^\d+$') {
        $index = [int]$selection - 1
        if ($index -ge 0 -and $index -lt $files.Count) { return [IO.Path]::GetRelativePath($ProjectDir, $files[$index]) }
    }
    return $selection
}

function Get-RandomPort {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $port = Get-Random -Minimum 3000 -Maximum 9000
        if (-not (Test-PortInUse $port)) { return $port }
    }
    return (Get-Random -Minimum 3000 -Maximum 9000)
}

function Read-PortNumber {
    $response = Read-Host 'Assign a random port? [Y/n]'
    if (-not (Test-HasValue $response) -or $response -match '^(?i:y|yes)$') {
        $port = Get-RandomPort
        Write-Host "Assigned port: $port" -ForegroundColor Green
        return $port
    }
    $port = Read-Host 'Enter port number'
    if ($port -notmatch '^\d+$') {
        Write-Host 'Invalid port, generating random...' -ForegroundColor Yellow
        $port = Get-RandomPort
        Write-Host "Assigned port: $port" -ForegroundColor Green
    }
    return [int]$port
}

function Confirm-Action {
    param([string]$Message = 'Are you sure?')
    return (Read-Host "$Message [y/N]") -match '^(?i:y|yes)$'
}

# ---------------------------------------------------------------------------------------------------------------------
# Run commands
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-PsLiteral { param([string]$Value) return "'" + ($Value -replace "'", "''") + "'" }

# Split leading VAR=value assignments off a command, e.g. "TZ=Europe/London uv run app"
# Returns @{ Env = [ordered]@{ TZ = 'Europe/London' }; Command = 'uv run app' }
function Split-EnvPrefix {
    param([string]$Command)
    $assignments = [ordered]@{}
    $rest = [string]$Command
    $pattern = '^([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|''[^'']*''|[^\s"'']*)\s+'
    while ($rest -match $pattern) {
        $value = $Matches[2]
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $assignments[$Matches[1]] = $value
        $rest = $rest.Substring($Matches[0].Length)
    }
    return @{ Env = $assignments; Command = $rest }
}

# Build the PowerShell run command for an app (same rules as build_app_run_command in the tmux edition)
# CustomCommand (Custom type, process, or Django management command) may use {port} for the app's Port and may start
# with VAR=value settings, which become $env:VAR = 'value' before the command (so "uv run" can still be put in front).
function Get-AppRunCommand {
    param([Parameter(Mandatory)][object]$App, [Parameter(Mandatory)][string]$WorkingDirectory)
    $type = [string](Get-AppField $App 'Type')
    $port = [string](Get-AppField $App 'Port')
    $indexPath = [string](Get-AppField $App 'IndexPath')
    $basePath = [string](Get-AppField $App 'BasePath')
    $nginxPath = [string](Get-AppField $App 'NginxPath')
    $venvPath = [string](Get-AppField $App 'VenvPath')
    $packageManager = [string](Get-AppField $App 'PackageManager')
    $customCommand = [string](Get-AppField $App 'CustomCommand')

    # {port} placeholder and leading VAR=value settings in CustomCommand
    $envPrefix = ''
    if (Test-HasValue $customCommand) {
        if ($customCommand.Contains('{port}')) {
            if (-not (Test-HasValue $port)) { throw 'CustomCommand uses {port} but Port is not set' }
            $customCommand = $customCommand.Replace('{port}', $port)
        }
        $split = Split-EnvPrefix $customCommand
        foreach ($name in $split.Env.Keys) { $envPrefix += "`$env:$name = $(ConvertTo-PsLiteral $split.Env[$name]); " }
        $customCommand = $split.Command
    }

    # Auto-detect package manager and venv if not specified
    if (-not (Test-HasValue $packageManager)) { $packageManager = Get-PackageManager $WorkingDirectory }
    if (-not (Test-HasValue $venvPath) -and $packageManager -eq 'pip') { $venvPath = Find-Venv $WorkingDirectory }

    $activate = ''
    if ($packageManager -eq 'pip') {
        $activateScript = Get-VenvActivateScript $venvPath
        if ($activateScript) { $activate = "& $(ConvertTo-PsLiteral $activateScript); " }
    }
    $uv = $packageManager -eq 'uv'

    switch -CaseSensitive ($type) {
        'Streamlit' {
            $effectiveBasePath = $basePath
            # Streamlit needs the upstream base path to match the nginx mount path.
            if (-not (Test-HasValue $effectiveBasePath) -and (Test-HasValue $nginxPath)) { $effectiveBasePath = $nginxPath }
            $effectiveBasePath = $effectiveBasePath.TrimStart('/')
            $portArg = if (Test-HasValue $port) { " --server.port $port" } else { '' }
            $basePathArg = if (Test-HasValue $effectiveBasePath) { " --server.baseUrlPath $(ConvertTo-PsLiteral $effectiveBasePath)" } else { '' }
            $run = if ($uv) { "uv run streamlit run $(ConvertTo-PsLiteral $indexPath)$portArg$basePathArg" } else { "${activate}streamlit run $(ConvertTo-PsLiteral $indexPath)$portArg$basePathArg" }
        }
        'Django' {
            $managePy = Find-ManagePy $WorkingDirectory
            $djangoArgs = if (Test-HasValue $customCommand) { $customCommand } else { 'runserver' + $(if (Test-HasValue $port) { " 0.0.0.0:$port" } else { '' }) }
            $run = if ($uv) { "uv run python $(ConvertTo-PsLiteral $managePy) $djangoArgs" } else { "${activate}python $(ConvertTo-PsLiteral $managePy) $djangoArgs" }
        }
        'Dash' {
            $portArg = if (Test-HasValue $port) { " --server.port $port" } else { '' }
            $run = if ($uv) { "uv run python $(ConvertTo-PsLiteral $indexPath)$portArg" } else { "${activate}python $(ConvertTo-PsLiteral $indexPath)$portArg" }
        }
        'Flask' {
            $hostPortArg = if (Test-HasValue $port) { " --host=0.0.0.0 --port $port" } else { '' }
            $flaskEnv = "`$env:FLASK_APP = $(ConvertTo-PsLiteral $indexPath); `$env:FLASK_ENV = 'development'; "
            $run = if ($uv) { "${flaskEnv}uv run flask run$hostPortArg" } else { "${flaskEnv}${activate}flask run$hostPortArg" }
        }
        default {
            # Custom type (web app with its own start command) or no Type (process): run CustomCommand
            if (Test-HasValue $customCommand) {
                # A Custom app's command is always a full command. Otherwise check if it looks like one (starts with
                # python, uv, etc., or is a path) or if it's just a Django management command name
                $looksFull = $customCommand -cmatch '^(python|py\s|uv|pip|bash|sh|pwsh|\.[\\/]|[^\\/\s]*[\\/]\S*)'
                $managePy = if ($type -ne 'Custom' -and -not $looksFull) { Find-ManagePy $WorkingDirectory } else { $null }
                if ($managePy) {
                    # Looks like a Django management command (single word or with args)
                    $run = if ($uv) { "uv run python $(ConvertTo-PsLiteral $managePy) $customCommand" } else { "${activate}python $(ConvertTo-PsLiteral $managePy) $customCommand" }
                } elseif ($uv -and $customCommand -notmatch '^uvx?\s') {
                    # Full command - run in the project env, unless it already starts with uv/uvx
                    $run = "uv run $customCommand"
                } else {
                    $run = "$activate$customCommand"
                }
            } elseif ($type -eq 'Custom') {
                throw 'Custom app needs a CustomCommand'
            } else {
                throw "Unsupported app type: $type"
            }
        }
    }

    return "$envPrefix$run"
}

# ---------------------------------------------------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------------------------------------------------

function Test-PortInUse {
    param([Parameter(Mandatory)][int]$Port)
    if ($IsWindows) {
        return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0
    }
    if (Get-Command ss -ErrorAction SilentlyContinue) {
        return [bool](@(ss -tuln 2>$null) -match ":$Port\b")
    }
    if (Get-Command lsof -ErrorAction SilentlyContinue) {
        $null = lsof -nP "-iTCP:$Port" -sTCP:LISTEN 2>$null
        return $LASTEXITCODE -eq 0
    }
    if (Get-Command netstat -ErrorAction SilentlyContinue) {
        return [bool](@(netstat -an 2>$null) -match '(?i)listen' -match "[.:]$Port\s")
    }
    return $false
}

function Get-PortPids {
    param([Parameter(Mandatory)][int]$Port)
    if ($IsWindows) {
        return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -gt 0 })
    }
    if (Get-Command lsof -ErrorAction SilentlyContinue) { return @(lsof -ti ":$Port" 2>$null | ForEach-Object { [int]$_ }) }
    if (Get-Command ss -ErrorAction SilentlyContinue) {
        return @(ss -tulnp 2>$null | Where-Object { $_ -match ":$Port\b" } | ForEach-Object { [regex]::Matches($_, 'pid=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } } | Select-Object -Unique)
    }
    return @()
}

# Stop a process: SIGTERM on Linux/macOS (the native kill, which lets it clean up), or a forced stop
function Stop-ProcessById {
    param([Parameter(Mandatory)][int]$Id, [switch]$Force)
    if ($IsWindows -or $Force) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue; return }
    $nativeKill = Get-Command kill -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nativeKill) { & $nativeKill.Source $Id 2>$null } else { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
}

# Stop the processes on a port: a normal stop, then a forced one after a second
function Stop-PortProcesses {
    param([Parameter(Mandatory)][int]$Port)
    $pids = @(Get-PortPids $Port)
    if ($pids.Count -eq 0) { return $false }
    Write-Host "Killing processes on port ${Port}: $($pids -join ' ')"
    $pids | ForEach-Object { Stop-ProcessById $_ }
    if (-not $IsWindows) {
        Start-Sleep -Seconds 1
        $pids | ForEach-Object { Stop-ProcessById $_ -Force }
    }
    return $true
}

function Wait-PortFree {
    param([Parameter(Mandatory)][int]$Port, [int]$Seconds = 10)
    $elapsed = 0
    while ((Test-PortInUse $Port) -and $elapsed -lt $Seconds) { Start-Sleep -Seconds 1; $elapsed++ }
    return -not (Test-PortInUse $Port)
}

# ---------------------------------------------------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------------------------------------------------

# The primary local IPv4 address: an interface that is up, with a default gateway first
function Get-NetworkUrlPrefix {
    try {
        $candidates = foreach ($interface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($interface.OperationalStatus -ne 'Up' -or $interface.NetworkInterfaceType -eq 'Loopback') { continue }
            $properties = $interface.GetIPProperties()
            $hasGateway = $false
            try { $hasGateway = @($properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0 } catch {}
            foreach ($address in $properties.UnicastAddresses) {
                $ip = $address.Address
                if ($ip.AddressFamily -ne 'InterNetwork') { continue }
                $text = $ip.ToString()
                if ($text -match '^(127\.|169\.254\.)') { continue }
                [pscustomobject]@{ Ip = $text; Gateway = $hasGateway }
            }
        }
        $best = @($candidates) | Sort-Object -Property @{ Expression = 'Gateway'; Descending = $true } | Select-Object -First 1
        if ($best) { return "http://$($best.Ip)" }
    } catch {}
    if ($env:APP_MGMT_NETWORK_URL) { return $env:APP_MGMT_NETWORK_URL }
    return 'http://127.0.0.1'
}

function Get-ExternalUrlPrefix {
    param([int]$TimeoutSec = 5)
    foreach ($service in @('https://api.ipify.org?format=text', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = ([string](Invoke-RestMethod -Uri $service -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop)).Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return "http://$ip" }
        } catch {}
    }
    if ($env:APP_MGMT_EXTERNAL_URL) { return $env:APP_MGMT_EXTERNAL_URL }
    return Get-NetworkUrlPrefix
}

function Get-GenericUrlPrefix { return 'http://localhost' }

Export-ModuleMember -Function @(
    'Get-AppField', 'Test-HasValue', 'Get-AppDisplayType', 'Read-AppsFile', 'Save-AppsFile', 'Get-SupportedApps',
    'Test-AppNameExists', 'Add-AppToFile', 'Update-AppInFile', 'Remove-AppFromFile', 'New-AppEntry', 'New-ProcessEntry',
    'Merge-UnmanagedFields', 'Format-AppJson', 'Get-GroupForAppPath', 'Get-AppNameForAppPath', 'Set-AppGroupInFile',
    'Read-LayoutFields', 'Add-LayoutFields', 'Get-VenvActivateScript', 'Find-Venv', 'Get-PackageManager',
    'Find-ManagePy', 'Find-RequirementsFile', 'Get-DetectedAppType', 'Find-PythonFiles', 'Read-AppType',
    'Read-CustomCommand', 'Select-IndexFile', 'Get-RandomPort', 'Read-PortNumber', 'Confirm-Action',
    'ConvertTo-PsLiteral', 'Split-EnvPrefix', 'Get-AppRunCommand', 'Test-PortInUse', 'Get-PortPids', 'Stop-ProcessById',
    'Stop-PortProcesses', 'Wait-PortFree', 'Get-NetworkUrlPrefix', 'Get-ExternalUrlPrefix', 'Get-GenericUrlPrefix'
)
