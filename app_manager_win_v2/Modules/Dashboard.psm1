#Requires -Version 7.0
<#
.SYNOPSIS
Dashboard HTML for app_manager_win_v2 (the page of the tuios edition).

.DESCRIPTION
Renders the same page as lib/dashboard.sh (and the tmux edition): one card per app with a Port, with Localhost,
Network and External links. Apps with NginxPath link through nginx (base_url/NginxPath/, no port); the others link to
base_url:Port, plus BasePath when set.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppHelpers.psm1')

function ConvertTo-HtmlText { param([string]$Text) return [System.Net.WebUtility]::HtmlEncode($Text) }

# A URL inside a single-quoted JavaScript string in an onclick attribute
function ConvertTo-JsAttribute {
    param([string]$Text)
    return ConvertTo-HtmlText (($Text -replace '\\', '\\') -replace "'", "\'")
}

# The static parts of the page, the same as the heredocs in lib/dashboard.sh
$script:HeaderHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App Management Dashboard</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 2.5em;
            font-weight: 300;
        }
        .header p {
            margin: 10px 0 0 0;
            opacity: 0.9;
            font-size: 1.1em;
        }
        .apps-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            padding: 30px;
        }
        .app-card {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            border-left: 4px solid #11998e;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .app-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 25px rgba(0,0,0,0.1);
        }
        .app-name {
            font-size: 1.3em;
            font-weight: 600;
            color: #2c3e50;
            margin-bottom: 10px;
        }
        .app-type {
            background: #e3f2fd;
            color: #1976d2;
            padding: 4px 8px;
            border-radius: 15px;
            font-size: 0.8em;
            display: inline-block;
            margin-bottom: 15px;
        }
        .app-type.streamlit { background: #ffebee; color: #c62828; }
        .app-type.django { background: #e8f5e9; color: #2e7d32; }
        .app-type.flask { background: #fff3e0; color: #ef6c00; }
        .app-type.dash { background: #e3f2fd; color: #1565c0; }
        .app-type.custom { background: #f3e5f5; color: #6a1b9a; }
        .url-section { margin-bottom: 15px; }
        .url-label { font-weight: 600; color: #555; margin-bottom: 5px; font-size: 0.9em; }
        .url-container { display: flex; align-items: center; gap: 8px; margin-bottom: 5px; }
        .url-link {
            flex: 1;
            background: white;
            border: 1px solid #ddd;
            border-radius: 5px;
            padding: 8px 12px;
            text-decoration: none;
            color: #2c3e50;
            transition: background-color 0.2s;
            word-break: break-all;
            display: block;
        }
        .url-link:hover { background: #f0f8ff; border-color: #11998e; }
        .copy-btn {
            background: #667eea;
            color: white;
            border: none;
            padding: 6px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.85em;
            transition: background 0.2s;
            white-space: nowrap;
        }
        .copy-btn:hover { background: #5568d3; }
        .copy-btn:active { background: #4454b8; }
        .copy-btn.copied { background: #2ecc71; }
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            border-top: 1px solid #eee;
        }
        .refresh-btn {
            background: #11998e;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 1em;
            margin-bottom: 20px;
        }
        .refresh-btn:hover { background: #0e7a6f; }
        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-right: 8px;
        }
        .status-running { background: #2ecc71; }
        .status-stopped { background: #e74c3c; }
    </style>
    <script>
        function copyToClipboard(url, button) {
            // Try modern clipboard API first (requires HTTPS or localhost)
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(url).then(() => {
                    showCopySuccess(button);
                }).catch(err => {
                    console.error('Clipboard API failed:', err);
                    fallbackCopy(url, button);
                });
            } else {
                // Fallback for non-secure contexts (HTTP)
                fallbackCopy(url, button);
            }
        }
        
        function fallbackCopy(url, button) {
            const textArea = document.createElement('textarea');
            textArea.value = url;
            textArea.style.position = 'fixed';
            textArea.style.left = '-9999px';
            textArea.style.top = '-9999px';
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            try {
                const successful = document.execCommand('copy');
                if (successful) {
                    showCopySuccess(button);
                } else {
                    showCopyFailed(button);
                }
            } catch (err) {
                console.error('Fallback copy failed:', err);
                showCopyFailed(button);
            }
            document.body.removeChild(textArea);
        }
        
        function showCopySuccess(button) {
            const originalText = button.textContent;
            button.textContent = '✓ Copied!';
            button.classList.add('copied');
            setTimeout(() => {
                button.textContent = originalText;
                button.classList.remove('copied');
            }, 2000);
        }
        
        function showCopyFailed(button) {
            button.textContent = '✗ Failed';
            setTimeout(() => {
                button.textContent = '📋 Copy';
            }, 2000);
        }
    </script>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🖥️ App Management Dashboard</h1>
            <p>Server with Windows Terminal</p>
        </div>
        <div style="text-align: center; padding-top: 20px;">
            <button class="refresh-btn" onclick="location.reload()">🔄 Refresh</button>
        </div>
        <div class="apps-grid">
'@

$script:FooterHtml = @'
        </div>
        <div class="footer">
            <p>Generated by App Management • Powered by Windows Terminal</p>
        </div>
    </div>
</body>
</html>
'@

function New-DashboardCard {
    param([object]$App, [string]$NetworkUrl, [string]$ExternalUrl)
    $name = [string](Get-AppField $App 'Name'); if (-not $name) { $name = 'Unknown' }
    # A typeless entry with a port and a CustomCommand is a web app with its own start command
    $type = [string](Get-AppField $App 'Type')
    if (-not $type) { $type = if (Test-HasValue (Get-AppField $App 'CustomCommand')) { 'Custom' } else { 'Unknown' } }
    $port = [int](Get-AppField $App 'Port')
    $basePath = [string](Get-AppField $App 'BasePath')
    $nginxPath = [string](Get-AppField $App 'NginxPath')

    $running = Test-PortInUse $port
    $statusClass = if ($running) { 'status-running' } else { 'status-stopped' }
    $statusText = if ($running) { 'Running' } else { 'Stopped' }

    # nginx-proxied apps use a path-based URL (no port)
    if ($nginxPath) {
        $urls = @("http://localhost/$nginxPath/", "$NetworkUrl/$nginxPath/", "$ExternalUrl/$nginxPath/")
    } else {
        $suffix = if ($basePath) { '/' + $basePath.TrimStart('/') } else { '' }
        $urls = @("http://localhost:$port$suffix", "${NetworkUrl}:$port$suffix", "${ExternalUrl}:$port$suffix")
    }
    $labels = @('🏠 Localhost:', '🌐 Network:', '🌍 External:')

    $sections = for ($i = 0; $i -lt $urls.Count; $i++) {
        $url = ConvertTo-HtmlText $urls[$i]
        @"
                <div class="url-section">
                    <div class="url-label">$($labels[$i])</div>
                    <div class="url-container">
                        <a href="$url" target="_blank" class="url-link">$url</a>
                        <button class="copy-btn" onclick="copyToClipboard('$(ConvertTo-JsAttribute $urls[$i])', this)">📋 Copy</button>
                    </div>
                </div>
"@
    }
    return @"
            <div class="app-card">
                <div class="app-name">
                    $(ConvertTo-HtmlText $name)
                    <span class="status-indicator $statusClass" title="$statusText"></span>
                </div>
                <span class="app-type $(ConvertTo-HtmlText $type.ToLowerInvariant())">$(ConvertTo-HtmlText $type)</span>
$($sections -join "`n")
            </div>
"@
}

# The full dashboard page for the apps in apps.json
function New-DashboardHtml {
    param([object[]]$Apps, [string]$NetworkUrl = 'http://localhost', [string]$ExternalUrl = 'http://localhost')
    $withPorts = @($Apps | Where-Object { $port = Get-AppField $_ 'Port'; [string]$port -match '^\d+$' -and [int]$port -gt 0 })
    $cards = foreach ($app in $withPorts) { New-DashboardCard -App $app -NetworkUrl $NetworkUrl -ExternalUrl $ExternalUrl }
    return ($script:HeaderHtml, ($cards -join "`n"), $script:FooterHtml) -join "`n"
}

Export-ModuleMember -Function @('New-DashboardHtml')
