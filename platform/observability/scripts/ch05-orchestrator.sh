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

apply_pre_vm_manifests() {
  # The VictoriaMetrics Operator expects VMAgent additionalScrapeConfigs as a
  # SecretKeySelector, not a ConfigMap. This must exist before the Helm release
  # creates/reconciles the VMAgent CR, otherwise the operator may create the CR
  # but never materialize a healthy VMAgent workload.
  log "Applying vmagent additional scrape Secret before VM stack deploy"
  kubectl create secret generic vmagent-additional-scrape \
    --namespace "${NAMESPACE}" \
    --from-file=additional-scrape.yaml="${REPO_ROOT}/manifests/metrics/vmagent-additional-scrape.yaml" \
    --dry-run=client -o yaml | kubectl apply -f -
}

prune_noise_dashboard_configmaps() {
  # Keep Grafana focused on the PlatformInit operational dashboards. The
  # VictoriaMetrics chart can create many upstream dashboards for generic
  # Kubernetes control-plane layouts. On single-node k3s these are noisy and
  # can show expected No data panels. PlatformInit dashboards are preserved via
  # app.kubernetes.io/part-of=platforminit.
  log "Pruning non-PlatformInit Grafana dashboard ConfigMaps"
  kubectl -n "${NAMESPACE}" delete configmap \
    -l 'grafana_dashboard=1,app.kubernetes.io/part-of notin (platforminit)' \
    --ignore-not-found >/dev/null 2>&1 || true
}

apply_post_vm_manifests() {
  prune_noise_dashboard_configmaps

  if [[ -f "${REPO_ROOT}/manifests/metrics/platform-k3s-core-vmservicescrapes.yaml" ]]; then
    log "Applying k3s core VMServiceScrape objects"
    kubectl apply -f "${REPO_ROOT}/manifests/metrics/platform-k3s-core-vmservicescrapes.yaml"
  fi

  log "Applying alert rules"
  kubectl apply -f "${REPO_ROOT}/manifests/alerts/platform-vmrule.yaml"

  if [[ -d "${REPO_ROOT}/manifests/dashboards" ]]; then
    log "Applying PlatformInit Grafana dashboards"
    kubectl apply -f "${REPO_ROOT}/manifests/dashboards"
  fi

  log "Provisioning Grafana datasources"
  bash "${REPO_ROOT}/scripts/provision-grafana-datasources.sh"

  log "Requesting VMAgent reconciliation after scrape Secret changes"
  kubectl -n "${NAMESPACE}" annotate vmagent --all \
    platforminit.io/reloaded-at="$(date -u +%Y%m%dT%H%M%SZ)" \
    --overwrite >/dev/null 2>&1 || true

  # Delete any existing VMAgent pod using a broad name selector. The chart and
  # operator labels can differ between versions, while generated pod names keep
  # vmagent in the name. This is intentionally best-effort and idempotent.
  kubectl -n "${NAMESPACE}" get pods -o name 2>/dev/null \
    | grep -E '/.*vmagent.*' \
    | xargs -r kubectl -n "${NAMESPACE}" delete --ignore-not-found >/dev/null 2>&1 || true
}

wait_for_named_pod_ready() {
  local regex="$1"
  local label="$2"
  local timeout_seconds="${3:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  local pod=""

  while (( SECONDS < deadline )); do
    pod="$(kubectl -n "${NAMESPACE}" get pods -o name 2>/dev/null | grep -E "$regex" | head -n1 || true)"
    if [[ -n "$pod" ]]; then
      if kubectl -n "${NAMESPACE}" wait --for=condition=Ready "$pod" --timeout=30s >/dev/null 2>&1; then
        log "${label} ready: ${pod#pod/}"
        return 0
      fi
    fi
    sleep 5
  done

  echo "WARN: ${label} pod did not become Ready within ${timeout_seconds}s" >&2
  kubectl -n "${NAMESPACE}" get pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get vmagent -o yaml >&2 || true
  return 1
}

wait_for_metric_pipeline() {
  log "Waiting for VMAgent and core exporters"

  wait_for_named_pod_ready '/.*vmagent.*' 'VMAgent' 300 || true

  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=kube-state-metrics \
    --timeout=300s >/dev/null 2>&1 || true

  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=prometheus-node-exporter \
    --timeout=300s >/dev/null 2>&1 || true

  # Give VMAgent a short warm-up window so that the first scrape cycle can land
  # before PromQL-based validation starts.
  sleep 30
}

register_argocd_apps() {
  if [[ "${REGISTER_ARGOCD_APPS:-true}" != "true" ]]; then
    log "Skipping Argo CD Application registration because REGISTER_ARGOCD_APPS=${REGISTER_ARGOCD_APPS:-}"
    return 0
  fi

  if [[ -x "${REPO_ROOT}/scripts/ch05-register-argocd-apps.sh" ]]; then
    env \
      KUBECONFIG="${KUBECONFIG}" \
      GITOPS_REPO_URL="${GITOPS_REPO_URL:-https://github.com/platforminit/platforminit-platform.git}" \
      GITOPS_TARGET_REVISION="${GITOPS_TARGET_REVISION:-dev}" \
      bash "${REPO_ROOT}/scripts/ch05-register-argocd-apps.sh"
  else
    log "No Argo CD Application registration script found; skipping"
  fi
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
  apply_pre_vm_manifests
  deploy_vm_stack
  wait_for_vm_crds
  apply_post_vm_manifests
  wait_for_metric_pipeline
  deploy_loki
  deploy_alloy
  restart_if_needed
  apply_grafana_ingress
  register_argocd_apps
  log "CH05 observability deploy completed with deploy_mode=${DEPLOY_MODE} issuer=${CLUSTER_ISSUER}"
}

main "$@"
