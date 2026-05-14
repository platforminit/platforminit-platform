#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
ISSUER_MODE="${ISSUER_MODE:-staging}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }
apply_dir(){ local dir="$1"; find "$dir" -type f -name '*.yaml' -print | sort | xargs -r -n1 kubectl apply -f; }
render_tpl(){ local src="$1" dst="$2"; sed -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" -e "s#__ISSUER_MODE__#${ISSUER_MODE}#g" "$src" > "$dst"; }

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
ensure_cluster
cat <<EOF
CH05.3 external host onboarding contract is reserved.

Target model:
- install Zabbix agent on the external host
- install Vector on the external host
- send logs to https://logs.${BASE_DOMAIN} or internal OpenObserve endpoint through a controlled route

No changes were applied.
EOF
