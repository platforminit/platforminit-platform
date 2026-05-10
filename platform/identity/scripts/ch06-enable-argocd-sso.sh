#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH06.2][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_OIDC_PROVIDER_SLUG="${ARGOCD_OIDC_PROVIDER_SLUG:-argocd}"
ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID:-}"
ARGOCD_OIDC_CLIENT_SECRET="${ARGOCD_OIDC_CLIENT_SECRET:-}"
ARGOCD_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.${BASE_DOMAIN}}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ARGOCD_CONFIG_CHANGED=0
ARGOCD_PREVIOUS_CM_FILE=""
ARGOCD_PREVIOUS_RBAC_FILE=""

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates python3 openssl >/dev/null
}

ensure_cluster_ready() {
  need kubectl
  [ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster via ${KUBECONFIG}"
}

read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

validate_prerequisites() {
  kubectl get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${IDENTITY_NAMESPACE}; deploy CH06 first"
  kubectl get ns "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${ARGOCD_NAMESPACE}; deploy CH04 first"
  kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=30s >/dev/null || die "Authentik server is not healthy"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy/argocd-server >/dev/null 2>&1 || die "Missing deployment: ${ARGOCD_NAMESPACE}/argocd-server"

  # Do not fail the whole SSO reconciliation if Argo CD is already in a
  # ProgressDeadlineExceeded state from a previous restart. CH06.2 is allowed
  # to repair/restart argocd-server after reconciling the OIDC config.
  if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null 2>&1; then
    log "WARN: Argo CD server is not currently healthy; continuing so the SSO repair/restart path can run"
    diagnose_argocd_server_rollout || true
  fi
}

resolve_or_create_argocd_oidc_secret() {
  local existing_id=""
  local existing_secret=""

  existing_id="$(read_secret_key "${ARGOCD_NAMESPACE}" argocd-authentik-oidc ARGOCD_OIDC_CLIENT_ID)"
  existing_secret="$(read_secret_key "${ARGOCD_NAMESPACE}" argocd-authentik-oidc ARGOCD_OIDC_CLIENT_SECRET)"

  if [[ -n "${ARGOCD_OIDC_CLIENT_ID}" && -n "${ARGOCD_OIDC_CLIENT_SECRET}" ]]; then
    log "Using provided Argo CD OIDC client credentials from environment"
  elif [[ -n "${existing_id}" && -n "${existing_secret}" ]]; then
    log "Reusing existing Argo CD OIDC client credentials from Kubernetes secret"
    ARGOCD_OIDC_CLIENT_ID="${existing_id}"
    ARGOCD_OIDC_CLIENT_SECRET="${existing_secret}"
  else
    log "Generating Argo CD OIDC client credentials inside the cluster automation"
    ARGOCD_OIDC_CLIENT_ID="platforminit-argocd"
    ARGOCD_OIDC_CLIENT_SECRET="$(openssl rand -hex 48)"
  fi

  [[ -n "${ARGOCD_OIDC_CLIENT_ID}" ]] || die "Failed to resolve Argo CD OIDC client id"
  [[ -n "${ARGOCD_OIDC_CLIENT_SECRET}" ]] || die "Failed to resolve Argo CD OIDC client secret"
  export ARGOCD_OIDC_CLIENT_ID ARGOCD_OIDC_CLIENT_SECRET

  kubectl -n "${ARGOCD_NAMESPACE}" create secret generic argocd-authentik-oidc \
    --from-literal=ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID}" \
    --from-literal=ARGOCD_OIDC_CLIENT_SECRET="${ARGOCD_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local patch_payload=""
  patch_payload="$(python3 - <<'PY'
import base64
import json
import os
import sys

secret = os.environ.get("ARGOCD_OIDC_CLIENT_SECRET", "")
if not secret:
    print("ARGOCD_OIDC_CLIENT_SECRET is empty; refusing to render argocd-secret patch", file=sys.stderr)
    sys.exit(1)

print(json.dumps({"data": {"oidc.authentik.clientSecret": base64.b64encode(secret.encode()).decode()}}))
PY
)"

  kubectl -n "${ARGOCD_NAMESPACE}" patch secret argocd-secret --type='merge' -p "${patch_payload}" >/dev/null
}

resolve_authentik_api_token() {
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
  fi
  [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run CH06 to create/preserve authentik-bootstrap secret"
  export AUTHENTIK_BOOTSTRAP_TOKEN
}

configure_authentik_argocd_provider() {
  log "Reconciling Authentik Argo CD provider/application via Authentik API"
  export BASE_DOMAIN AUTHENTIK_BASE_URL ARGOCD_OIDC_PROVIDER_SLUG ARGOCD_OIDC_CLIENT_ID ARGOCD_OIDC_CLIENT_SECRET

  python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

base_domain = os.environ["BASE_DOMAIN"]
base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
provider_slug = os.environ.get("ARGOCD_OIDC_PROVIDER_SLUG", "argocd")
client_id = os.environ["ARGOCD_OIDC_CLIENT_ID"]
client_secret = os.environ["ARGOCD_OIDC_CLIENT_SECRET"]

argocd_url = f"https://argocd.{base_domain}"
redirect_uri = f"{argocd_url}/auth/callback"
logout_uri = f"{argocd_url}/logout"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def request(method, path, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {body}") from exc


def paginated_results(path):
    obj = request("GET", path)
    if isinstance(obj, dict) and "results" in obj:
        return obj["results"]
    if isinstance(obj, list):
        return obj
    return []


def first_by_field(path, field, value):
    sep = "&" if "?" in path else "?"
    encoded = urllib.parse.quote(value)
    for query in (f"search={encoded}", f"{field}={encoded}"):
        for item in paginated_results(f"{path}{sep}{query}"):
            if item.get(field) == value:
                return item
    return None


def flow_pk(slug):
    flow = first_by_field("/api/v3/flows/instances/", "slug", slug)
    if not flow:
        raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return flow["pk"]


def default_scope_pks():
    wanted = {
        "authentik default OAuth Mapping: OpenID 'openid'",
        "authentik default OAuth Mapping: OpenID 'email'",
        "authentik default OAuth Mapping: OpenID 'profile'",
        "authentik default OAuth Mapping: OpenID 'entitlements'",
    }
    results = paginated_results("/api/v3/propertymappings/provider/scope/?page_size=200")
    found = [item["pk"] for item in results if item.get("name") in wanted]
    if len(found) < 3:
        print("WARN: fewer default scope mappings found than expected; continuing with available mappings", file=sys.stderr)
    return found

request("GET", "/api/v3/core/users/me/")
authorization_flow = flow_pk("default-provider-authorization-implicit-consent")
invalidation_flow = flow_pk("default-provider-invalidation-flow")
property_mappings = default_scope_pks()

provider_payload = {
    "name": "Argo CD",
    "authorization_flow": authorization_flow,
    "invalidation_flow": invalidation_flow,
    "client_type": "confidential",
    "grant_types": ["authorization_code", "refresh_token"],
    "client_id": client_id,
    "client_secret": client_secret,
    "redirect_uris": [
        {"matching_mode": "strict", "url": redirect_uri, "redirect_uri_type": "authorization"},
        {"matching_mode": "strict", "url": logout_uri, "redirect_uri_type": "logout"},
    ],
    "logout_uri": logout_uri,
    "logout_method": "frontchannel",
    "sub_mode": "hashed_user_id",
    "issuer_mode": "per_provider",
    "include_claims_in_id_token": True,
}
if property_mappings:
    provider_payload["property_mappings"] = property_mappings

provider = first_by_field("/api/v3/providers/oauth2/", "name", "Argo CD")
if provider:
    provider_pk = provider["pk"]
    request("PATCH", f"/api/v3/providers/oauth2/{provider_pk}/", provider_payload)
    print(f"Updated Authentik OAuth provider Argo CD pk={provider_pk}")
else:
    provider = request("POST", "/api/v3/providers/oauth2/", provider_payload)
    provider_pk = provider["pk"]
    print(f"Created Authentik OAuth provider Argo CD pk={provider_pk}")

app_payload = {
    "name": "Argo CD",
    "slug": provider_slug,
    "provider": provider_pk,
    "open_in_new_tab": True,
    "meta_launch_url": argocd_url,
    "meta_description": "PlatformInit GitOps control plane",
    "meta_publisher": "PlatformInit",
}
app = first_by_field("/api/v3/core/applications/", "slug", provider_slug)
if app:
    request("PATCH", f"/api/v3/core/applications/{provider_slug}/", app_payload)
    print(f"Updated Authentik application slug={provider_slug}")
else:
    request("POST", "/api/v3/core/applications/", app_payload)
    print(f"Created Authentik application slug={provider_slug}")
PY
}

render_and_apply_argocd_config() {
  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  ARGOCD_PREVIOUS_CM_FILE="${tmp_dir}/argocd-cm.previous.yaml"
  ARGOCD_PREVIOUS_RBAC_FILE="${tmp_dir}/argocd-rbac-cm.previous.yaml"
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o yaml > "${ARGOCD_PREVIOUS_CM_FILE}" 2>/dev/null || true
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o yaml > "${ARGOCD_PREVIOUS_RBAC_FILE}" 2>/dev/null || true

  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__ARGOCD_PROVIDER_SLUG__|${ARGOCD_OIDC_PROVIDER_SLUG}|g" \
    -e "s|__ARGOCD_OIDC_CLIENT_ID__|${ARGOCD_OIDC_CLIENT_ID}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-oidc-cm.yaml"

  sed \
    -e "s|__ARGOCD_ADMIN_GROUP__|${ARGOCD_ADMIN_GROUP}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-rbac-cm.yaml"

  local cm_apply_output=""
  local rbac_apply_output=""

  cm_apply_output="$(kubectl apply -f "${tmp_dir}/argocd-authentik-oidc-cm.yaml")"
  rbac_apply_output="$(kubectl apply -f "${tmp_dir}/argocd-authentik-rbac-cm.yaml")"
  echo "${cm_apply_output}"
  echo "${rbac_apply_output}"

  if echo "${cm_apply_output}
${rbac_apply_output}" | grep -Eq ' configured| created'; then
    ARGOCD_CONFIG_CHANGED=1
  else
    ARGOCD_CONFIG_CHANGED=0
  fi

  # Keep tmp_dir until the rollout path completes so rollback can restore the previous ConfigMaps.
}

restore_previous_argocd_config() {
  # Do not use `kubectl apply` with full live-object backups here. Those
  # backups contain resourceVersion/uid/last-applied metadata and can conflict
  # with a ConfigMap modified by a later reconciliation attempt. Recovery must
  # be conflict-free and field-scoped. The only argocd-cm field introduced by
  # CH06.2 that can crash argocd-server startup is oidc.config, so remove that
  # key explicitly instead of trying to replace the full ConfigMap object.
  log "Restoring Argo CD config with conflict-free field cleanup"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true

  # RBAC settings do not participate in argocd-server OIDC provider startup.
  # Keep them as-is during emergency recovery to avoid ConfigMap resourceVersion
  # conflicts and unnecessary pod-template churn.
}

remove_argocd_oidc_config_for_recovery() {
  log "Removing Argo CD OIDC config for emergency control-plane recovery"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true
}

delete_unhealthy_argocd_server_pods() {
  local bad_pods=""
  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | awk '$2 != "true" || $4 == "CrashLoopBackOff" {print $1}' || true)"

  if [[ -n "${bad_pods}" ]]; then
    log "Deleting unhealthy argocd-server pods only"
    while IFS= read -r pod_name; do
      [[ -n "${pod_name}" ]] || continue
      kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod_name}" --grace-period=0 --force >/dev/null 2>&1 || true
    done <<< "${bad_pods}"
  fi
}

clear_argocd_server_restart_annotation() {
  # Removing the restartedAt annotation mutates the pod template and can create
  # yet another ReplicaSet. Keep this helper only for cases where no stable
  # ReplicaSet revision can be identified. Prefer explicit rollback to the
  # revision that currently has a ready pod.
  log "Clearing argocd-server rollout restart annotation as fallback recovery"
  kubectl -n "${ARGOCD_NAMESPACE}" patch deployment argocd-server --type=json \
    -p='[{"op":"remove","path":"/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"}]' \
    >/dev/null 2>&1 || true
}

rollback_argocd_server_to_ready_revision() {
  local stable_revision=""

  stable_revision="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$3 > 0 && $4 == $3 {print $2}' \
    | sort -n \
    | head -1 || true)"

  if [[ -z "${stable_revision}" ]]; then
    log "No ready argocd-server ReplicaSet revision found for explicit rollback"
    return 1
  fi

  log "Rolling argocd-server back explicitly to ready ReplicaSet revision ${stable_revision}"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout undo deploy/argocd-server --to-revision="${stable_revision}" >/dev/null || return 1
  return 0
}

wait_for_existing_stable_argocd_server() {
  log "Checking whether an existing stable argocd-server pod is still serving the control plane"
  local ready_pods=""
  ready_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | awk '$2 == "true" {print $1}' || true)"

  if [[ -n "${ready_pods}" ]]; then
    log "Existing ready argocd-server pod detected; treating control-plane availability as preserved"
    return 0
  fi

  return 1
}

scale_down_unready_argocd_replicasets() {
  local bad_rs=""
  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  if [[ -n "${bad_rs}" ]]; then
    log "Scaling down unready argocd-server ReplicaSets"
    while IFS= read -r rs_name; do
      [[ -n "${rs_name}" ]] || continue
      kubectl -n "${ARGOCD_NAMESPACE}" scale rs "${rs_name}" --replicas=0 >/dev/null 2>&1 || true
    done <<< "${bad_rs}"
  fi
}

diagnose_argocd_server_rollout() {
  log "Collecting Argo CD server rollout diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
}

collect_argocd_server_crash_logs() {
  log "Collecting Argo CD server crash diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" describe deploy argocd-server || true
  kubectl -n "${ARGOCD_NAMESPACE}" get events --sort-by=.lastTimestamp | tail -80 || true

  local pods=""
  pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o jsonpath='{range .items[*]}{.metadata.name}{"
"}{end}' 2>/dev/null || true)"
  while IFS= read -r pod_name; do
    [[ -n "${pod_name}" ]] || continue
    log "Last logs for ${pod_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod_name}" --tail=120 || true
    log "Previous logs for ${pod_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod_name}" --previous --tail=120 || true
  done <<< "${pods}"
}

repair_argocd_server_rollout() {
  log "Attempting Argo CD server rollout repair"
  diagnose_argocd_server_rollout
  collect_argocd_server_crash_logs || true

  log "Repairing argocd-server by removing bad OIDC config and clearing degraded rollout state"
  restore_previous_argocd_config || true
  remove_argocd_oidc_config_for_recovery || true
  if ! rollback_argocd_server_to_ready_revision; then
    clear_argocd_server_restart_annotation || true
  fi
  scale_down_unready_argocd_replicasets || true
  delete_unhealthy_argocd_server_pods || true

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=90s; then
    log "Argo CD server repair completed"
    return 0
  fi

  if wait_for_existing_stable_argocd_server; then
    log "Argo CD deployment status is still degraded, but a stable server pod remains available after recovery cleanup"
    diagnose_argocd_server_rollout || true
    return 0
  fi

  diagnose_argocd_server_rollout || true
  return 1
}

restart_argocd_server() {
  if [[ "${ARGOCD_CONFIG_CHANGED}" != "1" ]]; then
    log "Argo CD OIDC/RBAC config unchanged; skipping unnecessary rollout restart"
    if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null 2>&1; then
      return 0
    fi

    log "Argo CD config is unchanged, but the existing rollout is degraded; running repair path"
    repair_argocd_server_rollout || die "Argo CD server rollout is degraded and repair failed"
    return 0
  fi

  log "Restarting Argo CD server to load changed OIDC config"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-server >/dev/null

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s; then
    return 0
  fi

  log "Argo CD server rollout failed after changed SSO config; restoring/removing SSO config to protect the control plane"
  collect_argocd_server_crash_logs || true
  restore_previous_argocd_config || true
  remove_argocd_oidc_config_for_recovery || true
  if ! rollback_argocd_server_to_ready_revision; then
    clear_argocd_server_restart_annotation || true
  fi
  scale_down_unready_argocd_replicasets || true
  delete_unhealthy_argocd_server_pods || true
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=90s || true
  wait_for_existing_stable_argocd_server || true
  die "Argo CD server failed to start with the reconciled SSO config; SSO config was removed/restored and restart annotation was cleared for recovery"
}

main() {
  ensure_runtime_deps
  ensure_cluster_ready
  validate_prerequisites
  resolve_or_create_argocd_oidc_secret
  resolve_authentik_api_token
  configure_authentik_argocd_provider
  render_and_apply_argocd_config
  restart_argocd_server
  log "Argo CD SSO enabled via Authentik provider slug=${ARGOCD_OIDC_PROVIDER_SLUG} url=https://argocd.${BASE_DOMAIN}"
}

main "$@"
