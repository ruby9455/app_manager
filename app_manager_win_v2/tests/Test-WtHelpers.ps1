# Tests for Modules/WtHelpers.psm1, PaneHost.ps1 and AppHelpers.psm1.
#   pwsh -File app_manager_win_v2/tests/Test-WtHelpers.ps1          # placement rules, wt arguments, lookup, registry
#   pwsh -File app_manager_win_v2/tests/Test-WtHelpers.ps1 -Live    # also real Windows Terminal windows (a throwaway
#                                                                   # session; its windows open and close)
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modules = Join-Path $root 'Modules'

$session = 'appmgr_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$tmp = Join-Path ([IO.Path]::GetTempPath()) $session
$savedEnv = @{}
foreach ($key in @('APP_MANAGER_WT_SESSION', 'APP_MANAGER_WT_STATE_DIR', 'APP_MANAGER_APPS_FILE', 'APP_MANAGER_CONFIG_DIR', 'WT_SESSION')) { $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key) }
$env:APP_MANAGER_WT_SESSION = $session
$env:APP_MANAGER_WT_STATE_DIR = Join-Path $tmp 'state'
Import-Module -Force (Join-Path $modules 'AppHelpers.psm1')
Import-Module -Force (Join-Path $modules 'WtHelpers.psm1')

$script:failed = 0
function Assert-Equal($Expected, $Actual, $Message) {
    if ("$Expected" -ceq "$Actual") { Write-Host "ok   - $Message" }
    else { Write-Host "FAIL - $Message`n       expected: $Expected`n       actual:   $Actual" -ForegroundColor Red; $script:failed++ }
}
function Assert-True($Condition, $Message) { Assert-Equal $true ([bool]$Condition) $Message }

New-Item -ItemType Directory -Force (Join-Path $tmp 'scripts'), (Join-Path $tmp 'config') | Out-Null

# A registry entry for the placement rules: a running pane with an id
function Pane($Name, $Id) { [pscustomobject]@{ Name = $Name; PaneId = $Id; Running = $true } }
function Placement($Apps, $Name, $Panes) { Get-WtGroupPlacement -Apps $Apps -App ($Apps | Where-Object Name -ceq $Name) -Panes $Panes }
function Show-Placement($Placement) { (@($Placement.Mode, $Placement.Side, $Placement.Target, $Placement.Ratio) | Where-Object { $null -ne $_ }) -join ' ' }

try {
    # --- apps.json lookup ---
    $env:APP_MANAGER_APPS_FILE = $null
    $env:APP_MANAGER_CONFIG_DIR = Join-Path $tmp 'config'
    $scripts = Join-Path $tmp 'scripts'
    Assert-Equal '' "$(Get-WtAppsPath -ScriptRoot $scripts)" 'no apps.json anywhere gives nothing'
    '[]' | Set-Content (Join-Path $scripts 'apps.json')
    Assert-Equal (Join-Path $scripts 'apps.json') (Get-WtAppsPath -ScriptRoot $scripts) 'falls back to apps.json next to the scripts'
    $machine = Join-Path $tmp "config/machines/$(Get-MachineName)"
    New-Item -ItemType Directory -Force (Join-Path $machine 'win_v2'), (Join-Path $machine 'win'), (Join-Path $machine 'tuios') | Out-Null
    '[]' | Set-Content (Join-Path $machine 'win/apps.json')
    '[]' | Set-Content (Join-Path $machine 'tuios/apps.json')
    Assert-Equal (Join-Path $scripts 'apps.json') (Get-WtAppsPath -ScriptRoot $scripts) 'ignores the win and tuios folders'
    '[]' | Set-Content (Join-Path $machine 'win_v2/apps.json')
    Assert-Equal (Resolve-Path (Join-Path $machine 'win_v2/apps.json')).Path (Get-WtAppsPath -ScriptRoot $scripts) 'uses machines/<hostname>/win_v2/apps.json'
    $env:APP_MANAGER_APPS_FILE = Join-Path $tmp 'missing.json'
    $threw = $false; try { Get-WtAppsPath -ScriptRoot $scripts | Out-Null } catch { $threw = $true }
    Assert-True $threw 'a missing APP_MANAGER_APPS_FILE is an error'
    $env:APP_MANAGER_APPS_FILE = $null

    # --- names, run commands ---
    Assert-Equal 'My_App__v1_2_x' (ConvertTo-WtPaneName 'My App: v1.2/x') 'pane names are sanitized as in the tmux edition'
    Assert-Equal "$session" (Get-WtWindowName) 'outside Windows Terminal, apps use the session window'
    $custom = [pscustomobject]@{ Name = 'api'; Type = 'Custom'; Port = 8100; PackageManager = 'uv'; CustomCommand = 'TZ=Europe/London uvicorn app:app --port {port}' }
    Assert-Equal "`$env:TZ = 'Europe/London'; uv run uvicorn app:app --port 8100" (Get-AppRunCommand -App $custom -WorkingDirectory $tmp) 'Custom: {port}, VAR=value and uv run'
    $sorted = Get-SupportedApps @([pscustomobject]@{ Name = 'beta'; Type = 'Flask' }, [pscustomobject]@{ Name = 'Alpha'; Type = 'Dash' }, [pscustomobject]@{ Name = 'x'; Type = 'Other' }, [pscustomobject]@{ Name = 'ALPHA'; Type = 'Dash' })
    Assert-Equal 'Alpha,beta' (($sorted | ForEach-Object Name) -join ',') 'supported apps: filtered, one per name, in name order'

    # --- wt arguments ---
    Assert-Equal 'a\;b|;|c' ((ConvertTo-WtArguments @('a;b', ';', 'c')) -join '|') "';' in an argument is escaped, a lone ';' separates commands"
    $file = 'C:\state\x.json'
    $tail = "--title|App|--suppressApplicationTitle|-d|C:\app|--|$(Get-PwshPath)|-NoLogo|-NoProfile|-ExecutionPolicy|Bypass|-File|$(Join-Path $modules 'PaneHost.ps1')|-StateFile|$file"
    Assert-Equal "new-tab|$tail" ((New-WtLaunchArguments -Mode tab -Title App -WorkingDirectory 'C:\app' -StateFile $file) -join '|') 'tab: new-tab'
    Assert-Equal "new-tab|$tail" ((New-WtLaunchArguments -Mode grouptab -Title App -WorkingDirectory 'C:\app' -StateFile $file) -join '|') "a group's first pane: new-tab"
    Assert-Equal "focus-pane|-t|2|;|split-pane|-H|-s|0.3|$tail" ((New-WtLaunchArguments -Mode split -Title App -WorkingDirectory 'C:\app' -StateFile $file -Side down -Target 2 -Ratio 30) -join '|') 'down 30: focus the pane, split it below with 30%'
    Assert-Equal "focus-pane|-t|0|;|split-pane|-H|-s|0.7|$tail|;|swap-pane|up" ((New-WtLaunchArguments -Mode split -Title App -WorkingDirectory 'C:\app' -StateFile $file -Side up -Target 0 -Ratio 30) -join '|') 'up 30: split below with 70%, then swap up'
    Assert-Equal "focus-pane|-t|1|;|split-pane|-V|$tail|;|swap-pane|left" ((New-WtLaunchArguments -Mode split -Title App -WorkingDirectory 'C:\app' -StateFile $file -Side left -Target 1) -join '|') 'left, no ratio: split right in half, then swap left'
    Assert-Equal "split-pane|-V|-s|0.4|$tail|;|move-focus|left" ((New-WtLaunchArguments -Mode beside -Title App -WorkingDirectory 'C:\app' -StateFile $file -Ratio 40) -join '|') 'beside: split the focused pane, then focus it again'
    Assert-Equal '-w|w' ((Get-WtTargetArguments @{ Name = 'w'; Handle = 1 }) -join '|') 'a named window: -w <name>'
    Assert-Equal '-w|0' ((Get-WtTargetArguments @{ Name = $null; Handle = 1 }) -join '|') 'the home window: -w 0 (the most recently activated)'
    Remove-Item env:WT_SESSION -ErrorAction SilentlyContinue
    Assert-Equal $null (Initialize-WtHome) 'outside Windows Terminal there is no home window'
    Assert-Equal "$session" ((Get-WtHomeTarget).Name) 'and panes go to the session window'

    # --- placement rules (the tuios edition's cases) ---
    $apps = @(
        [pscustomobject]@{ Name = 'Shop'; Type = 'Django'; Port = 8000; Group = 'Shop' },
        [pscustomobject]@{ Name = 'Shop Scheduler'; CustomCommand = 'sched'; Group = 'Shop'; PaneSide = 'down'; PaneRatio = 30 },
        [pscustomobject]@{ Name = 'Shop Mailer'; CustomCommand = 'mail'; Group = 'Shop'; PaneSide = 'down'; PaneRatio = 30 },
        [pscustomobject]@{ Name = 'Solo'; Type = 'Streamlit'; Port = 8502 }
    )
    Assert-Equal 'tab' (Show-Placement (Placement $apps 'Solo' @())) 'no Group: a tab'
    Assert-Equal 'grouptab' (Show-Placement (Placement $apps 'Shop Scheduler' @())) 'a group with nothing running: a tab of its own'
    Assert-Equal 'split down 0 30' (Show-Placement (Placement $apps 'Shop Scheduler' @((Pane 'Shop' 0)))) 'the scheduler goes below the app, at 30%'
    Assert-Equal 'split up 0 70' (Show-Placement (Placement $apps 'Shop' @((Pane 'Shop Scheduler' 0)))) 'the app restarting beside its scheduler goes above it, taking the rest'
    Assert-Equal 'split right 1 0' (Show-Placement (Placement $apps 'Shop Mailer' @((Pane 'Shop' 0), (Pane 'Shop Scheduler' 1)))) 'a second pane on the same side splits the first one across'
    Assert-Equal 'grouptab' (Show-Placement (Placement $apps 'Shop' @((Pane 'Solo' 0)))) 'panes of other groups do not count'
    $grid = @(
        [pscustomobject]@{ Name = 'Grid App'; Type = 'Streamlit'; Port = 8503; Group = 'Grid' },
        [pscustomobject]@{ Name = 'Grid A'; CustomCommand = 'a'; Group = 'Grid'; PaneSide = 'right' },
        [pscustomobject]@{ Name = 'Grid B'; CustomCommand = 'b'; Group = 'Grid'; PaneSide = 'down' },
        [pscustomobject]@{ Name = 'Grid C'; CustomCommand = 'c'; Group = 'Grid'; PaneSide = 'down'; PaneBeside = 'Grid A' }
    )
    $gridPanes = @((Pane 'Grid App' 0), (Pane 'Grid A' 1), (Pane 'Grid B' 2))
    Assert-Equal 'split down 0 0' (Show-Placement (Placement $grid 'Grid B' @((Pane 'Grid App' 0), (Pane 'Grid A' 1)))) '2x2: B splits the app below'
    Assert-Equal 'split down 1 0' (Show-Placement (Placement $grid 'Grid C' $gridPanes)) '2x2: C splits A (PaneBeside) below'

    # --- registry ---
    $paneFile = Get-WtPaneFile 'Reg Test'
    $me = Get-Process -Id $PID
    [IO.File]::WriteAllText($paneFile, (@{ Name = 'Reg Test'; HostPid = $PID; HostStart = $me.StartTime.ToFileTimeUtc(); Launched = 0 } | ConvertTo-Json))
    Assert-True ((Get-WtPane 'Reg Test').Running) 'a pane whose host is alive is running'
    [IO.File]::WriteAllText($paneFile, (@{ Name = 'Reg Test'; HostPid = $PID; HostStart = 1; Launched = 0 } | ConvertTo-Json))
    Assert-True (-not (Test-WtPane 'Reg Test')) 'a reused process id (another start time) is not the pane'
    Assert-True (-not (Test-Path $paneFile)) 'and its entry is removed'
    [IO.File]::WriteAllText($paneFile, (@{ Name = 'Reg Test'; HostPid = $null; HostStart = $null; Launched = [DateTime]::UtcNow.ToFileTimeUtc() } | ConvertTo-Json))
    $pending = Get-WtPane 'Reg Test'
    Assert-True ($pending -and -not $pending.Running) 'a pane just launched is listed, not yet running'
    Remove-Item $paneFile
    Set-WtTabState 'My Group' -NextPaneId 4 -TabIndex 2
    Assert-Equal '4 2' "$((Get-WtTabState 'My Group').NextPaneId) $((Get-WtTabState 'My Group').TabIndex)" "a group tab's next pane id and index are kept"
    Set-WtTabState 'My Group' -ClearTabIndex
    Assert-Equal '4 ' "$((Get-WtTabState 'My Group').NextPaneId) $((Get-WtTabState 'My Group').TabIndex)" 'and the index can be forgotten'

    # --- finding a tab: a fake window whose tabs show these panes (Name, RuntimeId) ---
    function V($Name, $Id) { [pscustomobject]@{ Name = $Name; RuntimeId = $Id } }
    $script:fakeTabs = @{ 0 = @((V 'Manager' 'm')); 1 = @((V 'Solo' 'a')); 2 = @((V 'Shop' 's1'), (V 'Shop Scheduler' 's2')); 3 = @((V 'Other' 'b')) }
    $script:active = 0; $script:selects = 0
    $fakeSelect = { param($Index) $script:selects++; if ($script:fakeTabs.ContainsKey([int]$Index)) { $script:active = [int]$Index } }
    $fakeRead = { $script:fakeTabs[$script:active] }
    function Find($Names, $Ids, $Hint) { Find-WtTab -Names $Names -RuntimeIds $Ids -Hint $Hint -Select $fakeSelect -Read $fakeRead -TimeoutMs 30 }

    $script:active = 2; $script:selects = 0
    $r = Find @('Shop') $null $null
    Assert-Equal 'True  0' "$($r.Found) $($r.Index) $script:selects" 'the selected tab already shows the pane: nothing to select'
    $script:active = 0; $script:selects = 0
    $r = Find @('Shop Scheduler') $null $null
    Assert-Equal 'True 2 2' "$($r.Found) $($r.Index) $script:active" 'found by scanning the indexes (and left selected)'
    $script:active = 0; $script:selects = 0
    $r = Find @('Other') $null 3
    Assert-Equal 'True 3 1' "$($r.Found) $($r.Index) $script:selects" 'the last known index is tried first'
    $script:active = 0; $script:selects = 0
    $r = Find @('Other') $null 1
    Assert-Equal 'True 3' "$($r.Found) $($r.Index)" 'a stale index (the tab moved) falls back to the scan'
    $script:active = 3; $script:selects = 0
    $r = Find $null @('m') $null
    Assert-Equal 'True 0 0' "$($r.Found) $($r.Index) $script:active" "the manager's tab is found by its pane's RuntimeId"
    $script:active = 0; $script:selects = 0
    $r = Find @('Missing') $null $null
    Assert-True (-not $r.Found -and $script:selects -le 6) "a missing tab is not found, and the scan stops past the last tab ($script:selects selects)"

    if ($Live) {
        Write-Host "--- Live: Windows Terminal session $session ---"
        Remove-Item env:WT_SESSION -ErrorAction SilentlyContinue
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        # Pane name -> its rectangle, in its tab (selected first: UI Automation shows the selected tab's panes only)
        function Get-Layout($Name) {
            $rects = @{}
            if (-not (Select-WtPane $Name)) { return $rects }
            $pane = Get-WtPane $Name
            $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][int64]$pane.WindowHandle)
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
            foreach ($control in $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) { $rects[$control.Current.Name] = $control.Current.BoundingRectangle }
            return $rects
        }
        function Get-Shown($Name) { @(Get-WtVisiblePanes (Get-WtPane $Name).WindowHandle | ForEach-Object Name | Sort-Object) -join ',' }
        function Start-Entry($Apps, $Name, $Command = 'Start-Sleep -Seconds 600') {
            $app = $Apps | Where-Object Name -ceq $Name
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Start-WtAppPane -Apps $Apps -App $app -Name $Name -WorkingDirectory $tmp -RunCommand $Command | Out-Null
            Write-Host "  started '$Name' in $($sw.ElapsedMilliseconds) ms"
            Start-Sleep -Milliseconds 700
        }

        Start-Entry $apps 'Shop'
        Assert-True ((Get-WtPane 'Shop').Running) 'the pane host registers'
        Assert-Equal "Shop 0 $session" "$((Get-WtPane 'Shop').Where) $((Get-WtPane 'Shop').PaneId) $((Get-WtPane 'Shop').Window)" 'the first pane of a group: pane 0 of its own tab in the session window'
        Start-Entry $apps 'Shop Scheduler'
        $l = Get-Layout 'Shop'
        Assert-True ($l['Shop Scheduler'].Y -gt $l['Shop'].Y -and $l['Shop Scheduler'].X -eq $l['Shop'].X) 'the scheduler opens below the app'
        $share = $l['Shop Scheduler'].Height / ($l['Shop'].Height + $l['Shop Scheduler'].Height)
        Assert-True ([Math]::Abs($share - 0.3) -le 0.05) "the scheduler takes about 30% ($([Math]::Round($share, 2)))"

        $shopHost = [int](Get-WtPane 'Shop').HostPid
        Assert-True (Stop-WtPane 'Shop') 'stop finds the pane'
        Assert-True (-not (Get-Process -Id $shopHost -ErrorAction SilentlyContinue)) 'stop ends the pane host (Ctrl+C, exit 0)'
        Start-Sleep -Milliseconds 700
        Assert-Equal 'Shop Scheduler' ((Get-Layout 'Shop Scheduler').Keys -join ',') 'and Windows Terminal closes the pane'

        Start-Entry $apps 'Shop'
        $l = Get-Layout 'Shop'
        Assert-True ($l['Shop'].Y -lt $l['Shop Scheduler'].Y -and $l['Shop'].Height -gt $l['Shop Scheduler'].Height) 'restarting beside the scheduler, the app goes above it and takes the larger share'
        Start-Entry $apps 'Shop Mailer'
        $l = Get-Layout 'Shop'
        Assert-True ($l['Shop Mailer'].Y -eq $l['Shop Scheduler'].Y -and $l['Shop Mailer'].X -gt $l['Shop Scheduler'].X) 'a second pane on the same side opens beside the first one'
        Assert-True ($l['Shop'].Height -gt $l['Shop Scheduler'].Height) 'and the app keeps its share'

        foreach ($entry in $grid) { Start-Entry $grid $entry.Name }
        $g = Get-Layout 'Grid App'
        Assert-Equal 4 $g.Count 'the 2x2 group shares one tab'
        Assert-True ($g['Grid App'].X -eq $g['Grid B'].X -and $g['Grid App'].Y -lt $g['Grid B'].Y) 'B is below the app (left column)'
        Assert-True ($g['Grid A'].X -eq $g['Grid C'].X -and $g['Grid A'].Y -lt $g['Grid C'].Y) 'C is below A (right column)'
        Assert-True ($g['Grid App'].Y -eq $g['Grid A'].Y -and $g['Grid App'].X -lt $g['Grid A'].X) 'A is right of the app (top row)'
        Assert-True ((Get-WtPane 'Grid App').WindowHandle -eq (Get-WtPane 'Shop').WindowHandle) 'in the same window as the other group, in a tab of its own'

        Start-Entry $apps 'Solo'
        Assert-Equal "tab $session" "$((Get-WtPane 'Solo').Where) $((Get-WtPane 'Solo').Window)" 'an app with no Group opens as a tab of the session window'
        Assert-True ((Get-WtPane 'Solo').WindowHandle -eq (Get-WtPane 'Shop').WindowHandle) 'the same window as the groups: no new window'
        Assert-True (Select-WtPane 'Solo') 't N finds the tab of an app with no Group'
        Assert-Equal 'Solo' (Get-Shown 'Solo') 'and selects it'

        # A split while another tab is selected: the group's tab is found first
        $shopLogs = @($apps) + [pscustomobject]@{ Name = 'Shop Logs'; CustomCommand = 'logs'; Group = 'Shop'; PaneSide = 'right' }
        Start-Entry $shopLogs 'Shop Logs'
        $l = Get-Layout 'Shop'
        Assert-True ($l.ContainsKey('Shop Logs') -and $l['Shop Logs'].X -gt $l['Shop'].X) "a split from another tab lands in the group's tab, right of the app"
        $g = Get-Layout 'Grid App'
        Assert-True ($g.Count -eq 4 -and -not $g.ContainsKey('Shop Logs')) 'the other group kept its own tab'

        # The last pane of a group stopping closes its tab
        foreach ($entry in $grid) { $null = Stop-WtPane $entry.Name }
        Start-Sleep -Milliseconds 700
        $gone = Find-WtTab -Target (Get-WtGroupTarget 'Shop') -Names @($grid | ForEach-Object Name)
        Assert-True (-not $gone.Found) "stopping a group's panes closes its tab"

        # An app that ends by itself: the pane waits for Enter, still registered, and a stop closes it
        Start-Entry @([pscustomobject]@{ Name = 'Solo Two'; CustomCommand = 'exit 3' }) 'Solo Two' 'cmd /c exit 3'
        Start-Sleep -Seconds 1
        $twoHost = [int](Get-WtPane 'Solo Two').HostPid
        Assert-True ((Get-WtPane 'Solo Two').Running) 'an app that has exited keeps its pane registered while it waits for Enter'
        $null = Stop-WtPane 'Solo Two'
        Assert-True (-not (Get-Process -Id $twoHost -ErrorAction SilentlyContinue)) 'and a stop closes that pane'

        # The home window (the manager's, addressed as -w 0): a stand-in manager pane in a window of its own
        Start-WtPane -Name 'Home Manager' -WorkingDirectory $tmp -RunCommand 'Start-Sleep -Seconds 600' -Mode tab -Target @{ Name = "$session-home"; Handle = $null } -Where 'tab'
        Start-Sleep -Milliseconds 700
        $homeHandle = [int64](Get-WtPane 'Home Manager').WindowHandle
        $managerPane = @(Get-WtVisiblePanes $homeHandle | Where-Object Name -ceq 'Home Manager')[0].RuntimeId
        $null = Initialize-WtHome -Handle $homeHandle -ManagerPane $managerPane
        Start-Entry @([pscustomobject]@{ Name = 'Home App'; CustomCommand = 'x' }) 'Home App'
        Assert-True ([int64](Get-WtPane 'Home App').WindowHandle -eq $homeHandle) 'with a home window, an app opens as a tab of it (-w 0)'
        Assert-Equal 'Home Manager' (Get-Shown 'Home App') "and the manager's tab is selected again"
        $null = Initialize-WtHome -Reset

        $hosts = @(Get-WtPanes | ForEach-Object { [int]$_.HostPid })
        Stop-AllWtPanes | Out-Null
        Assert-True (-not (Get-Process -Id $hosts -ErrorAction SilentlyContinue)) "stop all ends every pane ($($hosts.Count))"
        Assert-Equal 0 @(Get-WtPanes).Count 'and empties the registry'
    }
}
finally {
    if ($Live) { try { Stop-AllWtPanes | Out-Null } catch {} }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key]) }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'WtHelpers tests passed.'
