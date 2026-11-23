#Requires -Version 7.0
<#
.SYNOPSIS
Windows Terminal pane helpers for app_manager_win_v2: the tuios edition's sessions, workspaces and panes, on Windows
Terminal windows, tabs and split panes.

.DESCRIPTION
Windows Terminal (wt.exe) can open a tab, select a tab by its index, and split or focus a pane of the selected tab by
its id, but it cannot list, close or send keys to panes. So the manager keeps a registry of the panes it starts, and
each pane runs PaneHost.ps1, which records its process and window in the registry and stops the app itself when asked:

- Everything opens in the home window: the Windows Terminal window the manager runs in (wt -w 0, the most recently
  activated window, after bringing it to the front), else the window named after the session ('app_manager').
- An app with no Group opens as a tab of it.
- A Group opens as a tab of its own, its panes split as PaneSide/PaneRatio/PaneBeside say (the same rules as the tuios
  edition). Pane ids count up per tab and survive a sibling closing, so the registry keeps each pane's id and the next
  id of each group's tab. Before a split the group's tab is selected: tabs have no names, so focus-tab tries their
  indexes and UI Automation, which shows the panes of the selected tab only (by their --title), tells which one it is.
- After a launch the manager's tab is selected again (found by its pane's UI Automation RuntimeId).
- Stopping writes <pane>.stop; the pane sends Ctrl+C to its console and exits 0, and Windows Terminal closes it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SessionName = if ($env:APP_MANAGER_WT_SESSION) { $env:APP_MANAGER_WT_SESSION } else { 'app_manager' }
$script:PaneHostPath = Join-Path $PSScriptRoot 'PaneHost.ps1'
# A pane that has not reported in after this long is taken as failed to start
$script:PendingSeconds = 60
# The Windows Terminal window the manager runs in (Initialize-WtHome): @{ Handle; ManagerPane = UIA RuntimeId }
$script:HomeWindow = $null
# Last known tab index of the manager's pane in the home window
$script:ManagerTabIndex = $null

function Get-WtCommand {
    $name = if ($env:APP_MANAGER_WT_BIN) { $env:APP_MANAGER_WT_BIN } else { 'wt' }
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'Windows Terminal (wt.exe) was not found on PATH. Install it (winget install Microsoft.WindowsTerminal) or set APP_MANAGER_WT_BIN.' }
    return $command.Source
}

function Get-WtSessionName { return $script:SessionName }

# Same rule as the tmux and tuios editions: each of space / : . becomes _, then anything but letters, digits, _ and -
# is dropped
function ConvertTo-WtPaneName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    return ($Name -replace '[ /:.]', '_') -replace '[^A-Za-z0-9_-]', ''
}

# The named window used when the manager does not run in Windows Terminal
function Get-WtWindowName { return $script:SessionName }

# ---------------------------------------------------------------------------------------------------------------------
# wt.exe
# ---------------------------------------------------------------------------------------------------------------------

# wt splits its command line on ';' (even inside an argument); '\;' is a literal one. The ';' items are separators.
function ConvertTo-WtArguments {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
    return [string[]]@($Arguments | ForEach-Object { if ($_ -ceq ';') { $_ } else { $_.Replace(';', '\;') } })
}

# Run wt.exe with these arguments, passed as they are (no shell in between). wt hands them to the terminal and returns.
function Invoke-Wt {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $info = [System.Diagnostics.ProcessStartInfo]::new((Get-WtCommand))
    $info.UseShellExecute = $false
    foreach ($argument in (ConvertTo-WtArguments $Arguments)) { $info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($info)
    $null = $process.WaitForExit(15000)
}

# The pwsh to run in a pane. The bare name when pwsh is on PATH: a Store install's full path is an app execution alias
# under WindowsApps, which is better left to PATH lookup.
function Get-PwshPath {
    if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { return 'pwsh' }
    $current = [Environment]::ProcessPath
    if ($current -and [IO.Path]::GetFileNameWithoutExtension($current) -ieq 'pwsh') { return $current }
    throw 'pwsh was not found on PATH.'
}

# wt arguments (after -w <window>) that open a pane running PaneHost.ps1 for a registry entry. Modes:
#   tab       a new tab
#   grouptab  a new tab (the first pane of a group: its tab)
#   split     split pane -Target of the selected tab on -Side (left/right/up/down), the new pane taking -Ratio percent
#             (0: half)
#   beside    right of the focused pane (the manager's), taking -Ratio percent; the focus goes back to that pane
# Windows Terminal splits only down (-H) and right (-V); up and left split down/right and then swap the two panes, so
# the new pane, now in the original's place, gets the original's share: split with 100 - Ratio.
function New-WtLaunchArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('tab', 'grouptab', 'split', 'beside')][string]$Mode,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StateFile,
        [string]$Side = 'right',
        [object]$Target,
        [int]$Ratio = 0
    )
    $pane = @('--title', $Title, '--suppressApplicationTitle', '-d', $WorkingDirectory, '--',
        (Get-PwshPath), '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:PaneHostPath, '-StateFile', $StateFile)
    switch ($Mode) {
        { $_ -in @('tab', 'grouptab') } { return [string[]](@('new-tab') + $pane) }
        'beside' {
            $size = if ($Ratio -ge 1 -and $Ratio -le 99) { @('-s', (ConvertTo-WtSize $Ratio)) } else { @() }
            return [string[]](@('split-pane', '-V') + $size + $pane + @(';', 'move-focus', 'left'))
        }
        'split' {
            $swap = @()
            switch ($Side) {
                'down' { $flag = '-H'; $share = $Ratio }
                'right' { $flag = '-V'; $share = $Ratio }
                'up' { $flag = '-H'; $share = $(if ($Ratio) { 100 - $Ratio } else { 0 }); $swap = @(';', 'swap-pane', 'up') }
                'left' { $flag = '-V'; $share = $(if ($Ratio) { 100 - $Ratio } else { 0 }); $swap = @(';', 'swap-pane', 'left') }
                default { throw "Unknown pane side: $Side" }
            }
            $size = if ($share -ge 1 -and $share -le 99) { @('-s', (ConvertTo-WtSize $share)) } else { @() }
            return [string[]](@('focus-pane', '-t', [string]$Target, ';', 'split-pane', $flag) + $size + $pane + $swap)
        }
    }
}

function ConvertTo-WtSize { param([int]$Percent) return ($Percent / 100).ToString([cultureinfo]::InvariantCulture) }

# ---------------------------------------------------------------------------------------------------------------------
# Windows: the home window, addressing a window, and what UI Automation shows of it
# ---------------------------------------------------------------------------------------------------------------------

function Initialize-WtWin32 {
    if ('AppManagerWt.Win32' -as [type]) { return }
    Add-Type -Namespace AppManagerWt -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
'@
}

function Initialize-WtUia {
    if ('System.Windows.Automation.AutomationElement' -as [type]) { return }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
}

# The panes UI Automation shows in a window: those of its selected tab, @{ Name = title given with --title (or the
# title it started with); RuntimeId }
function Get-WtVisiblePanes {
    param([object]$Handle)
    if (-not $Handle) { return @() }
    Initialize-WtUia
    try {
        $window = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][int64]$Handle)
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
        return @(foreach ($control in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            [pscustomobject]@{ Name = [string]$control.Current.Name; RuntimeId = ($control.GetRuntimeId()) -join '.' }
        })
    } catch { return @() }
}

# Record the home window: the Windows Terminal window this process runs in, and its pane (the focused one, else the
# one titled 'Manager', else the only one), so the manager's tab can be found again. Outside Windows Terminal there is
# none and the session's named window is used. -Handle/-ManagerPane set it directly (tests); -Reset clears it.
function Initialize-WtHome {
    param([object]$Handle, [string]$ManagerPane, [switch]$Reset)
    $script:HomeWindow = $null
    $script:ManagerTabIndex = $null
    if ($Reset) { return $null }
    if (-not $Handle) {
        if (-not $env:WT_SESSION) { return $null }
        Initialize-WtWin32
        $Handle = [AppManagerWt.Win32]::GetAncestor([AppManagerWt.Win32]::GetConsoleWindow(), 3).ToInt64()
        if (-not $Handle) { return $null }
        $visible = @(Get-WtVisiblePanes $Handle)
        try {
            $focused = ([System.Windows.Automation.AutomationElement]::FocusedElement.GetRuntimeId()) -join '.'
            $ManagerPane = @($visible | Where-Object RuntimeId -ceq $focused | ForEach-Object RuntimeId) | Select-Object -First 1
        } catch {}
        if (-not $ManagerPane) { $ManagerPane = @($visible | Where-Object Name -ceq 'Manager' | ForEach-Object RuntimeId) | Select-Object -First 1 }
        if (-not $ManagerPane -and $visible.Count -eq 1) { $ManagerPane = $visible[0].RuntimeId }
    }
    $script:HomeWindow = [pscustomobject]@{ Handle = [int64]$Handle; ManagerPane = $ManagerPane }
    return $script:HomeWindow
}

function Get-WtHome { return $script:HomeWindow }

# Where panes open: @{ Name = a window name for wt -w; Handle = its window handle, when known }. The home window has no
# name: it is addressed as -w 0 once it is the most recently activated window.
function Get-WtHomeTarget {
    if ($script:HomeWindow) { return @{ Name = $null; Handle = $script:HomeWindow.Handle } }
    $pane = @(Get-WtPanes | Where-Object { $_.Running -and $_.WindowHandle -and ([string](Get-EntryField $_ 'Window')) -ceq $script:SessionName }) | Select-Object -First 1
    return @{ Name = $script:SessionName; Handle = $(if ($pane) { [int64]$pane.WindowHandle } else { $null }) }
}

# The window a registered pane is in, as a target
function Get-WtPaneTarget {
    param([Parameter(Mandatory)][object]$Pane)
    $homeTarget = Get-WtHomeTarget
    $handle = Get-EntryField $Pane 'WindowHandle'
    if (-not $handle -or ($homeTarget.Handle -and [int64]$handle -eq [int64]$homeTarget.Handle)) { return $homeTarget }
    $name = [string](Get-EntryField $Pane 'Window')
    return @{ Name = $(if ($name) { $name } else { $null }); Handle = [int64]$handle }
}

# The -w argument for a target
function Get-WtTargetArguments {
    param([Parameter(Mandatory)][hashtable]$Target)
    if ($Target.Name) { return [string[]]@('-w', $Target.Name) }
    return [string[]]@('-w', '0')
}

# Run wt commands in a target window. A window with no name is made the most recently activated one first (-w 0).
function Invoke-WtTarget {
    param([Parameter(Mandatory)][hashtable]$Target, [Parameter(Mandatory)][string[]]$Arguments)
    if (-not $Target.Name -and -not (Show-WtWindow $Target.Handle)) {
        Write-Host 'Warning: could not bring the Windows Terminal window to the front; using the most recently used one' -ForegroundColor Yellow
    }
    Invoke-Wt ((Get-WtTargetArguments $Target) + $Arguments)
}

# Bring a Windows Terminal window to the front (restored if minimized, else left as it is)
function Show-WtWindow {
    param([object]$Handle)
    if (-not $Handle) { return $false }
    Initialize-WtWin32
    $hwnd = [IntPtr][int64]$Handle
    if (-not [AppManagerWt.Win32]::IsWindow($hwnd)) { return $false }
    if ([AppManagerWt.Win32]::IsIconic($hwnd)) { $null = [AppManagerWt.Win32]::ShowWindow($hwnd, 9) }
    return [AppManagerWt.Win32]::SetForegroundWindow($hwnd)
}

# ---------------------------------------------------------------------------------------------------------------------
# Tabs: Windows Terminal selects a tab by index only, and UI Automation shows the panes of the selected tab only
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-WtPaneSetKey { param([object[]]$Panes) return (@($Panes | ForEach-Object { [string]$_.RuntimeId } | Sort-Object) -join '|') }

# Read the visible panes until they differ from -Before (the tab switched), or -TimeoutMs passes (the tab was already
# selected, or the index is past the last tab)
function Wait-WtVisibleChange {
    param([string]$Before, [Parameter(Mandatory)][scriptblock]$Read, [int]$TimeoutMs = 800)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $visible = @(& $Read)
        if ($visible.Count -gt 0 -and (ConvertTo-WtPaneSetKey $visible) -cne $Before) {
            Start-Sleep -Milliseconds 100
            return @(& $Read)
        }
        if ([DateTime]::UtcNow -ge $deadline) { return $visible }
        Start-Sleep -Milliseconds 50
    }
}

# True when the visible panes include one titled in -Names or with a RuntimeId in -RuntimeIds
function Test-WtPanesMatch {
    param([object[]]$Visible, [string[]]$Names, [string[]]$RuntimeIds)
    foreach ($pane in @($Visible)) {
        if (($Names -and [string]$pane.Name -cin $Names) -or ($RuntimeIds -and [string]$pane.RuntimeId -cin $RuntimeIds)) { return $true }
    }
    return $false
}

# Select the tab of -Target showing a pane titled in -Names (or with a RuntimeId in -RuntimeIds). The selected tab is
# checked first, then -Hint (its last known index), then indexes 0, 1, 2... up to -Max, stopping when an index shows the
# same panes as the one before (past the last tab). Returns @{ Found; Index } (Index is -Hint when the tab was already
# selected). -Select { param($Index) } and -Read { } replace the wt and UI Automation calls in tests.
function Find-WtTab {
    param(
        [hashtable]$Target,
        [string[]]$Names,
        [string[]]$RuntimeIds,
        [object]$Hint,
        [int]$Max = 30,
        [scriptblock]$Select,
        [scriptblock]$Read,
        [int]$TimeoutMs = 800
    )
    if (-not $Read) { $Read = { Get-WtVisiblePanes $Target.Handle } }
    $visible = @(& $Read)
    if (Test-WtPanesMatch $visible $Names $RuntimeIds) { return @{ Found = $true; Index = $Hint } }

    $order = [System.Collections.Generic.List[int]]::new()
    if ($null -ne $Hint -and [int]$Hint -ge 0 -and [int]$Hint -lt $Max) { $order.Add([int]$Hint) }
    for ($i = 0; $i -lt $Max; $i++) { if (-not $order.Contains($i)) { $order.Add($i) } }
    $last = ConvertTo-WtPaneSetKey $visible
    $previousIndex = $null; $previousKey = $null
    foreach ($index in $order) {
        if ($Select) { & $Select $index } else { Invoke-WtTarget $Target @('focus-tab', '-t', [string]$index) }
        $visible = @(Wait-WtVisibleChange -Before $last -Read $Read -TimeoutMs $TimeoutMs)
        $key = ConvertTo-WtPaneSetKey $visible
        if (Test-WtPanesMatch $visible $Names $RuntimeIds) {
            # Still the same tab a moment later: not a stale read of the tab before
            Start-Sleep -Milliseconds 150
            if (Test-WtPanesMatch @(& $Read) $Names $RuntimeIds) { return @{ Found = $true; Index = $index } }
        }
        if ($null -ne $previousIndex -and $index -eq $previousIndex + 1 -and $key -ceq $previousKey) { break }
        $previousIndex = $index; $previousKey = $key; $last = $key
    }
    return @{ Found = $false; Index = $null }
}

# The tab index last found for a group's tab, $null when unknown
function Get-WtTabState {
    param([Parameter(Mandatory)][string]$Group)
    $state = Read-WtJson (Join-Path (Get-WtStateDir) "tabs/$(ConvertTo-WtPaneName $Group).json")
    if (-not $state) { return [pscustomobject]@{ NextPaneId = 0; TabIndex = $null } }
    return [pscustomobject]@{ NextPaneId = [int](Get-EntryField $state 'NextPaneId'); TabIndex = (Get-EntryField $state 'TabIndex') }
}

function Set-WtTabState {
    param([Parameter(Mandatory)][string]$Group, [object]$NextPaneId, [object]$TabIndex, [switch]$ClearTabIndex)
    $state = Get-WtTabState $Group
    if ($null -ne $NextPaneId) { $state.NextPaneId = [int]$NextPaneId }
    if ($ClearTabIndex) { $state.TabIndex = $null } elseif ($null -ne $TabIndex) { $state.TabIndex = [int]$TabIndex }
    Write-WtJson (Join-Path (Get-WtStateDir) "tabs/$(ConvertTo-WtPaneName $Group).json") ([ordered]@{ Group = $Group; NextPaneId = $state.NextPaneId; TabIndex = $state.TabIndex })
}

# The window of a group's running panes (home when none runs)
function Get-WtGroupTarget {
    param([Parameter(Mandatory)][string]$Group)
    $member = @(Get-WtPanes | Where-Object { $_.Running -and ([string](Get-EntryField $_ 'Group')) -ieq $Group -and $_.WindowHandle }) | Select-Object -First 1
    if (-not $member) { return Get-WtHomeTarget }
    return Get-WtPaneTarget $member
}

# Select a group's tab (found by its running panes' titles) and remember its index; $true when found
function Select-WtGroupTab {
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][hashtable]$Target)
    $names = @(Get-WtPanes | Where-Object { $_.Running -and ([string](Get-EntryField $_ 'Group')) -ieq $Group } | ForEach-Object { [string]$_.Name })
    if ($names.Count -eq 0) { return $false }
    $result = Find-WtTab -Target $Target -Names $names -Hint (Get-WtTabState $Group).TabIndex
    if ($result.Found -and $null -ne $result.Index) { Set-WtTabState $Group -TabIndex $result.Index }
    return [bool]$result.Found
}

# Select the manager's tab again (after a launch selected another); $false when there is no home pane or it is not found
function Select-WtManagerTab {
    if (-not $script:HomeWindow -or -not $script:HomeWindow.ManagerPane) { return $false }
    $result = Find-WtTab -Target (Get-WtHomeTarget) -RuntimeIds @([string]$script:HomeWindow.ManagerPane) -Hint $script:ManagerTabIndex
    if ($result.Found -and $null -ne $result.Index) { $script:ManagerTabIndex = $result.Index }
    return [bool]$result.Found
}

# ---------------------------------------------------------------------------------------------------------------------
# Pane registry: <state>/<session>/panes/<pane>.json, written by the manager and completed by PaneHost.ps1
# ---------------------------------------------------------------------------------------------------------------------

function Get-WtStateDir {
    $root = if ($env:APP_MANAGER_WT_STATE_DIR) { $env:APP_MANAGER_WT_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'app_manager_wt' }
    $dir = Join-Path $root $script:SessionName
    foreach ($sub in @('panes', 'tabs')) { $null = New-Item -ItemType Directory -Force (Join-Path $dir $sub) }
    return $dir
}

function Get-WtPaneFile {
    param([Parameter(Mandatory)][string]$Name)
    return Join-Path (Get-WtStateDir) "panes/$(ConvertTo-WtPaneName $Name).json"
}

function Get-WtStopFile {
    param([Parameter(Mandatory)][string]$PaneFile)
    return [IO.Path]::ChangeExtension($PaneFile, '.stop')
}

function Read-WtJson {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-WtJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 5), [System.Text.UTF8Encoding]::new($false))
}

function Get-EntryField {
    param([object]$Entry, [string]$Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) { if ($Entry.Contains($Name)) { return $Entry[$Name] }; return $null }
    $property = $Entry.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# The pane's host process is alive, and is the one that registered (a PID can be reused)
function Test-WtPaneAlive {
    param([Parameter(Mandatory)][object]$Pane)
    $hostPid = Get-EntryField $Pane 'HostPid'
    if (-not $hostPid) { return $false }
    $process = Get-Process -Id ([int]$hostPid) -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try { return $process.StartTime.ToFileTimeUtc() -eq [int64](Get-EntryField $Pane 'HostStart') } catch { return $false }
}

# The panes of the session: Running (its host is alive) or Pending (just launched, not reported in yet). Entries of
# panes that have ended are removed.
function Get-WtPanes {
    $now = [DateTime]::UtcNow.ToFileTimeUtc()
    $panes = foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path (Get-WtStateDir) 'panes') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $pane = Read-WtJson $file.FullName
        if ($null -eq $pane) { continue }
        $running = Test-WtPaneAlive $pane
        $pending = -not $running -and -not (Get-EntryField $pane 'HostPid') -and
            ($now - [int64](Get-EntryField $pane 'Launched')) -lt ($script:PendingSeconds * 10000000L)
        if (-not $running -and -not $pending) {
            Remove-Item -LiteralPath $file.FullName, (Get-WtStopFile $file.FullName) -ErrorAction SilentlyContinue
            continue
        }
        $pane | Add-Member -NotePropertyName File -NotePropertyValue $file.FullName -Force
        $pane | Add-Member -NotePropertyName Running -NotePropertyValue $running -Force
        $pane
    }
    return @($panes)
}

# The registry entry of a running (or just launched) pane, $null when there is none
function Get-WtPane {
    param([Parameter(Mandatory)][string]$Name)
    $key = ConvertTo-WtPaneName $Name
    return @(Get-WtPanes) | Where-Object { (ConvertTo-WtPaneName ([string]$_.Name)) -ceq $key } | Select-Object -First 1
}

function Test-WtPane {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-WtPane $Name)
}

# Wait until the pane's host has registered; $false when it has not after -Seconds
function Wait-WtPaneRegistered {
    param([Parameter(Mandatory)][string]$PaneFile, [int]$Seconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pane = Read-WtJson $PaneFile
        if ($pane -and (Get-EntryField $pane 'HostPid')) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Open a pane that runs -RunCommand (PowerShell) in -WorkingDirectory, in the window -Target names (Get-WtHomeTarget),
# placed as New-WtLaunchArguments says. A split goes into the selected tab: select the group's tab first.
function Start-WtPane {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$RunCommand,
        [Parameter(Mandatory)][ValidateSet('tab', 'grouptab', 'split', 'beside')][string]$Mode,
        [Parameter(Mandatory)][hashtable]$Target,
        [string]$Group,
        [string]$Where,
        [string]$Side,
        [object]$PaneTarget,
        [int]$Ratio = 0
    )
    if (Test-WtPane $Name) { throw "Pane '$Name' already exists. Use restart to replace it." }
    $null = Get-WtCommand
    # Pane ids count per tab: a group's tab starts at 0
    $paneId = $null
    if ($Mode -eq 'grouptab') { $paneId = 0; Set-WtTabState $Group -NextPaneId 1 -ClearTabIndex }
    elseif ($Mode -eq 'split') { $paneId = (Get-WtTabState $Group).NextPaneId; Set-WtTabState $Group -NextPaneId ($paneId + 1) }

    $file = Get-WtPaneFile $Name
    Remove-Item -LiteralPath (Get-WtStopFile $file) -ErrorAction SilentlyContinue
    Write-WtJson $file ([ordered]@{
        Name = $Name; Window = $Target.Name; Group = $Group; Where = $Where; PaneId = $paneId
        WorkingDirectory = $WorkingDirectory; RunCommand = $RunCommand
        Launched = [DateTime]::UtcNow.ToFileTimeUtc(); HostPid = $null; HostStart = $null; WindowHandle = $null
    })
    $arguments = New-WtLaunchArguments -Mode $Mode -Title $Name -WorkingDirectory $WorkingDirectory -StateFile $file -Side $Side -Target $PaneTarget -Ratio $Ratio
    Invoke-WtTarget $Target $arguments
    # One pane at a time: the next split must not reach Windows Terminal before this pane exists (its id)
    if (-not (Wait-WtPaneRegistered $file)) {
        Write-Host "Warning: the pane for '$Name' has not started yet; check Windows Terminal" -ForegroundColor Yellow
        return
    }
    $handle = Get-EntryField (Read-WtJson $file) 'WindowHandle'
    if ($Target.Handle -and $handle -and [int64]$handle -ne [int64]$Target.Handle) {
        Write-Host "Warning: '$Name' opened in another Windows Terminal window than intended" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Placement (apps.json fields Group, PaneSide, PaneRatio, PaneBeside), the rules of the tuios edition
# ---------------------------------------------------------------------------------------------------------------------

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

# The running members of an entry's group, in apps.json order: @{ Entry; Id = pane id }
function Get-WtRunningGroupMembers {
    param([object[]]$Apps, [Parameter(Mandatory)][object]$App, [object[]]$Panes)
    $group = [string](Get-EntryField $App 'Group')
    $appName = [string](Get-EntryField $App 'Name')
    $members = foreach ($member in @($Apps)) {
        $memberName = [string](Get-EntryField $member 'Name')
        if (([string](Get-EntryField $member 'Group')) -ine $group -or $memberName -ieq $appName) { continue }
        $key = ConvertTo-WtPaneName $memberName
        $pane = @($Panes) | Where-Object { $_ -and (ConvertTo-WtPaneName ([string](Get-EntryField $_ 'Name'))) -ceq $key -and $null -ne (Get-EntryField $_ 'PaneId') } | Select-Object -First 1
        if ($pane) { [pscustomobject]@{ Entry = $member; Id = [int](Get-EntryField $pane 'PaneId') } }
    }
    return @($members)
}

# Where an app's pane goes:
#   - no Group: a tab of the home window
#   - no other pane of its Group running: a tab of its own (Mode 'grouptab')
#   - PaneBeside names a running pane of the group: split that pane on the side PaneSide names (default: right)
#   - else beside the group's main pane (the running member with a Port, else the first running one), split on the
#     side PaneSide names, taking PaneRatio percent. A second pane with the same PaneSide splits the first one across
#     (down/up -> right, left/right -> down), so the main pane keeps its share. An entry with no PaneSide (the app
#     restarting while its scheduler runs) goes on the opposite side of that pane, taking the rest of the space.
# -Panes is the registry (default: the current one). Returns @{ Mode = 'tab'|'grouptab'|'split'; Side; Target; Ratio }
function Get-WtGroupPlacement {
    param([object[]]$Apps, [Parameter(Mandatory)][object]$App, [object[]]$Panes)
    $group = [string](Get-EntryField $App 'Group')
    if (-not $group) { return @{ Mode = 'tab' } }
    if (-not $PSBoundParameters.ContainsKey('Panes')) { $Panes = @(Get-WtPanes) }

    $running = @(Get-WtRunningGroupMembers -Apps $Apps -App $App -Panes $Panes)
    if ($running.Count -eq 0) { return @{ Mode = 'grouptab' } }

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
function Format-WtPlacement {
    param([hashtable]$Placement)
    switch ($Placement.Mode) {
        'split' { return "split $($Placement.Side) of pane $($Placement.Target) in its group's tab" + $(if ($Placement.Ratio) { ", $($Placement.Ratio)%" } else { '' }) }
        'grouptab' { return 'a tab of its own for the group' }
        default { return 'a tab' }
    }
}

# Open an app's pane where its Group puts it (see Get-WtGroupPlacement), then select the manager's tab again
function Start-WtAppPane {
    param(
        [object[]]$Apps,
        [Parameter(Mandatory)][object]$App,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$RunCommand
    )
    $group = [string](Get-EntryField $App 'Group')
    $placement = Get-WtGroupPlacement -Apps $Apps -App $App
    try {
        switch ($placement.Mode) {
            'split' {
                $target = Get-WtGroupTarget $group
                if (-not (Select-WtGroupTab -Group $group -Target $target)) {
                    throw "Could not find the tab of group '$group' in Windows Terminal. Stop the group's apps and start them again."
                }
                Write-Host "Placing '$Name' $($placement.Side) of its group '$group'" -ForegroundColor Cyan
                Start-WtPane -Name $Name -WorkingDirectory $WorkingDirectory -RunCommand $RunCommand -Mode split -Target $target `
                    -Group $group -Where $group -Side $placement.Side -PaneTarget $placement.Target -Ratio $placement.Ratio
            }
            'grouptab' {
                Write-Host "Opening group '$group' in a tab of its own" -ForegroundColor Cyan
                Start-WtPane -Name $Name -WorkingDirectory $WorkingDirectory -RunCommand $RunCommand -Mode grouptab -Target (Get-WtHomeTarget) -Group $group -Where $group
            }
            default {
                Start-WtPane -Name $Name -WorkingDirectory $WorkingDirectory -RunCommand $RunCommand -Mode tab -Target (Get-WtHomeTarget) -Where 'tab'
            }
        }
    } finally {
        $null = Select-WtManagerTab
    }
}

# The dashboard never shares a pane layout with the apps:
#   - the manager runs in Windows Terminal: beside the manager's pane (right, 40%)
#   - else: a tab of its own in the session's window
function Start-WtDashboardPane {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$RunCommand
    )
    if ($script:HomeWindow) {
        Start-WtPane -Name $Name -WorkingDirectory $WorkingDirectory -RunCommand $RunCommand -Mode beside -Target (Get-WtHomeTarget) -Where 'beside manager' -Ratio 40
    } else {
        Start-WtPane -Name $Name -WorkingDirectory $WorkingDirectory -RunCommand $RunCommand -Mode tab -Target (Get-WtHomeTarget) -Where 'tab'
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Stopping
# ---------------------------------------------------------------------------------------------------------------------

# Ids of the processes below a process (children, grandchildren, ...), deepest first
function Get-WtDescendantProcessIds {
    param([Parameter(Mandatory)][int]$ProcessId)
    $children = @{}
    foreach ($process in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)) {
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) { $children[$parent] = [System.Collections.Generic.List[int]]::new() }
        $children[$parent].Add([int]$process.ProcessId)
    }
    $order = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue($ProcessId)
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if (-not $children.ContainsKey($id)) { continue }
        foreach ($child in $children[$id]) { if ($child -ne $id -and -not $order.Contains($child)) { $order.Add($child); $queue.Enqueue($child) } }
    }
    $order.Reverse()
    return @($order)
}

function Wait-WtProcessExit {
    param([Parameter(Mandatory)][int[]]$ProcessIds, [int]$Seconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not @($ProcessIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Stop panes: ask each to stop (Ctrl+C in its console; it exits 0 and Windows Terminal closes it), then force the
# app's processes of any pane still running after -Seconds, so the pane still closes; the host itself last.
function Stop-WtPanes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Panes, [int]$Seconds = 10)
    $live = @($Panes | Where-Object { $_ -and $_.Running })
    foreach ($pane in $live) { $null = New-Item -ItemType File -Force (Get-WtStopFile $pane.File) }
    $hostPids = @($live | ForEach-Object { [int]$_.HostPid })
    if ($hostPids.Count -gt 0 -and -not (Wait-WtProcessExit $hostPids $Seconds)) {
        foreach ($pane in $live) {
            $hostPid = [int]$pane.HostPid
            if (-not (Get-Process -Id $hostPid -ErrorAction SilentlyContinue)) { continue }
            Write-Host "'$($pane.Name)' did not stop on Ctrl+C; ending its processes" -ForegroundColor Yellow
            foreach ($id in (Get-WtDescendantProcessIds $hostPid)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            if (-not (Wait-WtProcessExit @($hostPid) 5)) {
                Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue
                Write-Host "The pane of '$($pane.Name)' is left open; close it with Ctrl+Shift+W" -ForegroundColor Yellow
            }
        }
    }
    foreach ($pane in @($Panes | Where-Object { $_ })) {
        Remove-Item -LiteralPath $pane.File, (Get-WtStopFile $pane.File) -ErrorAction SilentlyContinue
    }
}

# Stop an app's pane; $false when it has none
function Stop-WtPane {
    param([Parameter(Mandatory)][string]$Name, [int]$Seconds = 10)
    $pane = Get-WtPane $Name
    if (-not $pane) { return $false }
    Stop-WtPanes @($pane) $Seconds
    Write-Host "Closed pane: $Name" -ForegroundColor Green
    return $true
}

function Stop-AllWtPanes {
    $panes = @(Get-WtPanes)
    if ($panes.Count -eq 0) { Write-Host "No panes running in session '$script:SessionName'" -ForegroundColor Yellow; return }
    Stop-WtPanes $panes
    Write-Host "Closed $($panes.Count) pane(s)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------------------------------
# Listing and showing
# ---------------------------------------------------------------------------------------------------------------------

function Show-WtPanes {
    $panes = @(Get-WtPanes)
    if ($panes.Count -eq 0) { Write-Host "No panes running in session '$script:SessionName'" -ForegroundColor Yellow; return }
    Write-Host "Windows Terminal panes in session '$script:SessionName':" -ForegroundColor Cyan
    foreach ($pane in ($panes | Sort-Object { [string]$_.Name })) {
        $where = if ($pane.Where -eq 'tab') { 'a tab' }
            elseif ($pane.Group) { "the tab of group '$($pane.Group)', pane $($pane.PaneId)" }
            else { [string]$pane.Where }
        $state = if ($pane.Running) { "PID $($pane.HostPid)" } else { 'starting' }
        Write-Host ("  {0}: {1} ({2})" -f $pane.Name, $where, $state)
    }
}

# Show an app's pane: its window is brought forward and its tab selected; a group's pane is also focused
function Select-WtPane {
    param([Parameter(Mandatory)][string]$Name)
    $pane = Get-WtPane $Name
    if (-not $pane -or -not $pane.Running) { Write-Host "Pane '$Name' not found" -ForegroundColor Yellow; return $false }
    $target = Get-WtPaneTarget $pane
    $null = Show-WtWindow $pane.WindowHandle
    $result = Find-WtTab -Target $target -Names @([string]$pane.Name) -Hint $(if ($pane.Group) { (Get-WtTabState ([string]$pane.Group)).TabIndex } else { $null })
    if (-not $result.Found) { Write-Host "Could not find the tab of '$Name' in Windows Terminal" -ForegroundColor Yellow; return $false }
    if ($pane.Group) {
        if ($null -ne $result.Index) { Set-WtTabState ([string]$pane.Group) -TabIndex $result.Index }
        if ($null -ne $pane.PaneId) { Invoke-WtTarget $target @('focus-pane', '-t', [string]$pane.PaneId) }
    }
    return $true
}

# Bring every window with a running pane to the front, the home window last (on top)
function Connect-WtSession {
    $panes = @(Get-WtPanes | Where-Object { $_.Running -and $_.WindowHandle })
    if ($panes.Count -eq 0) { Write-Host 'No panes running. Start some apps first.' -ForegroundColor Yellow; return }
    $homeHandle = (Get-WtHomeTarget).Handle
    $handles = @($panes | ForEach-Object { [int64]$_.WindowHandle } | Select-Object -Unique | Sort-Object { $homeHandle -and $_ -eq [int64]$homeHandle })
    foreach ($handle in $handles) { $null = Show-WtWindow $handle }
    Write-Host "Showing $($handles.Count) Windows Terminal window(s)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------------------------------------------------
# apps.json
# ---------------------------------------------------------------------------------------------------------------------

# The machine name used for the config folder: COMPUTERNAME on Windows, hostname -s elsewhere
function Get-MachineName {
    if ($IsWindows -and $env:COMPUTERNAME) { return $env:COMPUTERNAME }
    $name = ''
    try { $name = [string](& hostname -s 2>$null) } catch {}
    if (-not $name) { $name = ([System.Net.Dns]::GetHostName() -split '\.')[0] }
    return $name.Trim()
}

# apps.json lookup, the same order as the other editions:
#   1. $env:APP_MANAGER_APPS_FILE (an error when it does not exist)
#   2. ($env:APP_MANAGER_CONFIG_DIR or ~/code/app_manager_config)/machines/<hostname>/win_v2/apps.json
#   3. apps.json next to the scripts, the folder above, or the current folder
# Returns $null when none exists.
function Get-WtAppsPath {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    if ($env:APP_MANAGER_APPS_FILE) {
        if (-not (Test-Path -LiteralPath $env:APP_MANAGER_APPS_FILE -PathType Leaf)) { throw "APP_MANAGER_APPS_FILE not found: $env:APP_MANAGER_APPS_FILE" }
        return (Resolve-Path -LiteralPath $env:APP_MANAGER_APPS_FILE).Path
    }
    $configDir = if ($env:APP_MANAGER_CONFIG_DIR) { $env:APP_MANAGER_CONFIG_DIR } else { Join-Path $HOME 'code/app_manager_config' }
    $candidates = @(
        (Join-Path $configDir "machines/$(Get-MachineName)/win_v2/apps.json"),
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
    'Get-WtCommand', 'Get-WtSessionName', 'ConvertTo-WtPaneName', 'Get-WtWindowName', 'ConvertTo-WtArguments', 'Invoke-Wt',
    'Get-PwshPath', 'New-WtLaunchArguments', 'Get-WtVisiblePanes', 'Initialize-WtHome', 'Get-WtHome', 'Get-WtHomeTarget',
    'Get-WtPaneTarget', 'Get-WtTargetArguments', 'Invoke-WtTarget', 'Show-WtWindow', 'Find-WtTab', 'Get-WtTabState',
    'Set-WtTabState', 'Get-WtGroupTarget', 'Select-WtGroupTab', 'Select-WtManagerTab',
    'Get-WtStateDir', 'Get-WtPaneFile', 'Get-WtStopFile', 'Test-WtPaneAlive',
    'Get-WtPanes', 'Get-WtPane', 'Test-WtPane', 'Start-WtPane',
    'Get-WtGroupPlacement', 'Format-WtPlacement', 'Start-WtAppPane', 'Start-WtDashboardPane',
    'Get-WtDescendantProcessIds', 'Stop-WtPanes', 'Stop-WtPane', 'Stop-AllWtPanes', 'Show-WtPanes',
    'Select-WtPane', 'Connect-WtSession', 'Get-MachineName', 'Get-WtAppsPath'
)
