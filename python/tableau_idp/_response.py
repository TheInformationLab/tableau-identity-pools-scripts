"""Helpers for parsing authn-service API responses.

The authn-service response format is not fully documented by Tableau.
These helpers try common field name patterns and raise descriptive errors
when nothing matches — the logged DEBUG output will show the full response,
making it easy to identify the correct field names against a real server.
"""

import logging

logger = logging.getLogger(__name__)


def _unwrap(value) -> str:
    """IDs are sometimes wrapped as {"value": "..."} (e.g. identity pool UUIDs)."""
    if isinstance(value, dict) and "value" in value:
        return str(value["value"])
    return str(value)


def extract_id(
    response: dict,
    resource: str,
    id_keys: tuple[str, ...] = ("id", "uuid"),
) -> str:
    """Extract a resource ID from a creation response.

    Tries top-level keys first, then looks inside a nested wrapper object.
    Raises ValueError with the full response if nothing matches.
    """
    for key in id_keys:
        if key in response:
            return _unwrap(response[key])

    # Some endpoints nest the created object under a wrapper key
    wrapper_key = resource.lower().replace(" ", "_")
    for candidate in (wrapper_key, "data", "result"):
        nested = response.get(candidate)
        if isinstance(nested, dict):
            for key in id_keys:
                if key in nested:
                    return _unwrap(nested[key])

    # Wrapper name not known in advance (the server uses e.g. {"store_instance": {...}}):
    # accept a single nested object that carries an ID.
    carriers = [
        v for v in response.values()
        if isinstance(v, dict) and any(k in v for k in id_keys)
    ]
    if len(carriers) == 1:
        for key in id_keys:
            if key in carriers[0]:
                return _unwrap(carriers[0][key])

    raise ValueError(
        f"Could not extract ID from {resource} response.\n"
        f"Full response: {response}\n"
        "Check the DEBUG logs for the raw response and update the id_keys argument."
    )


def extract_list(
    response: dict | list,
    list_keys: tuple[str, ...],
) -> list[dict]:
    """Extract a list of items from a list-endpoint response.

    Tries known wrapper key names in order. Returns an empty list and logs a
    warning if nothing matches so the caller can inspect the raw response.
    """
    if isinstance(response, list):
        return response
    for key in list_keys:
        value = response.get(key)
        if isinstance(value, list):
            return value
    logger.warning(
        "Could not identify list field in response. Keys tried: %s. Response: %s",
        list_keys,
        response,
    )
    return []
