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
kubectl get ns identity >/dev/null 2>&1 || die "Missing identity namespace. Run 04.5 first."
kubectl -n identity rollout status deploy/authentik-server --timeout=60s >/dev/null || die "Authentik server is not healthy"
kubectl -n "$NAMESPACE" get svc zabbix-web >/dev/null 2>&1 || die "Missing Zabbix service. Run 05 first."
kubectl -n "$NAMESPACE" get svc openobserve >/dev/null 2>&1 || die "Missing OpenObserve service. Run 05.2 first."
if ! kubectl -n identity get svc ak-outpost-authentik-embedded-outpost >/dev/null 2>&1; then
  die "Missing Authentik embedded outpost service: identity/ak-outpost-authentik-embedded-outpost. Enable/configure Authentik outpost before exposing operations WebUIs."
fi
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
render_tpl "$REPO_ROOT/manifests/sso/authentik-forward-auth.yaml.tpl" "$workdir/operations-sso.yaml"
log "Applying Authentik-gated operations ingresses"
kubectl apply -f "$workdir/operations-sso.yaml"
log "Operations SSO applied"
kubectl -n "$NAMESPACE" get ingress zabbix openobserve
