<#
.SYNOPSIS
    Set up a Tableau Server identity pool via the REST and authn-service APIs.

.DESCRIPTION
    PowerShell equivalent of setup_identity_pool.py. Steps (each validated before
    proceeding to the next):
      1. Authenticate with a personal access token
      2. Create an identity store
      3. Create an OIDC authentication configuration
      4. Create an identity pool linking the store and auth configuration
      5. Print the IdP redirect URI to configure in your identity provider

    Secrets are read from environment variables (or a .env file):
      TABLEAU_TOKEN_NAME          personal access token name
      TABLEAU_TOKEN_SECRET        personal access token secret
      TABLEAU_OIDC_CLIENT_SECRET  OIDC client secret

.PARAMETER Config
    Path to the YAML (or JSON) configuration file. Default: config.yml

.PARAMETER DryRun
    Log all planned actions without making any API calls.

.PARAMETER StateFile
    Where to record created resource IDs so teardown_identity_pool.ps1 can roll them back.
    Default: created_resources.json

.PARAMETER Resume
    Continue a run recorded in the state file: reuse the resources it already created (after
    checking they still exist and their config is unchanged) instead of refusing to run.
    Ignored with -DryRun.

.EXAMPLE
    .\powershell\setup_identity_pool.ps1 -Config config.yml -DryRun
    .\powershell\setup_identity_pool.ps1 -Config config.yml
    .\powershell\setup_identity_pool.ps1 -Config config.yml -Resume   # continue a run that failed part-way
#>
[CmdletBinding()]
param(
    [string]$Config = 'config.yml',
    [switch]$DryRun,
    [string]$StateFile = 'created_resources.json',
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TableauIdp.psm1') -Force

Import-IdpDotEnv -Path (Join-Path $PSScriptRoot '..\.env')
Import-IdpDotEnv -Path '.env'

$name = 'setup_identity_pool'
Initialize-IdpLogging -ScriptName $name | Out-Null

if ($DryRun) {
    Write-IdpLog -Name $name -Message ('=' * 60)
    Write-IdpLog -Name $name -Message 'DRY RUN MODE - no changes will be made to the server'
    Write-IdpLog -Name $name -Message ('=' * 60)
}

# ── Config & secrets ──────────────────────────────────────────────────────────
Write-IdpLog -Name $name -Message "Loading configuration from: $Config"
try {
    $cfg = Import-IdpConfig -Path $Config
    $serverUrl = Get-IdpConfigValue $cfg 'server' 'url' -Required
    $tokenName = Get-IdpRequiredEnv 'TABLEAU_TOKEN_NAME' 'personal access token name'
    $tokenSecret = Get-IdpRequiredEnv 'TABLEAU_TOKEN_SECRET' 'personal access token secret'
    $oidcClientSecret = Get-IdpRequiredEnv 'TABLEAU_OIDC_CLIENT_SECRET' 'OIDC client secret'
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Configuration error: $_"
    exit 1
}

$existing = if ($DryRun) { @{} } else { Read-IdpState -Path $StateFile }
if ($existing.Count -gt 0 -and -not $Resume) {
    Write-IdpLog -Level ERROR -Name $name -Message ("$StateFile already records resources from an earlier run. Continue it with -Resume, " +
        'roll it back with teardown_identity_pool.ps1, or delete the file to keep them and start over.')
    exit 1
}
if ($Resume -and -not $DryRun -and $existing.Count -eq 0) {
    Write-IdpLog -Name $name -Message "-Resume given but $StateFile has no recorded resources - starting fresh"
}
if ($existing.ContainsKey('server_url') -and $existing['server_url'].TrimEnd('/') -ne $serverUrl.TrimEnd('/')) {
    Write-IdpLog -Level ERROR -Name $name -Message "$StateFile was written for $($existing['server_url']) but the config points at $serverUrl - refusing to resume."
    exit 1
}

$session = New-IdpSession -ServerUrl $serverUrl -SiteUri (Get-IdpConfigValue $cfg 'server' 'site_uri' '') -DryRun:$DryRun
$exitCode = 0
$state = if ($existing.Count -gt 0) { $existing } else { @{ server_url = $session.ServerUrl } }
$fingerprints = @{}
if ($state.ContainsKey('fingerprints') -and $state['fingerprints']) {
    foreach ($prop in $state['fingerprints'].PSObject.Properties) { $fingerprints[$prop.Name] = $prop.Value }
}
$state['fingerprints'] = $fingerprints

function Save-Created($key, $value, $fpName, $section) {
    # Persist each created ID immediately so a later failure can still be rolled back.
    if (-not $DryRun) {
        $state[$key] = $value
        $fingerprints[$fpName] = Get-IdpConfigFingerprint -Section $section
        Write-IdpState -Path $StateFile -State $state
    }
}

function Use-Recorded($key, $label, $fpName, $section, [scriptblock]$validate) {
    # On -Resume, return the recorded ID for this step if it is still valid, else $null.
    if (-not $existing.ContainsKey($key) -or -not $existing[$key]) { return $null }
    $recorded = [string]$existing[$key]
    if ($fingerprints.ContainsKey($fpName)) {
        if ($fingerprints[$fpName] -ne (Get-IdpConfigFingerprint -Section $section)) {
            throw "The $label config changed since it was created ($recorded). Roll back with teardown_identity_pool.ps1 and run setup again."
        }
    }
    else {
        Write-IdpLog -Level WARNING -Name $name -Message "No config fingerprint recorded for the $label - cannot check it is unchanged"
    }
    if (-not (& $validate $recorded)) {
        throw "Recorded $label $recorded no longer exists on the server. Roll back with teardown_identity_pool.ps1 and run setup again."
    }
    Write-IdpLog -Name $name -Message "Resuming: reusing $label $recorded"
    return $recorded
}

try {
    # ── Step 1: Authenticate ──────────────────────────────────────────────────
    Write-IdpLog -Name $name -Message '── Step 1: Authenticating ──────────────────────────────'
    Connect-IdpSession -Session $session -TokenName $tokenName -TokenSecret $tokenSecret
    Write-IdpLog -Name $name -Message "Session established (API version: $($session.ApiVersion), site ID: $($session.SiteId))"

    # ── Step 2: Identity store ────────────────────────────────────────────────
    Write-IdpLog -Name $name -Message '── Step 2: Identity store ──────────────────────────────'
    $storeCfg = $cfg['identity_store']
    $storeId = Use-Recorded 'identity_store_id' 'identity store' 'identity_store' $storeCfg `
        { param($id) Test-IdpIdentityStoreExists -Session $session -StoreId $id }
    if (-not $storeId) {
        $storeId = New-IdpIdentityStore -Session $session `
            -Name (Get-IdpConfigValue $cfg 'identity_store' 'name' -Required) `
            -DisplayName (Get-IdpConfigValue $cfg 'identity_store' 'display_name')
        Save-Created 'identity_store_id' $storeId 'identity_store' $storeCfg
        if (-not (Test-IdpIdentityStoreExists -Session $session -StoreId $storeId)) {
            throw 'Identity store validation failed - aborting'
        }
    }

    # ── Step 3: Auth configuration ────────────────────────────────────────────
    Write-IdpLog -Name $name -Message '── Step 3: OIDC auth configuration ─────────────────────'
    $authCfg = $cfg['auth_config']
    $authConfigId = Use-Recorded 'auth_config_id' 'auth configuration' 'auth_config' $authCfg `
        { param($id) Test-IdpAuthConfigExists -Session $session -ConfigId $id }
    if (-not $authConfigId) {
        $authConfigId = New-IdpAuthConfig -Session $session `
            -AuthType (Get-IdpConfigValue $cfg 'auth_config' 'auth_type' -Required) `
            -ClientId (Get-IdpConfigValue $cfg 'auth_config' 'client_id' -Required) `
            -ClientSecret $oidcClientSecret `
            -ConfigUrl (Get-IdpConfigValue $cfg 'auth_config' 'config_url' -Required) `
            -IdClaim (Get-IdpConfigValue $cfg 'auth_config' 'id_claim' 'sub') `
            -UsernameClaim (Get-IdpConfigValue $cfg 'auth_config' 'username_claim' 'email') `
            -ClientAuthentication (Get-IdpConfigValue $cfg 'auth_config' 'client_authentication' 'CLIENT_SECRET_BASIC') `
            -IframedIdpEnabled ([bool](Get-IdpConfigValue $cfg 'auth_config' 'iframed_idp_enabled' $false))
        Save-Created 'auth_config_id' $authConfigId 'auth_config' $authCfg
        if (-not (Test-IdpAuthConfigExists -Session $session -ConfigId $authConfigId)) {
            throw 'Auth configuration validation failed - aborting'
        }
    }

    # ── Step 4: Identity pool ─────────────────────────────────────────────────
    Write-IdpLog -Name $name -Message '── Step 4: Identity pool ───────────────────────────────'
    $poolCfg = $cfg['identity_pool']
    $poolUuid = Use-Recorded 'identity_pool_uuid' 'identity pool' 'identity_pool' $poolCfg `
        { param($id) Test-IdpIdentityPoolExists -Session $session -PoolUuid $id }
    if (-not $poolUuid) {
        $poolUuid = New-IdpIdentityPool -Session $session `
            -Name (Get-IdpConfigValue $cfg 'identity_pool' 'name' -Required) `
            -Description (Get-IdpConfigValue $cfg 'identity_pool' 'description' '') `
            -StoreId $storeId `
            -AuthConfigId $authConfigId `
            -IsEnabled ([bool](Get-IdpConfigValue $cfg 'identity_pool' 'is_enabled' $true))
        Save-Created 'identity_pool_uuid' $poolUuid 'identity_pool' $poolCfg
        if (-not (Test-IdpIdentityPoolExists -Session $session -PoolUuid $poolUuid)) {
            throw 'Identity pool validation failed - aborting'
        }
    }

    # ── Done ──────────────────────────────────────────────────────────────────
    $redirectUri = "$($session.ServerUrl)authn-service/authenticate/oidc/$poolUuid/login"
    $suffix = if ($DryRun) { ' (dry run)' } else { '' }
    Write-IdpLog -Name $name -Message ('=' * 60)
    Write-IdpLog -Name $name -Message "Setup complete$suffix"
    Write-IdpLog -Name $name -Message "Identity pool UUID : $poolUuid"
    Write-IdpLog -Name $name -Message "IdP redirect URI   : $redirectUri"
    Write-IdpLog -Name $name -Message 'Configure the redirect URI above in your IdP application.'
    if (-not $DryRun) { Write-IdpLog -Name $name -Message "To roll back: .\powershell\teardown_identity_pool.ps1 (uses $StateFile)" }
    Write-IdpLog -Name $name -Message ('=' * 60)
}
catch {
    Write-IdpLog -Level ERROR -Name $name -Message "Aborted: $_"
    $exitCode = 1
}
finally {
    Disconnect-IdpSession -Session $session
}
exit $exitCode
