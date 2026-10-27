# PowerShell version

Functionally equivalent to the Python scripts, with no Python or extra modules required.
Works on the Windows PowerShell 5.1 that ships with Windows, and on PowerShell 7+.

| Python (`python/`)              | PowerShell (`powershell/`)          |
|---------------------------------|-------------------------------------|
| `setup_identity_pool.py`        | `setup_identity_pool.ps1`           |
| `list_resources.py`             | `list_resources.ps1`                |
| `teardown_identity_pool.py`     | `teardown_identity_pool.ps1`        |
| `set_identity_pool_state.py`    | `set_identity_pool_state.ps1`       |
| `tableau_idp/` package          | `TableauIdp.psm1` module            |

The TSM script is shared and lives in `scripts/` (`.bat`, `.sh` and `.ps1` variants).

The same `config.yml`, `.env` file (both in the repo root) and environment variables are used by both versions.
Run the scripts from the repo root.

## Usage

```powershell
# Secrets: environment variables, or a .env file in the repo root
$env:TABLEAU_TOKEN_NAME         = '<personal access token name>'
$env:TABLEAU_TOKEN_SECRET       = '<personal access token secret>'
$env:TABLEAU_OIDC_CLIENT_SECRET = '<OIDC client secret>'

.\powershell\setup_identity_pool.ps1 -Config config.yml -DryRun   # log planned actions only
.\powershell\setup_identity_pool.ps1 -Config config.yml
.\powershell\setup_identity_pool.ps1 -Config config.yml -Resume   # continue a run that failed part-way
.\powershell\list_resources.ps1 -Config config.yml

# Switch the pool on/off (create it with is_enabled: false first); no switch = show current state
.\powershell\set_identity_pool_state.ps1 -Config config.yml -Enable
.\powershell\set_identity_pool_state.ps1 -Config config.yml -Disable

# Roll back what setup created (reads created_resources.json, asks for confirmation)
.\powershell\teardown_identity_pool.ps1 -Config config.yml -DryRun
.\powershell\teardown_identity_pool.ps1 -Config config.yml
```

On the Tableau Server primary node (TSM admin), before the setup script:

```powershell
.\scripts\enable_identity_pools.ps1 -ExternalUrl http://mytableau.example.com
# behind a forward proxy: add -ProxyHost <host> -ProxyPort <port>
```

Logs are written to `logs\<script>_<timestamp>.log` in the directory you run from; the OIDC client secret is redacted in them.

## Execution policy

If scripts were downloaded or copied from a share, Windows may block them. Either unblock them:

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1 | Unblock-File
```

or follow whatever script-signing policy the customer's environment requires.

## Config notes

`config.yml` is read by a small built-in parser that supports the layout in `config.example.yml`
(sections of `key: value` pairs, quoted strings, booleans, `#` comments). A `.json` file with the
same structure can be passed to `-Config` instead.
