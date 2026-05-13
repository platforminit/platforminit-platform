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
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl apply -f "$REPO_ROOT/manifests/00-namespace/namespace.yaml"
log "Preparing OpenObserve root secret"
existing_password="$(kubectl -n "$NAMESPACE" get secret openobserve-root -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
root_email="${OPENOBSERVE_ROOT_USER_EMAIL:-admin@${BASE_DOMAIN}}"
if [[ -z "$existing_password" ]]; then
  root_password="${OPENOBSERVE_ROOT_USER_PASSWORD:-$(openssl rand -hex 24)}"
else
  root_password="$existing_password"
fi
kubectl -n "$NAMESPACE" create secret generic openobserve-root \
  --from-literal=ZO_ROOT_USER_EMAIL="$root_email" \
  --from-literal=ZO_ROOT_USER_PASSWORD="$root_password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Applying OpenObserve manifests"
kubectl apply -f "$REPO_ROOT/manifests/openobserve/openobserve.yaml" || true
kubectl -n "$NAMESPACE" create secret generic openobserve-root \
  --from-literal=ZO_ROOT_USER_EMAIL="$root_email" \
  --from-literal=ZO_ROOT_USER_PASSWORD="$root_password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/openobserve --timeout=300s
log "OpenObserve deployment complete. Public ingress is created by CH05.4 Operations SSO."
