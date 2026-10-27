"""Authenticated HTTP session for Tableau REST and authn-service APIs.

Both API tiers share the same X-Tableau-Auth token header:
  Standard REST API:   {server_url}/api/{api_version}/...
  authn-service API:   {server_url}/api/-/authn-service/...

In dry-run mode all mutating calls are logged and skipped; GET calls are also
skipped so the script can run without a live server.
"""

import logging

import requests

from tableau_idp.auth import get_api_version, get_auth_response, sign_out

logger = logging.getLogger(__name__)

_DRY_RUN_API_VERSION = "3.19"
_DRY_RUN_SITE_ID = "DRY-RUN-SITE-ID"
_DRY_RUN_TOKEN = "DRY-RUN-AUTH-TOKEN"


_SECRET_KEYS = {"client_secret", "personalAccessTokenSecret"}


def _redact(value):
    """Copy of a request body with secrets masked, safe to log."""
    if isinstance(value, dict):
        return {k: "***" if k in _SECRET_KEYS else _redact(v) for k, v in value.items()}
    return value


def _raise_for_status(resp: requests.Response) -> None:
    """Like raise_for_status(), but includes the server's response body in the error."""
    try:
        resp.raise_for_status()
    except requests.HTTPError as exc:
        raise requests.HTTPError(f"{exc} | Response: {resp.text[:500]}", response=resp) from None


class TableauSession:
    def __init__(self, server_url: str, site_uri: str = "", dry_run: bool = False):
        self.server_url = server_url.rstrip("/") + "/"
        self.site_uri = site_uri
        self.dry_run = dry_run
        self.api_version: str | None = None
        self.site_id: str | None = None
        self._token: str | None = None

    def connect(self, token_name: str, token_secret: str) -> None:
        """Authenticate and store the session token."""
        if self.dry_run:
            logger.info("[DRY RUN] Skipping authentication (token: %s)", token_name)
            self.api_version = _DRY_RUN_API_VERSION
            self.site_id = _DRY_RUN_SITE_ID
            self._token = _DRY_RUN_TOKEN
            return
        self.api_version = get_api_version(self.server_url)
        self.site_id, self._token = get_auth_response(
            token_name, token_secret, self.server_url, self.site_uri, self.api_version
        )

    def disconnect(self) -> None:
        """Sign out and clear the session token."""
        if self.dry_run:
            logger.info("[DRY RUN] Skipping sign out")
            return
        if self._token:
            sign_out(self.server_url, self.api_version, self._token)
        self._token = None
        self.site_id = None

    def _headers(self) -> dict:
        return {
            "X-Tableau-Auth": self._token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def get(self, url: str) -> dict | None:
        if self.dry_run:
            logger.info("[DRY RUN] GET %s", url)
            return None
        resp = requests.get(url, headers=self._headers(), timeout=30)
        logger.debug("GET %s -> %d", url, resp.status_code)
        resp.raise_for_status()
        return resp.json()

    def post(self, url: str, body: dict) -> dict | None:
        if self.dry_run:
            logger.info("[DRY RUN] POST %s", url)
            logger.debug("[DRY RUN] Body: %s", _redact(body))
            return None
        logger.debug("POST %s body: %s", url, _redact(body))
        resp = requests.post(url, json=body, headers=self._headers(), timeout=30)
        logger.debug("POST %s -> %d %s", url, resp.status_code, resp.text[:500])
        _raise_for_status(resp)
        return resp.json() if resp.text else {}

    def put(self, url: str, body: dict) -> dict | None:
        if self.dry_run:
            logger.info("[DRY RUN] PUT %s", url)
            logger.debug("[DRY RUN] Body: %s", body)
            return None
        resp = requests.put(url, json=body, headers=self._headers(), timeout=30)
        logger.debug("PUT %s -> %d", url, resp.status_code)
        resp.raise_for_status()
        return resp.json() if resp.text else {}

    def delete(self, url: str) -> None:
        if self.dry_run:
            logger.info("[DRY RUN] DELETE %s", url)
            return
        resp = requests.delete(url, headers=self._headers(), timeout=30)
        logger.debug("DELETE %s -> %d", url, resp.status_code)
        resp.raise_for_status()
