#Requires -Version 7.0
<#
.SYNOPSIS
tuios session and window helpers for the PowerShell tuios edition (Windows, Linux and macOS).

.DESCRIPTION
The PowerShell twin of lib/tuios_helpers.sh. Every app runs in a named window of one detached tuios session, driven
through the tuios CLI, which talks to the tuios daemon whether or not a client is attached. Windows are found by name
in `tuios list-windows --json` and then addressed by their full id, so a name is never taken for an index or an id
prefix.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SessionName = if ($env:APP_MANAGER_TUIOS_SESSION) { $env:APP_MANAGER_TUIOS_SESSION } else { 'app_manager' }
$script:PlaceholderName = '_placeholder'

function Get-TuiosCommand {
    $name = if ($env:APP_MANAGER_TUIOS_BIN) { $env:APP_MANAGER_TUIOS_BIN } else { 'tuios' }
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "tuios was not found on PATH. Install it (https://github.com/Gaurav-Gosain/tuios) or set APP_MANAGER_TUIOS_BIN." }
    return $command.Source
}

# Run the tuios CLI; returns its output lines. $LASTEXITCODE is the CLI's exit code.
function Invoke-Tuios {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    $tuios = Get-TuiosCommand
    if ($Quiet) { return @(& $tuios @Arguments 2>$null) }
    return @(& $tuios @Arguments)
}

function Get-TuiosSessionName { return $script:SessionName }

# Same rule as the tmux edition: each of space / : . becomes _, then anything but letters, digits, _ and - is dropped
function ConvertTo-TuiosWindowName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    return ($Name -replace '[ /:.]', '_') -replace '[^A-Za-z0-9_-]', ''
}

# Parse the JSON output of the CLI; $null when it is empty or not JSON
function ConvertFrom-TuiosJson {
    param([string[]]$Lines)
    $text = ($Lines -join "`n").Trim()
    if (-not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# Names of the live sessions (saved sessions of a stopped daemon are left out)
function Get-TuiosSessionNames {
    $lines = Invoke-Tuios -Arguments @('ls', '--json') -Quiet
    # No daemon: `tuios ls` exits 3 and lists the saved sessions, which are not running
    if ($LASTEXITCODE -ne 0) { return @() }
    # A list of sessions, or an object holding one in "sessions"
    $names = foreach ($item in @(ConvertFrom-TuiosJson $lines)) {
        if ($null -eq $item) { continue }
        $sessions = if ($item.PSObject.Properties['sessions']) { @($item.sessions) } else { @($item) }
        foreach ($session in $sessions) {
            if ($null -eq $session -or -not $session.PSObject.Properties['name']) { continue }
            if ($session.PSObject.Properties['saved'] -and $session.saved) { continue }
            [string]$session.name
        }
    }
    return @($names)
}

function Test-TuiosSession { return (@(Get-TuiosSessionNames) -ccontains $script:SessionName) }

# Create the app manager session if it doesn't exist
# Names its first window _placeholder; that window is closed when the first app starts
function Initialize-TuiosSession {
    if (Test-TuiosSession) { return }
    $null = Invoke-Tuios -Arguments @('new', $script:SessionName, '--detach')
    if ($LASTEXITCODE -ne 0) { throw "Unable to create tuios session '$script:SessionName'." }
    $null = Invoke-Tuios -Arguments @('set-window', '-s', $script:SessionName, '--name', $script:PlaceholderName) -Quiet
    Write-Host "Created tuios session: $script:SessionName" -ForegroundColor Green
}

# The windows of the session (empty when there is no session)
function Get-TuiosWindows {
    $lines = Invoke-Tuios -Arguments @('list-windows', '-s', $script:SessionName, '--json') -Quiet
    if ($LASTEXITCODE -ne 0) { return @() }
    $document = ConvertFrom-TuiosJson $lines
    if ($null -eq $document -or -not $document.PSObject.Properties['windows']) { return @() }
    return @($document.windows)
}

function Get-TuiosWindowCustomName {
    param([object]$Window)
    if ($Window.PSObject.Properties['custom_name']) { return [string]$Window.custom_name }
    return ''
}

# Full id of the window with the given name, $null when there is none
function Get-TuiosWindowId {
    param([Parameter(Mandatory)][string]$Name)
    $windowName = ConvertTo-TuiosWindowName $Name
    $window = @(Get-TuiosWindows) | Where-Object { (Get-TuiosWindowCustomName $_) -ceq $windowName } | Select-Object -First 1
    if ($window) { return [string]$window.window_id }
    return $null
}

function Test-TuiosWindow {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-TuiosWindowId $Name)
}

# The script a window runs: banner, the run command, its exit code, then wait for Enter (as the tmux edition does)
function New-TuiosEncodedCommand {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$RunCommand
    )
    $escapedDirectory = $WorkingDirectory -replace "'", "''"
    $escapedTitle = $Title -replace "'", "''"
    $commandText = @"
Set-Location -LiteralPath '$escapedDirectory'
Write-Host '=== Starting: $escapedTitle ===' -ForegroundColor Cyan
Write-Host 'Directory: $escapedDirectory'
Write-Host '---'
`$global:LASTEXITCODE = 0
try {
    $RunCommand
    `$exitCode = if (`$null -eq `$LASTEXITCODE) { 0 } else { `$LASTEXITCODE }
} catch {
    Write-Error `$_
    `$exitCode = 1
}
Write-Host ''
Write-Host "=== App exited with code `$exitCode ===" -ForegroundColor Yellow
Read-Host 'Press Enter to close this window...' | Out-Null
"@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
}

# The pwsh to run in a window. The bare name when pwsh is on PATH: on Windows a Store install's full path (an app
# execution alias under WindowsApps) fails when tuios starts it, as pwsh then reads its own path as a script to run.
function Get-PwshPath {
    if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { return 'pwsh' }
    $current = [Environment]::ProcessPath
    if ($current -and [IO.Path]::GetFileNameWithoutExtension($current) -ieq 'pwsh') { return $current }
    throw 'pwsh was not found on PATH.'
}

function Remove-TuiosPlaceholder {
    $placeholderId = Get-TuiosWindowId $script:PlaceholderName
    if ($placeholderId) { $null = Invoke-Tuios -Arguments @('close-window', '-s', $script:SessionName, $placeholderId) -Quiet }
}

# Create a named window that runs an encoded pwsh command
# Placement: -Workspace N opens it on workspace N; -SplitSide/-SplitTarget split the pane SplitTarget and open it on
# that side (left/right/up/down), taking -SplitRatio percent of its space (default: half)
function New-TuiosWindow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$EncodedCommand,
        [int]$Workspace = 0,
        [string]$SplitSide,
        [string]$SplitTarget,
        [int]$SplitRatio = 0
    )
    Initialize-TuiosSession
    if (Test-TuiosWindow $Name) { throw "Window '$Name' already exists. Use restart to replace it." }
    $windowName = ConvertTo-TuiosWindowName $Name
    # Words after -- are the argv the window runs, with no shell in between
    $run = @('--', (Get-PwshPath), '-NoLogo', '-NoProfile', '-EncodedCommand', $EncodedCommand)
    if ($SplitSide -and $SplitTarget) {
        # A headless session floats its panes; split-window tiles them (move-window --beside is refused there)
        $ratio = if ($SplitRatio -ge 1 -and $SplitRatio -le 99) { @('--ratio', [string]$SplitRatio) } else { @() }
        $null = Invoke-Tuios -Arguments (@('split-window', $SplitSide, '-s', $script:SessionName, '-w', $SplitTarget) + $ratio +
            @('--name', $windowName, '--cwd', $WorkingDirectory, '--no-focus') + $run)
    } else {
        $workspaceArgs = if ($Workspace -ge 1) { @('--workspace', [string]$Workspace) } else { @() }
        $null = Invoke-Tuios -Arguments (@('new-window', '-s', $script:SessionName, $windowName) + $workspaceArgs + @('--cwd', $WorkingDirectory) + $run)
    }
    if ($LASTEXITCODE -ne 0) { throw "Unable to create tuios window '$Name'." }
    # Remove the placeholder once something else is on workspace 1 (closing the session's first window while it is
    # alone there makes tuios pull the other windows onto workspace 1)
    if (-not $SplitSide -and ($Workspace -le 1)) { Remove-TuiosPlaceholder }
}

# The workspaces of the session (empty when there is no session)
function Get-TuiosWorkspaces {
    $lines = Invoke-Tuios -Arguments @('list-workspaces', '-s', $script:SessionName, '--json') -Quiet
    if ($LASTEXITCODE -ne 0) { return @() }
    $document = ConvertFrom-TuiosJson $lines
    if ($null -eq $document -or -not $document.PSObject.Properties['workspaces']) { return @() }
    return @($document.workspaces)
}

# Lowest empty workspace from 2 to 9 (workspace 1 holds the dashboard and the apps with no Group), $null when none
function Get-TuiosFreeWorkspace {
    $free = @(Get-TuiosWorkspaces) | Where-Object { [int]$_.workspace -ge 2 -and [int]$_.window_count -eq 0 } |
        Sort-Object { [int]$_.workspace } | Select-Object -First 1
    if ($free) { return [int]$free.workspace }
    return $null
}

# Label a workspace (no name clears it)
function Set-TuiosWorkspaceName {
    param([Parameter(Mandatory)][int]$Workspace, [string]$Name)
    $arguments = @('set-workspace-name', '-s', $script:SessionName, [string]$Workspace)
    if ($Name) { $arguments += $Name }
    $null = Invoke-Tuios -Arguments $arguments -Quiet
}

# Clear the labels of empty workspaces, so a stopped group leaves no name behind
function Clear-TuiosEmptyWorkspaceNames {
    foreach ($workspace in @(Get-TuiosWorkspaces)) {
        $name = if ($workspace.PSObject.Properties['name']) { [string]$workspace.name } else { '' }
        if ([int]$workspace.window_count -eq 0 -and $name) { Set-TuiosWorkspaceName ([int]$workspace.workspace) }
    }
}

function Get-EntryField {
    param([object]$Entry, [string]$Name)
    $property = $Entry.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# PaneSide of an entry, lower case, '' when it has none or it is not left/right/up/down
function Get-EntryPaneSide {
    param([object]$Entry)
    $side = ([string](Get-EntryField $Entry 'PaneSide')).ToLowerInvariant()
    if ($side -in @('left', 'right', 'up', 'down')) { return $side }
    return ''
}

# PaneRatio of an entry, 0 when it has none or it is not 1-99
function Get-EntryPaneRatio {
    param([object]$Entry)
    $ratio = Get-EntryField $Entry 'PaneRatio'
    if ([string]$ratio -match '^\d+(\.\d+)?$' -and [double]$ratio -ge 1 -and [double]$ratio -le 99) { return [int][Math]::Floor([double]$ratio) }
    return 0
}

# Where an app's window goes (apps.json fields Group, PaneSide, PaneRatio, PaneBeside), the same rules as
# tuios_group_placement:
#   - no Group: workspace 1, with the dashboard
#   - no other pane of its Group running: a workspace of its own (Mode 'group'; the caller picks the lowest empty one)
#   - PaneBeside names a running pane of the group: split that pane on the side PaneSide names (default: right)
#   - else beside the group's main pane (the running member with a Port, else the first running one), split on the
#     side PaneSide names, taking PaneRatio percent. A second pane with the same PaneSide splits the first one across
#     (down/up -> right, left/right -> down), so the main pane keeps its share. An entry with no PaneSide (the app
#     restarting while its scheduler runs) goes on the opposite side of that pane, taking the rest of the space.
# Returns @{ Mode = 'workspace'|'group'|'split'; Workspace; Side; Target; Ratio }
function Get-TuiosGroupPlacement {
    param([object[]]$Apps, [Parameter(Mandatory)][object]$App)
    $group = [string](Get-EntryField $App 'Group')
    if (-not $group) { return @{ Mode = 'workspace'; Workspace = 1 } }

    $appName = [string](Get-EntryField $App 'Name')
    $windows = @(Get-TuiosWindows)
    $running = foreach ($member in @($Apps)) {
        if (([string](Get-EntryField $member 'Group')) -ine $group -or ([string](Get-EntryField $member 'Name')) -ieq $appName) { continue }
        $windowName = ConvertTo-TuiosWindowName ([string](Get-EntryField $member 'Name'))
        $window = $windows | Where-Object { (Get-TuiosWindowCustomName $_) -ceq $windowName } | Select-Object -First 1
        if ($window) { [pscustomobject]@{ Entry = $member; Id = [string]$window.window_id } }
    }
    $running = @($running)
    if ($running.Count -eq 0) { return @{ Mode = 'group' } }

    $anchor = @($running | Where-Object { [string](Get-EntryField $_.Entry 'Port') -match '^\d+$' -and [int](Get-EntryField $_.Entry 'Port') -gt 0 }) + $running | Select-Object -First 1
    $side = Get-EntryPaneSide $App
    $beside = [string](Get-EntryField $App 'PaneBeside')
    $target = if ($beside) { $running | Where-Object { ([string](Get-EntryField $_.Entry 'Name')) -ieq $beside } | Select-Object -First 1 } else { $null }
    if ($target) {
        return @{ Mode = 'split'; Side = $(if ($side) { $side } else { 'right' }); Target = $target.Id; Ratio = (Get-EntryPaneRatio $App) }
    }
    if ($side) {
        $sibling = @($running | Where-Object { $_.Id -ne $anchor.Id -and (Get-EntryPaneSide $_.Entry) -eq $side -and -not (Get-EntryField $_.Entry 'PaneBeside') }) | Select-Object -Last 1
        if ($sibling) {
            $across = if ($side -in @('down', 'up')) { 'right' } else { 'down' }
            return @{ Mode = 'split'; Side = $across; Target = $sibling.Id; Ratio = 0 }
        }
        return @{ Mode = 'split'; Side = $side; Target = $anchor.Id; Ratio = (Get-EntryPaneRatio $App) }
    }
    $anchorSide = Get-EntryPaneSide $anchor.Entry
    if ($anchorSide) {
        $opposite = @{ down = 'up'; up = 'down'; left = 'right'; right = 'left' }[$anchorSide]
        $anchorRatio = Get-EntryPaneRatio $anchor.Entry
        if ($anchorRatio -eq 0) { $anchorRatio = 50 }
        return @{ Mode = 'split'; Side = $opposite; Target = $anchor.Id; Ratio = 100 - $anchorRatio }
    }
    return @{ Mode = 'split'; Side = 'right'; Target = $anchor.Id; Ratio = 0 }
}

# A placement as one line, for -DryRun
function Format-TuiosPlacement {
    param([hashtable]$Placement)
    switch ($Placement.Mode) {
        'split' { return "split $($Placement.Side) $($Placement.Target)" + $(if ($Placement.Ratio) { " $($Placement.Ratio)" } else { '' }) }
        'group' { return 'group' }
        default { return "workspace $($Placement.Workspace)" }
    }
}

# Open an app's window where its Group puts it (see Get-TuiosGroupPlacement); a group that has no running pane gets
# the lowest empty workspace from 2 to 9, labelled with the group name
function Start-TuiosAppWindow {
    param(
        [object[]]$Apps,
        [Parameter(Mandatory)][object]$App,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$EncodedCommand
    )
    Initialize-TuiosSession
    $group = [string](Get-EntryField $App 'Group')
    $placement = Get-TuiosGroupPlacement -Apps $Apps -App $App
    switch ($placement.Mode) {
        'split' {
            Write-Host "Placing '$Name' $($placement.Side) of its group '$group'" -ForegroundColor Cyan
            New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand `
                -SplitSide $placement.Side -SplitTarget $placement.Target -SplitRatio $placement.Ratio
        }
        'group' {
            Clear-TuiosEmptyWorkspaceNames
            $workspace = Get-TuiosFreeWorkspace
            if ($workspace) {
                Write-Host "Opening group '$group' on workspace $workspace" -ForegroundColor Cyan
                New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -Workspace $workspace
                Set-TuiosWorkspaceName -Workspace $workspace -Name $group
            } else {
                Write-Host "Workspaces 2-9 are all in use; opening '$Name' on workspace 1" -ForegroundColor Yellow
                New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -Workspace 1
            }
        }
        default {
            New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -Workspace 1
        }
    }
}

# Run a script block with the helpers pointed at another session
function Invoke-InTuiosSession {
    param([Parameter(Mandatory)][string]$Session, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $saved = $script:SessionName
    $script:SessionName = $Session
    try { & $ScriptBlock } finally { $script:SessionName = $saved }
}

# The dashboard never shares a workspace with the apps:
#   - the manager runs in a tuios pane: the dashboard opens beside it (right, 40%), in the manager's session
#   - else: a workspace of its own in the apps' session, the lowest empty one from 2 to 9, labelled "Dashboard"
function Start-TuiosDashboardWindow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$EncodedCommand
    )
    if ($env:TUIOS_SESSION -and $env:TUIOS_WINDOW_ID) {
        Invoke-InTuiosSession $env:TUIOS_SESSION {
            New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -SplitSide 'right' -SplitTarget $env:TUIOS_WINDOW_ID -SplitRatio 40
        }
        return
    }
    Initialize-TuiosSession
    Clear-TuiosEmptyWorkspaceNames
    $workspace = Get-TuiosFreeWorkspace
    if ($workspace) {
        New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -Workspace $workspace
        Set-TuiosWorkspaceName -Workspace $workspace -Name 'Dashboard'
    } else {
        Write-Host 'Workspaces 2-9 are all in use; opening the dashboard on workspace 1' -ForegroundColor Yellow
        New-TuiosWindow -Name $Name -WorkingDirectory $WorkingDirectory -EncodedCommand $EncodedCommand -Workspace 1
    }
}

# Session that holds the dashboard window: the manager's own session (when it runs in a tuios pane), else the apps'
# session; $null when neither has it
function Get-TuiosDashboardSession {
    param([Parameter(Mandatory)][string]$Name)
    if ($env:TUIOS_SESSION -and (Invoke-InTuiosSession $env:TUIOS_SESSION { Test-TuiosWindow $Name })) { return $env:TUIOS_SESSION }
    if (Test-TuiosWindow $Name) { return $script:SessionName }
    return $null
}

# Send Ctrl+C to a window to gracefully stop the app
function Send-TuiosCtrlC {
    param([Parameter(Mandatory)][string]$Name)
    $windowId = Get-TuiosWindowId $Name
    if (-not $windowId) { Write-Host "Window '$Name' not found" -ForegroundColor Yellow; return $false }
    $null = Invoke-Tuios -Arguments @('send-keys', '-s', $script:SessionName, '-w', $windowId, 'ctrl+c') -Quiet
    return $true
}

# Close a window by name
function Remove-TuiosWindow {
    param([Parameter(Mandatory)][string]$Name)
    $windowId = Get-TuiosWindowId $Name
    if (-not $windowId) { Write-Host "Window '$Name' not found" -ForegroundColor Yellow; return }
    $null = Invoke-Tuios -Arguments @('close-window', '-s', $script:SessionName, $windowId) -Quiet
    Write-Host "Killed window: $Name" -ForegroundColor Green
}

# Stop an app gracefully (Ctrl+C) then close the window
function Stop-TuiosApp {
    param([Parameter(Mandatory)][string]$Name, [switch]$KeepWindow)
    if (-not (Test-TuiosWindow $Name)) { return }
    $null = Send-TuiosCtrlC $Name
    Start-Sleep -Seconds 1
    if (-not $KeepWindow) {
        Remove-TuiosWindow $Name
        # A group that has stopped leaves no label on its workspace
        Clear-TuiosEmptyWorkspaceNames
    }
}

function Show-TuiosWindows {
    if (-not (Test-TuiosSession)) { Write-Host 'No tuios session found' -ForegroundColor Yellow; return }
    Write-Host "tuios windows in session '$script:SessionName':" -ForegroundColor Cyan
    foreach ($window in @(Get-TuiosWindows)) {
        $name = Get-TuiosWindowCustomName $window
        if (-not $name) { $name = foreach ($field in @('display_name', 'title', 'window_id')) { if ($window.PSObject.Properties[$field] -and $window.$field) { [string]$window.$field; break } } }
        $workspace = if ($window.PSObject.Properties['workspace']) { $window.workspace } else { '?' }
        Write-Host ("  {0}: {1} (workspace {2})" -f $window.index, $name, $workspace)
    }
}

# Names of the app windows (the placeholder left out)
function Get-TuiosRunningWindowNames {
    return @(Get-TuiosWindows | ForEach-Object { Get-TuiosWindowCustomName $_ } | Where-Object { $_ -and $_ -ne $script:PlaceholderName })
}

function Stop-AllTuiosWindows {
    if (-not (Test-TuiosSession)) { Write-Host 'No tuios session found' -ForegroundColor Yellow; return }
    foreach ($window in @(Get-TuiosWindows)) {
        if ((Get-TuiosWindowCustomName $window) -eq $script:PlaceholderName) { continue }
        $null = Invoke-Tuios -Arguments @('send-keys', '-s', $script:SessionName, '-w', [string]$window.window_id, 'ctrl+c') -Quiet
    }
    Start-Sleep -Seconds 1
    $null = Invoke-Tuios -Arguments @('kill-session', $script:SessionName) -Quiet
    Write-Host 'Killed all windows and session' -ForegroundColor Green
}

# Show the session: attach, or from inside a tuios pane switch this client to it (tuios refuses a nested attach)
function Connect-TuiosSession {
    if (-not (Test-TuiosSession)) { Write-Host 'No tuios session found. Start some apps first.' -ForegroundColor Yellow; return }
    $tuios = Get-TuiosCommand
    if ($env:TUIOS_SESSION) { & $tuios switch-session $script:SessionName } else { & $tuios attach $script:SessionName }
}

function Select-TuiosWindow {
    param([Parameter(Mandatory)][string]$Name)
    $windowId = Get-TuiosWindowId $Name
    if (-not $windowId) { Write-Host "Window '$Name' not found" -ForegroundColor Yellow; return $false }
    $null = Invoke-Tuios -Arguments @('focus-window', '-s', $script:SessionName, $windowId) -Quiet
    return $true
}

# The machine name used for the config folder: hostname -s on Linux/macOS, COMPUTERNAME on Windows
function Get-MachineName {
    if ($IsWindows -and $env:COMPUTERNAME) { return $env:COMPUTERNAME }
    $name = ''
    try { $name = [string](& hostname -s 2>$null) } catch {}
    if (-not $name) { $name = ([System.Net.Dns]::GetHostName() -split '\.')[0] }
    return $name.Trim()
}

# apps.json lookup, the same order as the bash version:
#   1. $env:APP_MANAGER_APPS_FILE (an error when it does not exist)
#   2. ($env:APP_MANAGER_CONFIG_DIR or ~/code/app_manager_config)/machines/<hostname>/tuios/apps.json
#   3. apps.json next to the scripts, the folder above, or the current folder
# Returns $null when none exists.
function Get-TuiosAppsPath {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    if ($env:APP_MANAGER_APPS_FILE) {
        if (-not (Test-Path -LiteralPath $env:APP_MANAGER_APPS_FILE -PathType Leaf)) { throw "APP_MANAGER_APPS_FILE not found: $env:APP_MANAGER_APPS_FILE" }
        return (Resolve-Path -LiteralPath $env:APP_MANAGER_APPS_FILE).Path
    }
    $configDir = if ($env:APP_MANAGER_CONFIG_DIR) { $env:APP_MANAGER_CONFIG_DIR } else { Join-Path $HOME 'code/app_manager_config' }
    $candidates = @(
        (Join-Path $configDir "machines/$(Get-MachineName)/tuios/apps.json"),
        (Join-Path $ScriptRoot 'apps.json'),
        (Join-Path $ScriptRoot '../apps.json'),
        (Join-Path (Get-Location).Path 'apps.json')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

Export-ModuleMember -Function @(
    'Get-TuiosCommand', 'Invoke-Tuios', 'Get-TuiosSessionName', 'ConvertTo-TuiosWindowName', 'Get-TuiosSessionNames',
    'Test-TuiosSession', 'Initialize-TuiosSession', 'Get-TuiosWindows', 'Get-TuiosWindowId', 'Test-TuiosWindow',
    'New-TuiosEncodedCommand', 'New-TuiosWindow', 'Get-TuiosWorkspaces', 'Get-TuiosFreeWorkspace', 'Set-TuiosWorkspaceName',
    'Clear-TuiosEmptyWorkspaceNames', 'Get-TuiosGroupPlacement', 'Format-TuiosPlacement', 'Start-TuiosAppWindow',
    'Invoke-InTuiosSession', 'Start-TuiosDashboardWindow', 'Get-TuiosDashboardSession',
    'Send-TuiosCtrlC', 'Remove-TuiosWindow', 'Stop-TuiosApp',
    'Show-TuiosWindows', 'Get-TuiosRunningWindowNames', 'Stop-AllTuiosWindows', 'Connect-TuiosSession',
    'Select-TuiosWindow', 'Get-MachineName', 'Get-TuiosAppsPath'
)
