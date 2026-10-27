<#
.SYNOPSIS
    List all identity stores, auth configurations and identity pools on the Tableau Server.

.DESCRIPTION
    PowerShell equivalent of list_resources.py. Read-only; useful for inspecting state
    before or after running setup_identity_pool.ps1.

    Secrets are read from environment variables (or a .env file):
      TABLEAU_TOKEN_NAME    personal access token name
      TABLEAU_TOKEN_SECRET  personal access token secret

.PARAMETER Config
    Path to the YAML (or JSON) configuration file. Default: config.yml

.PARAMETER DryRun
    Simulate without making API calls.

.EXAMPLE
    .\powershell\list_resources.ps1 -Config config.yml
#>
[CmdletBinding()]
param(
    [string]$Config = 'config.yml',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TableauIdp.psm1') -Force

Import-IdpDotEnv -Path (Join-Path $PSScriptRoot '..\.env')
Import-IdpDotEnv -Path '.env'

$name = 'list_resources'
Initialize-IdpLogging -ScriptName $name | Out-Null

if ($DryRun) { Write-IdpLog -Name $name -Message '[DRY RUN] No real API calls will be made' }

function Format-Resources($items) {
    if (@($items).Count -eq 0) { return '(none)' }
    return ($items | ConvertTo-Json -Depth 10)
}

try {
    $cfg = Import-IdpConfig -Path $Config
    $serverUrl = Get-IdpConfigValue $cfg 'server' 'url' -Required
    $tokenName = Get-IdpRequiredEnv 'TABLEAU_TOKEN_NAME' 'personal access token name'
    $tokenSecret = Get-IdpRequiredEnv 'TABLEAU_TOKEN_SECRET' 'personal access token secret'
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Configuration error: $_"
    exit 1
}

$session = New-IdpSession -ServerUrl $serverUrl -SiteUri (Get-IdpConfigValue $cfg 'server' 'site_uri' '') -DryRun:$DryRun
$exitCode = 0

try {
    Connect-IdpSession -Session $session -TokenName $tokenName -TokenSecret $tokenSecret

    $stores = Get-IdpIdentityStores -Session $session
    Write-IdpLog -Name $name -Message '── Identity Stores ──────────────────────────────────'
    Write-IdpLog -Name $name -Message (Format-Resources $stores)

    $configs = Get-IdpAuthConfigs -Session $session
    Write-IdpLog -Name $name -Message '── Auth Configurations ──────────────────────────────'
    Write-IdpLog -Name $name -Message (Format-Resources $configs)

    $pools = Get-IdpIdentityPools -Session $session
    Write-IdpLog -Name $name -Message '── Identity Pools ───────────────────────────────────'
    Write-IdpLog -Name $name -Message (Format-Resources $pools)
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Failed: $_"
    $exitCode = 1
}
finally {
    Disconnect-IdpSession -Session $session
}
exit $exitCode
