#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05.1][$(date -u +%FT%TZ)] $*"; }
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

log "Applying PlatformInit operational Grafana dashboards only"
mapfile -t dashboard_files < <(find "${REPO_ROOT}/manifests/dashboards" -maxdepth 1 -type f -name 'grafana-dashboard-[0-9][0-9]-*.yaml' | sort)
if [[ "${#dashboard_files[@]}" -eq 0 ]]; then
  die "No operational dashboard manifests found under ${REPO_ROOT}/manifests/dashboards"
fi
for dashboard_file in "${dashboard_files[@]}"; do
  kubectl apply -f "${dashboard_file}"
done

log "Pruning noisy legacy/upstream Grafana dashboard ConfigMaps from the operator landing view"
keep_csv="grafana-dashboard-00-platform-overview,grafana-dashboard-05-alert-operations-center,grafana-dashboard-10-host-infrastructure,grafana-dashboard-20-kubernetes-k3s,grafana-dashboard-30-argocd-gitops,grafana-dashboard-40-identity-sso,grafana-dashboard-50-observability-self-monitoring,grafana-dashboard-60-security-audit,grafana-dashboard-90-application-template"
prune_file="$(mktemp)"
kubectl -n "${NAMESPACE}" get configmap -l grafana_dashboard=1 -o json \
  | KEEP_CSV="${keep_csv}" python3 -c 'import json, os, sys
keep=set(os.environ.get("KEEP_CSV", "").split(","))
for item in json.load(sys.stdin).get("items", []):
    name=item.get("metadata", {}).get("name", "")
    if name and name not in keep:
        print(name)' > "${prune_file}"
while IFS= read -r cm_name; do
  [[ -z "${cm_name}" ]] && continue
  log "Deleting noisy dashboard ConfigMap: ${cm_name}"
  kubectl -n "${NAMESPACE}" delete configmap "${cm_name}" --ignore-not-found=true >/dev/null 2>&1 || true
done < "${prune_file}"
rm -f "${prune_file}"

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

log "CH05.1 dashboard provisioning completed"
