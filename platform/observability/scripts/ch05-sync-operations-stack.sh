#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
export KUBECONFIG
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD app: $APP_NAME. Run 05 register first."
log "Requesting Argo CD refresh for $APP_NAME"
kubectl -n "$ARGOCD_NAMESPACE" annotate application.argoproj.io "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
start="$(date +%s)"
while true; do
  sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  phase="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  log "Argo CD status: sync=${sync_status:-unknown} health=${health_status:-unknown} phase=${phase:-none}"
  if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
    log "Operations stack is synced and healthy"
    break
  fi
  now="$(date +%s)"
  if (( now - start > TIMEOUT_SECONDS )); then
    kubectl -n "$ARGOCD_NAMESPACE" describe application.argoproj.io "$APP_NAME" || true
    kubectl -n operations get pods,ingress,svc,pvc || true
    die "Timed out waiting for Argo CD operations stack to become Synced/Healthy"
  fi
  sleep 15
done
kubectl -n operations get pods,svc,ingress,pvc
