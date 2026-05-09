#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH05][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DEPLOY_MODE="${DEPLOY_MODE:-baseline}"
ISSUER_MODE="${ISSUER_MODE:-staging}"

case "${DEPLOY_MODE}" in
  baseline|reconcile) ;;
  *) die "DEPLOY_MODE must be baseline or reconcile, got: ${DEPLOY_MODE}" ;;
esac

case "${ISSUER_MODE}" in
  staging|prod) ;;
  *) die "ISSUER_MODE must be staging or prod, got: ${ISSUER_MODE}" ;;
esac

CLUSTER_ISSUER="letsencrypt-${ISSUER_MODE}"
NAMESPACE="${NAMESPACE:-observability}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-changeme}"
VM_STACK_CHART_VERSION="${VM_STACK_CHART_VERSION:-0.72.5}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-6.55.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.0.0}"

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG


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
  [ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster via ${KUBECONFIG}"
}

ensure_namespace() {
  kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
}

prepare_values() {
  local vm_values="${REPO_ROOT}/values/victoria-metrics-k8s-stack-values.yaml"
  cp "${vm_values}" /tmp/ch05-vm-values.yaml
  sed -i "s/adminPassword: changeme/adminPassword: ${GRAFANA_ADMIN_PASSWORD//\//\/}/" /tmp/ch05-vm-values.yaml
}

apply_grafana_ingress() {
  local tmp_dir=""
  tmp_dir="$(mktemp -d)"

  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    "${REPO_ROOT}/ingress/grafana-ingress.yaml" > "${tmp_dir}/grafana-ingress.yaml"

  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__CLUSTER_ISSUER__|${CLUSTER_ISSUER}|g" \
    "${REPO_ROOT}/ingress/grafana-certificate.yaml" > "${tmp_dir}/grafana-certificate.yaml"

  kubectl apply -f "${tmp_dir}/grafana-certificate.yaml"
  kubectl apply -f "${tmp_dir}/grafana-ingress.yaml"

  rm -rf "${tmp_dir}"
}

install_repos() {
  helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
}

deploy_vm_stack() {
  log "Deploying VictoriaMetrics stack (mode=${DEPLOY_MODE})"

  local helm_args=(
    upgrade --install observability-vmstack vm/victoria-metrics-k8s-stack
    --namespace "${NAMESPACE}"
    --version "${VM_STACK_CHART_VERSION}"
    -f /tmp/ch05-vm-values.yaml
    --wait --timeout 15m
  )

  # CH05 owns the Grafana Helm release. After CH06.1 enables SSO, reconcile mode
  # must preserve the existing Grafana auth overlay instead of resetting the
  # release to the base observability values only.
  if [[ "${DEPLOY_MODE}" == "reconcile" ]] && helm -n "${NAMESPACE}" status observability-vmstack >/dev/null 2>&1; then
    log "Using --reuse-values to preserve post-CH05 overlays such as Grafana SSO"
    helm_args+=(--reuse-values)
  fi

  if [[ "${DEPLOY_MODE}" == "baseline" ]] && kubectl -n "${NAMESPACE}" get secret grafana-authentik-oauth >/dev/null 2>&1; then
    log "Grafana SSO secret detected; baseline mode may reset Grafana OAuth Helm values. Run 06.1 after CH05 baseline if SSO disappears."
  fi

  helm "${helm_args[@]}"
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
  apply_grafana_ingress
  log "CH05 observability deploy completed with deploy_mode=${DEPLOY_MODE} issuer=${CLUSTER_ISSUER}"
}

main "$@"
