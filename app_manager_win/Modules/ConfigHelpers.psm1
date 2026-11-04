Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ConfigHelpers.psm1 - centralize apps.json pathing, load/save, and in-memory state prep
# Depends on AppHelpers for ConvertTo-NormalizedAppsList and ConvertTo-Hashtable, Select-UniqueAppsByName

# Lookup order:
#   1. $env:APP_MANAGER_APPS_FILE (explicit path)
#   2. ($env:APP_MANAGER_CONFIG_DIR or ~/code/app_manager_config)/machines/<COMPUTERNAME>/<Platform>/apps.json, if it exists
#   3. apps.json next to the scripts
function Get-AppsJsonFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ScriptRoot,
        [Parameter(Mandatory=$false)][string]$Platform = 'win'
    )
    if ($env:APP_MANAGER_APPS_FILE) {
        if (-not (Test-Path -LiteralPath $env:APP_MANAGER_APPS_FILE)) { throw "APP_MANAGER_APPS_FILE not found: $env:APP_MANAGER_APPS_FILE" }
        return $env:APP_MANAGER_APPS_FILE
    }

    $configDir = if ($env:APP_MANAGER_CONFIG_DIR) { $env:APP_MANAGER_CONFIG_DIR } else { Join-Path $HOME 'code\app_manager_config' }
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    $machinePath = Join-Path $configDir (Join-Path 'machines' (Join-Path $hostName (Join-Path $Platform 'apps.json')))
    if (Test-Path -LiteralPath $machinePath) { return $machinePath }

    return (Join-Path $ScriptRoot 'apps.json')
}

function Initialize-AppsJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$JsonFilePath,
        [Parameter(Mandatory=$true)][string]$ExamplePath
    )
    if (-not (Test-Path $JsonFilePath)) {
        try {
            if (Test-Path $ExamplePath) {
                Copy-Item -Path $ExamplePath -Destination $JsonFilePath -Force
                Write-Host "Created apps.json from template: $ExamplePath"
            } else {
                '[]' | Out-File -FilePath $JsonFilePath -Encoding UTF8 -Force
                Write-Host "Created empty apps.json at: $JsonFilePath"
            }
        } catch {
            throw "Failed to create apps.json at ${JsonFilePath}: $($_.Exception.Message)"
        }
    }
}

function Get-AppsFromJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$JsonFilePath
    )
    $apps = Get-Content $JsonFilePath | ConvertFrom-Json
    return (ConvertTo-NormalizedAppsList -Apps $apps)
}

function Initialize-EditableApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()][AllowEmptyCollection()][array]$Apps
    )
    if ($null -eq $Apps) { $Apps = @() }
    $editable = @()
    foreach ($a in $Apps) { $editable += (ConvertTo-Hashtable -Object $a) }
    if ($editable.Count -eq 0) {
        $global:apps = @()
        return ,@()
    }
    $editable = Select-UniqueAppsByName -Apps $editable
    $global:apps = $editable
    return $editable
}

function Save-AppsInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$JsonFilePath,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$EditableApps
    )
    $saveResponse = Read-Host ">>> Would you like to save the updated apps list to the JSON file? (y/n)"
    if ($saveResponse -ieq "yes" -or $saveResponse -ieq "y") {
        try {
            $EditableApps | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFilePath -Encoding UTF8
            Write-Host "Apps list saved successfully to $JsonFilePath."
            # reload from file (read-only view)
            $apps = Get-AppsFromJson -JsonFilePath $JsonFilePath
            # refresh editable list (deduped)
            $editable = Initialize-EditableApps -Apps $apps
            return [pscustomobject]@{ Apps = $apps; EditableApps = $editable }
        } catch {
            Write-Host "Failed to save file: $($_.Exception.Message)"
            return [pscustomobject]@{ Apps = $null; EditableApps = $EditableApps }
        }
    }
    return [pscustomobject]@{ Apps = $null; EditableApps = $EditableApps }
}

Export-ModuleMember -Function @(
    'Get-AppsJsonFilePath',
    'Initialize-AppsJsonFile',
    'Get-AppsFromJson',
    'Initialize-EditableApps',
    'Save-AppsInteractive'
)
