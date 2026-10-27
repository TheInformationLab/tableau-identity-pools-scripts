"""
Set up a Tableau Server identity pool via the REST and authn-service APIs.

Steps (each validated before proceeding to the next):
  1. Authenticate with a personal access token
  2. Create an identity store
  3. Create an OIDC authentication configuration
  4. Create an identity pool linking the store and auth configuration
  5. Print the IdP redirect URI to configure in your identity provider

Usage:
    python python/setup_identity_pool.py --config config.yml
    python python/setup_identity_pool.py --config config.yml --dry-run
    python python/setup_identity_pool.py --config config.yml --resume    # continue a run that failed part-way

(run from the repo root; config.yml and .env are looked up there)

Secrets are read from environment variables (or a .env file):
    TABLEAU_TOKEN_NAME         personal access token name
    TABLEAU_TOKEN_SECRET       personal access token secret
    TABLEAU_OIDC_CLIENT_SECRET OIDC client secret
"""

import argparse
import logging
import os
import sys

import yaml
from dotenv import load_dotenv

from logging_config import setup_logging
from tableau_idp.auth_config import create_auth_config, validate_auth_config_exists
from tableau_idp.client import TableauSession
from tableau_idp.identity_pool import create_identity_pool, validate_pool_exists
from tableau_idp.identity_store import create_identity_store, validate_store_exists
from tableau_idp.state import DEFAULT_STATE_FILE, fingerprint, load_state, save_state

load_dotenv()


def _require_env(var: str, description: str) -> str:
    value = os.getenv(var)
    if not value:
        raise EnvironmentError(
            f"Required environment variable '{var}' is not set ({description}). "
            "Export it directly or add it to a .env file in this directory."
        )
    return value


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Set up a Tableau Server identity pool via the REST API.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--config",
        default="config.yml",
        help="Path to YAML configuration file (default: config.yml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Log all planned actions without making any API calls",
    )
    parser.add_argument(
        "--state-file",
        default=DEFAULT_STATE_FILE,
        help=f"Where to record created resource IDs for rollback (default: {DEFAULT_STATE_FILE})",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Continue a run recorded in the state file: reuse the resources it already created "
        "(after checking they still exist and their config is unchanged). Ignored with --dry-run.",
    )
    args = parser.parse_args()

    logger = setup_logging("setup_identity_pool")

    if args.dry_run:
        logger.info("=" * 60)
        logger.info("DRY RUN MODE — no changes will be made to the server")
        logger.info("=" * 60)

    # ── Config & secrets ──────────────────────────────────────────────────────
    logger.info("Loading configuration from: %s", args.config)
    try:
        config = load_config(args.config)
        token_name = _require_env("TABLEAU_TOKEN_NAME", "personal access token name")
        token_secret = _require_env("TABLEAU_TOKEN_SECRET", "personal access token secret")
        oidc_client_secret = _require_env(
            "TABLEAU_OIDC_CLIENT_SECRET", "OIDC client secret"
        )
    except (FileNotFoundError, EnvironmentError) as exc:
        logger.error("Configuration error: %s", exc)
        sys.exit(1)

    existing = {} if args.dry_run else load_state(args.state_file)
    if existing and not args.resume:
        logger.error(
            "%s already records resources from an earlier run. Continue it with --resume, "
            "roll it back with teardown_identity_pool.py, or delete the file to keep them and start over.",
            args.state_file,
        )
        sys.exit(1)
    if args.resume and not args.dry_run and not existing:
        logger.info("--resume given but %s has no recorded resources - starting fresh", args.state_file)
    server_url = config["server"]["url"]
    recorded_url = existing.get("server_url")
    if recorded_url and recorded_url.rstrip("/") != server_url.rstrip("/"):
        logger.error(
            "%s was written for %s but the config points at %s - refusing to resume.",
            args.state_file, recorded_url, server_url,
        )
        sys.exit(1)

    session = TableauSession(
        server_url=server_url,
        site_uri=config["server"].get("site_uri", ""),
        dry_run=args.dry_run,
    )
    state = existing or {"server_url": session.server_url}
    state.setdefault("fingerprints", {})

    def record(key: str, value: str, fp_name: str, section: dict) -> None:
        """Persist each created ID immediately so a later failure can still be rolled back."""
        if not args.dry_run:
            state[key] = value
            state["fingerprints"][fp_name] = fingerprint(section)
            save_state(args.state_file, state)

    def reuse(key: str, label: str, fp_name: str, section: dict, validate) -> str | None:
        """On --resume, return the recorded ID for this step if it is still valid, else None."""
        recorded = existing.get(key)
        if not recorded:
            return None
        saved = existing["fingerprints"].get(fp_name) if "fingerprints" in existing else None
        if saved is None:
            logger.warning("No config fingerprint recorded for the %s - cannot check it is unchanged", label)
        elif saved != fingerprint(section):
            raise RuntimeError(
                f"The {label} config changed since it was created ({recorded}). "
                "Roll back with teardown_identity_pool.py and run setup again."
            )
        if not validate(session, recorded):
            raise RuntimeError(
                f"Recorded {label} {recorded} no longer exists on the server. "
                "Roll back with teardown_identity_pool.py and run setup again."
            )
        logger.info("Resuming: reusing %s %s", label, recorded)
        return recorded

    try:
        # ── Step 1: Authenticate ──────────────────────────────────────────────
        logger.info("── Step 1: Authenticating ──────────────────────────────")
        session.connect(token_name, token_secret)
        logger.info(
            "Session established (API version: %s, site ID: %s)",
            session.api_version,
            session.site_id,
        )

        # ── Step 2: Identity store ────────────────────────────────────────────
        logger.info("── Step 2: Identity store ──────────────────────────────")
        store_cfg = config["identity_store"]
        store_id = reuse(
            "identity_store_id", "identity store", "identity_store", store_cfg, validate_store_exists
        )
        if store_id is None:
            store_id = create_identity_store(
                session,
                name=store_cfg["name"],
                display_name=store_cfg.get("display_name"),
            )
            record("identity_store_id", store_id, "identity_store", store_cfg)
            if not validate_store_exists(session, store_id):
                raise RuntimeError("Identity store validation failed — aborting")

        # ── Step 3: Auth configuration ────────────────────────────────────────
        logger.info("── Step 3: OIDC auth configuration ─────────────────────")
        auth_cfg = config["auth_config"]
        auth_config_id = reuse(
            "auth_config_id", "auth configuration", "auth_config", auth_cfg, validate_auth_config_exists
        )
        if auth_config_id is None:
            auth_config_id = create_auth_config(
                session,
                auth_type=auth_cfg["auth_type"],
                client_id=auth_cfg["client_id"],
                client_secret=oidc_client_secret,
                config_url=auth_cfg["config_url"],
                id_claim=auth_cfg.get("id_claim", "sub"),
                username_claim=auth_cfg.get("username_claim", "email"),
                client_authentication=auth_cfg.get(
                    "client_authentication", "CLIENT_SECRET_BASIC"
                ),
                iframed_idp_enabled=auth_cfg.get("iframed_idp_enabled", False),
            )
            record("auth_config_id", auth_config_id, "auth_config", auth_cfg)
            if not validate_auth_config_exists(session, auth_config_id):
                raise RuntimeError("Auth configuration validation failed — aborting")

        # ── Step 4: Identity pool ─────────────────────────────────────────────
        logger.info("── Step 4: Identity pool ───────────────────────────────")
        pool_cfg = config["identity_pool"]
        pool_uuid = reuse(
            "identity_pool_uuid", "identity pool", "identity_pool", pool_cfg, validate_pool_exists
        )
        if pool_uuid is None:
            pool_uuid = create_identity_pool(
                session,
                name=pool_cfg["name"],
                description=pool_cfg.get("description", ""),
                store_id=store_id,
                auth_config_id=auth_config_id,
                is_enabled=pool_cfg.get("is_enabled", True),
            )
            record("identity_pool_uuid", pool_uuid, "identity_pool", pool_cfg)
            if not validate_pool_exists(session, pool_uuid):
                raise RuntimeError("Identity pool validation failed — aborting")

        # ── Done ──────────────────────────────────────────────────────────────
        redirect_uri = (
            f"{session.server_url}authn-service/authenticate/oidc/{pool_uuid}/login"
        )
        logger.info("=" * 60)
        logger.info("Setup complete%s", " (dry run)" if args.dry_run else "")
        logger.info("Identity pool UUID : %s", pool_uuid)
        logger.info("IdP redirect URI   : %s", redirect_uri)
        logger.info("Configure the redirect URI above in your IdP application.")
        if not args.dry_run:
            logger.info("To roll back: python python/teardown_identity_pool.py (uses %s)", args.state_file)
        logger.info("=" * 60)

    except RuntimeError as exc:
        logger.error("Aborted: %s", exc)
        sys.exit(1)
    except Exception as exc:
        logger.exception("Unexpected error: %s", exc)
        sys.exit(1)
    finally:
        session.disconnect()


if __name__ == "__main__":
    main()
