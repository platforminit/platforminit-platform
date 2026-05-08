#!/usr/bin/env bash
set -euo pipefail

ORG="platforminit"
REPO="platforminit-platform"
SECRETS_DIR="${SECRETS_DIR:-.local_secrets}"
SCOPE="${SCOPE:-repo}" # repo or org

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing local secret file: $path" >&2; exit 1; }
}

set_secret() {
  local name="$1"
  local file="$2"
  require_file "$file"

  if [[ "$SCOPE" == "org" ]]; then
    gh secret set "$name" \
      --org "$ORG" \
      --repos "$REPO" \
      --visibility selected \
      --body "$(cat "$file")"
  else
    gh secret set "$name" \
      --repo "$ORG/$REPO" \
      --body "$(cat "$file")"
  fi
}

gh auth status >/dev/null

set_secret HCLOUD_TOKEN_DEVELOPMENT "$SECRETS_DIR/development_api_key"
set_secret HCLOUD_TOKEN_N8N "$SECRETS_DIR/n8n_api_key"
set_secret HCLOUD_TOKEN_PLATFORMINIT "$SECRETS_DIR/platforminit_api_key"

echo "Hetzner project secrets uploaded successfully to $SCOPE scope."
