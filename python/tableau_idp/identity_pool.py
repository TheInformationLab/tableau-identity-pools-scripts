"""Create, list, validate, update, and delete identity pools."""

import logging

from tableau_idp._response import extract_id, extract_list
from tableau_idp.client import TableauSession

logger = logging.getLogger(__name__)

_PLACEHOLDER_UUID = "DRY-RUN-POOL-UUID"
# Identity pools use 'uuid' as their primary identifier per the Tableau docs
_ID_KEYS = ("uuid", "id", "identity_pool_id")
_LIST_KEYS = ("instances", "identity_pools", "pools", "items", "data", "results")


def create_identity_pool(
    session: TableauSession,
    name: str,
    description: str,
    store_id: str,
    auth_config_id: str,
    is_enabled: bool = True,
) -> str:
    """Create an identity pool linking an identity store and auth configuration.

    Returns the pool UUID, which is needed to configure the IdP redirect URI.
    """
    url = f"{session.server_url}api/-/authn-service/identity-pools"
    body = {
        "name": name,
        "description": description,
        "identity_store_instance": store_id,
        "auth_type_instance": auth_config_id,
        "is_enabled": is_enabled,
    }

    logger.info("Creating identity pool '%s'", name)
    result = session.post(url, body)

    if session.dry_run:
        logger.info("[DRY RUN] Returning placeholder pool UUID: %s", _PLACEHOLDER_UUID)
        return _PLACEHOLDER_UUID

    logger.debug("Identity pool creation response: %s", result)
    pool_uuid = extract_id(result, "identity_pool", id_keys=_ID_KEYS)
    logger.info("Identity pool created. UUID: %s", pool_uuid)
    return pool_uuid


def get_identity_pool(session: TableauSession, pool_uuid: str) -> dict | None:
    """Fetch a single identity pool by UUID."""
    url = f"{session.server_url}api/-/authn-service/identity-pools/{pool_uuid}"
    logger.info("Getting identity pool: %s", pool_uuid)
    result = session.get(url)
    if session.dry_run:
        return None
    logger.debug("Identity pool response: %s", result)
    return result


def list_identity_pools(session: TableauSession) -> list[dict]:
    """List all identity pools."""
    url = f"{session.server_url}api/-/authn-service/identity-pools"
    logger.info("Listing identity pools")
    result = session.get(url)

    if session.dry_run:
        return []

    logger.debug("Identity pools list response: %s", result)
    pools = extract_list(result, _LIST_KEYS)
    logger.info("Found %d identity pool(s)", len(pools))
    return pools


def validate_pool_exists(session: TableauSession, pool_uuid: str) -> bool:
    """Return True if the pool can be fetched directly by UUID."""
    if session.dry_run:
        logger.info("[DRY RUN] Skipping identity pool validation")
        return True
    pool = get_identity_pool(session, pool_uuid)
    found = pool is not None and bool(pool)
    if found:
        logger.info("Validation passed: identity pool %s exists", pool_uuid)
    else:
        logger.error("Validation failed: identity pool %s not found", pool_uuid)
    return found


def update_identity_pool(
    session: TableauSession,
    pool_uuid: str,
    updates: dict,
) -> dict | None:
    """Update an identity pool by UUID."""
    url = f"{session.server_url}api/-/authn-service/identity-pools/{pool_uuid}"
    logger.info("Updating identity pool: %s", pool_uuid)
    result = session.put(url, updates)
    if not session.dry_run:
        logger.info("Identity pool %s updated", pool_uuid)
    return result


def delete_identity_pool(session: TableauSession, pool_uuid: str) -> None:
    """Delete an identity pool by UUID."""
    url = f"{session.server_url}api/-/authn-service/identity-pools/{pool_uuid}"
    logger.info("Deleting identity pool: %s", pool_uuid)
    session.delete(url)
    if not session.dry_run:
        logger.info("Identity pool %s deleted", pool_uuid)
