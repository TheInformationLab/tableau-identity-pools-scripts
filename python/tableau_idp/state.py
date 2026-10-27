"""Record the resources a setup run creates so they can be rolled back precisely.

The state file is plain JSON shared with the PowerShell scripts:
    {"server_url": ..., "identity_store_id": ..., "auth_config_id": ..., "identity_pool_uuid": ...,
     "fingerprints": {"identity_store": ..., "auth_config": ..., "identity_pool": ...}}
Keys are added as each resource is created, so a run that fails part-way is still recoverable.
The fingerprints let --resume detect that a config section changed since the resource was created.
"""

import hashlib
import json
import logging
import os

logger = logging.getLogger(__name__)

DEFAULT_STATE_FILE = "created_resources.json"


def load_state(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8-sig") as f:  # -sig: tolerate a BOM
        return json.load(f)


def save_state(path: str, state: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    logger.debug("State saved to %s: %s", path, state)


def clear_state(path: str) -> None:
    if os.path.exists(path):
        os.remove(path)


def fingerprint(section: dict) -> str:
    """Short stable hash of a config section.

    Must produce the same value as the PowerShell implementation: sorted keys, "key=value" lines,
    booleans as true/false, empty values ignored, SHA-256 of the UTF-8 text, first 16 hex chars.
    """
    def fmt(v) -> str:
        return str(v).lower() if isinstance(v, bool) else str(v)

    canonical = "\n".join(
        f"{k}={fmt(v)}" for k, v in sorted(section.items()) if v is not None and v != ""
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]
