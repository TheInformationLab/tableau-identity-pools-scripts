"""Handles authentication to the Tableau Server REST API using personal access tokens."""

import logging

import requests

logger = logging.getLogger(__name__)

_JSON_HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}


def get_api_version(server_url: str) -> str:
    """Fetch the latest REST API version supported by the server."""
    resp = requests.get(
        f"{server_url}api/2.4/serverinfo",
        headers={"Accept": "application/json"},
        timeout=10,
    )
    resp.raise_for_status()
    api_version = resp.json()["serverInfo"]["restApiVersion"]
    logger.info("Server REST API version: %s", api_version)
    return api_version


def get_auth_response(
    token_name: str,
    token_secret: str,
    server_url: str,
    site_uri: str,
    api_version: str,
) -> tuple[str, str]:
    """Sign in with a personal access token. Returns (site_id, auth_token)."""
    endpoint = f"{server_url}api/{api_version}/auth/signin"
    body = {
        "credentials": {
            "personalAccessTokenName": token_name,
            "personalAccessTokenSecret": token_secret,
            "site": {"contentUrl": site_uri},
        }
    }
    resp = requests.post(endpoint, json=body, headers=_JSON_HEADERS, timeout=10)
    logger.info("Sign in response: %d", resp.status_code)
    resp.raise_for_status()

    data = resp.json()
    site_id = data["credentials"]["site"]["id"]
    auth_token = data["credentials"]["token"]
    logger.info("Authenticated. Site ID: %s", site_id)
    return site_id, auth_token


def sign_out(server_url: str, api_version: str, auth_token: str) -> None:
    """Sign out and invalidate the session token."""
    endpoint = f"{server_url}api/{api_version}/auth/signout"
    resp = requests.post(
        endpoint,
        headers={"X-Tableau-Auth": auth_token, "Accept": "application/json"},
        timeout=10,
    )
    if resp.status_code == 204:
        logger.info("Signed out successfully")
    else:
        raise requests.HTTPError(f"Sign out failed: {resp.status_code} - {resp.text}")
