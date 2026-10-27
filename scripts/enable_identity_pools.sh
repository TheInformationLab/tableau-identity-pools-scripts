#!/bin/bash
# Enable the Tableau Server identity pools feature via TSM.
#
# Run this on the Tableau Server primary node as a user with TSM admin access
# BEFORE running setup_identity_pool.py. The pending-changes apply step will
# restart Tableau Server services.
#
# Usage:
#   ./enable_identity_pools.sh <external_url>
#   ./enable_identity_pools.sh http://mytableau.example.com
#
# Optional: if Tableau Server sits behind a forward proxy, uncomment and fill
# in the proxy section below.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <external_url>"
    echo "Example: $0 http://mytableau.example.com"
    exit 1
fi

EXTERNAL_URL="$1"

echo "=== Configuring Tableau Server for identity pools ==="

echo "Setting gateway external URL: $EXTERNAL_URL"
tsm configuration set -k gateway.external_url -v "$EXTERNAL_URL"

echo "Enabling identity pools feature flags..."
tsm configuration set -k features.IdentityPools -v true
tsm configuration set -k features.NewIdentityMode -v true
tsm configuration set -k wgserver.authentication.legacy_identity_mode.enabled -v false

# ── Forward proxy (uncomment if needed) ───────────────────────────────────────
# tsm configuration set -k tomcat.useSystemProxies -v true
# tsm configuration set -k tomcat.http.proxyHost -v <proxy_host>
# tsm configuration set -k tomcat.http.proxyPort -v <proxy_port>
# tsm pending-changes apply  # applied again below, no need to run twice

echo "Applying pending changes (Tableau Server services will restart)..."
tsm pending-changes apply --ignore-prompt

echo ""
echo "=== Done ==="
echo "Identity pools feature is enabled."
echo "Next: run 'python python/setup_identity_pool.py --config config.yml' to create a pool."
