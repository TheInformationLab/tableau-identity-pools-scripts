"""
Build a self-contained, offline-capable Windows bundle of the Python scripts.

Run this once on a machine WITH internet access (any OS, any Python 3.8+ with pip).
It produces dist/tableau-idp-portable.zip, which can be carried to a locked-down Windows
machine and run with no Python install, no admin rights and no PowerShell scripts:

    tableau-idp-portable/
      setup_identity_pool.bat     launchers (plain batch files - not subject to
      list_resources.bat          PowerShell execution policy)
      teardown_identity_pool.bat
      set_identity_pool_state.bat
      runtime/                    official python.org "embeddable" Python (Windows x64)
      site-packages/              dependencies from python/requirements.txt (wheels)
      app/                        setup_identity_pool.py, list_resources.py, tableau_idp/ ...
      scripts/                    TSM enable scripts
      config.example.yml

Usage:
    python portable/build_portable.py
    python portable/build_portable.py --python-version 3.12.10
"""

import argparse
import hashlib
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_PYTHON = "3.12.10"  # must be >= 3.10 (the code uses `X | None` annotations)

LAUNCHER = """@echo off
REM Runs {script} with the bundled Python. No installation required.
REM Config, .env and logs\\ are all relative to this folder.
setlocal
cd /d "%~dp0"
"%~dp0runtime\\python.exe" "%~dp0app\\{script}" %*
exit /b %ERRORLEVEL%
"""

BUNDLE_README = """Tableau identity pool scripts - portable Windows bundle
=======================================================

No Python install, admin rights or PowerShell scripts needed.

1. Copy config.example.yml to config.yml and edit it.
2. Create a file called .env in this folder containing:
       TABLEAU_TOKEN_NAME=<personal access token name>
       TABLEAU_TOKEN_SECRET=<personal access token secret>
       TABLEAU_OIDC_CLIENT_SECRET=<OIDC client secret>
   (or set them as environment variables instead).
3. Open Command Prompt (or PowerShell) in this folder and run:
       setup_identity_pool.bat --config config.yml --dry-run
       setup_identity_pool.bat --config config.yml
       list_resources.bat --config config.yml

If setup fails part-way, fix the cause and continue where it stopped:
       setup_identity_pool.bat --config config.yml --resume

To enable/disable the pool (no switch = show current state):
       set_identity_pool_state.bat --config config.yml --enable
       set_identity_pool_state.bat --config config.yml --disable

To roll back what setup created (reads created_resources.json, asks for confirmation):
       teardown_identity_pool.bat --config config.yml --dry-run
       teardown_identity_pool.bat --config config.yml

Logs are written to the logs\\ folder.

TLS: if Tableau Server uses a certificate from an internal CA, Python will not trust it
by default (it does not use the Windows certificate store). Export the CA certificate as
Base-64 .pem and set, before running:
       set REQUESTS_CA_BUNDLE=C:\\path\\to\\internal-ca.pem

Bundled runtime: Python {python} (embeddable, Windows x64).
"""


def download(url: str, dest: Path) -> None:
    print(f"Downloading {url}")
    with urllib.request.urlopen(url, timeout=120) as resp, open(dest, "wb") as out:
        shutil.copyfileobj(resp, out)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--python-version", default=DEFAULT_PYTHON, help=f"default: {DEFAULT_PYTHON}")
    parser.add_argument("--out", default=str(REPO / "dist"), help="output directory (default: dist/)")
    args = parser.parse_args()

    major, minor, _ = args.python_version.split(".")
    if (int(major), int(minor)) < (3, 10):
        sys.exit("Python 3.10 or newer is required.")

    out = Path(args.out)
    cache = out / "cache"
    bundle = out / "tableau-idp-portable"
    if bundle.exists():
        shutil.rmtree(bundle)
    cache.mkdir(parents=True, exist_ok=True)
    bundle.mkdir(parents=True)

    # 1. Embeddable Python runtime
    embed_name = f"python-{args.python_version}-embed-amd64.zip"
    embed_zip = cache / embed_name
    if not embed_zip.exists():
        download(f"https://www.python.org/ftp/python/{args.python_version}/{embed_name}", embed_zip)
    print(f"Runtime archive SHA-256: {sha256(embed_zip)}")
    runtime = bundle / "runtime"
    with zipfile.ZipFile(embed_zip) as z:
        z.extractall(runtime)

    # The ._pth file replaces the default sys.path and makes the runtime isolated, so the
    # script directory is NOT added automatically - list everything explicitly.
    pth = next(runtime.glob("python*._pth"))
    stdlib_zip = next(runtime.glob("python*.zip")).name
    pth.write_text(f"{stdlib_zip}\n.\n..\\site-packages\n..\\app\nimport site\n", encoding="utf-8")

    # 2. Dependencies as Windows wheels (works even when building on Linux/macOS)
    site_packages = bundle / "site-packages"
    print("Installing dependencies")
    subprocess.run(
        [
            sys.executable, "-m", "pip", "install",
            "--target", str(site_packages),
            "--platform", "win_amd64",
            "--python-version", f"{major}.{minor}",
            "--implementation", "cp",
            "--only-binary=:all:",
            "--no-compile",
            "-r", str(REPO / "python" / "requirements.txt"),
        ],
        check=True,
    )

    # 3. Application code and shared files
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(REPO / "python", bundle / "app", ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "requirements.txt"))
    shutil.copytree(REPO / "scripts", bundle / "scripts", ignore=ignore)
    shutil.copy(REPO / "config.example.yml", bundle / "config.example.yml")

    # 4. Launchers and readme (CRLF for Windows)
    for script in ("setup_identity_pool", "list_resources", "teardown_identity_pool", "set_identity_pool_state"):
        (bundle / f"{script}.bat").write_bytes(LAUNCHER.format(script=f"{script}.py").replace("\n", "\r\n").encode("ascii"))
    (bundle / "README.txt").write_bytes(BUNDLE_README.format(python=args.python_version).replace("\n", "\r\n").encode("ascii"))

    # 5. Zip it
    zip_path = out / "tableau-idp-portable.zip"
    if zip_path.exists():
        zip_path.unlink()
    shutil.make_archive(str(zip_path.with_suffix("")), "zip", out, "tableau-idp-portable")
    print(f"\nBuilt {zip_path} ({zip_path.stat().st_size / 1e6:.1f} MB)")
    print(f"SHA-256: {sha256(zip_path)}")


if __name__ == "__main__":
    main()
