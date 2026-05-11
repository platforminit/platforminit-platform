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
ARGOCD_BASELINE_RESTART_REQUIRED=0

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
need kubectl
need curl

ensure_argocd_namespace() {
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

mark_restart_required() {
  local reason="$1"
  ARGOCD_BASELINE_RESTART_REQUIRED=1
  log "Argo CD server restart required: ${reason}"
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
    mark_restart_required "one or more Argo CD core objects were missing"
  fi
}

ensure_core_configmaps_exist() {
  log "Ensuring Argo CD core ConfigMaps exist"

  if ! kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm >/dev/null 2>&1; then
    mark_restart_required "argocd-cm was missing and had to be recreated"
  fi
  kubectl -n "${ARGOCD_NAMESPACE}" create configmap argocd-cm \
    --from-literal=url="${ARGOCD_URL}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if ! kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm >/dev/null 2>&1; then
    mark_restart_required "argocd-rbac-cm was missing and had to be recreated"
  fi
  kubectl -n "${ARGOCD_NAMESPACE}" create configmap argocd-rbac-cm \
    --from-literal=policy.default="role:readonly" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if ! kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cmd-params-cm >/dev/null 2>&1; then
    mark_restart_required "argocd-cmd-params-cm was missing and had to be recreated"
  fi
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
  if kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null | grep -q .; then
    mark_restart_required "stale CH06.2 oidc.config was removed from argocd-cm"
  fi
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true

  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm --type=merge \
    -p '{"data":{"server.insecure":"true"}}' >/dev/null
}

ready_argocd_server_pods() {
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk '$2 == "true" && $3 == "Running" {print $1}' || true
}

ready_argocd_server_hash() {
  local pod="$1"
  kubectl -n "${ARGOCD_NAMESPACE}" get pod "${pod}" -o jsonpath='{.metadata.labels.pod-template-hash}' 2>/dev/null || true
}

ready_argocd_server_revision() {
  local hash="$1"
  local rs="argocd-server-${hash}"
  kubectl -n "${ARGOCD_NAMESPACE}" get rs "${rs}" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true
}

current_argocd_server_hash() {
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' >/dev/null 2>&1 || return 0
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | sort -k2,2n | tail -n 1 | awk '{sub(/^argocd-server-/, "", $1); print $1}' || true
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

align_deployment_to_ready_revision() {
  local ready_pod="$1"
  local ready_hash=""
  local ready_revision=""
  local current_hash=""

  ready_hash="$(ready_argocd_server_hash "${ready_pod}")"
  [[ -n "${ready_hash}" ]] || return 0
  ready_revision="$(ready_argocd_server_revision "${ready_hash}")"
  [[ -n "${ready_revision}" ]] || return 0
  current_hash="$(current_argocd_server_hash)"

  if [[ "${current_hash}" != "${ready_hash}" ]]; then
    log "Current argocd-server deployment template is not the ready ReplicaSet (${current_hash:-unknown} != ${ready_hash}); rolling back to revision ${ready_revision}"
    kubectl -n "${ARGOCD_NAMESPACE}" rollout undo deployment/argocd-server --to-revision="${ready_revision}" >/dev/null || true
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=90s >/dev/null || true
  else
    log "argocd-server deployment template already matches the ready ReplicaSet (${ready_hash})"
  fi

  # Avoid restart-loop revisions created by failed SSO/config recovery attempts.
  kubectl -n "${ARGOCD_NAMESPACE}" patch deployment argocd-server --type=json \
    -p='[{"op":"remove","path":"/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"}]' >/dev/null 2>&1 || true
}

argocd_settings_reports_missing_configmap() {
  local body=""
  local pf_pid=""
  local pf_log="/tmp/platforminit-argocd-port-forward.log"

  rm -f "${pf_log}"
  kubectl -n "${ARGOCD_NAMESPACE}" port-forward svc/argocd-server 18080:80 >"${pf_log}" 2>&1 &
  pf_pid="$!"
  sleep 3
  body="$(curl -fsS --max-time 10 http://127.0.0.1:18080/api/v1/settings 2>/dev/null || true)"
  kill "${pf_pid}" >/dev/null 2>&1 || true
  wait "${pf_pid}" >/dev/null 2>&1 || true

  if echo "${body}" | grep -qi 'argocd-cm.*not found\|configmap.*not found'; then
    log "Argo CD settings API reports missing ConfigMap: ${body}"
    return 0
  fi
  return 1
}

collect_argocd_server_diagnostics() {
  log "Collecting argocd-server diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy,rs,pods -l app.kubernetes.io/name=argocd-server -o wide || true
  local bad_pods=""
  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $3 == "CrashLoopBackOff" {print $1}' || true)"
  if [[ -n "${bad_pods}" ]]; then
    while read -r pod; do
      [[ -n "${pod}" ]] || continue
      log "Previous logs for unhealthy pod ${pod}"
      kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod}" -c argocd-server --previous --tail=120 || true
      log "Current logs for unhealthy pod ${pod}"
      kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod}" -c argocd-server --tail=120 || true
    done <<<"${bad_pods}"
  fi
  kubectl -n "${ARGOCD_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 80 || true
}

safe_restart_argocd_server() {
  local ready_before=""

  ready_before="$(ready_argocd_server_pods | head -n 1 || true)"
  if [[ -n "${ready_before}" ]]; then
    align_deployment_to_ready_revision "${ready_before}"
  fi

  log "Restarting argocd-server after baseline ConfigMap repair using stable deployment template"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment/argocd-server >/dev/null

  if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=180s; then
    log "argocd-server restart failed after baseline repair; attempting rollback to previously ready revision"
    if [[ -n "${ready_before}" ]]; then
      align_deployment_to_ready_revision "${ready_before}"
      cleanup_unhealthy_argocd_server_state
    fi
    collect_argocd_server_diagnostics
    die "Argo CD baseline repair restart did not converge"
  fi
}

validate_or_recover_argocd_server() {
  local ready_pods=""
  local ready_pod=""

  ready_pods="$(ready_argocd_server_pods)"

  if [[ -n "${ready_pods}" ]]; then
    ready_pod="$(echo "${ready_pods}" | head -n 1)"
    log "Existing ready argocd-server pod detected: ${ready_pod}"
    align_deployment_to_ready_revision "${ready_pod}"
    cleanup_unhealthy_argocd_server_state

    if argocd_settings_reports_missing_configmap; then
      mark_restart_required "Argo CD settings API still reports missing argocd-cm after baseline object repair"
    fi

    if [[ "${ARGOCD_BASELINE_RESTART_REQUIRED}" == "1" ]]; then
      safe_restart_argocd_server
    else
      log "Skipping argocd-server restart; baseline ConfigMaps are present and settings API does not report missing argocd-cm"
    fi
    return 0
  fi

  log "No ready argocd-server pod detected; attempting controlled rollout recovery"
  safe_restart_argocd_server
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

  if argocd_settings_reports_missing_configmap; then
    die "Argo CD settings API still reports argocd-cm missing after CH04 baseline repair"
  fi

  log "Argo CD baseline objects are present, SSO config is cleared and settings API is healthy"
}

ensure_argocd_namespace
apply_argocd_install_if_baseline_missing
ensure_core_configmaps_exist
patch_argocd_baseline_fields
validate_or_recover_argocd_server
validate_baseline_objects
