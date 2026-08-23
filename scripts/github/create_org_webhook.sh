#!/usr/bin/env bash
# create_org_webhook.sh
#
# Registers an organization-level webhook via GitHub's REST API instead of
# clicking through the Settings -> Webhooks UI. This endpoint is available
# on every GitHub plan (unlike the audit-log API, which needs Enterprise
# Cloud) -- creating webhooks has never been the gated part.
#
# Required env vars:
#   GITHUB_TOKEN  - a token with admin:org scope (classic) or equivalent
#                    fine-grained "Webhooks" org permission
#   GITHUB_ORG    - your org's login, e.g. renato-wazuh-lab
#   WEBHOOK_URL   - the public URL to receive deliveries, e.g. the ngrok
#                    URL printed by scripts/mac/start_listener.sh
#
# Never hardcode GITHUB_TOKEN in this file -- export it in your shell
# before running, or source it from a local .env you keep out of git.

set -euo pipefail

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN first (export GITHUB_TOKEN=...)}"
: "${GITHUB_ORG:?Set GITHUB_ORG first (export GITHUB_ORG=your-org)}"
: "${WEBHOOK_URL:?Set WEBHOOK_URL first (export WEBHOOK_URL=https://...)}"

echo "Creating webhook on $GITHUB_ORG -> $WEBHOOK_URL ..."

RESPONSE="$(curl -sS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/$GITHUB_ORG/hooks" \
    -d '{
        "name": "web",
        "active": true,
        "events": ["*"],
        "config": {
            "url": "'"$WEBHOOK_URL"'",
            "content_type": "json",
            "insecure_ssl": "0"
        }
    }')"

echo "$RESPONSE" | python3 -m json.tool

HOOK_ID="$(echo "$RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))')"
if [ -n "$HOOK_ID" ]; then
    echo
    echo "Webhook created, id: $HOOK_ID"
else
    echo
    echo "No id in the response -- check the output above for an error message" >&2
    exit 1
fi

echo
echo "Note: free ngrok URLs change every time you restart the tunnel"
echo "(unless you've reserved a static domain on your ngrok account)."
echo "Re-run this script with a fresh WEBHOOK_URL whenever the tunnel changes,"
echo "or edit the existing webhook's URL from the GitHub UI instead."
