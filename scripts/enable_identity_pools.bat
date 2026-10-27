@echo off
REM Enable the Tableau Server identity pools feature via TSM.
REM
REM Run this on the Tableau Server primary node as a user with TSM admin access
REM BEFORE running setup_identity_pool.py. The pending-changes apply step will
REM restart Tableau Server services.
REM
REM Usage:
REM   enable_identity_pools.bat <external_url>
REM   enable_identity_pools.bat http://mytableau.example.com
REM
REM Optional: if Tableau Server sits behind a forward proxy, uncomment and fill
REM in the proxy section below.

setlocal

if "%~1"=="" (
    echo Usage: %~nx0 ^<external_url^>
    echo Example: %~nx0 http://mytableau.example.com
    exit /b 1
)

set EXTERNAL_URL=%~1

echo === Configuring Tableau Server for identity pools ===

echo Setting gateway external URL: %EXTERNAL_URL%
tsm configuration set -k gateway.external_url -v %EXTERNAL_URL%

echo Enabling identity pools feature flags...
tsm configuration set -k features.IdentityPools -v true
tsm configuration set -k features.NewIdentityMode -v true
tsm configuration set -k wgserver.authentication.legacy_identity_mode.enabled -v false

REM ── Forward proxy (uncomment if needed) ────────────────────────────────────
REM tsm configuration set -k tomcat.useSystemProxies -v true
REM tsm configuration set -k tomcat.http.proxyHost -v <proxy_host>
REM tsm configuration set -k tomcat.http.proxyPort -v <proxy_port>

echo Applying pending changes (Tableau Server services will restart)...
tsm pending-changes apply --ignore-prompt

echo.
echo === Done ===
echo Identity pools feature is enabled.
echo Next: run "python python/setup_identity_pool.py --config config.yml" to create a pool.

endlocal
