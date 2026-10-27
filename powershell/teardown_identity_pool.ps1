<#
.SYNOPSIS
    Roll back what setup_identity_pool.ps1 created.

.DESCRIPTION
    Deletes the identity pool, then the authentication configuration, then the identity
    store (reverse order of creation). By default the IDs come from created_resources.json,
    which setup writes as it goes. Only resources recorded there (or passed explicitly)
    are ever deleted. The state file is shared with the Python scripts.

    Secrets are read from environment variables (or a .env file):
      TABLEAU_TOKEN_NAME    personal access token name
      TABLEAU_TOKEN_SECRET  personal access token secret

.PARAMETER Config
    Path to the YAML (or JSON) configuration file. Default: config.yml

.PARAMETER StateFile
    Recorded IDs to delete. Default: created_resources.json

.PARAMETER PoolUuid
    Delete this specific identity pool instead of reading the state file.

.PARAMETER AuthConfigId
    Delete this specific auth configuration instead of reading the state file.

.PARAMETER StoreId
    Delete this specific identity store instead of reading the state file.

.PARAMETER DryRun
    Log planned deletions without making any API calls.

.PARAMETER Force
    Do not ask for confirmation.

.EXAMPLE
    .\powershell\teardown_identity_pool.ps1 -Config config.yml -DryRun
    .\powershell\teardown_identity_pool.ps1 -Config config.yml
#>
[CmdletBinding()]
param(
    [string]$Config = 'config.yml',
    [string]$StateFile = 'created_resources.json',
    [string]$PoolUuid,
    [string]$AuthConfigId,
    [string]$StoreId,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TableauIdp.psm1') -Force

Import-IdpDotEnv -Path (Join-Path $PSScriptRoot '..\.env')
Import-IdpDotEnv -Path '.env'

$name = 'teardown_identity_pool'
Initialize-IdpLogging -ScriptName $name | Out-Null

# Order matters: pool first, store last.
$steps = @(
    @{ Key = 'identity_pool_uuid'; Label = 'identity pool'; Delete = { param($s, $v) Remove-IdpIdentityPool -Session $s -PoolUuid $v } },
    @{ Key = 'auth_config_id'; Label = 'auth configuration'; Delete = { param($s, $v) Remove-IdpAuthConfig -Session $s -ConfigId $v } },
    @{ Key = 'identity_store_id'; Label = 'identity store'; Delete = { param($s, $v) Remove-IdpIdentityStore -Session $s -StoreId $v } }
)

$useExplicit = [bool]($PoolUuid -or $AuthConfigId -or $StoreId)
if ($useExplicit) {
    $state = @{}
    if ($PoolUuid) { $state['identity_pool_uuid'] = $PoolUuid }
    if ($AuthConfigId) { $state['auth_config_id'] = $AuthConfigId }
    if ($StoreId) { $state['identity_store_id'] = $StoreId }
}
else {
    $state = Read-IdpState -Path $StateFile
}
$targets = @($steps | Where-Object { $state.ContainsKey($_.Key) -and $state[$_.Key] })
if ($targets.Count -eq 0) {
    Write-IdpLog -Level ERROR -Name $name -Message "Nothing to delete: no IDs in $StateFile and none passed as parameters."
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

if ($state.ContainsKey('server_url') -and $state['server_url'].TrimEnd('/') -ne $serverUrl.TrimEnd('/')) {
    Write-IdpLog -Level ERROR -Name $name -Message "State file was written for $($state['server_url']) but the config points at $serverUrl - refusing to continue."
    exit 1
}

Write-IdpLog -Name $name -Message "Will delete from ${serverUrl}:"
foreach ($t in $targets) { Write-IdpLog -Name $name -Message ('  {0,-18} {1}' -f $t.Label, $state[$t.Key]) }

if (-not $DryRun -and -not $Force) {
    try { $answer = Read-Host "Type 'yes' to delete the resources above" } catch { $answer = '' }
    if ("$answer".Trim().ToLower() -ne 'yes') {
        Write-IdpLog -Name $name -Message 'Aborted - nothing deleted.'
        exit 1
    }
}

$session = New-IdpSession -ServerUrl $serverUrl -SiteUri (Get-IdpConfigValue $cfg 'server' 'site_uri' '') -DryRun:$DryRun
$failures = 0
$exitCode = 0

try {
    Connect-IdpSession -Session $session -TokenName $tokenName -TokenSecret $tokenSecret
    foreach ($t in $targets) {
        $value = $state[$t.Key]
        try {
            & $t.Delete $session $value
        }
        catch {
            if ("$_" -match '404') {
                Write-IdpLog -Level WARNING -Name $name -Message "$($t.Label) $value was already gone (404) - treating as deleted"
            }
            else {
                # Keep going so one failure doesn't strand the rest.
                $failures++
                Write-IdpLog -Level ERROR -Name $name -Message "Failed to delete $($t.Label) ${value}: $_"
                continue
            }
        }
        if (-not $DryRun -and -not $useExplicit) {
            $state.Remove($t.Key)
            Write-IdpState -Path $StateFile -State $state
        }
    }
    if ($failures -gt 0) {
        Write-IdpLog -Level ERROR -Name $name -Message "$failures deletion(s) failed - see above. Remaining IDs are still in $StateFile."
        $exitCode = 1
    }
    else {
        if (-not $DryRun -and -not $useExplicit) { Remove-IdpStateFile -Path $StateFile }
        $suffix = if ($DryRun) { ' (dry run)' } else { '' }
        Write-IdpLog -Name $name -Message "Teardown complete$suffix"
    }
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Aborted: $_"
    $exitCode = 1
}
finally {
    Disconnect-IdpSession -Session $session
}
exit $exitCode
