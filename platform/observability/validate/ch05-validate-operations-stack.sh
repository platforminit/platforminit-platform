#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
export KUBECONFIG
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD application $APP_NAME"
kubectl -n "$NAMESPACE" get deploy zabbix-postgres zabbix-server zabbix-web openobserve >/dev/null
kubectl -n "$NAMESPACE" get ds zabbix-agent2 vector >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-postgres --timeout=120s >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-server --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-web --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/openobserve --timeout=240s >/dev/null
kubectl -n "$NAMESPACE" rollout status ds/vector --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" get ingress zabbix openobserve >/dev/null
for host in "zabbix.${BASE_DOMAIN}" "logs.${BASE_DOMAIN}"; do
  kubectl -n "$NAMESPACE" get ingress -o json | grep -q "$host" || die "Missing ingress host: $host"
done
kubectl -n "$NAMESPACE" get secret zabbix-postgres openobserve-root openobserve-sso zabbix-saml-certs >/dev/null
if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
  die "Stale forward-auth middleware exists; Operations WebUIs must use native app SSO"
fi
sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
[[ "$sync_status" == "Synced" ]] || die "Argo CD app is not Synced: ${sync_status:-unknown}"
log "PASS: CH05 operations stack is Argo CD-owned and runtime resources are healthy"
