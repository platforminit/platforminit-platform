#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }

ensure_cluster
kubectl -n "$IDENTITY_NAMESPACE" get svc authentik-server >/dev/null
kubectl -n "$NAMESPACE" get middleware authentik-forward-auth >/dev/null
address="$(kubectl -n "$NAMESPACE" get middleware authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}' 2>/dev/null || true)"
case "$address" in
  *authentik-server.identity.svc.cluster.local*/outpost.goauthentik.io/auth/traefik*) ;;
  *) die "Unexpected forwardAuth address: ${address}" ;;
esac
kubectl -n "$NAMESPACE" get ingress zabbix openobserve >/dev/null
zabbix_host="$(kubectl -n "$NAMESPACE" get ingress zabbix -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
logs_host="$(kubectl -n "$NAMESPACE" get ingress openobserve -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
[[ "$zabbix_host" == "zabbix.${BASE_DOMAIN}" ]] || die "Unexpected Zabbix host: ${zabbix_host}"
[[ "$logs_host" == "logs.${BASE_DOMAIN}" ]] || die "Unexpected OpenObserve host: ${logs_host}"
echo "PASS: Operations SSO ingress objects present and routed through Authentik embedded outpost endpoint"
