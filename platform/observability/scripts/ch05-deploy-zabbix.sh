#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ISSUER_MODE="${ISSUER_MODE:-staging}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }
apply_dir(){ local dir="$1"; find "$dir" -type f -name '*.yaml' -print | sort | xargs -r -n1 kubectl apply -f; }
render_tpl(){ local src="$1" dst="$2"; sed -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" -e "s#__ISSUER_MODE__#${ISSUER_MODE}#g" "$src" > "$dst"; }

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
ensure_cluster
log "Applying operations namespace"
kubectl apply -f "$REPO_ROOT/manifests/00-namespace/namespace.yaml"
log "Preparing Zabbix PostgreSQL secret"
existing_db_password="$(kubectl -n "$NAMESPACE" get secret zabbix-postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -z "$existing_db_password" ]]; then
  db_password="$(openssl rand -hex 24)"
  existing_db_password="$db_password"
  kubectl -n "$NAMESPACE" create secret generic zabbix-postgres \
    --from-literal=POSTGRES_DB=zabbix \
    --from-literal=POSTGRES_USER=zabbix \
    --from-literal=POSTGRES_PASSWORD="$db_password" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
log "Applying Zabbix manifests"
# Apply PVC/deployments after preserving the generated secret.
kubectl apply -f "$REPO_ROOT/manifests/zabbix/postgres.yaml" || true
if [[ -n "$existing_db_password" ]]; then
  kubectl -n "$NAMESPACE" create secret generic zabbix-postgres \
    --from-literal=POSTGRES_DB=zabbix \
    --from-literal=POSTGRES_USER=zabbix \
    --from-literal=POSTGRES_PASSWORD="$existing_db_password" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
kubectl apply -f "$REPO_ROOT/manifests/zabbix/zabbix-server.yaml"
kubectl apply -f "$REPO_ROOT/manifests/zabbix/zabbix-web.yaml"
kubectl apply -f "$REPO_ROOT/manifests/zabbix/zabbix-agent2.yaml"
log "Waiting for Zabbix rollouts"
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-postgres --timeout=300s
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-server --timeout=300s
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-web --timeout=300s
kubectl -n "$NAMESPACE" rollout status ds/zabbix-agent2 --timeout=300s || true
log "Zabbix base deployment complete. Public ingress is created by CH05.4 Operations SSO."
