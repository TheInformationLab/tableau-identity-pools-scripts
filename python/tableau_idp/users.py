"""Add and remove users from identity pools via the standard REST API."""

import logging

from tableau_idp.client import TableauSession

logger = logging.getLogger(__name__)


def add_user_to_pool(
    session: TableauSession,
    user_id: str,
    pool_uuid: str,
    identity_uuid: str,
    username: str | None = None,
    site_role: str | None = None,
    auth_setting: str | None = None,
) -> dict | None:
    """Add an existing Tableau user to an identity pool.

    Args:
        user_id:       Tableau user ID (from the Get Users endpoint).
        pool_uuid:     UUID of the target identity pool.
        identity_uuid: Identifier used to match the user in the identity store.
        username:      Optional display name override.
        site_role:     Optional site role (Creator, Explorer, Viewer, etc.).
        auth_setting:  Optional authentication configuration instance reference.

    Returns the API response body, or None in dry-run mode.
    """
    url = (
        f"{session.server_url}api/{session.api_version}"
        f"/sites/{session.site_id}/users/identityPool"
    )
    user_body: dict = {
        "id": user_id,
        "identityPoolUuid": pool_uuid,
        "identityUuid": identity_uuid,
    }
    if username:
        user_body["name"] = username
    if site_role:
        user_body["siteRole"] = site_role
    if auth_setting:
        user_body["authSetting"] = auth_setting

    logger.info("Adding user %s to identity pool %s", user_id, pool_uuid)
    result = session.post(url, {"user": user_body})

    if session.dry_run:
        return None

    logger.debug("Add user to pool response: %s", result)
    logger.info("User %s added to pool %s", user_id, pool_uuid)
    return result


def remove_user_from_pool(
    session: TableauSession,
    user_id: str,
    pool_uuid: str,
) -> None:
    """Remove a user from an identity pool."""
    url = (
        f"{session.server_url}api/{session.api_version}"
        f"/sites/{session.site_id}/users/{user_id}/identityPool/{pool_uuid}"
    )
    logger.info("Removing user %s from identity pool %s", user_id, pool_uuid)
    session.delete(url)
    if not session.dry_run:
        logger.info("User %s removed from pool %s", user_id, pool_uuid)
