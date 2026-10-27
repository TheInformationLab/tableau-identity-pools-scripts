# Tableau identity pool scripts

Scripts to set up a Tableau Server identity pool (identity store, OIDC auth configuration,
identity pool) via the REST and authn-service APIs. Two equivalent implementations are provided;
use whichever suits the environment.

```
config.example.yml   shared config template - copy to config.yml and edit
.env                 shared secrets (optional; or use environment variables)
scripts/             TSM scripts to enable the identity pools feature (.bat / .sh / .ps1)
python/              Python implementation  -> see below
powershell/          PowerShell implementation -> see powershell/README.md
portable/            builds an offline Windows bundle of the Python scripts (see below)
template-functions/  reference snippets
```

## Order of operations

1. On the Tableau Server primary node, run `scripts/enable_identity_pools.*` (restarts services).
2. Copy `config.example.yml` to `config.yml` and fill it in.
3. Set `TABLEAU_TOKEN_NAME`, `TABLEAU_TOKEN_SECRET` and `TABLEAU_OIDC_CLIENT_SECRET`
   (environment variables or `.env`).
4. Run `setup_identity_pool` (Python or PowerShell), with dry-run first.
5. Configure the printed redirect URI in your IdP.
6. To undo a run, use `teardown_identity_pool` (see *Rolling back* below).

## Rolling back

`setup_identity_pool` records each ID it creates in `created_resources.json` as it goes (so even a
run that fails part-way can be undone). `teardown_identity_pool` deletes exactly those resources -
identity pool, then auth configuration, then identity store - after a confirmation prompt. It never
touches anything not recorded in the file (e.g. the built-in `default` identity store). The file
format is shared, so either implementation can roll back the other's work. Setup refuses to run
again while the file exists, so a rollback is never forgotten.

### Resuming a failed run

If setup fails part-way (say the pool step is rejected), fix the problem and continue instead of
rolling back and starting over:

```
python python/setup_identity_pool.py --config config.yml --resume
.\powershell\setup_identity_pool.ps1 -Config config.yml -Resume
```

`--resume` reuses the resources already recorded (confirming each still exists on the server) and
creates only what's missing. It refuses to continue if the config for an already-created step has
changed since it was created - roll back and start again in that case - or if the state file was
written for a different server. Running it on a completed setup just reprints the pool UUID and
redirect URI. It is ignored with `--dry-run`.

Limitation: if a crash happens after the server created something but before its ID was recorded,
that resource is not in the state file. Find it with `list_resources` and delete it with the
explicit-ID options of teardown.

## Python

```
pip install -r python/requirements.txt
python python/setup_identity_pool.py --config config.yml --dry-run
python python/setup_identity_pool.py --config config.yml
python python/list_resources.py --config config.yml
python python/teardown_identity_pool.py --config config.yml --dry-run   # then without --dry-run
```

## PowerShell

```powershell
.\powershell\setup_identity_pool.ps1 -Config config.yml -DryRun
.\powershell\setup_identity_pool.ps1 -Config config.yml
.\powershell\list_resources.ps1 -Config config.yml
.\powershell\teardown_identity_pool.ps1 -Config config.yml -DryRun   # then without -DryRun
```

Run both from the repo root.

## Portable Python bundle (no Python install, no PowerShell scripts)

For locked-down Windows machines. On a machine with internet access:

```
python portable/build_portable.py
```

This produces `dist/tableau-idp-portable.zip`: the official embeddable Python runtime, the
dependencies as wheels, the scripts and `.bat` launchers. Copy the zip across, unzip, then
(see the `README.txt` inside it) create `config.yml` and `.env` and run
`setup_identity_pool.bat --config config.yml --dry-run`.

Note: Python does not use the Windows certificate store. If Tableau Server uses an internal CA,
set `REQUESTS_CA_BUNDLE` to the CA certificate (PEM) - this applies to the normal Python
version as well.
