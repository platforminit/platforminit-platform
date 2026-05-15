#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
AUTHENTIK_LOCAL_PORT="${AUTHENTIK_LOCAL_PORT:-19080}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-http://127.0.0.1:${AUTHENTIK_LOCAL_PORT}}"
AUTHENTIK_OPERATIONS_ADMIN_USERNAME="${AUTHENTIK_OPERATIONS_ADMIN_USERNAME:-akadmin}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
CHECKMK_LOCAL_PORT="${CHECKMK_LOCAL_PORT:-18085}"
CHECKMK_REMOTE_USER_HEADER="${CHECKMK_REMOTE_USER_HEADER:-X-Remote-User}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
need curl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl get ns "$IDENTITY_NAMESPACE" >/dev/null 2>&1 || die "Missing identity namespace. Run 04.5 first."
kubectl -n "$IDENTITY_NAMESPACE" rollout status deploy/authentik-server --timeout=90s >/dev/null || die "Authentik server is not ready"
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"

read_secret_key(){ kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true; }
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
if [[ -z "$AUTHENTIK_BOOTSTRAP_TOKEN" ]]; then
  AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "$IDENTITY_NAMESPACE" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
fi
[[ -n "$AUTHENTIK_BOOTSTRAP_TOKEN" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run 04.5 - Deploy Identity Foundation"

AUTHENTIK_PORT_FORWARD_PID=""
CHECKMK_PORT_FORWARD_PID=""
cleanup(){
  [[ -n "${AUTHENTIK_PORT_FORWARD_PID:-}" ]] && kill "$AUTHENTIK_PORT_FORWARD_PID" >/dev/null 2>&1 || true
  [[ -n "${CHECKMK_PORT_FORWARD_PID:-}" ]] && kill "$CHECKMK_PORT_FORWARD_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Starting Authentik API port-forward on 127.0.0.1:${AUTHENTIK_LOCAL_PORT}"
kubectl -n "$IDENTITY_NAMESPACE" port-forward --address 127.0.0.1 svc/authentik-server "${AUTHENTIK_LOCAL_PORT}:80" >/tmp/ch05-checkmk-authentik-port-forward.log 2>&1 &
AUTHENTIK_PORT_FORWARD_PID="$!"
for _ in $(seq 1 30); do
  curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null || { cat /tmp/ch05-checkmk-authentik-port-forward.log >&2 || true; die "Authentik API was not reachable"; }

log "Reconciling Authentik application/provider contract for Checkmk forward auth"
export BASE_DOMAIN AUTHENTIK_BASE_URL AUTHENTIK_BOOTSTRAP_TOKEN AUTHENTIK_OPERATIONS_ADMIN_USERNAME CHECKMK_SITE
python3 - <<'PY_AUTHENTIK'
import json, os, sys, urllib.parse, urllib.request, urllib.error
base_domain=os.environ['BASE_DOMAIN']
base_url=os.environ['AUTHENTIK_BASE_URL'].rstrip('/')
token=os.environ['AUTHENTIK_BOOTSTRAP_TOKEN']
admin_username=os.environ.get('AUTHENTIK_OPERATIONS_ADMIN_USERNAME','akadmin')
checkmk_url=f"https://checkmk.{base_domain}"
headers={"Authorization":f"Bearer {token}","Accept":"application/json","Content-Type":"application/json"}

def request(method,path,payload=None,tolerate_404=False):
    data=json.dumps(payload).encode() if payload is not None else None
    req=urllib.request.Request(f"{base_url}{path}",data=data,method=method,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=30) as resp:
            raw=resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body=exc.read().decode(errors='replace')
        if tolerate_404 and exc.code==404:
            return None
        raise RuntimeError(f"{method} {path} failed HTTP {exc.code}: {body}")

def paginated(path):
    out=[]; nxt=path
    while nxt:
        obj=request('GET',nxt)
        if isinstance(obj,dict) and 'results' in obj:
            out.extend(obj.get('results') or [])
            nxt=(obj.get('pagination',{}) or {}).get('next') or obj.get('next')
            if nxt and str(nxt).startswith(base_url): nxt=str(nxt)[len(base_url):]
        elif isinstance(obj,list):
            out.extend(obj); break
        else: break
    return out

def first_by(path,field,value):
    enc=urllib.parse.quote(str(value)); sep='&' if '?' in path else '?'
    for q in (f"{field}={enc}",f"search={enc}"):
        for item in paginated(f"{path}{sep}{q}"):
            if str(item.get(field,''))==str(value) or str(item.get('name',''))==str(value) or str(item.get('slug',''))==str(value):
                return item
    return None

def flow(slug):
    item=first_by('/api/v3/flows/instances/','slug',slug)
    if not item: raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return item['pk']

def ensure_group(name):
    existing=first_by('/api/v3/core/groups/','name',name)
    payload={"name":name,"is_superuser":False,"parent":None,"attributes":{}}
    if existing:
        request('PATCH',f"/api/v3/core/groups/{existing['pk']}/",payload); return existing['pk']
    return request('POST','/api/v3/core/groups/',payload)['pk']

def group_pks(raw):
    vals=[]
    for x in raw or []:
        if isinstance(x,str): vals.append(x)
        elif isinstance(x,dict):
            v=x.get('pk') or x.get('id') or x.get('uuid')
            if v: vals.append(v)
    return vals

def ensure_user_in_group(username, group_pk):
    user=first_by('/api/v3/core/users/','username',username)
    if not user:
        print(f"WARN: Authentik user {username!r} not found; Checkmk SSO group exists but user was not added", file=sys.stderr); return
    detail=request('GET',f"/api/v3/core/users/{user['pk']}/")
    groups=group_pks(detail.get('groups',[]))
    if group_pk not in groups:
        groups.append(group_pk)
        request('PATCH',f"/api/v3/core/users/{user['pk']}/",{"groups":groups})
        print(f"Added {username} to PlatformInit Operations")

def provider_payload(mode):
    payload={
        "name":"PlatformInit Checkmk",
        "authorization_flow":flow('default-provider-authorization-implicit-consent'),
        "external_host":checkmk_url,
        "internal_host":"http://checkmk.operations.svc.cluster.local",
        "mode":mode,
        "cookie_domain":base_domain,
        "intercept_header_auth":False,
        "basic_auth_enabled":False,
    }
    try:
        payload["authentication_flow"]=flow('default-authentication-flow')
    except Exception:
        pass
    return payload

def ensure_proxy_provider():
    existing=first_by('/api/v3/providers/proxy/','name','PlatformInit Checkmk')
    errors=[]
    for mode in ('forward_single','forward_domain'):
        payload=provider_payload(mode)
        try:
            if existing:
                request('PATCH',f"/api/v3/providers/proxy/{existing['pk']}/",payload)
                print(f"Updated Authentik proxy provider PlatformInit Checkmk mode={mode}")
                return existing['pk']
            created=request('POST','/api/v3/providers/proxy/',payload)
            print(f"Created Authentik proxy provider PlatformInit Checkmk mode={mode}")
            return created['pk']
        except Exception as exc:
            errors.append(f"{mode}: {exc}")
    raise RuntimeError('Could not create/update Authentik proxy provider: ' + ' | '.join(errors))

def ensure_application(provider_pk):
    slug='platforminit-checkmk'
    payload={"name":"PlatformInit Checkmk","slug":slug,"provider":provider_pk,"open_in_new_tab":True,"meta_launch_url":f"{checkmk_url}/cmk/","meta_description":"PlatformInit Checkmk Community operations console","meta_publisher":"PlatformInit"}
    existing=first_by('/api/v3/core/applications/','slug',slug)
    if existing:
        request('PATCH',f"/api/v3/core/applications/{slug}/",payload)
        print('Updated Authentik application platforminit-checkmk')
    else:
        request('POST','/api/v3/core/applications/',payload)
        print('Created Authentik application platforminit-checkmk')
    return slug

def ensure_outpost_application(slug):
    outposts=paginated('/api/v3/outposts/instances/?page_size=100')
    embedded=None
    for o in outposts:
        name=str(o.get('name','')).lower()
        if 'embedded' in name:
            embedded=o; break
    if not embedded:
        print('WARN: no embedded outpost found through API; attach PlatformInit Checkmk to an Authentik proxy outpost if forward auth says no app for hostname.', file=sys.stderr)
        return
    detail=request('GET',f"/api/v3/outposts/instances/{embedded['pk']}/")
    apps=detail.get('applications') or []
    refs=[]
    for a in apps:
        if isinstance(a,str): refs.append(a)
        elif isinstance(a,dict): refs.append(a.get('slug') or a.get('pk') or a.get('name'))
    if slug not in refs:
        try:
            request('PATCH',f"/api/v3/outposts/instances/{embedded['pk']}/",{"applications":refs+[slug]})
            print(f"Attached {slug} to embedded Authentik outpost")
        except Exception as exc:
            print(f"WARN: could not attach {slug} to embedded outpost via API: {exc}. Attach it manually if forward auth returns 'no app for hostname'.", file=sys.stderr)

request('GET','/api/v3/core/users/me/')
ops_group=ensure_group('PlatformInit Operations')
ensure_user_in_group(admin_username, ops_group)
provider=ensure_proxy_provider()
slug=ensure_application(provider)
ensure_outpost_application(slug)
print('Checkmk Authentik forward-auth contract reconciled')
PY_AUTHENTIK

log "Starting temporary Checkmk port-forward on 127.0.0.1:${CHECKMK_LOCAL_PORT}"
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:5000" >/tmp/ch05-checkmk-port-forward.log 2>&1 &
CHECKMK_PORT_FORWARD_PID="$!"
for _ in $(seq 1 45); do
  code="$(curl -sS -o /tmp/ch05-checkmk-health.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
  [[ "$code" =~ ^(200|302|401|403)$ ]] && break
  sleep 2
done
code="$(curl -sS -o /tmp/ch05-checkmk-health.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
[[ "$code" =~ ^(200|302|401|403)$ ]] || { cat /tmp/ch05-checkmk-port-forward.log >&2 || true; die "Checkmk frontend did not answer through port-forward; HTTP=${code}"; }

kubectl -n "$NAMESPACE" create secret generic checkmk-sso \
  --from-literal=CHECKMK_SITE="$CHECKMK_SITE" \
  --from-literal=CHECKMK_REMOTE_USER_HEADER="$CHECKMK_REMOTE_USER_HEADER" \
  --from-literal=CHECKMK_PUBLIC_URL="https://checkmk.${BASE_DOMAIN}/${CHECKMK_SITE}/" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Checkmk trusted-header SSO contract reconciled. If first SSO login still shows the Checkmk local login screen, enable 'Authenticate users by incoming HTTP requests' once in Checkmk Global Settings."
