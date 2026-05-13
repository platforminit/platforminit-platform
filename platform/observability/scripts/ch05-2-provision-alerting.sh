#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05.2][$(date -u +%FT%TZ)] $*"; }
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

log "Waiting for VictoriaMetrics alerting CRDs"
timeout 180 bash -c 'until kubectl get crd vmrules.operator.victoriametrics.com >/dev/null 2>&1; do sleep 2; done' \
  || die "VMRule CRD is not ready"

if [[ ! -f "${REPO_ROOT}/manifests/alerts/platform-vmrule.yaml" ]]; then
  die "Missing VMRule manifest: ${REPO_ROOT}/manifests/alerts/platform-vmrule.yaml"
fi

log "Applying PlatformInit operational VMRule set"
kubectl apply -f "${REPO_ROOT}/manifests/alerts/platform-vmrule.yaml"

log "Annotating VMRule for traceability"
kubectl -n "${NAMESPACE}" annotate vmrule platform-rules \
  platforminit.io/provisioned-by="ch05.2" \
  platforminit.io/provisioned-at="$(date -u +%Y%m%dT%H%M%SZ)" \
  --overwrite >/dev/null 2>&1 || true

log "Requesting VMAlert reconciliation"
kubectl -n "${NAMESPACE}" annotate vmalert --all \
  platforminit.io/reloaded-at="$(date -u +%Y%m%dT%H%M%SZ)" \
  --overwrite >/dev/null 2>&1 || true

# Best-effort restart: generated pod labels can vary across chart versions, but
# vmalert appears in the pod name. The operator will recreate it if needed.
kubectl -n "${NAMESPACE}" get pods -o name 2>/dev/null \
  | grep -E '/.*vmalert.*' \
  | xargs -r kubectl -n "${NAMESPACE}" delete --ignore-not-found >/dev/null 2>&1 || true

log "Waiting for VMAlert workload readiness"
if kubectl -n "${NAMESPACE}" get pods -o name 2>/dev/null | grep -qE '/.*vmalert.*'; then
  for pod in $(kubectl -n "${NAMESPACE}" get pods -o name | grep -E '/.*vmalert.*'); do
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready "${pod}" --timeout=180s || true
  done
else
  log "WARN: VMAlert pod not found immediately after reconciliation request"
fi

log "CH05.2 alerting provisioning completed"
