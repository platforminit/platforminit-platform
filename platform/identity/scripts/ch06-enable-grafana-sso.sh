#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH06.1][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
GRAFANA_RELEASE_NAME="${GRAFANA_RELEASE_NAME:-observability-vmstack}"
VM_STACK_CHART_VERSION="${VM_STACK_CHART_VERSION:-0.72.5}"
GRAFANA_OIDC_PROVIDER_SLUG="${GRAFANA_OIDC_PROVIDER_SLUG:-grafana}"
GRAFANA_OIDC_CLIENT_ID="${GRAFANA_OIDC_CLIENT_ID:-}"
GRAFANA_OIDC_CLIENT_SECRET="${GRAFANA_OIDC_CLIENT_SECRET:-}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.${BASE_DOMAIN}}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates gnupg rsync openssl python3 >/dev/null
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

read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

validate_prerequisites() {
  kubectl get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${IDENTITY_NAMESPACE}; deploy CH06 first"
  kubectl get ns "${OBS_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${OBS_NAMESPACE}; deploy CH05 first"
  kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=30s >/dev/null || die "Authentik server is not healthy"
  kubectl -n "${OBS_NAMESPACE}" rollout status deploy/observability-vmstack-grafana --timeout=30s >/dev/null || die "Grafana is not healthy"
}

resolve_or_create_grafana_oidc_secret() {
  local existing_id=""
  local existing_secret=""

  existing_id="$(read_secret_key "${OBS_NAMESPACE}" grafana-authentik-oauth GRAFANA_OIDC_CLIENT_ID)"
  existing_secret="$(read_secret_key "${OBS_NAMESPACE}" grafana-authentik-oauth GRAFANA_OIDC_CLIENT_SECRET)"

  if [[ -n "${GRAFANA_OIDC_CLIENT_ID}" && -n "${GRAFANA_OIDC_CLIENT_SECRET}" ]]; then
    log "Using provided Grafana OIDC client credentials from environment"
  elif [[ -n "${existing_id}" && -n "${existing_secret}" ]]; then
    log "Reusing existing Grafana OIDC client credentials from Kubernetes secret"
    GRAFANA_OIDC_CLIENT_ID="${existing_id}"
    GRAFANA_OIDC_CLIENT_SECRET="${existing_secret}"
  else
    log "Generating Grafana OIDC client credentials inside the cluster automation"
    GRAFANA_OIDC_CLIENT_ID="platforminit-grafana"
    GRAFANA_OIDC_CLIENT_SECRET="$(openssl rand -hex 48)"
  fi

  kubectl -n "${OBS_NAMESPACE}" create secret generic grafana-authentik-oauth \
    --from-literal=GRAFANA_OIDC_CLIENT_ID="${GRAFANA_OIDC_CLIENT_ID}" \
    --from-literal=GRAFANA_OIDC_CLIENT_SECRET="${GRAFANA_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

resolve_authentik_api_token() {
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
  fi
  [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run CH06 to create/preserve authentik-bootstrap secret"
  export AUTHENTIK_BOOTSTRAP_TOKEN
}

configure_authentik_grafana_provider() {
  log "Reconciling Authentik Grafana provider/application via Authentik API"
  export BASE_DOMAIN AUTHENTIK_BASE_URL GRAFANA_OIDC_PROVIDER_SLUG GRAFANA_OIDC_CLIENT_ID GRAFANA_OIDC_CLIENT_SECRET

  python3 - <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

base_domain = os.environ["BASE_DOMAIN"]
base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
provider_slug = os.environ.get("GRAFANA_OIDC_PROVIDER_SLUG", "grafana")
client_id = os.environ["GRAFANA_OIDC_CLIENT_ID"]
client_secret = os.environ["GRAFANA_OIDC_CLIENT_SECRET"]

grafana_url = f"https://grafana.{base_domain}"
redirect_uri = f"{grafana_url}/login/generic_oauth"
logout_uri = f"{grafana_url}/logout"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def request(method, path, payload=None, allow_404=False):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        if allow_404 and exc.code == 404:
            return None
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
    candidates = paginated_results(f"{path}{sep}search={encoded}")
    for item in candidates:
        if item.get(field) == value:
            return item
    candidates = paginated_results(f"{path}{sep}{field}={encoded}")
    for item in candidates:
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

# Validate token/API reachability early.
request("GET", "/api/v3/core/users/me/")

authorization_flow = flow_pk("default-provider-authorization-implicit-consent")
invalidation_flow = flow_pk("default-provider-invalidation-flow")
property_mappings = default_scope_pks()

provider_payload = {
    "name": "Grafana",
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

provider = first_by_field("/api/v3/providers/oauth2/", "name", "Grafana")
if provider:
    provider_pk = provider["pk"]
    request("PATCH", f"/api/v3/providers/oauth2/{provider_pk}/", provider_payload)
    print(f"Updated Authentik OAuth provider Grafana pk={provider_pk}")
else:
    provider = request("POST", "/api/v3/providers/oauth2/", provider_payload)
    provider_pk = provider["pk"]
    print(f"Created Authentik OAuth provider Grafana pk={provider_pk}")

app_payload = {
    "name": "Grafana",
    "slug": provider_slug,
    "provider": provider_pk,
    "open_in_new_tab": True,
    "meta_launch_url": grafana_url,
    "meta_description": "PlatformInit observability dashboard",
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

render_values_overlay() {
  local tmp_values="/tmp/ch06-grafana-sso-values.yaml"
  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__GRAFANA_PROVIDER_SLUG__|${GRAFANA_OIDC_PROVIDER_SLUG}|g" \
    "${REPO_ROOT}/integrations/grafana/grafana-authentik-oauth-values.yaml.tpl" > "${tmp_values}"
  echo "${tmp_values}"
}

install_repos() {
  helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null
  helm repo update >/dev/null
}

apply_grafana_values() {
  local values_file="$1"
  log "Enabling Grafana Generic OAuth via Helm values overlay"
  helm upgrade "${GRAFANA_RELEASE_NAME}" vm/victoria-metrics-k8s-stack \
    --namespace "${OBS_NAMESPACE}" \
    --version "${VM_STACK_CHART_VERSION}" \
    --reuse-values \
    -f "${values_file}" \
    --wait --timeout 10m
}

wait_for_grafana() {
  log "Waiting for Grafana rollout"
  kubectl -n "${OBS_NAMESPACE}" rollout restart deploy/observability-vmstack-grafana >/dev/null
  kubectl -n "${OBS_NAMESPACE}" rollout status deploy/observability-vmstack-grafana --timeout=300s
}

main() {
  ensure_runtime_deps
  ensure_helm
  ensure_cluster_ready
  validate_prerequisites
  resolve_or_create_grafana_oidc_secret
  resolve_authentik_api_token
  configure_authentik_grafana_provider
  values_file="$(render_values_overlay)"
  install_repos
  apply_grafana_values "${values_file}"
  wait_for_grafana
  log "Grafana SSO enabled via Authentik provider slug=${GRAFANA_OIDC_PROVIDER_SLUG} url=https://grafana.${BASE_DOMAIN}/login"
}

main "$@"
