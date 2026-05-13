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

ensure_cluster
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-postgres --timeout=60s
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-server --timeout=60s
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-web --timeout=60s
kubectl -n "$NAMESPACE" get ds/zabbix-agent2 >/dev/null
echo "PASS: Zabbix base deployment healthy"
