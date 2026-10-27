"""
Read-only utility: list all identity stores, auth configurations, and identity pools
currently configured on the Tableau Server.

Useful for inspecting state before or after running setup_identity_pool.py.

Usage:
    python python/list_resources.py --config config.yml
    python python/list_resources.py --config config.yml --dry-run

(run from the repo root; config.yml and .env are looked up there)

Secrets are read from environment variables (or a .env file):
    TABLEAU_TOKEN_NAME    personal access token name
    TABLEAU_TOKEN_SECRET  personal access token secret
"""

import argparse
import json
import logging
import os
import sys

import yaml
from dotenv import load_dotenv

from logging_config import setup_logging
from tableau_idp.auth_config import list_auth_configs
from tableau_idp.client import TableauSession
from tableau_idp.identity_pool import list_identity_pools
from tableau_idp.identity_store import list_identity_stores

load_dotenv()

logger = logging.getLogger(__name__)


def _require_env(var: str, description: str) -> str:
    value = os.getenv(var)
    if not value:
        raise EnvironmentError(
            f"Required environment variable '{var}' is not set ({description})."
        )
    return value


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def _format(data: list[dict]) -> str:
    return json.dumps(data, indent=2, default=str) if data else "(none)"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List identity stores, auth configurations, and identity pools.",
    )
    parser.add_argument(
        "--config",
        default="config.yml",
        help="Path to YAML configuration file (default: config.yml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate without making API calls",
    )
    args = parser.parse_args()

    logger_root = setup_logging("list_resources")

    if args.dry_run:
        logger_root.info("[DRY RUN] No real API calls will be made")

    try:
        config = load_config(args.config)
        token_name = _require_env("TABLEAU_TOKEN_NAME", "personal access token name")
        token_secret = _require_env("TABLEAU_TOKEN_SECRET", "personal access token secret")
    except (FileNotFoundError, EnvironmentError) as exc:
        logger_root.error("Configuration error: %s", exc)
        sys.exit(1)

    session = TableauSession(
        server_url=config["server"]["url"],
        site_uri=config["server"].get("site_uri", ""),
        dry_run=args.dry_run,
    )

    try:
        session.connect(token_name, token_secret)

        stores = list_identity_stores(session)
        logger_root.info("── Identity Stores ──────────────────────────────────")
        logger_root.info(_format(stores))

        configs = list_auth_configs(session)
        logger_root.info("── Auth Configurations ──────────────────────────────")
        logger_root.info(_format(configs))

        pools = list_identity_pools(session)
        logger_root.info("── Identity Pools ───────────────────────────────────")
        logger_root.info(_format(pools))

    except Exception as exc:
        logger_root.exception("Failed: %s", exc)
        sys.exit(1)
    finally:
        session.disconnect()


if __name__ == "__main__":
    main()
