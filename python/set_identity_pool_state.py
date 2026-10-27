"""
Enable or disable an identity pool, e.g. create it disabled, register the redirect URI in your
IdP, then switch it on - and switch it straight back off if something looks wrong.

With neither --enable nor --disable it just reports the pool's current state (read-only).

The pool UUID comes from created_resources.json (written by setup_identity_pool.py) unless
--pool-uuid is given.

Usage:
    python python/set_identity_pool_state.py --config config.yml               # show state
    python python/set_identity_pool_state.py --config config.yml --enable
    python python/set_identity_pool_state.py --config config.yml --disable
    python python/set_identity_pool_state.py --config config.yml --enable --dry-run

Secrets are read from environment variables (or a .env file):
    TABLEAU_TOKEN_NAME    personal access token name
    TABLEAU_TOKEN_SECRET  personal access token secret
"""

import argparse
import os
import sys

import yaml
from dotenv import load_dotenv

from logging_config import setup_logging
from tableau_idp.client import TableauSession
from tableau_idp.identity_pool import get_pool_enabled, set_pool_enabled
from tableau_idp.state import DEFAULT_STATE_FILE, load_state

load_dotenv()


def _require_env(var: str, description: str) -> str:
    value = os.getenv(var)
    if not value:
        raise EnvironmentError(
            f"Required environment variable '{var}' is not set ({description})."
        )
    return value


def _label(enabled: bool | None) -> str:
    return "unknown" if enabled is None else ("ENABLED" if enabled else "DISABLED")


def main() -> None:
    parser = argparse.ArgumentParser(description="Enable or disable an identity pool.")
    parser.add_argument("--config", default="config.yml", help="Path to YAML configuration file")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help=f"default: {DEFAULT_STATE_FILE}")
    parser.add_argument("--pool-uuid", help="Identity pool UUID (default: read from the state file)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--enable", action="store_true", help="Enable the pool")
    group.add_argument("--disable", action="store_true", help="Disable the pool")
    parser.add_argument("--dry-run", action="store_true", help="Log planned actions without making API calls")
    args = parser.parse_args()

    logger = setup_logging("set_identity_pool_state")

    state = load_state(args.state_file)
    pool_uuid = args.pool_uuid or state.get("identity_pool_uuid")
    if not pool_uuid:
        logger.error("No pool UUID: pass --pool-uuid or run setup_identity_pool.py first (%s).", args.state_file)
        sys.exit(1)

    try:
        with open(args.config, encoding="utf-8") as f:
            config = yaml.safe_load(f)
        token_name = _require_env("TABLEAU_TOKEN_NAME", "personal access token name")
        token_secret = _require_env("TABLEAU_TOKEN_SECRET", "personal access token secret")
    except (FileNotFoundError, EnvironmentError) as exc:
        logger.error("Configuration error: %s", exc)
        sys.exit(1)

    server_url = config["server"]["url"]
    recorded_url = state.get("server_url")
    if not args.pool_uuid and recorded_url and recorded_url.rstrip("/") != server_url.rstrip("/"):
        logger.error(
            "State file was written for %s but config.yml points at %s - refusing to continue.",
            recorded_url, server_url,
        )
        sys.exit(1)

    session = TableauSession(
        server_url=server_url,
        site_uri=config["server"].get("site_uri", ""),
        dry_run=args.dry_run,
    )

    exit_code = 0
    try:
        session.connect(token_name, token_secret)
        before = get_pool_enabled(session, pool_uuid)
        logger.info("Identity pool %s is currently %s", pool_uuid, _label(before))

        if not (args.enable or args.disable):
            return  # report only

        desired = args.enable
        if before is desired:
            logger.info("Already %s - nothing to do", _label(desired))
        elif set_pool_enabled(session, pool_uuid, desired):
            suffix = " (dry run)" if args.dry_run else ""
            logger.info("Identity pool %s is now %s%s", pool_uuid, _label(desired), suffix)
        else:
            logger.error(
                "Could not set the pool to %s - see the warnings above and the log file for the "
                "requests and responses.", _label(desired),
            )
            exit_code = 1
    except Exception as exc:
        logger.exception("Failed: %s", exc)
        exit_code = 1
    finally:
        session.disconnect()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
