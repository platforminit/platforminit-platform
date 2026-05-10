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
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null || die "Argo CD server is not healthy"
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

  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__ARGOCD_PROVIDER_SLUG__|${ARGOCD_OIDC_PROVIDER_SLUG}|g" \
    -e "s|__ARGOCD_OIDC_CLIENT_ID__|${ARGOCD_OIDC_CLIENT_ID}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-oidc-cm.yaml"

  sed \
    -e "s|__ARGOCD_ADMIN_GROUP__|${ARGOCD_ADMIN_GROUP}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-rbac-cm.yaml"

  kubectl apply -f "${tmp_dir}/argocd-authentik-oidc-cm.yaml"
  kubectl apply -f "${tmp_dir}/argocd-authentik-rbac-cm.yaml"
  rm -rf "${tmp_dir}"
}

diagnose_argocd_server_rollout() {
  log "Collecting Argo CD server rollout diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
}

force_delete_terminating_argocd_server_pods() {
  local terminating_pods=""
  terminating_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o json | python3 -c 'import json, sys; data=json.load(sys.stdin); [print(item["metadata"]["name"]) for item in data.get("items", []) if item.get("metadata", {}).get("deletionTimestamp")]')"

  if [[ -z "${terminating_pods}" ]]; then
    log "No terminating Argo CD server pods found after rollout timeout"
    return 1
  fi

  log "Force deleting terminating Argo CD server pods to unblock rollout: ${terminating_pods}"
  while IFS= read -r pod_name; do
    [[ -n "${pod_name}" ]] || continue
    kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod_name}" --grace-period=0 --force --wait=false || true
  done <<< "${terminating_pods}"
}

restart_argocd_server() {
  log "Restarting Argo CD server to load OIDC config"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-server >/dev/null

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=300s; then
    return 0
  fi

  log "Argo CD server rollout did not complete within primary timeout; attempting terminating-pod cleanup"
  diagnose_argocd_server_rollout

  if force_delete_terminating_argocd_server_pods; then
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s
    return 0
  fi

  die "Argo CD server rollout failed and no safe terminating-pod cleanup was possible"
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
