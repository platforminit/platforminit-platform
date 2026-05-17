#!/usr/bin/env bash
set -euo pipefail

log() { printf '[deploy-n8n-runtime][%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || fatal "Missing required environment variable: ${name}"
}

require_env N8N_DOMAIN
require_env TLS_EMAIL
require_env N8N_ENCRYPTION_KEY
require_env POSTGRES_PASSWORD

N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.8-alpine}"
N8N_TIMEZONE="${N8N_TIMEZONE:-Europe/Budapest}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
POSTGRES_USER="${POSTGRES_USER:-n8n}"
RUNTIME_DIR="${RUNTIME_DIR:-/srv/n8n}"
SOURCE_DIR="${SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

[[ "$N8N_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "N8N_DOMAIN contains unsupported characters"
[[ "$TLS_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fatal "TLS_EMAIL does not look like an email address"
[ -f "${SOURCE_DIR}/templates/docker-compose.yml.tpl" ] || fatal "Missing docker-compose template under ${SOURCE_DIR}"
[ -f "${SOURCE_DIR}/templates/Caddyfile.tpl" ] || fatal "Missing Caddyfile template under ${SOURCE_DIR}"

log "Deploying standalone n8n runtime domain=${N8N_DOMAIN} runtime_dir=${RUNTIME_DIR}"

export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker from Ubuntu packages"
  apt-get update
  apt-get install -y docker.io docker-compose-plugin
else
  log "Docker already installed: $(docker --version)"
  if ! docker compose version >/dev/null 2>&1; then
    log "Installing docker-compose-plugin"
    apt-get update
    apt-get install -y docker-compose-plugin
  fi
fi

systemctl enable --now docker

install -d -m 0750 "${RUNTIME_DIR}"
install -d -m 0750 "${RUNTIME_DIR}/data" "${RUNTIME_DIR}/postgres" "${RUNTIME_DIR}/caddy-data" "${RUNTIME_DIR}/caddy-config"

umask 077
cat > "${RUNTIME_DIR}/.env" <<ENVEOF
N8N_DOMAIN=${N8N_DOMAIN}
N8N_TIMEZONE=${N8N_TIMEZONE}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ENVEOF

sed \
  -e "s#__N8N_IMAGE__#${N8N_IMAGE}#g" \
  -e "s#__POSTGRES_IMAGE__#${POSTGRES_IMAGE}#g" \
  -e "s#__CADDY_IMAGE__#${CADDY_IMAGE}#g" \
  "${SOURCE_DIR}/templates/docker-compose.yml.tpl" > "${RUNTIME_DIR}/docker-compose.yml"

sed \
  -e "s#__N8N_DOMAIN__#${N8N_DOMAIN}#g" \
  -e "s#__TLS_EMAIL__#${TLS_EMAIL}#g" \
  "${SOURCE_DIR}/templates/Caddyfile.tpl" > "${RUNTIME_DIR}/Caddyfile"

chmod 0600 "${RUNTIME_DIR}/.env"
chmod 0640 "${RUNTIME_DIR}/docker-compose.yml" "${RUNTIME_DIR}/Caddyfile"

cat > /etc/systemd/system/platforminit-n8n-runtime.service <<SERVICEEOF
[Unit]
Description=PlatformInit standalone n8n runtime
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${RUNTIME_DIR}
ExecStart=/usr/bin/docker compose --env-file ${RUNTIME_DIR}/.env -f ${RUNTIME_DIR}/docker-compose.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose --env-file ${RUNTIME_DIR}/.env -f ${RUNTIME_DIR}/docker-compose.yml down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable platforminit-n8n-runtime.service

if command -v ufw >/dev/null 2>&1; then
  log "Ensuring UFW allows HTTP/HTTPS"
  ufw allow 80/tcp comment 'PlatformInit n8n Caddy HTTP' >/dev/null || true
  ufw allow 443/tcp comment 'PlatformInit n8n Caddy HTTPS' >/dev/null || true
fi

log "Pulling and starting containers"
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" pull
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" up -d --remove-orphans

log "Runtime status"
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" ps

log "n8n deployment completed. First login/owner setup is handled by n8n WebUI at https://${N8N_DOMAIN}/"
