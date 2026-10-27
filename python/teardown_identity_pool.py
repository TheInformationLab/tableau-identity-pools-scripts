"""
Roll back what setup_identity_pool.py created: delete the identity pool, then the
authentication configuration, then the identity store (reverse order of creation).

By default the IDs come from created_resources.json, which setup_identity_pool.py writes
as it goes. Only resources recorded there (or passed explicitly) are ever deleted.

Usage:
    python python/teardown_identity_pool.py --config config.yml --dry-run
    python python/teardown_identity_pool.py --config config.yml
    python python/teardown_identity_pool.py --config config.yml --yes      # skip the prompt
    python python/teardown_identity_pool.py --config config.yml --pool-uuid <uuid>   # explicit IDs

Secrets are read from environment variables (or a .env file):
    TABLEAU_TOKEN_NAME    personal access token name
    TABLEAU_TOKEN_SECRET  personal access token secret
"""

import argparse
import logging
import os
import sys

import yaml
from dotenv import load_dotenv

from logging_config import setup_logging
from tableau_idp.auth_config import delete_auth_config
from tableau_idp.client import TableauSession
from tableau_idp.identity_pool import delete_identity_pool
from tableau_idp.identity_store import delete_identity_store
from tableau_idp.state import DEFAULT_STATE_FILE, clear_state, load_state, save_state

load_dotenv()

# (state key, label, delete function) in the order they must be deleted
_STEPS = (
    ("identity_pool_uuid", "identity pool", delete_identity_pool),
    ("auth_config_id", "auth configuration", delete_auth_config),
    ("identity_store_id", "identity store", delete_identity_store),
)


def _require_env(var: str, description: str) -> str:
    value = os.getenv(var)
    if not value:
        raise EnvironmentError(
            f"Required environment variable '{var}' is not set ({description})."
        )
    return value


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Delete the identity pool, auth configuration and identity store created by setup.",
    )
    parser.add_argument("--config", default="config.yml", help="Path to YAML configuration file")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help=f"default: {DEFAULT_STATE_FILE}")
    parser.add_argument("--pool-uuid", help="Delete this identity pool (overrides the state file)")
    parser.add_argument("--auth-config-id", help="Delete this auth configuration (overrides the state file)")
    parser.add_argument("--store-id", help="Delete this identity store (overrides the state file)")
    parser.add_argument("--dry-run", action="store_true", help="Log planned deletions without making API calls")
    parser.add_argument("--yes", action="store_true", help="Do not ask for confirmation")
    args = parser.parse_args()

    logger = setup_logging("teardown_identity_pool")

    explicit = {
        "identity_pool_uuid": args.pool_uuid,
        "auth_config_id": args.auth_config_id,
        "identity_store_id": args.store_id,
    }
    use_explicit = any(explicit.values())
    state = {k: v for k, v in explicit.items() if v} if use_explicit else load_state(args.state_file)
    targets = [(key, label, fn, state[key]) for key, label, fn in _STEPS if state.get(key)]
    if not targets:
        logger.error("Nothing to delete: no IDs in %s and none passed on the command line.", args.state_file)
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
    if recorded_url and recorded_url.rstrip("/") != server_url.rstrip("/"):
        logger.error(
            "State file was written for %s but config.yml points at %s - refusing to continue.",
            recorded_url, server_url,
        )
        sys.exit(1)

    logger.info("Will delete from %s:", server_url)
    for _, label, _, value in targets:
        logger.info("  %-18s %s", label, value)

    if not args.dry_run and not args.yes:
        try:
            answer = input("Type 'yes' to delete the resources above: ")
        except EOFError:
            answer = ""
        if answer.strip().lower() != "yes":
            logger.info("Aborted - nothing deleted.")
            sys.exit(1)

    session = TableauSession(
        server_url=server_url,
        site_uri=config["server"].get("site_uri", ""),
        dry_run=args.dry_run,
    )

    failures = 0
    try:
        session.connect(token_name, token_secret)
        for key, label, delete_fn, value in targets:
            try:
                delete_fn(session, value)
            except Exception as exc:  # keep going so one failure doesn't strand the rest
                status = getattr(getattr(exc, "response", None), "status_code", None)
                if status == 404:
                    logger.warning("%s %s was already gone (404) - treating as deleted", label, value)
                else:
                    failures += 1
                    logger.error("Failed to delete %s %s: %s", label, value, exc)
                    continue
            if not args.dry_run and not use_explicit:
                state.pop(key)
                save_state(args.state_file, state)
    except Exception as exc:
        logger.exception("Unexpected error: %s", exc)
        sys.exit(1)
    finally:
        session.disconnect()

    if failures:
        logger.error("%d deletion(s) failed - see above. Remaining IDs are still in %s.", failures, args.state_file)
        sys.exit(1)
    if not args.dry_run and not use_explicit:
        clear_state(args.state_file)
    logger.info("Teardown complete%s", " (dry run)" if args.dry_run else "")


if __name__ == "__main__":
    main()
