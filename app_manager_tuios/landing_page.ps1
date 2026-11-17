#Requires -Version 7.0
<#
.SYNOPSIS
Host an HTML dashboard for all app URLs on port 1111 (or a supplied port).

.DESCRIPTION
The PowerShell twin of landing_page.sh. The page is regenerated from apps.json on each request, so app status and
links stay current. It listens on every interface like the bash version (for the Network/External links and nginx).
On Windows that needs a URL reservation, which a standard user does not have; without one it listens on localhost and
says so. Press Enter (or Ctrl+C) to stop it.

.EXAMPLE
./landing_page.ps1
./landing_page.ps1 -Port 8080
#>
[CmdletBinding()]
param([Parameter(Position = 0)][ValidateRange(1, 65535)][int]$Port = 1111)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$modules = Join-Path $PSScriptRoot 'Modules'
Import-Module (Join-Path $modules 'AppHelpers.psm1') -Force
Import-Module (Join-Path $modules 'TuiosHelpers.psm1') -Force
Import-Module (Join-Path $modules 'Dashboard.psm1') -Force

$htmlFile = Join-Path $PSScriptRoot 'app_index.html'

function Get-DashboardPage {
    $appsPath = Get-TuiosAppsPath -ScriptRoot $PSScriptRoot
    if (-not $appsPath) { return "<html><body><p>apps.json not found</p></body></html>" }
    return New-DashboardHtml -Apps @(Read-AppsFile $appsPath) -NetworkUrl $script:NetworkUrl -ExternalUrl $script:ExternalUrl
}

function Send-Response {
    param([System.Net.HttpListenerResponse]$Response, [int]$Status, [string]$ContentType, [string]$Body)
    # Content-Length is the byte count, not the character count (emojis are multi-byte in UTF-8)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

Write-Host 'Detecting network configuration...' -ForegroundColor Blue
$script:NetworkUrl = Get-NetworkUrlPrefix
$script:ExternalUrl = Get-ExternalUrlPrefix
$genericUrl = Get-GenericUrlPrefix
Write-Host "  Network URL:  $script:NetworkUrl" -ForegroundColor Cyan
Write-Host "  External URL: $script:ExternalUrl" -ForegroundColor Cyan
Write-Host "  Generic URL:  $genericUrl" -ForegroundColor Cyan
Write-Host ''

# Check if HTML file exists, if not generate it
if (Test-Path -LiteralPath $htmlFile) {
    Write-Host "Dashboard found at: $htmlFile" -ForegroundColor Blue
} else {
    Write-Host 'Generating dashboard HTML...' -ForegroundColor Blue
    [System.IO.File]::WriteAllText($htmlFile, (Get-DashboardPage), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Dashboard generated and saved to: $htmlFile" -ForegroundColor Green
}

$listener = $null
$localOnly = $false
foreach ($prefix in @("http://+:$Port/", "http://localhost:$Port/")) {
    $candidate = [System.Net.HttpListener]::new()
    $candidate.Prefixes.Add($prefix)
    try {
        $candidate.Start()
        $listener = $candidate
        $localOnly = $prefix -like 'http://localhost*'
        break
    } catch {
        $candidate.Close()
        $message = $_.Exception.Message
    }
}
if (-not $listener) {
    Write-Host "Error: port $Port is unavailable. The dashboard must bind to this fixed port for nginx. $message" -ForegroundColor Red
    exit 1
}

Write-Host "Starting HTTP server on port $Port" -ForegroundColor Green
Write-Host ''
Write-Host 'Access the dashboard at:'
if ($localOnly) {
    Write-Host "  Local:     http://localhost:$Port" -ForegroundColor Green
    Write-Host '  Listening on localhost only: Windows needs a URL reservation to listen on every interface, e.g. (as admin)' -ForegroundColor Yellow
    Write-Host "    netsh http add urlacl url=http://+:$Port/ user=$env:USERDOMAIN\$env:USERNAME" -ForegroundColor Yellow
} else {
    Write-Host "  Network:   ${script:NetworkUrl}:$Port" -ForegroundColor Green
    Write-Host "  External:  ${script:ExternalUrl}:$Port" -ForegroundColor Green
    Write-Host "  Local:     http://localhost:$Port" -ForegroundColor Green
}
Write-Host ''

$interactive = -not [Console]::IsInputRedirected
if ($interactive) { Write-Host 'Press Enter to stop the server' -ForegroundColor Cyan }
else { Write-Host 'Running without a terminal; stop it with Ctrl+C or by closing its window' -ForegroundColor Cyan }

try {
    $pending = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if (-not $pending.Wait(200)) {
            if ($interactive -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Enter) { break }
            continue
        }
        $context = $pending.Result
        $pending = $listener.GetContextAsync()
        try {
            if ($context.Request.Url.AbsolutePath -in @('/', '/index.html')) {
                Send-Response $context.Response 200 'text/html; charset=utf-8' (Get-DashboardPage)
            } else {
                Send-Response $context.Response 404 'text/plain' '404 - Not Found'
            }
        } catch {
            try { Send-Response $context.Response 500 'text/plain; charset=utf-8' "Error: $($_.Exception.Message)" } catch {}
        }
    }
} finally {
    Write-Host ''
    Write-Host 'Shutting down server...' -ForegroundColor Yellow
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host 'Server stopped' -ForegroundColor Green
}
