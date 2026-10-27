<#
.SYNOPSIS
    Enable or disable an identity pool.

.DESCRIPTION
    PowerShell equivalent of set_identity_pool_state.py. Typical use: create the pool disabled
    (is_enabled: false in config.yml), register the redirect URI in your IdP, then switch the pool
    on - and switch it straight back off if something looks wrong.

    With neither -Enable nor -Disable it only reports the pool's current state (read-only).
    The change is verified by fetching the pool again afterwards.

    The pool UUID comes from created_resources.json (written by setup_identity_pool.ps1) unless
    -PoolUuid is given.

    Secrets are read from environment variables (or a .env file):
      TABLEAU_TOKEN_NAME    personal access token name
      TABLEAU_TOKEN_SECRET  personal access token secret

.PARAMETER Config
    Path to the YAML (or JSON) configuration file. Default: config.yml

.PARAMETER StateFile
    Where the pool UUID is read from. Default: created_resources.json

.PARAMETER PoolUuid
    Identity pool UUID (default: read from the state file).

.PARAMETER Enable
    Enable the pool.

.PARAMETER Disable
    Disable the pool.

.PARAMETER DryRun
    Log planned actions without making API calls.

.EXAMPLE
    .\powershell\set_identity_pool_state.ps1 -Config config.yml            # show current state
    .\powershell\set_identity_pool_state.ps1 -Config config.yml -Enable
    .\powershell\set_identity_pool_state.ps1 -Config config.yml -Disable
#>
[CmdletBinding()]
param(
    [string]$Config = 'config.yml',
    [string]$StateFile = 'created_resources.json',
    [string]$PoolUuid,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TableauIdp.psm1') -Force

Import-IdpDotEnv -Path (Join-Path $PSScriptRoot '..\.env')
Import-IdpDotEnv -Path '.env'

$name = 'set_identity_pool_state'
Initialize-IdpLogging -ScriptName $name | Out-Null

function Format-State($enabled) {
    if ($null -eq $enabled) { return 'unknown' }
    if ($enabled) { return 'ENABLED' } else { return 'DISABLED' }
}

if ($Enable -and $Disable) {
    Write-IdpLog -Level ERROR -Name $name -Message 'Specify either -Enable or -Disable, not both.'
    exit 1
}

$state = Read-IdpState -Path $StateFile
$explicitPool = [bool]$PoolUuid
if (-not $PoolUuid -and $state.ContainsKey('identity_pool_uuid')) { $PoolUuid = [string]$state['identity_pool_uuid'] }
if (-not $PoolUuid) {
    Write-IdpLog -Level ERROR -Name $name -Message "No pool UUID: pass -PoolUuid or run setup_identity_pool.ps1 first ($StateFile)."
    exit 1
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

if (-not $explicitPool -and $state.ContainsKey('server_url') -and $state['server_url'].TrimEnd('/') -ne $serverUrl.TrimEnd('/')) {
    Write-IdpLog -Level ERROR -Name $name -Message "State file was written for $($state['server_url']) but the config points at $serverUrl - refusing to continue."
    exit 1
}

$session = New-IdpSession -ServerUrl $serverUrl -SiteUri (Get-IdpConfigValue $cfg 'server' 'site_uri' '') -DryRun:$DryRun
$exitCode = 0

try {
    Connect-IdpSession -Session $session -TokenName $tokenName -TokenSecret $tokenSecret
    $before = Get-IdpPoolEnabled -Session $session -PoolUuid $PoolUuid
    Write-IdpLog -Name $name -Message "Identity pool $PoolUuid is currently $(Format-State $before)"

    if ($Enable -or $Disable) {
        $desired = [bool]$Enable
        if ($null -ne $before -and $before -eq $desired) {
            Write-IdpLog -Name $name -Message "Already $(Format-State $desired) - nothing to do"
        }
        elseif (Set-IdpPoolEnabled -Session $session -PoolUuid $PoolUuid -Enabled $desired) {
            $suffix = if ($DryRun) { ' (dry run)' } else { '' }
            Write-IdpLog -Name $name -Message "Identity pool $PoolUuid is now $(Format-State $desired)$suffix"
        }
        else {
            Write-IdpLog -Level ERROR -Name $name -Message ("Could not set the pool to $(Format-State $desired) - see the warnings above " +
                'and the log file for the requests and responses.')
            $exitCode = 1
        }
    }
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Failed: $_"
    $exitCode = 1
}
finally {
    Disconnect-IdpSession -Session $session
}
exit $exitCode
