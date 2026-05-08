#!/usr/bin/env bash
set -euo pipefail
ORG="platforminit"
REPO="platforminit-platform"
gh secret set HCLOUD_TOKEN_DEVELOPMENT --org "$ORG" --repos "$REPO" --body "$(cat .local-secrets/development_api_key)"
gh secret set HCLOUD_TOKEN_N8N --org "$ORG" --repos "$REPO" --body "$(cat .local-secrets/n8n_api_key)"
gh secret set HCLOUD_TOKEN_PLATFORMINIT --org "$ORG" --repos "$REPO" --body "$(cat .local-secrets/platforminit_api_key)"
