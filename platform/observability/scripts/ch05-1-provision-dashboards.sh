#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05.5][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-observability}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

need kubectl
[ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${NAMESPACE}. Run 05 - Deploy Observability Stack first."

if [[ ! -d "${REPO_ROOT}/manifests/dashboards" ]]; then
  die "Missing dashboards directory: ${REPO_ROOT}/manifests/dashboards"
fi

log "Applying PlatformInit operational Grafana dashboards"
kubectl apply -f "${REPO_ROOT}/manifests/dashboards"

log "Annotating dashboard ConfigMaps for traceability"
kubectl -n "${NAMESPACE}" annotate configmap \
  -l 'grafana_dashboard=1,app.kubernetes.io/part-of=platforminit' \
  platforminit.io/provisioned-at="$(date -u +%Y%m%dT%H%M%SZ)" \
  --overwrite >/dev/null 2>&1 || true

if kubectl -n "${NAMESPACE}" get deploy observability-vmstack-grafana >/dev/null 2>&1; then
  log "Restarting Grafana so sidecar/dashboard provisioning refreshes immediately"
  kubectl -n "${NAMESPACE}" rollout restart deploy/observability-vmstack-grafana >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deploy/observability-vmstack-grafana --timeout=300s || true
else
  log "WARN: Grafana deployment not found; dashboards were applied but UI refresh could not be forced"
fi

log "CH05.5 dashboard provisioning completed"
