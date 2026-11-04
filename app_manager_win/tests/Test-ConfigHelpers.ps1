# Simple smoke test for ConfigHelpers
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$modules = Join-Path $root 'Modules'
Import-Module -Force (Join-Path $modules 'AppHelpers.psm1')
Import-Module -Force (Join-Path $modules 'ConfigHelpers.psm1')

function Assert-Equal($Expected, $Actual, $Message) {
    if ($Expected -ne $Actual) { throw "$Message`n  expected: $Expected`n  actual:   $Actual" }
}

# Work in a temp folder so the test never reads or creates a real apps.json
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("appmgr_test_" + [guid]::NewGuid().ToString('N'))
$scriptRoot = Join-Path $tmp 'scripts'
$configDir = Join-Path $tmp 'config'
New-Item -ItemType Directory -Force $scriptRoot, $configDir | Out-Null
$savedEnv = @{
    APP_MANAGER_APPS_FILE  = $env:APP_MANAGER_APPS_FILE
    APP_MANAGER_CONFIG_DIR = $env:APP_MANAGER_CONFIG_DIR
}

try {
    $env:APP_MANAGER_APPS_FILE = $null
    $env:APP_MANAGER_CONFIG_DIR = $configDir
    $localPath = Join-Path $scriptRoot 'apps.json'

    Write-Host 'Test: falls back to apps.json next to the scripts when there is no machine folder'
    Assert-Equal $localPath (Get-AppsJsonFilePath -ScriptRoot $scriptRoot) 'local fallback'

    Write-Host 'Test: uses machines/<COMPUTERNAME>/<platform>/apps.json when it exists'
    $machineDir = Join-Path $configDir "machines\$env:COMPUTERNAME"
    New-Item -ItemType Directory -Force (Join-Path $machineDir 'win'), (Join-Path $machineDir 'psmux') | Out-Null
    '[]' | Set-Content (Join-Path $machineDir 'win\apps.json')
    Assert-Equal (Join-Path $machineDir 'win\apps.json') (Get-AppsJsonFilePath -ScriptRoot $scriptRoot) 'machine folder (win)'

    Write-Host 'Test: -Platform picks that platform folder, falling back to local when it has no file'
    Assert-Equal $localPath (Get-AppsJsonFilePath -ScriptRoot $scriptRoot -Platform 'psmux') 'missing psmux file falls back'
    '[]' | Set-Content (Join-Path $machineDir 'psmux\apps.json')
    Assert-Equal (Join-Path $machineDir 'psmux\apps.json') (Get-AppsJsonFilePath -ScriptRoot $scriptRoot -Platform 'psmux') 'machine folder (psmux)'

    Write-Host 'Test: APP_MANAGER_APPS_FILE overrides everything, and must exist'
    $explicit = Join-Path $tmp 'explicit.json'
    '[]' | Set-Content $explicit
    $env:APP_MANAGER_APPS_FILE = $explicit
    Assert-Equal $explicit (Get-AppsJsonFilePath -ScriptRoot $scriptRoot) 'explicit override'
    $env:APP_MANAGER_APPS_FILE = Join-Path $tmp 'missing.json'
    $threw = $false
    try { Get-AppsJsonFilePath -ScriptRoot $scriptRoot | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'missing APP_MANAGER_APPS_FILE should throw' }
    $env:APP_MANAGER_APPS_FILE = $null

    Write-Host 'Test: initialize, load and prepare editable apps from the template'
    Remove-Item -Recurse -Force (Join-Path $configDir 'machines')
    $jsonPath = Get-AppsJsonFilePath -ScriptRoot $scriptRoot
    Initialize-AppsJsonFile -JsonFilePath $jsonPath -ExamplePath (Join-Path $root 'apps_example.json')
    $apps = @(Get-AppsFromJson -JsonFilePath $jsonPath)
    if ($apps -eq $null) { throw 'Read-AppsFromJson returned null' }
    $editable = Initialize-EditableApps -Apps $apps
    if (-not (Get-Variable -Name apps -Scope Global -ErrorAction SilentlyContinue)) { throw 'global:apps not set' }
}
finally {
    $env:APP_MANAGER_APPS_FILE = $savedEnv.APP_MANAGER_APPS_FILE
    $env:APP_MANAGER_CONFIG_DIR = $savedEnv.APP_MANAGER_CONFIG_DIR
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host 'ConfigHelpers smoke tests completed.'
