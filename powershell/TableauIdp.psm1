<#
.SYNOPSIS
    PowerShell port of the tableau_idp Python package.

.DESCRIPTION
    Authenticated session handling plus create/list/validate/update/delete helpers for
    Tableau Server identity stores, OIDC authentication configurations and identity pools.
    Requires only Windows PowerShell 5.1 or PowerShell 7+ - no extra modules.

    Both API tiers share the same X-Tableau-Auth token header:
      Standard REST API:   {server_url}api/{api_version}/...
      authn-service API:   {server_url}api/-/authn-service/...

    In dry-run mode all calls (including GETs) are logged and skipped so the scripts
    can run without a live server.
#>

Set-StrictMode -Version 2.0

# Windows PowerShell 5.1 defaults to older TLS versions; Tableau Server needs 1.2+.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:LogFile = $null
$script:DryRunApiVersion = '3.19'
$script:DryRunSiteId = 'DRY-RUN-SITE-ID'
$script:DryRunToken = 'DRY-RUN-AUTH-TOKEN'

# ── Logging ───────────────────────────────────────────────────────────────────

function Initialize-IdpLogging {
    <# Start a timestamped log file for this run and return its full path. #>
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$LogDir = 'logs'
    )
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path (Resolve-Path -LiteralPath $LogDir).Path "${ScriptName}_${timestamp}.log"
    Write-IdpLog -Level INFO -Name $ScriptName -Message "Log file: $script:LogFile"
    return $script:LogFile
}

function Write-IdpLog {
    <# Write to the console and the log file. DEBUG goes to the log file only. #>
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$Name = 'tableau_idp'
    )
    $line = '{0} | {1,-8} | {2,-40} | {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Name, $Message
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    switch ($Level) {
        'DEBUG'   { }
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line }
    }
}

function Format-IdpBody {
    # JSON for debug logging with secrets redacted.
    param($Body)
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    return ($json -replace '("(?:client_secret|personalAccessTokenSecret)"\s*:\s*)"(?:[^"\\]|\\.)*"', '$1"***"')
}

# ── Configuration helpers ─────────────────────────────────────────────────────

function Import-IdpDotEnv {
    <# Load KEY=VALUE pairs from a .env file into the process environment.
       Existing environment variables win, matching python-dotenv's default. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value -match '^"(.*)"\s*(?:#.*)?$' -or $value -match "^'(.*)'\s*(?:#.*)?$") {
                $value = $Matches[1]
            }
            elseif ($value -match '^(.*?)\s+#') {
                $value = $Matches[1]
            }
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }
}

function Get-IdpRequiredEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) {
        throw ("Required environment variable '$Name' is not set ($Description). " +
            "Set it with `$env:$Name = '...' or add it to a .env file in this directory.")
    }
    return $value
}

function Remove-YamlComment {
    # Strip a trailing '# comment' that is not inside quotes.
    param([string]$Line)
    $quote = $null
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote) {
            if ($c -eq $quote) { $quote = $null }
        }
        elseif ($c -eq '"' -or $c -eq "'") { $quote = $c }
        elseif ($c -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($Line[$i - 1]))) {
            return $Line.Substring(0, $i)
        }
    }
    return $Line
}

function ConvertFrom-IdpYaml {
    <# Minimal parser for the config.yml layout: top-level sections containing
       scalar 'key: value' pairs. Supports quoted strings, booleans and comments.
       Anything fancier (lists, deeper nesting, anchors) is deliberately rejected. #>
    param([Parameter(Mandatory)][string]$Text)

    $result = @{}
    $section = $null
    $lineNo = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $lineNo++
        $line = (Remove-YamlComment $raw).TrimEnd()
        if (-not $line.Trim()) { continue }

        $indent = $line.Length - $line.TrimStart().Length
        if ($line.Trim() -notmatch '^([A-Za-z0-9_\-]+)\s*:(?:\s+(.*))?$') {
            throw "Unsupported YAML syntax on line ${lineNo}: $raw"
        }
        $key = $Matches[1]
        $rawValue = if ($Matches.ContainsKey(2)) { $Matches[2].Trim() } else { '' }

        if ($indent -eq 0) {
            if ($rawValue -ne '') { throw "Top-level scalar values are not supported (line ${lineNo}): $raw" }
            $section = @{}
            $result[$key] = $section
            continue
        }
        if ($null -eq $section) { throw "Indented value before any section on line ${lineNo}: $raw" }

        if ($rawValue -match '^"(.*)"$' -or $rawValue -match "^'(.*)'$") { $value = $Matches[1] }
        elseif ($rawValue -ieq 'true') { $value = $true }
        elseif ($rawValue -ieq 'false') { $value = $false }
        elseif ($rawValue -ieq 'null' -or $rawValue -eq '~') { $value = $null }
        else { $value = $rawValue }
        $section[$key] = $value
    }
    return $result
}

function Import-IdpConfig {
    <# Load a YAML (.yml/.yaml) or JSON (.json) configuration file. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($Path -match '\.json$') {
        $obj = $text | ConvertFrom-Json
        $config = @{}
        foreach ($section in $obj.PSObject.Properties) {
            $h = @{}
            foreach ($p in $section.Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
            $config[$section.Name] = $h
        }
        return $config
    }
    return ConvertFrom-IdpYaml -Text $text
}

function Get-IdpConfigValue {
    # Section/key lookup with a default, mirroring dict.get() in the Python scripts.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        $Default = $null,
        [switch]$Required
    )
    if ($Config.ContainsKey($Section) -and $Config[$Section].ContainsKey($Key) -and $null -ne $Config[$Section][$Key]) {
        return $Config[$Section][$Key]
    }
    if ($Required) { throw "Missing required config value: $Section.$Key" }
    return $Default
}

# ── Response parsing (port of _response.py) ───────────────────────────────────

function Get-IdpProperty {
    # Return a property/key value from an object or hashtable, or $null if absent.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        # The leading comma stops PowerShell unrolling array values (empty -> $null, one item -> bare object)
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return , $prop.Value }
    return $null
}

function Resolve-IdpIdValue {
    # IDs are sometimes wrapped as {"value": "..."} (e.g. identity pool UUIDs).
    param($Value)
    if ($Value -is [pscustomobject] -and $Value.PSObject.Properties['value']) { return [string]$Value.value }
    return [string]$Value
}

function Get-IdpIdFromResponse {
    <# Extract a resource ID from a creation response, looking at the top level first and
       then inside a nested wrapper object. Throws with the full response if nothing matches. #>
    param(
        $Response,
        [Parameter(Mandatory)][string]$Resource,
        [string[]]$IdKeys = @('id', 'uuid')
    )
    foreach ($key in $IdKeys) {
        $v = Get-IdpProperty $Response $key
        if ($null -ne $v) { return (Resolve-IdpIdValue $v) }
    }
    $wrapperKey = $Resource.ToLower().Replace(' ', '_')
    foreach ($candidate in @($wrapperKey, 'data', 'result')) {
        $nested = Get-IdpProperty $Response $candidate
        if ($null -ne $nested -and $nested -isnot [string] -and $nested -isnot [array]) {
            foreach ($key in $IdKeys) {
                $v = Get-IdpProperty $nested $key
                if ($null -ne $v) { return (Resolve-IdpIdValue $v) }
            }
        }
    }
    # Wrapper name not known in advance (the server uses e.g. {"store_instance": {...}}):
    # accept a single nested object that carries an ID.
    $carriers = @()
    if ($Response -is [pscustomobject]) {
        foreach ($prop in $Response.PSObject.Properties) {
            if ($prop.Value -is [pscustomobject]) {
                foreach ($key in $IdKeys) {
                    if ($null -ne (Get-IdpProperty $prop.Value $key)) { $carriers += , $prop.Value; break }
                }
            }
        }
    }
    if ($carriers.Count -eq 1) {
        foreach ($key in $IdKeys) {
            $v = Get-IdpProperty $carriers[0] $key
            if ($null -ne $v) { return (Resolve-IdpIdValue $v) }
        }
    }
    $dump = $Response | ConvertTo-Json -Depth 10 -Compress
    throw ("Could not extract ID from $Resource response.`nFull response: $dump`n" +
        'Check the log file for the raw response and update the ID keys.')
}

function Get-IdpListFromResponse {
    <# Extract the item list from a list-endpoint response, trying known wrapper keys.
       Returns an empty array and logs a warning if nothing matches. #>
    param(
        $Response,
        [Parameter(Mandatory)][string[]]$ListKeys
    )
    if ($Response -is [array]) { return , $Response }
    foreach ($key in $ListKeys) {
        $v = Get-IdpProperty $Response $key
        if ($v -is [array]) { return , $v }
    }
    $dump = $Response | ConvertTo-Json -Depth 10 -Compress
    Write-IdpLog -Level WARNING -Message "Could not identify list field in response. Keys tried: $($ListKeys -join ', '). Response: $dump"
    return , @()
}

# ── Session (port of client.py / auth.py) ─────────────────────────────────────

function Get-HttpErrorDetail {
    # Pull the response body out of a failed web request (differs between PS 5.1 and 7).
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) { $response = $ErrorRecord.Exception.Response }
    if ($response -and $response.PSObject.Methods['GetResponseStream']) {
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            return $reader.ReadToEnd()
        }
        catch { }
    }
    return ''
}

function Invoke-IdpWebRequest {
    # Single choke point for HTTP calls: JSON in/out, UTF-8 body, descriptive errors.
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Headers = @{},
        $Body = $null,
        [int]$TimeoutSec = 30
    )
    $params = @{
        Uri        = $Url
        Method     = $Method
        Headers    = $Headers + @{ Accept = 'application/json' }
        TimeoutSec = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }

    try {
        $result = Invoke-RestMethod @params
        Write-IdpLog -Level DEBUG -Message "$Method $Url -> OK"
        return $result
    }
    catch {
        $detail = Get-HttpErrorDetail $_
        Write-IdpLog -Level DEBUG -Message "$Method $Url -> FAILED: $($_.Exception.Message) $detail"
        $msg = "$Method $Url failed: $($_.Exception.Message)"
        if ($detail) { $msg += " | Response: $detail" }
        throw $msg
    }
}

function New-IdpSession {
    param(
        [Parameter(Mandatory)][string]$ServerUrl,
        [string]$SiteUri = '',
        [switch]$DryRun
    )
    [pscustomobject]@{
        ServerUrl  = $ServerUrl.TrimEnd('/') + '/'
        SiteUri    = $SiteUri
        DryRun     = [bool]$DryRun
        ApiVersion = $null
        SiteId     = $null
        Token      = $null
    }
}

function Connect-IdpSession {
    <# Authenticate with a personal access token and store the session token. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$TokenName,
        [Parameter(Mandatory)][string]$TokenSecret
    )
    if ($Session.DryRun) {
        Write-IdpLog -Message "[DRY RUN] Skipping authentication (token: $TokenName)"
        $Session.ApiVersion = $script:DryRunApiVersion
        $Session.SiteId = $script:DryRunSiteId
        $Session.Token = $script:DryRunToken
        return
    }

    $info = Invoke-IdpWebRequest -Method GET -Url "$($Session.ServerUrl)api/2.4/serverinfo" -TimeoutSec 10
    $Session.ApiVersion = $info.serverInfo.restApiVersion
    Write-IdpLog -Message "Server REST API version: $($Session.ApiVersion)"

    $body = @{
        credentials = @{
            personalAccessTokenName   = $TokenName
            personalAccessTokenSecret = $TokenSecret
            site                      = @{ contentUrl = $Session.SiteUri }
        }
    }
    $auth = Invoke-IdpWebRequest -Method POST -Url "$($Session.ServerUrl)api/$($Session.ApiVersion)/auth/signin" -Body $body -TimeoutSec 10
    $Session.SiteId = $auth.credentials.site.id
    $Session.Token = $auth.credentials.token
    Write-IdpLog -Message "Authenticated. Site ID: $($Session.SiteId)"
}

function Disconnect-IdpSession {
    <# Sign out and clear the session token. Never throws - safe to call from finally. #>
    param([Parameter(Mandatory)]$Session)
    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Skipping sign out'
        return
    }
    if ($Session.Token) {
        try {
            Invoke-IdpWebRequest -Method POST -Url "$($Session.ServerUrl)api/$($Session.ApiVersion)/auth/signout" `
                -Headers @{ 'X-Tableau-Auth' = $Session.Token } -TimeoutSec 10 | Out-Null
            Write-IdpLog -Message 'Signed out successfully'
        }
        catch {
            Write-IdpLog -Level WARNING -Message "Sign out failed: $_"
        }
    }
    $Session.Token = $null
    $Session.SiteId = $null
}

function Invoke-IdpRequest {
    <# Authenticated request against the server. Returns $null in dry-run mode or for empty responses. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body = $null
    )
    if ($Session.DryRun) {
        Write-IdpLog -Message "[DRY RUN] $Method $Url"
        if ($null -ne $Body) { Write-IdpLog -Level DEBUG -Message "[DRY RUN] Body: $(Format-IdpBody $Body)" }
        return $null
    }
    if ($null -ne $Body) { Write-IdpLog -Level DEBUG -Message "$Method $Url body: $(Format-IdpBody $Body)" }
    return Invoke-IdpWebRequest -Method $Method -Url $Url -Headers @{ 'X-Tableau-Auth' = $Session.Token } -Body $Body
}

# ── Identity stores (port of identity_store.py) ───────────────────────────────

function New-IdpIdentityStore {
    <# Create a local identity store. Returns the store ID. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Name,
        [string]$DisplayName,
        [string]$StoreType = '0'
    )
    $url = "$($Session.ServerUrl)api/-/authn-service/identity-stores"
    $body = [ordered]@{ name = $Name; type = $StoreType }
    if ($DisplayName) { $body['display_name'] = $DisplayName }

    Write-IdpLog -Message "Creating identity store '$Name'"
    $result = Invoke-IdpRequest -Session $Session -Method POST -Url $url -Body $body

    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Returning placeholder store ID: DRY-RUN-STORE-ID'
        return 'DRY-RUN-STORE-ID'
    }
    Write-IdpLog -Level DEBUG -Message "Identity store creation response: $($result | ConvertTo-Json -Depth 10 -Compress)"
    $storeId = Get-IdpIdFromResponse -Response $result -Resource 'identity_store'
    Write-IdpLog -Message "Identity store created. ID: $storeId"
    return $storeId
}

function Get-IdpIdentityStores {
    <# List all configured identity stores. #>
    param([Parameter(Mandatory)]$Session)
    $url = "$($Session.ServerUrl)api/-/authn-service/identity-stores"
    Write-IdpLog -Message 'Listing identity stores'
    $result = Invoke-IdpRequest -Session $Session -Method GET -Url $url
    if ($Session.DryRun) { return , @() }

    Write-IdpLog -Level DEBUG -Message "Identity stores list response: $($result | ConvertTo-Json -Depth 10 -Compress)"
    $stores = Get-IdpListFromResponse -Response $result -ListKeys 'instances', 'identity_stores', 'items', 'data', 'results'
    Write-IdpLog -Message "Found $($stores.Count) identity store(s)"
    return , $stores
}

function Test-IdpIdentityStoreExists {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$StoreId)
    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Skipping identity store validation'
        return $true
    }
    $stores = Get-IdpIdentityStores -Session $Session
    $found = @($stores | Where-Object { [string](Get-IdpProperty $_ 'id') -eq $StoreId }).Count -gt 0
    if ($found) { Write-IdpLog -Message "Validation passed: identity store $StoreId exists" }
    else { Write-IdpLog -Level ERROR -Message "Validation failed: identity store $StoreId not found. Existing stores: $($stores | ConvertTo-Json -Depth 10 -Compress)" }
    return $found
}

function Remove-IdpIdentityStore {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$StoreId)
    Write-IdpLog -Message "Deleting identity store: $StoreId"
    Invoke-IdpRequest -Session $Session -Method DELETE -Url "$($Session.ServerUrl)api/-/authn-service/identity-stores/$StoreId" | Out-Null
    if (-not $Session.DryRun) { Write-IdpLog -Message "Identity store $StoreId deleted" }
}

# ── Auth configurations (port of auth_config.py) ──────────────────────────────

function New-IdpAuthConfig {
    <# Create an OIDC authentication configuration. Returns the config ID. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$AuthType,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$ConfigUrl,
        [string]$IdClaim = 'sub',
        [string]$UsernameClaim = 'email',
        [string]$ClientAuthentication = 'CLIENT_SECRET_BASIC',
        [bool]$IframedIdpEnabled = $false
    )
    $url = "$($Session.ServerUrl)api/-/authn-service/auth-configurations"
    # Per the Tableau docs the IdP settings are nested under an "oidc" object
    $body = [ordered]@{
        auth_type           = $AuthType
        iframed_idp_enabled = $IframedIdpEnabled
        oidc                = [ordered]@{
            client_id             = $ClientId
            client_secret         = $ClientSecret
            config_url            = $ConfigUrl
            id_claim              = $IdClaim
            username_claim        = $UsernameClaim
            client_authentication = $ClientAuthentication
        }
    }

    Write-IdpLog -Message "Creating auth configuration (type: $AuthType, IdP: $ConfigUrl)"
    $result = Invoke-IdpRequest -Session $Session -Method POST -Url $url -Body $body

    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Returning placeholder auth config ID: DRY-RUN-AUTH-CONFIG-ID'
        return 'DRY-RUN-AUTH-CONFIG-ID'
    }
    Write-IdpLog -Level DEBUG -Message "Auth config creation response: $(Format-IdpBody $result)"
    $configId = Get-IdpIdFromResponse -Response $result -Resource 'auth_configuration'
    Write-IdpLog -Message "Auth configuration created. ID: $configId"
    return $configId
}

function Get-IdpAuthConfigs {
    param([Parameter(Mandatory)]$Session)
    $url = "$($Session.ServerUrl)api/-/authn-service/auth-configurations"
    Write-IdpLog -Message 'Listing auth configurations'
    $result = Invoke-IdpRequest -Session $Session -Method GET -Url $url
    if ($Session.DryRun) { return , @() }

    Write-IdpLog -Level DEBUG -Message "Auth configs list response: $(Format-IdpBody $result)"
    $configs = Get-IdpListFromResponse -Response $result -ListKeys 'instances', 'auth_configurations', 'configurations', 'items', 'data', 'results'
    Write-IdpLog -Message "Found $($configs.Count) auth configuration(s)"
    return , $configs
}

function Test-IdpAuthConfigExists {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$ConfigId)
    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Skipping auth configuration validation'
        return $true
    }
    $configs = Get-IdpAuthConfigs -Session $Session
    $found = @($configs | Where-Object { [string](Get-IdpProperty $_ 'id') -eq $ConfigId }).Count -gt 0
    if ($found) { Write-IdpLog -Message "Validation passed: auth configuration $ConfigId exists" }
    else { Write-IdpLog -Level ERROR -Message "Validation failed: auth configuration $ConfigId not found. Existing configs: $(Format-IdpBody $configs)" }
    return $found
}

function Update-IdpAuthConfig {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$ConfigId, [Parameter(Mandatory)][hashtable]$Updates)
    Write-IdpLog -Message "Updating auth configuration: $ConfigId"
    $result = Invoke-IdpRequest -Session $Session -Method PUT -Url "$($Session.ServerUrl)api/-/authn-service/auth-configurations/$ConfigId" -Body $Updates
    if (-not $Session.DryRun) { Write-IdpLog -Message "Auth configuration $ConfigId updated" }
    return $result
}

function Remove-IdpAuthConfig {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$ConfigId)
    Write-IdpLog -Message "Deleting auth configuration: $ConfigId"
    Invoke-IdpRequest -Session $Session -Method DELETE -Url "$($Session.ServerUrl)api/-/authn-service/auth-configurations/$ConfigId" | Out-Null
    if (-not $Session.DryRun) { Write-IdpLog -Message "Auth configuration $ConfigId deleted" }
}

# ── Identity pools (port of identity_pool.py) ─────────────────────────────────

function New-IdpIdentityPool {
    <# Create an identity pool linking a store and auth configuration. Returns the pool UUID. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [Parameter(Mandatory)][string]$StoreId,
        [Parameter(Mandatory)][string]$AuthConfigId,
        [bool]$IsEnabled = $true
    )
    $url = "$($Session.ServerUrl)api/-/authn-service/identity-pools"
    $body = [ordered]@{
        name                    = $Name
        description             = $Description
        identity_store_instance = $StoreId
        auth_type_instance      = $AuthConfigId
        is_enabled              = $IsEnabled
    }

    Write-IdpLog -Message "Creating identity pool '$Name'"
    $result = Invoke-IdpRequest -Session $Session -Method POST -Url $url -Body $body

    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Returning placeholder pool UUID: DRY-RUN-POOL-UUID'
        return 'DRY-RUN-POOL-UUID'
    }
    Write-IdpLog -Level DEBUG -Message "Identity pool creation response: $($result | ConvertTo-Json -Depth 10 -Compress)"
    # Identity pools use 'uuid' as their primary identifier per the Tableau docs
    $poolUuid = Get-IdpIdFromResponse -Response $result -Resource 'identity_pool' -IdKeys 'uuid', 'id', 'identity_pool_id'
    Write-IdpLog -Message "Identity pool created. UUID: $poolUuid"
    return $poolUuid
}

function Get-IdpIdentityPool {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$PoolUuid)
    Write-IdpLog -Message "Getting identity pool: $PoolUuid"
    $result = Invoke-IdpRequest -Session $Session -Method GET -Url "$($Session.ServerUrl)api/-/authn-service/identity-pools/$PoolUuid"
    if ($Session.DryRun) { return $null }
    Write-IdpLog -Level DEBUG -Message "Identity pool response: $($result | ConvertTo-Json -Depth 10 -Compress)"
    return $result
}

function Get-IdpIdentityPools {
    param([Parameter(Mandatory)]$Session)
    $url = "$($Session.ServerUrl)api/-/authn-service/identity-pools"
    Write-IdpLog -Message 'Listing identity pools'
    $result = Invoke-IdpRequest -Session $Session -Method GET -Url $url
    if ($Session.DryRun) { return , @() }

    Write-IdpLog -Level DEBUG -Message "Identity pools list response: $($result | ConvertTo-Json -Depth 10 -Compress)"
    $pools = Get-IdpListFromResponse -Response $result -ListKeys 'instances', 'identity_pools', 'pools', 'items', 'data', 'results'
    Write-IdpLog -Message "Found $($pools.Count) identity pool(s)"
    return , $pools
}

function Test-IdpIdentityPoolExists {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$PoolUuid)
    if ($Session.DryRun) {
        Write-IdpLog -Message '[DRY RUN] Skipping identity pool validation'
        return $true
    }
    $pool = Get-IdpIdentityPool -Session $Session -PoolUuid $PoolUuid
    $found = $null -ne $pool -and "$pool" -ne ''
    if ($found) { Write-IdpLog -Message "Validation passed: identity pool $PoolUuid exists" }
    else { Write-IdpLog -Level ERROR -Message "Validation failed: identity pool $PoolUuid not found" }
    return $found
}

function Update-IdpIdentityPool {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$PoolUuid, [Parameter(Mandatory)][hashtable]$Updates)
    Write-IdpLog -Message "Updating identity pool: $PoolUuid"
    $result = Invoke-IdpRequest -Session $Session -Method PUT -Url "$($Session.ServerUrl)api/-/authn-service/identity-pools/$PoolUuid" -Body $Updates
    if (-not $Session.DryRun) { Write-IdpLog -Message "Identity pool $PoolUuid updated" }
    return $result
}

function Remove-IdpIdentityPool {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$PoolUuid)
    Write-IdpLog -Message "Deleting identity pool: $PoolUuid"
    Invoke-IdpRequest -Session $Session -Method DELETE -Url "$($Session.ServerUrl)api/-/authn-service/identity-pools/$PoolUuid" | Out-Null
    if (-not $Session.DryRun) { Write-IdpLog -Message "Identity pool $PoolUuid deleted" }
}

# ── Rollback state (port of state.py) ─────────────────────────────────────────

function Read-IdpState {
    <# Read the JSON file recording resources created by setup. Returns an empty hashtable if absent. #>
    param([Parameter(Mandatory)][string]$Path)
    $state = @{}
    if (Test-Path -LiteralPath $Path) {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($obj) { foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value } }
    }
    return $state
}

function Write-IdpState {
    # UTF-8 without BOM so the Python scripts can read the same file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$State)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.File]::WriteAllText($full, ($State | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Write-IdpLog -Level DEBUG -Message "State saved to ${Path}: $($State | ConvertTo-Json -Compress)"
}

function Get-IdpConfigFingerprint {
    <# Short stable hash of a config section. Must match fingerprint() in tableau_idp/state.py:
       sorted keys, "key=value" lines, booleans as true/false, empty values ignored,
       SHA-256 of the UTF-8 text, first 16 hex chars. #>
    param([Parameter(Mandatory)][hashtable]$Section)
    $keys = [string[]]@($Section.Keys)
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $lines = foreach ($k in $keys) {
        $v = $Section[$k]
        if ($null -eq $v -or "$v" -eq '') { continue }
        $text = if ($v -is [bool]) { "$v".ToLower() } else { "$v" }
        "$k=$text"
    }
    $canonical = $lines -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}

function Remove-IdpStateFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path }
}

# ── Users (port of users.py) ──────────────────────────────────────────────────

function Add-IdpUserToPool {
    <# Add an existing Tableau user to an identity pool via the standard REST API. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$PoolUuid,
        [Parameter(Mandatory)][string]$IdentityUuid,
        [string]$Username,
        [string]$SiteRole,
        [string]$AuthSetting
    )
    $url = "$($Session.ServerUrl)api/$($Session.ApiVersion)/sites/$($Session.SiteId)/users/identityPool"
    $user = [ordered]@{ id = $UserId; identityPoolUuid = $PoolUuid; identityUuid = $IdentityUuid }
    if ($Username) { $user['name'] = $Username }
    if ($SiteRole) { $user['siteRole'] = $SiteRole }
    if ($AuthSetting) { $user['authSetting'] = $AuthSetting }

    Write-IdpLog -Message "Adding user $UserId to identity pool $PoolUuid"
    $result = Invoke-IdpRequest -Session $Session -Method POST -Url $url -Body @{ user = $user }
    if ($Session.DryRun) { return $null }
    Write-IdpLog -Message "User $UserId added to pool $PoolUuid"
    return $result
}

function Remove-IdpUserFromPool {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$PoolUuid
    )
    $url = "$($Session.ServerUrl)api/$($Session.ApiVersion)/sites/$($Session.SiteId)/users/$UserId/identityPool/$PoolUuid"
    Write-IdpLog -Message "Removing user $UserId from identity pool $PoolUuid"
    Invoke-IdpRequest -Session $Session -Method DELETE -Url $url | Out-Null
    if (-not $Session.DryRun) { Write-IdpLog -Message "User $UserId removed from pool $PoolUuid" }
}

Export-ModuleMember -Function `
    Initialize-IdpLogging, Write-IdpLog, `
    Import-IdpDotEnv, Get-IdpRequiredEnv, ConvertFrom-IdpYaml, Import-IdpConfig, Get-IdpConfigValue, `
    New-IdpSession, Connect-IdpSession, Disconnect-IdpSession, Invoke-IdpRequest, `
    New-IdpIdentityStore, Get-IdpIdentityStores, Test-IdpIdentityStoreExists, Remove-IdpIdentityStore, `
    New-IdpAuthConfig, Get-IdpAuthConfigs, Test-IdpAuthConfigExists, Update-IdpAuthConfig, Remove-IdpAuthConfig, `
    New-IdpIdentityPool, Get-IdpIdentityPool, Get-IdpIdentityPools, Test-IdpIdentityPoolExists, Update-IdpIdentityPool, Remove-IdpIdentityPool, `
    Read-IdpState, Write-IdpState, Get-IdpConfigFingerprint, Remove-IdpStateFile, `
    Add-IdpUserToPool, Remove-IdpUserFromPool
