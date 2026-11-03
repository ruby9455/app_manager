# Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulesRoot = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'Modules'
Import-Module -Force (Join-Path $modulesRoot 'LaunchHelpers.psm1')
Import-Module -Force (Join-Path $modulesRoot 'TerminalHelpers.psm1')

function Assert-NotNullOrEmpty($value, $message){ if ([string]::IsNullOrEmpty([string]$value)) { throw $message } }
function Assert-True($cond, $message){ if (-not $cond) { throw $message } }

Write-Host 'Test: New-EncodedPwshCommand returns a base64 string'
$cmd = New-EncodedPwshCommand -WorkingDir $PSScriptRoot -WindowTitle 'Test' -RunCmd 'Write-Host "Hello"'
Assert-NotNullOrEmpty $cmd 'Expected a non-empty encoded command'

Write-Host 'Test: Get-PackageContext returns expected properties'
$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP (New-Guid)) -Force
try {
	$ctx = Get-PackageContext -App ([pscustomobject]@{}) -WorkingDir $tmp.FullName
	Assert-True ($ctx.PSObject.Properties.Name -contains 'PackageManager') 'Missing PackageManager'
	Assert-True ($ctx.PSObject.Properties.Name -contains 'VenvActivate') 'Missing VenvActivate'
	Assert-True ($ctx.PSObject.Properties.Name -contains 'Bootstrap') 'Missing Bootstrap'
} finally { Remove-Item -Recurse -Force $tmp.FullName }

Write-Host 'Test: Start-AppsList DryRun does not throw'
$pwshPath = (Get-Command pwsh).Source
$dummy = [pscustomobject]@{ Name = 'Dummy'; Type='Streamlit'; AppPath = $PSScriptRoot; IndexPath = 'Test-LaunchHelpers.ps1'; Port = 12345 }
Start-AppsList -AppList @($dummy) -PwshPath $pwshPath -DryRun

# The command a DryRun would start (or the warning it gives) for one app entry
function Get-DryRunLine([hashtable]$Fields) {
	$base = @{ Name = 'T'; AppPath = $PSScriptRoot; PackageManager = 'uv' }
	foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
	$app = [pscustomobject]$base
	$out = @(Start-AppsList -AppList @($app) -PwshPath $pwshPath -DryRun 6>&1 3>&1 | ForEach-Object { "$_" })
	return ($out -join "`n") -replace "^\[DryRun\] Would start 'T' in '.*?' with: ", ''
}
function Assert-Equal($expected, $actual, $message){ if ($expected -cne $actual) { throw "$message`nExpected: $expected`nActual:   $actual" } }

Write-Host 'Test: Custom app fills {port} and keeps a command that starts with uv'
Assert-Equal 'uv run --directory web_ui/backend python -m serve --host 0.0.0.0 --port 8080' `
	(Get-DryRunLine @{ Type = 'Custom'; Port = 8080; CustomCommand = 'uv run --directory web_ui/backend python -m serve --host 0.0.0.0 --port {port}' }) 'uv command'

Write-Host 'Test: Custom app sets leading VAR=value settings first and puts uv run in front (uvicorn is not uv)'
Assert-Equal "`$env:TZ = 'Europe/London'; uv run uvicorn app.main:app --port 8100" `
	(Get-DryRunLine @{ Type = 'Custom'; Port = 8100; CustomCommand = 'TZ=Europe/London uvicorn app.main:app --port {port}' }) 'env + uvicorn'
Assert-Equal "`$env:A = 'it''s here'; `$env:B = 'x y'; uv run python app.py" `
	(Get-DryRunLine @{ Type = 'Custom'; Port = 1; CustomCommand = "A=`"it's here`" B='x y' python app.py" }) 'quoted values'

Write-Host 'Test: a uv/uvx command runs as-is even with pip (no venv bootstrap)'
Assert-Equal 'uvx some-tool --port 8100' (Get-DryRunLine @{ Type = 'Custom'; Port = 8100; PackageManager = 'pip'; CustomCommand = 'uvx some-tool --port {port}' }) 'uvx with pip'

Write-Host 'Test: Custom app without Port or CustomCommand is skipped with a reason'
Assert-True ((Get-DryRunLine @{ Type = 'Custom'; CustomCommand = 'uvicorn app:app' }) -match 'needs a Port') 'Custom without Port'
Assert-True ((Get-DryRunLine @{ Type = 'Custom'; Port = 8100 }) -match 'needs a CustomCommand') 'Custom without CustomCommand'
Assert-True ((Get-DryRunLine @{ CustomCommand = 'python serve.py --port {port}' }) -match 'uses \{port\} but Port is not set') 'process with {port}, no Port'

Write-Host 'Test: processes (CustomCommand, no Type) are unchanged'
Assert-Equal 'uv run python -m app.scheduler' (Get-DryRunLine @{ CustomCommand = 'python -m app.scheduler' }) 'process'

Write-Host 'LaunchHelpers tests completed.' -ForegroundColor Green
