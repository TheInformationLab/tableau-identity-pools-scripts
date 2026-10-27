"""Create, list, validate, update, and delete OIDC authentication configurations."""

import logging

from tableau_idp._response import extract_id, extract_list
from tableau_idp.client import TableauSession

logger = logging.getLogger(__name__)

_PLACEHOLDER_ID = "DRY-RUN-AUTH-CONFIG-ID"
_LIST_KEYS = ("instances", "auth_configurations", "configurations", "items", "data", "results")


def create_auth_config(
    session: TableauSession,
    auth_type: str,
    client_id: str,
    client_secret: str,
    config_url: str,
    id_claim: str = "sub",
    username_claim: str = "email",
    client_authentication: str = "CLIENT_SECRET_BASIC",
    iframed_idp_enabled: bool = False,
) -> str:
    """Create an OIDC authentication configuration. Returns the config ID."""
    url = f"{session.server_url}api/-/authn-service/auth-configurations"
    # Per the Tableau docs the IdP settings are nested under an "oidc" object
    body = {
        "auth_type": auth_type,
        "iframed_idp_enabled": iframed_idp_enabled,
        "oidc": {
            "client_id": client_id,
            "client_secret": client_secret,
            "config_url": config_url,
            "id_claim": id_claim,
            "username_claim": username_claim,
            "client_authentication": client_authentication,
        },
    }

    logger.info("Creating auth configuration (type: %s, IdP: %s)", auth_type, config_url)
    result = session.post(url, body)

    if session.dry_run:
        logger.info("[DRY RUN] Returning placeholder auth config ID: %s", _PLACEHOLDER_ID)
        return _PLACEHOLDER_ID

    logger.debug("Auth config creation response: %s", result)
    config_id = extract_id(result, "auth_configuration")
    logger.info("Auth configuration created. ID: %s", config_id)
    return config_id


def list_auth_configs(session: TableauSession) -> list[dict]:
    """List all authentication configurations."""
    url = f"{session.server_url}api/-/authn-service/auth-configurations"
    logger.info("Listing auth configurations")
    result = session.get(url)

    if session.dry_run:
        return []

    logger.debug("Auth configs list response: %s", result)
    configs = extract_list(result, _LIST_KEYS)
    logger.info("Found %d auth configuration(s)", len(configs))
    return configs


def validate_auth_config_exists(session: TableauSession, config_id: str) -> bool:
    """Return True if the given config ID appears in the list of auth configurations."""
    if session.dry_run:
        logger.info("[DRY RUN] Skipping auth configuration validation")
        return True
    configs = list_auth_configs(session)
    found = any(str(c.get("id", "")) == config_id for c in configs)
    if found:
        logger.info("Validation passed: auth configuration %s exists", config_id)
    else:
        logger.error(
            "Validation failed: auth configuration %s not found. Existing configs: %s",
            config_id,
            configs,
        )
    return found


def update_auth_config(
    session: TableauSession,
    config_id: str,
    updates: dict,
) -> dict | None:
    """Update an existing authentication configuration by ID."""
    url = f"{session.server_url}api/-/authn-service/auth-configurations/{config_id}"
    logger.info("Updating auth configuration: %s", config_id)
    result = session.put(url, updates)
    if not session.dry_run:
        logger.info("Auth configuration %s updated", config_id)
    return result


def delete_auth_config(session: TableauSession, config_id: str) -> None:
    """Delete an authentication configuration by ID."""
    url = f"{session.server_url}api/-/authn-service/auth-configurations/{config_id}"
    logger.info("Deleting auth configuration: %s", config_id)
    session.delete(url)
    if not session.dry_run:
        logger.info("Auth configuration %s deleted", config_id)
