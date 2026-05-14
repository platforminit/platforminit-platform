#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

diag_pods(){
  log "Operations pod diagnostics"
  kubectl -n "$NAMESPACE" get pods -o wide || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -80 || true
  kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '$2 != "1/1" || $3 != "Running" {print $1}' | while read -r pod; do
    [ -n "$pod" ] || continue
    echo "--- describe pod/${pod} ---"
    kubectl -n "$NAMESPACE" describe pod "$pod" || true
    echo "--- logs pod/${pod} ---"
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=160 || true
  done
}

wait_deployment_ready(){
  local name="$1" timeout="${2:-180}" start now desired available updated observed generation
  log "Checking deployment/${name} readiness"
  start="$(date +%s)"
  while true; do
    desired="$(kubectl -n "$NAMESPACE" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    available="$(kubectl -n "$NAMESPACE" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
    updated="$(kubectl -n "$NAMESPACE" get deploy "$name" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo 0)"
    observed="$(kubectl -n "$NAMESPACE" get deploy "$name" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
    generation="$(kubectl -n "$NAMESPACE" get deploy "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
    desired="${desired:-0}"; available="${available:-0}"; updated="${updated:-0}"; observed="${observed:-0}"; generation="${generation:-0}"
    log "deployment/${name}: desired=${desired} updated=${updated} available=${available} observedGeneration=${observed}/${generation}"
    if [[ "$observed" == "$generation" && "$available" -ge "$desired" && "$updated" -ge "$desired" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      kubectl -n "$NAMESPACE" describe deploy "$name" || true
      kubectl -n "$NAMESPACE" get rs,pods -l app.kubernetes.io/name="$name" -o wide || true
      diag_pods
      die "deployment/${name} did not become ready within ${timeout}s"
    fi
    sleep 10
  done
}

wait_daemonset_ready(){
  local name="$1" timeout="${2:-180}" start now desired ready updated unavailable observed generation
  log "Checking daemonset/${name} readiness"
  start="$(date +%s)"
  while true; do
    desired="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    ready="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    updated="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.status.updatedNumberScheduled}' 2>/dev/null || echo 0)"
    unavailable="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.status.numberUnavailable}' 2>/dev/null || echo 0)"
    observed="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
    generation="$(kubectl -n "$NAMESPACE" get ds "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
    desired="${desired:-0}"; ready="${ready:-0}"; updated="${updated:-0}"; unavailable="${unavailable:-0}"; observed="${observed:-0}"; generation="${generation:-0}"
    log "daemonset/${name}: desired=${desired} updated=${updated} ready=${ready} unavailable=${unavailable} observedGeneration=${observed}/${generation}"
    if [[ "$observed" == "$generation" && "$desired" -gt 0 && "$ready" -ge "$desired" && "$updated" -ge "$desired" && "$unavailable" -eq 0 ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      kubectl -n "$NAMESPACE" describe ds "$name" || true
      kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name="$name" -o wide || true
      kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name="$name" --all-containers --tail=160 || true
      diag_pods
      die "daemonset/${name} did not become ready within ${timeout}s"
    fi
    sleep 10
  done
}

kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD application $APP_NAME"
kubectl -n "$NAMESPACE" get deploy zabbix-postgres zabbix-server zabbix-web openobserve >/dev/null
kubectl -n "$NAMESPACE" get ds zabbix-agent2 vector >/dev/null
wait_deployment_ready zabbix-postgres 120
wait_deployment_ready zabbix-server 180
wait_deployment_ready zabbix-web 180
wait_deployment_ready openobserve 240
wait_daemonset_ready zabbix-agent2 120
wait_daemonset_ready vector 180
kubectl -n "$NAMESPACE" get ingress zabbix openobserve >/dev/null
for host in "zabbix.${BASE_DOMAIN}" "logs.${BASE_DOMAIN}"; do
  kubectl -n "$NAMESPACE" get ingress -o json | grep -q "$host" || die "Missing ingress host: $host"
done
kubectl -n "$NAMESPACE" get secret zabbix-postgres openobserve-root openobserve-sso zabbix-saml-certs >/dev/null
if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
  die "Stale forward-auth middleware exists; Operations WebUIs must use native app SSO"
fi
sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
[[ "$sync_status" == "Synced" ]] || die "Argo CD app is not Synced: ${sync_status:-unknown}"
[[ "$health_status" == "Healthy" ]] || die "Argo CD app is not Healthy: ${health_status:-unknown}"
log "PASS: CH05 operations stack is Argo CD-owned and runtime resources are healthy"
