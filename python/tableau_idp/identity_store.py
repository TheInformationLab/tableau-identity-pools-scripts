"""Create, list, validate, and delete authn-service identity stores."""

import logging

from tableau_idp._response import extract_id, extract_list
from tableau_idp.client import TableauSession

logger = logging.getLogger(__name__)

_PLACEHOLDER_ID = "DRY-RUN-STORE-ID"
_LIST_KEYS = ("instances", "identity_stores", "items", "data", "results")


def create_identity_store(
    session: TableauSession,
    name: str,
    display_name: str | None = None,
    store_type: str = "0",
) -> str:
    """Create a local identity store. Returns the store ID."""
    url = f"{session.server_url}api/-/authn-service/identity-stores"
    body: dict = {"name": name, "type": store_type}
    if display_name:
        body["display_name"] = display_name

    logger.info("Creating identity store '%s'", name)
    result = session.post(url, body)

    if session.dry_run:
        logger.info("[DRY RUN] Returning placeholder store ID: %s", _PLACEHOLDER_ID)
        return _PLACEHOLDER_ID

    logger.debug("Identity store creation response: %s", result)
    store_id = extract_id(result, "identity_store")
    logger.info("Identity store created. ID: %s", store_id)
    return store_id


def list_identity_stores(session: TableauSession) -> list[dict]:
    """List all configured identity stores."""
    url = f"{session.server_url}api/-/authn-service/identity-stores"
    logger.info("Listing identity stores")
    result = session.get(url)

    if session.dry_run:
        return []

    logger.debug("Identity stores list response: %s", result)
    stores = extract_list(result, _LIST_KEYS)
    logger.info("Found %d identity store(s)", len(stores))
    return stores


def validate_store_exists(session: TableauSession, store_id: str) -> bool:
    """Return True if the given store ID appears in the list of identity stores."""
    if session.dry_run:
        logger.info("[DRY RUN] Skipping identity store validation")
        return True
    stores = list_identity_stores(session)
    found = any(str(s.get("id", "")) == store_id for s in stores)
    if found:
        logger.info("Validation passed: identity store %s exists", store_id)
    else:
        logger.error(
            "Validation failed: identity store %s not found. Existing stores: %s",
            store_id,
            stores,
        )
    return found


def delete_identity_store(session: TableauSession, store_id: str) -> None:
    """Delete an identity store by ID."""
    url = f"{session.server_url}api/-/authn-service/identity-stores/{store_id}"
    logger.info("Deleting identity store: %s", store_id)
    session.delete(url)
    if not session.dry_run:
        logger.info("Identity store %s deleted", store_id)
