#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DEPLOY_MODE="${DEPLOY_MODE:-baseline}"
NAMESPACE="${NAMESPACE:-observability}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-changeme}"
VM_STACK_CHART_VERSION="${VM_STACK_CHART_VERSION:-0.72.5}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-6.55.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.0.0}"

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates gnupg rsync >/dev/null
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
}

ensure_cluster_ready() {
  need kubectl
  kubectl get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster"
}

ensure_namespace() {
  kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
}

prepare_values() {
  local vm_values="${REPO_ROOT}/values/victoria-metrics-k8s-stack-values.yaml"
  cp "${vm_values}" /tmp/ch05-vm-values.yaml
  sed -i "s/adminPassword: changeme/adminPassword: ${GRAFANA_ADMIN_PASSWORD//\//\/}/" /tmp/ch05-vm-values.yaml
}

install_repos() {
  helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
}

deploy_vm_stack() {
  log "Deploying VictoriaMetrics stack"
  helm upgrade --install observability-vmstack vm/victoria-metrics-k8s-stack     --namespace "${NAMESPACE}"     --version "${VM_STACK_CHART_VERSION}"     -f /tmp/ch05-vm-values.yaml     --wait --timeout 15m
}

wait_for_vm_crds() {
  log "Waiting for VictoriaMetrics CRDs"
  local crd
  for crd in     vmrules.operator.victoriametrics.com     vmagents.operator.victoriametrics.com     vmalerts.operator.victoriametrics.com     vmsingles.operator.victoriametrics.com
  do
    timeout 180 bash -c "until kubectl get crd ${crd} >/dev/null 2>&1; do sleep 2; done"
  done

  log "Waiting for VictoriaMetrics API registration"
  timeout 180 bash -c 'until kubectl api-resources --api-group=operator.victoriametrics.com 2>/dev/null | grep -q "VMRule"; do sleep 2; done'
}

deploy_loki() {
  log "Deploying Loki"
  helm upgrade --install loki grafana/loki     --namespace "${NAMESPACE}"     --version "${LOKI_CHART_VERSION}"     -f "${REPO_ROOT}/values/loki-values.yaml"     --wait --timeout 15m
}

deploy_alloy() {
  log "Applying Alloy config"
  kubectl apply -f "${REPO_ROOT}/manifests/logging/alloy-logs-config.yaml"

  log "Deploying Alloy"
  helm upgrade --install alloy grafana/alloy     --namespace "${NAMESPACE}"     --version "${ALLOY_CHART_VERSION}"     -f "${REPO_ROOT}/values/alloy-values.yaml"     --wait --timeout 15m
}

apply_post_vm_manifests() {
  log "Applying vmagent additional scrape config"
  kubectl create configmap vmagent-additional-scrape     --namespace "${NAMESPACE}"     --from-file=additional-scrape.yaml="${REPO_ROOT}/manifests/metrics/vmagent-additional-scrape.yaml"     --dry-run=client -o yaml | kubectl apply -f -

  log "Applying alert rules"
  kubectl apply -f "${REPO_ROOT}/manifests/alerts/platform-vmrule.yaml"

  log "Provisioning Grafana datasources"
  bash "${REPO_ROOT}/scripts/provision-grafana-datasources.sh"
}

restart_if_needed() {
  kubectl -n "${NAMESPACE}" rollout restart deploy/observability-vmstack-grafana || true
  kubectl -n "${NAMESPACE}" rollout status deploy/observability-vmstack-grafana --timeout=300s || true
}

main() {
  ensure_runtime_deps
  ensure_helm
  ensure_cluster_ready
  ensure_namespace
  prepare_values
  install_repos
  deploy_vm_stack
  wait_for_vm_crds
  apply_post_vm_manifests
  deploy_loki
  deploy_alloy
  restart_if_needed
  log "CH05 observability deploy completed in mode=${DEPLOY_MODE}"
}

main "$@"
