#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ISSUER_MODE="${ISSUER_MODE:-prod}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
AUTHENTIK_LOCAL_PORT="${AUTHENTIK_LOCAL_PORT:-19080}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-http://127.0.0.1:${AUTHENTIK_LOCAL_PORT}}"
AUTHENTIK_OPERATIONS_ADMIN_USERNAME="${AUTHENTIK_OPERATIONS_ADMIN_USERNAME:-akadmin}"
export KUBECONFIG

ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }
render_tpl(){ local src="$1" dst="$2"; sed -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" -e "s#__ISSUER_MODE__#${ISSUER_MODE}#g" "$src" > "$dst"; }
read_secret_key(){
  local namespace="$1" secret="$2" key="$3"
  kubectl -n "$namespace" get secret "$secret" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}
resolve_authentik_api_token(){
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
  fi
  [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run 04.5 - Deploy Identity Foundation"
  export AUTHENTIK_BOOTSTRAP_TOKEN
}
start_authentik_api_port_forward(){
  log "Starting temporary Authentik API port-forward on 127.0.0.1:${AUTHENTIK_LOCAL_PORT}"
  kubectl -n "${IDENTITY_NAMESPACE}" port-forward --address 127.0.0.1 svc/authentik-server "${AUTHENTIK_LOCAL_PORT}:80" \
    >/tmp/ch05-4-authentik-port-forward.log 2>&1 &
  AUTHENTIK_PORT_FORWARD_PID="$!"
  export AUTHENTIK_PORT_FORWARD_PID
  trap '[[ -n "${AUTHENTIK_PORT_FORWARD_PID:-}" ]] && kill "${AUTHENTIK_PORT_FORWARD_PID}" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    if curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null 2>&1; then
      log "Authentik API is reachable"
      return 0
    fi
    sleep 2
  done
  cat /tmp/ch05-4-authentik-port-forward.log >&2 || true
  die "Authentik API was not reachable through port-forward"
}

configure_authentik_operations_proxy(){
  log "Reconciling Authentik proxy providers/applications for Operations WebUIs"
  export BASE_DOMAIN AUTHENTIK_BASE_URL AUTHENTIK_BOOTSTRAP_TOKEN AUTHENTIK_OPERATIONS_ADMIN_USERNAME
  python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

base_domain = os.environ["BASE_DOMAIN"]
authentik_public_host = f"https://auth.{base_domain}"
base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
admin_username = os.environ.get("AUTHENTIK_OPERATIONS_ADMIN_USERNAME", "akadmin")
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}

apps = [
    {
        "name": "PlatformInit Zabbix",
        "slug": "platforminit-zabbix",
        "external_host": f"https://zabbix.{base_domain}",
        "description": "PlatformInit operations monitoring UI",
    },
    {
        "name": "PlatformInit OpenObserve",
        "slug": "platforminit-openobserve",
        "external_host": f"https://logs.{base_domain}",
        "description": "PlatformInit log search and RCA UI",
    },
]


def request(method, path, payload=None, tolerate_404=False):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        if tolerate_404 and exc.code == 404:
            return None
        raise RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {body}") from exc


def paginated_results(path):
    items = []
    next_path = path
    while next_path:
        obj = request("GET", next_path)
        if isinstance(obj, dict) and "results" in obj:
            items.extend(obj.get("results") or [])
            next_url = obj.get("pagination", {}).get("next") or obj.get("next")
            if not next_url:
                break
            if str(next_url).startswith(base_url):
                next_path = str(next_url)[len(base_url):]
            else:
                next_path = str(next_url)
        elif isinstance(obj, list):
            items.extend(obj)
            break
        else:
            break
    return items


def first_by_field(path, field, value):
    encoded = urllib.parse.quote(str(value))
    sep = "&" if "?" in path else "?"
    for query in (f"{field}={encoded}", f"search={encoded}"):
        for item in paginated_results(f"{path}{sep}{query}"):
            if str(item.get(field, "")) == str(value):
                return item
    return None


def flow_pk(slug):
    flow = first_by_field("/api/v3/flows/instances/", "slug", slug)
    if not flow:
        raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return flow["pk"]


def ensure_group(name):
    existing = first_by_field("/api/v3/core/groups/", "name", name)
    payload = {"name": name, "is_superuser": False, "parent": None, "attributes": {}}
    if existing:
        request("PATCH", f"/api/v3/core/groups/{existing['pk']}/", payload)
        return existing["pk"]
    created = request("POST", "/api/v3/core/groups/", payload)
    return created["pk"]


def group_pk_list(raw_groups):
    values = []
    for item in raw_groups or []:
        if isinstance(item, str):
            values.append(item)
        elif isinstance(item, dict):
            value = item.get("pk") or item.get("id") or item.get("uuid")
            if value:
                values.append(value)
    return values


def find_user_by_username(username):
    encoded = urllib.parse.quote(username)
    for path in (f"/api/v3/core/users/?username={encoded}", f"/api/v3/core/users/?search={encoded}"):
        for item in paginated_results(path):
            if item.get("username") == username:
                return item
    return None


def ensure_user_in_group(username, group_pk, group_name):
    user = find_user_by_username(username)
    if not user:
        print(f"WARN: Authentik user {username!r} not found; group {group_name!r} was created but not populated", file=sys.stderr)
        return
    editable = request("GET", f"/api/v3/core/users/{user['pk']}/")
    groups = group_pk_list(editable.get("groups", []))
    if group_pk not in groups:
        groups.append(group_pk)
        request("PATCH", f"/api/v3/core/users/{user['pk']}/", {"groups": groups})
        print(f"Added Authentik user {username} to {group_name}")


def make_proxy_payload(name, external_host, authorization_flow, invalidation_flow):
    # Keep this payload intentionally minimal. Authentik versions expose additional
    # proxy-provider knobs differently, but these fields are stable for a forward
    # auth single-application provider.
    return {
        "name": name,
        "authorization_flow": authorization_flow,
        "invalidation_flow": invalidation_flow,
        "mode": "forward_single",
        "external_host": external_host,
        "internal_host": "",
        "internal_host_ssl_validation": True,
        "basic_auth_enabled": False,
        "intercept_header_auth": False,
        "cookie_domain": base_domain,
    }


def ensure_proxy_provider(app, authorization_flow, invalidation_flow):
    payload = make_proxy_payload(app["name"], app["external_host"], authorization_flow, invalidation_flow)
    existing = first_by_field("/api/v3/providers/proxy/", "name", app["name"])
    if existing:
        provider_pk = existing["pk"]
        try:
            request("PATCH", f"/api/v3/providers/proxy/{provider_pk}/", payload)
        except RuntimeError as exc:
            if "cookie_domain" in str(exc):
                payload.pop("cookie_domain", None)
                request("PATCH", f"/api/v3/providers/proxy/{provider_pk}/", payload)
            else:
                raise
        print(f"Updated Authentik proxy provider {app['name']} pk={provider_pk}")
        return provider_pk
    try:
        created = request("POST", "/api/v3/providers/proxy/", payload)
    except RuntimeError as exc:
        if "cookie_domain" in str(exc):
            payload.pop("cookie_domain", None)
            created = request("POST", "/api/v3/providers/proxy/", payload)
        else:
            raise
    print(f"Created Authentik proxy provider {app['name']} pk={created['pk']}")
    return created["pk"]


def ensure_application(app, provider_pk):
    payload = {
        "name": app["name"],
        "slug": app["slug"],
        "provider": provider_pk,
        "open_in_new_tab": True,
        "meta_launch_url": app["external_host"],
        "meta_description": app["description"],
        "meta_publisher": "PlatformInit",
    }
    existing = first_by_field("/api/v3/core/applications/", "slug", app["slug"])
    if existing:
        request("PATCH", f"/api/v3/core/applications/{app['slug']}/", payload)
        print(f"Updated Authentik application {app['slug']}")
    else:
        request("POST", "/api/v3/core/applications/", payload)
        print(f"Created Authentik application {app['slug']}")


def normalize_provider_refs(raw):
    refs = []
    for item in raw or []:
        if isinstance(item, int):
            refs.append(item)
        elif isinstance(item, str):
            try:
                refs.append(int(item))
            except ValueError:
                refs.append(item)
        elif isinstance(item, dict):
            value = item.get("pk") or item.get("id")
            if value is not None:
                refs.append(value)
    return refs


def ensure_embedded_outpost_provider_assignment(provider_pks):
    outposts = paginated_results("/api/v3/outposts/instances/?page_size=200")
    candidates = []
    for outpost in outposts:
        name = str(outpost.get("name") or "")
        outpost_type = str(outpost.get("type") or "").lower()
        if "embedded" in name.lower() or ("proxy" in outpost_type and "embedded" in str(outpost).lower()):
            candidates.append(outpost)
    if not candidates:
        print("WARN: Authentik embedded outpost was not found through the API; proxy providers/applications were created but outpost assignment must be checked manually", file=sys.stderr)
        return

    outpost = candidates[0]
    outpost_pk = outpost.get("pk") or outpost.get("uuid")
    existing_refs = normalize_provider_refs(outpost.get("providers", []))
    desired_refs = list(existing_refs)
    for pk in provider_pks:
        if pk not in desired_refs:
            desired_refs.append(pk)

    existing_config = outpost.get("config") or {}
    desired_config = dict(existing_config)
    desired_config["authentik_host"] = authentik_public_host
    desired_config["authentik_host_browser"] = authentik_public_host

    patch = {}
    if desired_refs != existing_refs:
        patch["providers"] = desired_refs
    if desired_config != existing_config:
        patch["config"] = desired_config

    if not patch:
        print(f"Authentik embedded outpost already includes operations proxy providers and public host ({outpost.get('name')})")
        return

    request("PATCH", f"/api/v3/outposts/instances/{outpost_pk}/", patch)
    print(f"Updated Authentik embedded outpost provider assignment/public host ({outpost.get('name')})")


request("GET", "/api/v3/core/users/me/")
authorization_flow = flow_pk("default-provider-authorization-implicit-consent")
invalidation_flow = flow_pk("default-provider-invalidation-flow")
ops_group_pk = ensure_group("PlatformInit Operations")
ensure_user_in_group(admin_username, ops_group_pk, "PlatformInit Operations")
provider_pks = []
for app in apps:
    provider_pk = ensure_proxy_provider(app, authorization_flow, invalidation_flow)
    ensure_application(app, provider_pk)
    provider_pks.append(provider_pk)
ensure_embedded_outpost_provider_assignment(provider_pks)
PY
}

ensure_tls_issuer_state() {
  local desired="letsencrypt-${ISSUER_MODE}"
  for cert in zabbix-tls openobserve-tls; do
    local current=""
    current="$(kubectl -n "$NAMESPACE" get certificate "$cert" -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$desired" ]]; then
      log "Deleting stale TLS material for $cert: current issuer=$current desired issuer=$desired"
      kubectl -n "$NAMESPACE" delete certificate "$cert" --ignore-not-found=true >/dev/null 2>&1 || true
      kubectl -n "$NAMESPACE" delete secret "$cert" --ignore-not-found=true >/dev/null 2>&1 || true
    fi
  done
}

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
ensure_cluster
need curl
need python3
kubectl get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 || die "Missing identity namespace. Run 04.5 first."
kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=60s >/dev/null || die "Authentik server is not healthy"
kubectl -n "${IDENTITY_NAMESPACE}" get svc authentik-server >/dev/null 2>&1 || die "Missing Authentik server service. Run 04.5 first."
kubectl -n "$NAMESPACE" get svc zabbix-web >/dev/null 2>&1 || die "Missing Zabbix service. Run 05 first."
kubectl -n "$NAMESPACE" get svc openobserve >/dev/null 2>&1 || die "Missing OpenObserve service. Run 05.1 first."

resolve_authentik_api_token
start_authentik_api_port_forward
configure_authentik_operations_proxy
ensure_tls_issuer_state

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"; [[ -n "${AUTHENTIK_PORT_FORWARD_PID:-}" ]] && kill "${AUTHENTIK_PORT_FORWARD_PID}" >/dev/null 2>&1 || true' EXIT
render_tpl "$REPO_ROOT/manifests/sso/authentik-forward-auth.yaml.tpl" "$workdir/operations-sso.yaml"
log "Applying Authentik-gated operations ingresses"
kubectl apply -f "$workdir/operations-sso.yaml"
log "Operations SSO applied"
kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth
kubectl -n "$NAMESPACE" get ingress zabbix openobserve
