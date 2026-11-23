# Tests for Modules/TuiosHelpers.psm1 and AppHelpers.psm1 against the real tuios on PATH (or APP_MANAGER_TUIOS_BIN).
# Uses a throwaway session, removed at the end. Run: pwsh -File app_manager_tuios/tests/Test-TuiosHelpers.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modules = Join-Path $root 'Modules'

$session = 'appmgr_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$savedEnv = @{ APP_MANAGER_TUIOS_SESSION = $env:APP_MANAGER_TUIOS_SESSION; APP_MANAGER_APPS_FILE = $env:APP_MANAGER_APPS_FILE; APP_MANAGER_CONFIG_DIR = $env:APP_MANAGER_CONFIG_DIR }
$env:APP_MANAGER_TUIOS_SESSION = $session
Import-Module -Force (Join-Path $modules 'AppHelpers.psm1')
Import-Module -Force (Join-Path $modules 'TuiosHelpers.psm1')

$script:failed = 0
function Assert-Equal($Expected, $Actual, $Message) {
    if ("$Expected" -ceq "$Actual") { Write-Host "ok   - $Message" }
    else { Write-Host "FAIL - $Message`n       expected: $Expected`n       actual:   $Actual" -ForegroundColor Red; $script:failed++ }
}
function Assert-True($Condition, $Message) { Assert-Equal $true ([bool]$Condition) $Message }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('appmgr_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $tmp 'scripts'), (Join-Path $tmp 'config') | Out-Null
$tuios = Get-TuiosCommand

function Get-Window($Name) { Get-TuiosWindows | Where-Object { $_.PSObject.Properties['custom_name'] -and $_.custom_name -ceq (ConvertTo-TuiosWindowName $Name) } | Select-Object -First 1 }
function Get-WorkspaceName($Number) { $w = Get-TuiosWorkspaces | Where-Object { [int]$_.workspace -eq $Number }; if ($w -and $w.PSObject.Properties['name']) { [string]$w.name } else { '' } }
# A window that runs until it is stopped
$sleep = New-TuiosEncodedCommand $tmp 'test' 'Start-Sleep -Seconds 600'

try {
    Write-Host "Using $tuios, session $session"

    # --- Config lookup and helpers (no tuios needed) ---
    $env:APP_MANAGER_APPS_FILE = $null
    $env:APP_MANAGER_CONFIG_DIR = Join-Path $tmp 'config'
    $scripts = Join-Path $tmp 'scripts'
    Assert-Equal '' "$(Get-TuiosAppsPath -ScriptRoot $scripts)" 'no apps.json anywhere gives nothing'
    '[]' | Set-Content (Join-Path $scripts 'apps.json')
    Assert-Equal (Join-Path $scripts 'apps.json') (Get-TuiosAppsPath -ScriptRoot $scripts) 'falls back to apps.json next to the scripts'
    $machine = Join-Path $tmp "config/machines/$(Get-MachineName)"
    New-Item -ItemType Directory -Force (Join-Path $machine 'tuios'), (Join-Path $machine 'psmux') | Out-Null
    '[]' | Set-Content (Join-Path $machine 'psmux/apps.json')
    Assert-Equal (Join-Path $scripts 'apps.json') (Get-TuiosAppsPath -ScriptRoot $scripts) 'ignores the other platform folders'
    '[]' | Set-Content (Join-Path $machine 'tuios/apps.json')
    Assert-Equal (Resolve-Path (Join-Path $machine 'tuios/apps.json')).Path (Get-TuiosAppsPath -ScriptRoot $scripts) 'uses machines/<hostname>/tuios/apps.json'
    $env:APP_MANAGER_APPS_FILE = Join-Path $tmp 'missing.json'
    $threw = $false; try { Get-TuiosAppsPath -ScriptRoot $scripts | Out-Null } catch { $threw = $true }
    Assert-True $threw 'a missing APP_MANAGER_APPS_FILE is an error'
    $env:APP_MANAGER_APPS_FILE = $null

    Assert-Equal 'My_App__v1_2_x' (ConvertTo-TuiosWindowName 'My App: v1.2/x') 'window names are sanitized as in the tmux edition'
    $custom = [pscustomobject]@{ Name = 'api'; Type = 'Custom'; Port = 8100; PackageManager = 'uv'; CustomCommand = 'TZ=Europe/London uvicorn app:app --port {port}' }
    Assert-Equal "`$env:TZ = 'Europe/London'; uv run uvicorn app:app --port 8100" (Get-AppRunCommand -App $custom -WorkingDirectory $tmp) 'Custom: {port}, VAR=value and uv run'
    $sorted = Get-SupportedApps @([pscustomobject]@{ Name = 'beta'; Type = 'Flask' }, [pscustomobject]@{ Name = 'Alpha'; Type = 'Dash' }, [pscustomobject]@{ Name = 'x'; Type = 'Other' }, [pscustomobject]@{ Name = 'ALPHA'; Type = 'Dash' })
    Assert-Equal 'Alpha,beta' (($sorted | ForEach-Object Name) -join ',') 'supported apps: filtered, one per name, in name order (as jq unique_by)'

    # --- Session and windows on the real tuios ---
    Assert-True (-not (Test-TuiosSession)) 'no session before the first app'
    Initialize-TuiosSession
    Assert-True (Test-TuiosSession) 'Initialize-TuiosSession creates the session'
    Assert-True (Test-TuiosWindow '_placeholder') 'the first window is named _placeholder'

    # The command in a pane really runs (a Store pwsh's full path once made every pane fail at start)
    $marker = Join-Path $tmp 'ran.txt'
    $writer = New-TuiosEncodedCommand $tmp 'marker' "Set-Content -LiteralPath '$marker' -Value ok; Start-Sleep -Seconds 600"
    New-TuiosWindow -Name 'marker' -WorkingDirectory $tmp -EncodedCommand $writer -Workspace 9
    for ($i = 0; $i -lt 40 -and -not (Test-Path $marker); $i++) { Start-Sleep -Milliseconds 250 }
    Assert-True (Test-Path $marker) 'the command in a pane runs'
    Remove-TuiosWindow 'marker' | Out-Null

    # The dashboard has a workspace of its own, not workspace 1 with the apps
    Start-TuiosDashboardWindow -Name '_Dashboard' -WorkingDirectory $tmp -EncodedCommand $sleep | Out-Null
    Assert-Equal '2 Dashboard' "$((Get-Window '_Dashboard').workspace) $(Get-WorkspaceName 2)" 'outside tuios, the dashboard gets a workspace of its own, labelled Dashboard'
    Assert-Equal $session (Get-TuiosDashboardSession '_Dashboard') 'the dashboard is found in the apps session'
    Stop-TuiosApp '_Dashboard'
    Assert-Equal '' (Get-WorkspaceName 2) 'stopping the dashboard frees its workspace'

    $apps = @(
        [pscustomobject]@{ Name = 'Shop'; Type = 'Django'; Port = 8000; Group = 'Shop' },
        [pscustomobject]@{ Name = 'Shop Scheduler'; CustomCommand = 'sched'; Group = 'Shop'; PaneSide = 'down'; PaneRatio = 30 },
        [pscustomobject]@{ Name = 'Shop Mailer'; CustomCommand = 'mail'; Group = 'Shop'; PaneSide = 'down'; PaneRatio = 30 },
        [pscustomobject]@{ Name = 'Blog'; Type = 'Streamlit'; Port = 8501; Group = 'Blog' },
        [pscustomobject]@{ Name = 'Solo'; Type = 'Streamlit'; Port = 8502 }
    )
    function Start-Entry($Name) { $app = $apps | Where-Object Name -ceq $Name; Start-TuiosAppWindow -Apps $apps -App $app -Name $Name -WorkingDirectory $tmp -EncodedCommand $sleep | Out-Null }

    Assert-Equal 'group' (Get-TuiosGroupPlacement -Apps $apps -App $apps[1]).Mode 'a group with nothing running needs a workspace of its own'
    Start-Entry 'Shop Scheduler'
    Assert-True (Test-TuiosWindow '_placeholder') 'the placeholder stays while workspace 1 has nothing else (closing it would pull the group onto 1)'
    Assert-Equal 2 (Get-Window 'Shop Scheduler').workspace 'the first pane of a group opens on the lowest empty workspace (2)'
    Assert-Equal 'Shop' (Get-WorkspaceName 2) 'the workspace is labelled with the group'
    Start-Entry 'Shop'
    $shop = Get-Window 'Shop'; $scheduler = Get-Window 'Shop Scheduler'
    Assert-Equal 2 $shop.workspace 'the app joins its running scheduler'
    Assert-True ($shop.y -lt $scheduler.y -and $shop.height -gt $scheduler.height) 'restarting beside the scheduler, the app goes above it and takes the larger share'

    Stop-TuiosApp 'Shop'; Stop-TuiosApp 'Shop Scheduler'
    Assert-True (-not (Test-TuiosWindow 'Shop')) 'stop closes the window'
    Assert-Equal '' (Get-WorkspaceName 2) 'stopping the last pane of a group clears its label'

    Start-Entry 'Shop'
    Start-Entry 'Shop Scheduler'
    $shop = Get-Window 'Shop'; $scheduler = Get-Window 'Shop Scheduler'
    Assert-Equal 2 $shop.workspace 'the freed workspace is used again'
    Assert-True ($scheduler.workspace -eq 2 -and $scheduler.y -gt $shop.y -and $scheduler.x -eq $shop.x) 'the scheduler opens below the app'
    $total = $shop.height + $scheduler.height
    Assert-True ([Math]::Abs($scheduler.height / $total - 0.3) -le 0.1) "the scheduler takes about 30% ($($scheduler.height) of $total rows)"
    Start-Entry 'Shop Mailer'
    $shop = Get-Window 'Shop'; $scheduler = Get-Window 'Shop Scheduler'; $mailer = Get-Window 'Shop Mailer'
    Assert-True ($mailer.workspace -eq 2 -and $mailer.y -eq $scheduler.y -and $mailer.x -gt $scheduler.x) 'a second pane on the same side opens beside the first one'
    Assert-True ($shop.height -gt $scheduler.height) 'and the app keeps its share'

    Start-Entry 'Blog'
    Assert-Equal '3 Blog' "$((Get-Window 'Blog').workspace) $(Get-WorkspaceName 3)" 'another group gets the next empty workspace'
    Start-Entry 'Solo'
    Assert-Equal 1 (Get-Window 'Solo').workspace 'an app with no Group opens on workspace 1'
    Assert-True (-not (Test-TuiosWindow '_placeholder')) 'the placeholder is closed once workspace 1 has a window'
    Assert-Equal '2 2 2 3' "$((Get-Window 'Shop').workspace) $((Get-Window 'Shop Scheduler').workspace) $((Get-Window 'Shop Mailer').workspace) $((Get-Window 'Blog').workspace)" 'and the groups stay on their workspaces'

    # 2x2: PaneBeside names the pane to split
    $grid = @(
        [pscustomobject]@{ Name = 'Grid App'; Type = 'Streamlit'; Port = 8503; Group = 'Grid' },
        [pscustomobject]@{ Name = 'Grid A'; CustomCommand = 'a'; Group = 'Grid'; PaneSide = 'right' },
        [pscustomobject]@{ Name = 'Grid B'; CustomCommand = 'b'; Group = 'Grid'; PaneSide = 'down' },
        [pscustomobject]@{ Name = 'Grid C'; CustomCommand = 'c'; Group = 'Grid'; PaneSide = 'down'; PaneBeside = 'Grid A' }
    )
    foreach ($entry in $grid) { Start-TuiosAppWindow -Apps $grid -App $entry -Name $entry.Name -WorkingDirectory $tmp -EncodedCommand $sleep | Out-Null }
    $g = @{}; foreach ($entry in $grid) { $g[$entry.Name] = Get-Window $entry.Name }
    Assert-Equal '4 4 4 4' (($grid | ForEach-Object { $g[$_.Name].workspace }) -join ' ') 'the 2x2 group shares one workspace'
    Assert-True ($g['Grid App'].x -eq $g['Grid B'].x -and $g['Grid App'].y -lt $g['Grid B'].y) 'B is below the app (left column)'
    Assert-True ($g['Grid A'].x -eq $g['Grid C'].x -and $g['Grid A'].y -lt $g['Grid C'].y) 'C is below A (right column)'
    Assert-True ($g['Grid App'].y -eq $g['Grid A'].y -and $g['Grid App'].x -lt $g['Grid A'].x) 'A is right of the app (top row)'
    Assert-True ($g['Grid B'].y -eq $g['Grid C'].y) 'B and C share the bottom row'
    Write-Host ('  2x2 geometry: ' + (($grid | ForEach-Object { $w = $g[$_.Name]; "$($_.Name)=$($w.x),$($w.y) $($w.width)x$($w.height)" }) -join '; '))

    Stop-AllTuiosWindows | Out-Null
    Assert-True (-not (Test-TuiosSession)) 'stop all removes the session'

    # A manager running in a tuios pane: the dashboard opens beside it, in the manager's session
    $managerSession = "${session}_mgr"
    & $tuios new $managerSession --detach 2>$null | Out-Null
    $managerPane = Invoke-InTuiosSession $managerSession {
        New-TuiosWindow -Name 'manager' -WorkingDirectory $tmp -EncodedCommand $sleep
        Get-TuiosWindowId 'manager'
    }
    $env:TUIOS_SESSION = $managerSession; $env:TUIOS_WINDOW_ID = $managerPane
    try {
        Start-TuiosDashboardWindow -Name '_Dashboard' -WorkingDirectory $tmp -EncodedCommand $sleep | Out-Null
        Assert-Equal $managerSession (Get-TuiosDashboardSession '_Dashboard') 'in a tuios pane, the dashboard opens in the manager''s session'
        $panes = Invoke-InTuiosSession $managerSession { @((Get-Window 'manager'), (Get-Window '_Dashboard')) }
        Assert-True ($panes[0].workspace -eq $panes[1].workspace -and $panes[1].x -gt $panes[0].x) 'beside the manager''s pane, on its workspace'
        Assert-True (-not (Test-TuiosSession)) 'and the apps session is not created for it'
    } finally {
        Remove-Item env:TUIOS_SESSION, env:TUIOS_WINDOW_ID -ErrorAction SilentlyContinue
        & $tuios kill-session $managerSession 2>$null | Out-Null
    }
}
finally {
    & $tuios kill-session $session 2>$null | Out-Null
    foreach ($key in $savedEnv.Keys) { Set-Item "env:$key" $savedEnv[$key] -ErrorAction SilentlyContinue; if ($null -eq $savedEnv[$key]) { Remove-Item "env:$key" -ErrorAction SilentlyContinue } }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'TuiosHelpers tests passed.'
