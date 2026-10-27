<#
.SYNOPSIS
    Enable the Tableau Server identity pools feature via TSM.

.DESCRIPTION
    Run this on the Tableau Server primary node as a user with TSM admin access BEFORE
    running setup_identity_pool.ps1. The pending-changes apply step restarts Tableau
    Server services.

.PARAMETER ExternalUrl
    Gateway external URL, e.g. http://mytableau.example.com

.PARAMETER ProxyHost
    Optional forward proxy host (use with -ProxyPort) if Tableau Server sits behind one.

.PARAMETER ProxyPort
    Optional forward proxy port.

.EXAMPLE
    .\enable_identity_pools.ps1 -ExternalUrl http://mytableau.example.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExternalUrl,
    [string]$ProxyHost,
    [string]$ProxyPort
)

$ErrorActionPreference = 'Stop'

function Invoke-Tsm {
    & tsm @args
    if ($LASTEXITCODE -ne 0) { throw "tsm $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

Write-Host '=== Configuring Tableau Server for identity pools ==='

Write-Host "Setting gateway external URL: $ExternalUrl"
Invoke-Tsm configuration set -k gateway.external_url -v $ExternalUrl

Write-Host 'Enabling identity pools feature flags...'
Invoke-Tsm configuration set -k features.IdentityPools -v true
Invoke-Tsm configuration set -k features.NewIdentityMode -v true
Invoke-Tsm configuration set -k wgserver.authentication.legacy_identity_mode.enabled -v false

if ($ProxyHost) {
    if (-not $ProxyPort) { throw '-ProxyPort is required when -ProxyHost is set' }
    Write-Host "Configuring forward proxy: ${ProxyHost}:$ProxyPort"
    Invoke-Tsm configuration set -k tomcat.useSystemProxies -v true
    Invoke-Tsm configuration set -k tomcat.http.proxyHost -v $ProxyHost
    Invoke-Tsm configuration set -k tomcat.http.proxyPort -v $ProxyPort
}

Write-Host 'Applying pending changes (Tableau Server services will restart)...'
Invoke-Tsm pending-changes apply --ignore-prompt

Write-Host ''
Write-Host '=== Done ==='
Write-Host 'Identity pools feature is enabled.'
Write-Host 'Next: run ".\powershell\setup_identity_pool.ps1 -Config config.yml" to create a pool.'
