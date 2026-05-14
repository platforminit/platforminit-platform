#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
warn(){ echo "WARN: $*" >&2; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
VALIDATION_MODE="${VALIDATION_MODE:-runtime}"
export KUBECONFIG

[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
case "$VALIDATION_MODE" in
  runtime|runtime_with_sso) ;;
  *) die "Invalid VALIDATION_MODE=${VALIDATION_MODE}. Use runtime or runtime_with_sso." ;;
esac

need kubectl
need curl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

secret_value(){
  local secret="$1" key="$2"
  kubectl -n "$NAMESPACE" get secret "$secret" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}
validate_openobserve_oidc_secret(){
  local expected_base="https://auth.${BASE_DOMAIN}/application/o/platforminit-openobserve/"
  local base auth_suffix token_suffix keys_suffix
  base="$(secret_value openobserve-sso O2_DEX_BASE_URL)"
  auth_suffix="$(secret_value openobserve-sso O2_DEX_AUTH_EP_SUFFIX)"
  token_suffix="$(secret_value openobserve-sso O2_DEX_TOKEN_EP_SUFFIX)"
  keys_suffix="$(secret_value openobserve-sso O2_DEX_KEYS_EP_SUFFIX)"
  [[ "$base" == "$expected_base" ]] || die "OpenObserve O2_DEX_BASE_URL is invalid: '${base:-missing}'. Expected '${expected_base}'. Authentik returns the application issuer with a trailing slash, and OpenObserve validates it strictly. The parent /application/o path still breaks OIDC discovery."
  [[ "$auth_suffix" == "/../authorize/" ]] || die "OpenObserve O2_DEX_AUTH_EP_SUFFIX is invalid: '${auth_suffix:-missing}'"
  [[ "$token_suffix" == "/../token/" ]] || die "OpenObserve O2_DEX_TOKEN_EP_SUFFIX is invalid: '${token_suffix:-missing}'"
  [[ "$keys_suffix" == "/jwks/" ]] || die "OpenObserve O2_DEX_KEYS_EP_SUFFIX is invalid: '${keys_suffix:-missing}'"
  log "PASS: OpenObserve OIDC discovery base is application-scoped: ${base}"
}

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

start_port_forward(){
  local svc="$1"
  local local_port="$2"
  local remote_port="$3"
  local pid_var="$4"
  local log_file="/tmp/ch05-validate-${svc}.portforward.log"
  kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "svc/${svc}" "${local_port}:${remote_port}" >"$log_file" 2>&1 &
  local pid="$!"
  printf -v "$pid_var" '%s' "$pid"
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 4 "http://127.0.0.1:${local_port}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  cat "$log_file" >&2 || true
  return 1
}

validate_local_break_glass_web(){
  log "Validating local break-glass WebUI reachability through internal services"
  local zabbix_pf_pid="" openobserve_pf_pid=""
  start_port_forward zabbix-web 18084 8080 zabbix_pf_pid || die "Zabbix local WebUI is not reachable through service/zabbix-web"
  start_port_forward openobserve 15084 5080 openobserve_pf_pid || die "OpenObserve local WebUI is not reachable through service/openobserve"
  curl -fsS --max-time 5 "http://127.0.0.1:18084/index.php" >/dev/null || die "Zabbix login page is not reachable through local service port-forward"
  curl -fsS --max-time 5 "http://127.0.0.1:15084/" >/dev/null || die "OpenObserve login page is not reachable through local service port-forward"
  kill "$zabbix_pf_pid" "$openobserve_pf_pid" >/dev/null 2>&1 || true
  log "PASS: local break-glass WebUIs are reachable. Manual local credentials remain the runtime fallback."
}

validate_storage_contract(){
  log "Validating CH05 observability storage contract"
  for pv in platforminit-zabbix-postgres-data platforminit-openobserve-data; do
    kubectl get pv "$pv" >/dev/null || die "Missing static observability PV: $pv"
  done
  for pvc in zabbix-postgres-data openobserve-data; do
    local phase
    phase="$(kubectl -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Bound" ]] || die "PVC $pvc is not Bound: ${phase:-missing}"
  done
  for path in /srv/observability/data /srv/observability/data/zabbix-postgres /srv/observability/data/openobserve /srv/observability/data/vector; do
    [[ -d "$path" ]] || die "Missing observability storage directory: $path"
  done
  if ! findmnt -T /srv/observability >/dev/null 2>&1; then
    warn "/srv/observability is not a dedicated mountpoint; storage contract path exists, but it may be on the root filesystem."
  fi
  log "PASS: CH05 observability storage contract is present."
}

validate_runtime(){
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
  kubectl -n "$NAMESPACE" get secret zabbix-postgres openobserve-root >/dev/null
  validate_storage_contract
  validate_local_break_glass_web
  sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [[ "$sync_status" == "Synced" ]] || die "Argo CD app is not Synced: ${sync_status:-unknown}"
  [[ "$health_status" == "Healthy" ]] || die "Argo CD app is not Healthy: ${health_status:-unknown}"
}

validate_sso_prerequisites(){
  log "Validating optional native SSO prerequisites"
  kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null
  kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q 'openobserve-enterprise' || die "OpenObserve is not using the Enterprise image"
  kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}' | grep -q 'openobserve-sso' || die "OpenObserve SSO secret is not mounted"
  validate_openobserve_oidc_secret
  kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q 'ZBX_SSO_SETTINGS' || die "Zabbix SAML runtime env is missing"
  kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' | grep -q 'zabbix-saml-certs' || die "Zabbix SAML certificate volume is not mounted"
  if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
    die "Stale forward-auth middleware exists; Operations WebUIs must use native app SSO when SSO validation is required"
  fi
  log "PASS: optional native SSO prerequisites are configured. This does not prove browser login mapping."
}

validate_runtime
if [[ "$VALIDATION_MODE" == "runtime_with_sso" ]]; then
  validate_sso_prerequisites
else
  if ! kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null 2>&1; then
    warn "Native SSO secrets are missing or incomplete; base runtime remains valid because VALIDATION_MODE=runtime."
  fi
  if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
    warn "Stale forward-auth middleware exists; ignored for runtime validation, but must be removed before requiring SSO."
  fi
  log "SSO browser login is intentionally not part of base runtime validation. Use VALIDATION_MODE=runtime_with_sso to require SSO prerequisites."
fi
log "PASS: CH05 operations stack runtime is healthy with observability storage, local break-glass WebUI access, and validation_mode=${VALIDATION_MODE}"
