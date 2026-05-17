#!/usr/bin/env bash
set -euo pipefail

log() { printf '[validate-n8n-runtime][%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

N8N_DOMAIN="${N8N_DOMAIN:-}"
RUNTIME_DIR="${RUNTIME_DIR:-/srv/n8n}"
[ -n "$N8N_DOMAIN" ] || fatal "Missing N8N_DOMAIN"

log "Validating standalone n8n runtime domain=${N8N_DOMAIN}"

command -v docker >/dev/null 2>&1 || fatal "docker is not installed"
docker compose version >/dev/null 2>&1 || fatal "docker compose plugin is not available"
[ -f "${RUNTIME_DIR}/docker-compose.yml" ] || fatal "Missing ${RUNTIME_DIR}/docker-compose.yml"
[ -f "${RUNTIME_DIR}/Caddyfile" ] || fatal "Missing ${RUNTIME_DIR}/Caddyfile"
[ -f "${RUNTIME_DIR}/.env" ] || fatal "Missing ${RUNTIME_DIR}/.env"

systemctl is-enabled platforminit-n8n-runtime.service >/dev/null 2>&1 || fatal "platforminit-n8n-runtime.service is not enabled"

docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" ps

for container in platforminit-n8n-postgres platforminit-n8n platforminit-n8n-caddy; do
  state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
  [ "$state" = "true" ] || fatal "Container is not running: ${container}"
done

log "Checking local n8n health endpoint through container network"
docker exec platforminit-n8n sh -lc 'wget -qO- http://127.0.0.1:5678/healthz >/dev/null' || fatal "n8n local health endpoint failed"

log "Checking host HTTP/HTTPS listener"
ss -lntp | grep -E ':(80|443)\s' || fatal "Expected Caddy listeners on 80/443"

log "Checking public HTTPS route"
http_code="$(curl -ksS -o /tmp/platforminit-n8n-validate.html -w '%{http_code}' "https://${N8N_DOMAIN}/" || true)"
case "$http_code" in
  200|301|302|307|308) log "Public HTTPS route returned HTTP=${http_code}" ;;
  *) fatal "Unexpected HTTPS status from https://${N8N_DOMAIN}/: HTTP=${http_code}" ;;
esac

log "PASS: standalone n8n runtime validation completed"
