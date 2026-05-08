#!/usr/bin/env bash
set -euo pipefail

ORG="${ORG:-platforminit}"
REPO="${REPO:-platforminit-platform}"
SECRETS_DIR="${SECRETS_DIR:-.local_secrets}"
SCOPE="${SCOPE:-repo}" # repo or org

require_file() {
  local path="$1"
  [[ -s "$path" ]] || { echo "Missing or empty secret file: $path" >&2; exit 1; }
}

upload_secret() {
  local secret_name="$1"
  local file_path="$2"
  require_file "$file_path"

  if [[ "$SCOPE" == "org" ]]; then
    gh secret set "$secret_name" \
      --org "$ORG" \
      --repos "$REPO" \
      --visibility selected \
      --body "$(tr -d '\r\n' < "$file_path")"
  elif [[ "$SCOPE" == "repo" ]]; then
    gh secret set "$secret_name" \
      --repo "$ORG/$REPO" \
      --body "$(tr -d '\r\n' < "$file_path")"
  else
    echo "Unsupported SCOPE=$SCOPE. Use SCOPE=repo or SCOPE=org." >&2
    exit 1
  fi
}

gh auth status >/dev/null

upload_secret "HCLOUD_TOKEN_DEVELOPMENT" "$SECRETS_DIR/development_api_key"
upload_secret "HCLOUD_TOKEN_N8N" "$SECRETS_DIR/n8n_api_key"
upload_secret "HCLOUD_TOKEN_PLATFORMINIT" "$SECRETS_DIR/platforminit_api_key"

echo "Hetzner project secrets uploaded successfully to $SCOPE scope for $ORG/$REPO"
