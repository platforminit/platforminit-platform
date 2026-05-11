#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH03][argocd-baseline][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ARGOCD_DOMAIN="${ARGOCD_DOMAIN:-argocd.${BASE_DOMAIN}}"
ARGOCD_URL="${ARGOCD_URL:-https://${ARGOCD_DOMAIN}}"
ARGO_VERSION="${ARGO_VERSION:-v2.8.4}"
ARGO_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
need kubectl

ensure_argocd_namespace() {
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_argocd_install_if_baseline_missing() {
  local missing=0

  for obj in \
    "configmap/argocd-cm" \
    "configmap/argocd-rbac-cm" \
    "configmap/argocd-cmd-params-cm" \
    "secret/argocd-secret" \
    "deployment/argocd-server"; do
    if ! kubectl -n "${ARGOCD_NAMESPACE}" get "${obj}" >/dev/null 2>&1; then
      log "Missing ${ARGOCD_NAMESPACE}/${obj}; Argo CD install baseline will be re-applied"
      missing=1
    fi
  done

  if [[ "${missing}" == "1" ]]; then
    log "Re-applying Argo CD ${ARGO_VERSION} install manifest to restore missing core objects"
    kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${ARGO_INSTALL_URL}" >/dev/null
  fi
}

ensure_core_configmaps_exist() {
  log "Ensuring Argo CD core ConfigMaps exist"

  kubectl -n "${ARGOCD_NAMESPACE}" create configmap argocd-cm \
    --from-literal=url="${ARGOCD_URL}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${ARGOCD_NAMESPACE}" create configmap argocd-rbac-cm \
    --from-literal=policy.default="role:readonly" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${ARGOCD_NAMESPACE}" create configmap argocd-cmd-params-cm \
    --from-literal=server.insecure="true" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

patch_argocd_baseline_fields() {
  log "Applying safe Argo CD baseline fields"

  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=merge \
    -p "{\"data\":{\"url\":\"${ARGOCD_URL}\"}}" >/dev/null

  # CH06.2 owns SSO. CH04 must guarantee that the baseline UI/login can recover
  # even after a failed SSO attempt, therefore stale OIDC config is removed here.
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true

  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm --type=merge \
    -p '{"data":{"server.insecure":"true"}}' >/dev/null
}

cleanup_unhealthy_argocd_server_state() {
  local bad_pods=""
  local bad_rs=""

  log "Cleaning unhealthy argocd-server pods and active unready ReplicaSets"

  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $4 == "CrashLoopBackOff" {print $1}' || true)"

  if [[ -n "${bad_pods}" ]]; then
    while read -r pod; do
      [[ -n "${pod}" ]] || continue
      log "Deleting unhealthy argocd-server pod: ${pod}"
      kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done <<<"${bad_pods}"
  fi

  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  if [[ -n "${bad_rs}" ]]; then
    while read -r rs; do
      [[ -n "${rs}" ]] || continue
      log "Scaling down unhealthy argocd-server ReplicaSet: ${rs}"
      kubectl -n "${ARGOCD_NAMESPACE}" scale rs "${rs}" --replicas=0 >/dev/null 2>&1 || true
    done <<<"${bad_rs}"
  fi
}

ready_argocd_server_pods() {
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null     | awk '$2 == "true" && $3 == "Running" {print $1}' || true
}

validate_or_recover_argocd_server() {
  local ready_pods=""

  ready_pods="$(ready_argocd_server_pods)"

  if [[ -n "${ready_pods}" ]]; then
    log "Existing ready argocd-server pod detected; preserving control-plane availability"
    log "Skipping rollout restart during CH04 baseline repair to avoid creating another CrashLoopBackOff ReplicaSet"
    cleanup_unhealthy_argocd_server_state
    return 0
  fi

  log "No ready argocd-server pod detected; attempting controlled rollout recovery"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment/argocd-server >/dev/null

  if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=180s; then
    log "Argo CD server rollout failed after baseline repair"
    kubectl -n "${ARGOCD_NAMESPACE}" get deploy,rs,pods -l app.kubernetes.io/name=argocd-server -o wide || true
    kubectl -n "${ARGOCD_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 80 || true
    die "Argo CD baseline repair did not converge and no ready argocd-server pod is available"
  fi
}

validate_baseline_objects() {
  log "Validating Argo CD baseline objects"
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cmd-params-cm >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server >/dev/null

  if kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null | grep -q .; then
    die "argocd-cm still contains oidc.config after CH04 baseline repair"
  fi

  log "Argo CD baseline objects are present and SSO config is cleared"
}

ensure_argocd_namespace
apply_argocd_install_if_baseline_missing
ensure_core_configmaps_exist
patch_argocd_baseline_fields
cleanup_unhealthy_argocd_server_state
validate_or_recover_argocd_server
validate_baseline_objects
