#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05][argocd-apps][$(date -u +%FT%TZ)] $*"; }
warn(){ echo "WARN: $*" >&2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-https://github.com/platforminit/platforminit-platform.git}"
GITOPS_TARGET_REVISION="${GITOPS_TARGET_REVISION:-dev}"

export KUBECONFIG

if ! kubectl get ns "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  warn "Argo CD namespace ${ARGOCD_NAMESPACE} does not exist; skipping Application registration"
  exit 0
fi

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  warn "Argo CD Application CRD is not installed; skipping Application registration"
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

rendered="${tmp_dir}/ch05-observability-inventory.yaml"
sed \
  -e "s|__REPO_URL__|${GITOPS_REPO_URL}|g" \
  -e "s|__TARGET_REVISION__|${GITOPS_TARGET_REVISION}|g" \
  "${REPO_ROOT}/argocd/ch05-observability-inventory.yaml.tpl" > "${rendered}"

log "Registering CH05 observability inventory Application in Argo CD"
kubectl apply -f "${rendered}"

log "Registered ch05-observability Application with repo=${GITOPS_REPO_URL} revision=${GITOPS_TARGET_REVISION}"
log "Note: Helm-owned releases remain workflow-owned until a dedicated GitOps migration is performed."
