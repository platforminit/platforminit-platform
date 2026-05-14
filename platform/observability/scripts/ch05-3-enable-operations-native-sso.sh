#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ISSUER_MODE="${ISSUER_MODE:-prod}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
AUTHENTIK_LOCAL_PORT="${AUTHENTIK_LOCAL_PORT:-19080}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-http://127.0.0.1:${AUTHENTIK_LOCAL_PORT}}"
AUTHENTIK_OPERATIONS_ADMIN_USERNAME="${AUTHENTIK_OPERATIONS_ADMIN_USERNAME:-akadmin}"
ZABBIX_LOCAL_PORT="${ZABBIX_LOCAL_PORT:-18080}"
ZABBIX_API_URL="http://127.0.0.1:${ZABBIX_LOCAL_PORT}/api_jsonrpc.php"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-zabbix}"
OPENOBSERVE_OIDC_CLIENT_ID="${OPENOBSERVE_OIDC_CLIENT_ID:-platforminit-openobserve}"
OPENOBSERVE_OIDC_CLIENT_SECRET="${OPENOBSERVE_OIDC_CLIENT_SECRET:-}"
export KUBECONFIG

ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }
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
  kubectl -n "${IDENTITY_NAMESPACE}" port-forward --address 127.0.0.1 svc/authentik-server "${AUTHENTIK_LOCAL_PORT}:80" >/tmp/ch05-3-authentik-port-forward.log 2>&1 &
  AUTHENTIK_PORT_FORWARD_PID="$!"
  export AUTHENTIK_PORT_FORWARD_PID
  for _ in $(seq 1 30); do
    if curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null 2>&1; then
      log "Authentik API is reachable"
      return 0
    fi
    sleep 2
  done
  cat /tmp/ch05-3-authentik-port-forward.log >&2 || true
  die "Authentik API was not reachable through port-forward"
}
start_zabbix_api_port_forward(){
  log "Starting temporary Zabbix API port-forward on 127.0.0.1:${ZABBIX_LOCAL_PORT}"
  kubectl -n "${NAMESPACE}" port-forward --address 127.0.0.1 svc/zabbix-web "${ZABBIX_LOCAL_PORT}:8080" >/tmp/ch05-3-zabbix-port-forward.log 2>&1 &
  ZABBIX_PORT_FORWARD_PID="$!"
  export ZABBIX_PORT_FORWARD_PID
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${ZABBIX_LOCAL_PORT}/" >/dev/null 2>&1; then
      log "Zabbix frontend is reachable"
      return 0
    fi
    sleep 2
  done
  cat /tmp/ch05-3-zabbix-port-forward.log >&2 || true
  die "Zabbix frontend was not reachable through port-forward"
}
cleanup(){
  [[ -n "${AUTHENTIK_PORT_FORWARD_PID:-}" ]] && kill "${AUTHENTIK_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  [[ -n "${ZABBIX_PORT_FORWARD_PID:-}" ]] && kill "${ZABBIX_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

configure_authentik_native_sso(){
  log "Reconciling native Authentik providers/applications for Operations WebUIs"
  export BASE_DOMAIN AUTHENTIK_BASE_URL AUTHENTIK_BOOTSTRAP_TOKEN AUTHENTIK_OPERATIONS_ADMIN_USERNAME OPENOBSERVE_OIDC_CLIENT_ID OPENOBSERVE_OIDC_CLIENT_SECRET
  python3 - <<'PY'
import json, os, secrets, sys, urllib.error, urllib.parse, urllib.request
base_domain=os.environ["BASE_DOMAIN"]
authentik_public_host=f"https://auth.{base_domain}"
base_url=os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token=os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
admin_username=os.environ.get("AUTHENTIK_OPERATIONS_ADMIN_USERNAME","akadmin")
openobserve_client_id=os.environ.get("OPENOBSERVE_OIDC_CLIENT_ID","platforminit-openobserve")
openobserve_client_secret=os.environ.get("OPENOBSERVE_OIDC_CLIENT_SECRET") or secrets.token_urlsafe(48)
headers={"Authorization":f"Bearer {token}","Accept":"application/json","Content-Type":"application/json"}
operations_group_name="PlatformInit Operations"
zabbix_host=f"https://zabbix.{base_domain}"
logs_host=f"https://logs.{base_domain}"
zabbix_slug="platforminit-zabbix"
openobserve_slug="platforminit-openobserve"

def request(method,path,payload=None,tolerate_404=False,accept_json=True):
    data=json.dumps(payload).encode("utf-8") if payload is not None else None
    req=urllib.request.Request(f"{base_url}{path}",data=data,method=method,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=30) as resp:
            raw=resp.read().decode("utf-8")
            if not accept_json:
                return raw
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body=exc.read().decode("utf-8",errors="replace")
        if tolerate_404 and exc.code==404:
            return None
        raise RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {body}") from exc

def paginated_results(path):
    items=[]; next_path=path
    while next_path:
        obj=request("GET",next_path)
        if isinstance(obj,dict) and "results" in obj:
            items.extend(obj.get("results") or [])
            nxt=obj.get("pagination",{}).get("next") or obj.get("next")
            if not nxt: break
            next_path=str(nxt)[len(base_url):] if str(nxt).startswith(base_url) else str(nxt)
        elif isinstance(obj,list):
            items.extend(obj); break
        else: break
    return items

def first_by_field(path,field,value):
    enc=urllib.parse.quote(str(value)); sep="&" if "?" in path else "?"
    for q in (f"{field}={enc}",f"search={enc}"):
        for item in paginated_results(f"{path}{sep}{q}"):
            if str(item.get(field,""))==str(value): return item
    return None

def first_by_name(path,name): return first_by_field(path,"name",name)
def flow_pk(slug):
    flow=first_by_field("/api/v3/flows/instances/","slug",slug)
    if not flow: raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return flow["pk"]
def ensure_group(name):
    existing=first_by_name("/api/v3/core/groups/",name)
    payload={"name":name,"is_superuser":False,"parent":None,"attributes":{}}
    if existing:
        request("PATCH",f"/api/v3/core/groups/{existing['pk']}/",payload); return existing["pk"]
    return request("POST","/api/v3/core/groups/",payload)["pk"]
def group_pk_list(raw):
    vals=[]
    for item in raw or []:
        if isinstance(item,str): vals.append(item)
        elif isinstance(item,dict):
            v=item.get("pk") or item.get("id") or item.get("uuid")
            if v: vals.append(v)
    return vals
def find_user_by_username(username):
    enc=urllib.parse.quote(username)
    for path in (f"/api/v3/core/users/?username={enc}",f"/api/v3/core/users/?search={enc}"):
        for item in paginated_results(path):
            if item.get("username")==username: return item
    return None
def ensure_user_in_group(username,group_pk,group_name):
    user=find_user_by_username(username)
    if not user:
        print(f"WARN: Authentik user {username!r} not found; group {group_name!r} was created but not populated",file=sys.stderr); return
    editable=request("GET",f"/api/v3/core/users/{user['pk']}/")
    groups=group_pk_list(editable.get("groups",[]))
    if group_pk not in groups:
        groups.append(group_pk); request("PATCH",f"/api/v3/core/users/{user['pk']}/",{"groups":groups})
        print(f"Added Authentik user {username} to {group_name}")
def ensure_saml_mapping(name,saml_name,expression,friendly_name=""):
    existing=first_by_name("/api/v3/propertymappings/provider/saml/",name)
    payload={"name":name,"saml_name":saml_name,"friendly_name":friendly_name,"expression":expression}
    if existing:
        request("PATCH",f"/api/v3/propertymappings/provider/saml/{existing['pk']}/",payload); return existing["pk"]
    return request("POST","/api/v3/propertymappings/provider/saml/",payload)["pk"]
def scope_mapping_pks():
    wanted={"goauthentik.io/providers/oauth2/scope-openid","goauthentik.io/providers/oauth2/scope-email","goauthentik.io/providers/oauth2/scope-profile"}
    results=[]
    for m in paginated_results("/api/v3/propertymappings/provider/scope/?page_size=200"):
        managed=str(m.get("managed") or ""); name=str(m.get("name") or "").lower()
        if managed in wanted or name in {"openid","email","profile"}:
            pk=m.get("pk")
            if pk and pk not in results: results.append(pk)
    groups_name="PlatformInit OIDC groups"
    existing=first_by_name("/api/v3/propertymappings/provider/scope/",groups_name)
    payload={"name":groups_name,"scope_name":"groups","description":"Expose Authentik group names for PlatformInit operations apps.","expression":"return {'groups': [group.name for group in request.user.ak_groups.all()]}"}
    try:
        if existing:
            request("PATCH",f"/api/v3/propertymappings/provider/scope/{existing['pk']}/",payload); pk=existing["pk"]
        else:
            pk=request("POST","/api/v3/propertymappings/provider/scope/",payload)["pk"]
        if pk not in results: results.append(pk)
    except Exception as exc:
        print(f"WARN: could not create custom groups scope mapping: {exc}",file=sys.stderr)
    return results
def certificate_pem_from_pair(pair):
    for key in ("certificate_data","certificate","certificate_pem","cert","public_certificate","certificate_chain"):
        val=pair.get(key)
        if isinstance(val,str) and "BEGIN CERTIFICATE" in val:
            return val
    pk=pair.get("pk") or pair.get("uuid")
    if pk:
        for path in (f"/api/v3/crypto/certificatekeypairs/{pk}/view_certificate/", f"/api/v3/crypto/certificatekeypairs/{pk}/"):
            try:
                raw=request("GET",path,accept_json=False)
                if "BEGIN CERTIFICATE" in raw:
                    return raw
                try:
                    obj=json.loads(raw)
                    for key in ("certificate_data","certificate","certificate_pem","cert","public_certificate","certificate_chain"):
                        val=obj.get(key)
                        if isinstance(val,str) and "BEGIN CERTIFICATE" in val:
                            return val
                except Exception:
                    pass
            except Exception:
                pass
    return None
def signing_keypair():
    pairs=paginated_results("/api/v3/crypto/certificatekeypairs/?page_size=200")
    ordered=[]
    for p in pairs:
        if "authentik" in str(p.get("name") or "").lower(): ordered.append(p)
    ordered.extend([p for p in pairs if p not in ordered])
    for p in ordered:
        pk=p.get("pk") or p.get("uuid")
        if not pk: continue
        pem=certificate_pem_from_pair(p)
        if pem:
            return pk,pem
    raise RuntimeError("No Authentik certificate/keypair with readable public certificate was found for Zabbix SAML")
def cleanup_proxy_provider(name):
    existing=first_by_name("/api/v3/providers/proxy/",name)
    if existing:
        request("DELETE",f"/api/v3/providers/proxy/{existing['pk']}/"); print(f"Deleted stale Authentik proxy provider {name}")
def ensure_application(name,slug,provider_pk,launch_url,description):
    payload={"name":name,"slug":slug,"provider":provider_pk,"open_in_new_tab":True,"meta_launch_url":launch_url,"meta_description":description,"meta_publisher":"PlatformInit"}
    existing=first_by_field("/api/v3/core/applications/","slug",slug)
    if existing:
        request("PATCH",f"/api/v3/core/applications/{slug}/",payload); print(f"Updated Authentik application {slug}")
    else:
        request("POST","/api/v3/core/applications/",payload); print(f"Created Authentik application {slug}")
def ensure_saml_provider(authorization_flow,invalidation_flow):
    signing_kp,cert_pem=signing_keypair()
    email=ensure_saml_mapping("PlatformInit SAML email","email","return request.user.email","email")
    username=ensure_saml_mapping("PlatformInit SAML username","username","return request.user.username","username")
    name=ensure_saml_mapping("PlatformInit SAML name","name","return request.user.name or request.user.username","name")
    groups=ensure_saml_mapping("PlatformInit SAML groups","groups","for group in request.user.ak_groups.all(): yield group.name","groups")
    payload={"name":"PlatformInit Zabbix","authorization_flow":authorization_flow,"invalidation_flow":invalidation_flow,"acs_url":f"{zabbix_host}/index_sso.php?acs","slo_url":f"{zabbix_host}/index_sso.php?sls","issuer":zabbix_host,"audience":zabbix_host,"sp_binding":"post","signing_kp":signing_kp,"property_mappings":[email,username,name,groups],"name_id_mapping":username,"default_name_id_policy":"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified","sign_assertion":True,"sign_response":False,"sign_logout_request":False}
    existing=first_by_name("/api/v3/providers/saml/","PlatformInit Zabbix")
    if existing:
        pk=existing["pk"]
        try: request("PATCH",f"/api/v3/providers/saml/{pk}/",payload)
        except RuntimeError:
            minimal={k:v for k,v in payload.items() if k in {"name","authorization_flow","invalidation_flow","acs_url","slo_url","issuer","audience","sp_binding","signing_kp","property_mappings","name_id_mapping"}}
            request("PATCH",f"/api/v3/providers/saml/{pk}/",minimal)
        print(f"Updated Authentik SAML provider PlatformInit Zabbix pk={pk}")
    else:
        try: created=request("POST","/api/v3/providers/saml/",payload)
        except RuntimeError:
            minimal={k:v for k,v in payload.items() if k in {"name","authorization_flow","invalidation_flow","acs_url","slo_url","issuer","audience","sp_binding","signing_kp","property_mappings","name_id_mapping"}}
            created=request("POST","/api/v3/providers/saml/",minimal)
        pk=created["pk"]; print(f"Created Authentik SAML provider PlatformInit Zabbix pk={pk}")
    ensure_application("PlatformInit Zabbix",zabbix_slug,pk,f"{zabbix_host}/index_sso.php","PlatformInit operational monitoring UI")
    with open("/tmp/platforminit-zabbix-idp.crt","w",encoding="utf-8") as fh:
        fh.write(cert_pem.strip()+"\n")
def ensure_oauth2_provider(authorization_flow,invalidation_flow):
    scopes=scope_mapping_pks()
    payload={"name":"PlatformInit OpenObserve","authorization_flow":authorization_flow,"invalidation_flow":invalidation_flow,"client_type":"confidential","client_id":openobserve_client_id,"client_secret":openobserve_client_secret,"redirect_uris":[{"matching_mode":"strict","url":f"{logs_host}/config/redirect"}],"include_claims_in_id_token":True,"sub_mode":"hashed_user_id","issuer_mode":"per_provider","property_mappings":scopes}
    existing=first_by_name("/api/v3/providers/oauth2/","PlatformInit OpenObserve")
    if existing:
        pk=existing["pk"]
        try: request("PATCH",f"/api/v3/providers/oauth2/{pk}/",payload)
        except RuntimeError:
            minimal={k:v for k,v in payload.items() if k in {"name","authorization_flow","invalidation_flow","client_type","client_id","client_secret","redirect_uris","property_mappings"}}
            request("PATCH",f"/api/v3/providers/oauth2/{pk}/",minimal)
        print(f"Updated Authentik OAuth2/OIDC provider PlatformInit OpenObserve pk={pk}")
    else:
        try: created=request("POST","/api/v3/providers/oauth2/",payload)
        except RuntimeError:
            minimal={k:v for k,v in payload.items() if k in {"name","authorization_flow","invalidation_flow","client_type","client_id","client_secret","redirect_uris","property_mappings"}}
            created=request("POST","/api/v3/providers/oauth2/",minimal)
        pk=created["pk"]; print(f"Created Authentik OAuth2/OIDC provider PlatformInit OpenObserve pk={pk}")
    ensure_application("PlatformInit OpenObserve",openobserve_slug,pk,logs_host,"PlatformInit log search and RCA UI")

request("GET","/api/v3/core/users/me/")
authorization_flow=flow_pk("default-provider-authorization-implicit-consent")
invalidation_flow=flow_pk("default-provider-invalidation-flow")
ops_group_pk=ensure_group(operations_group_name)
ensure_user_in_group(admin_username,ops_group_pk,operations_group_name)
cleanup_proxy_provider("PlatformInit Zabbix")
cleanup_proxy_provider("PlatformInit OpenObserve")
ensure_saml_provider(authorization_flow,invalidation_flow)
ensure_oauth2_provider(authorization_flow,invalidation_flow)
with open("/tmp/platforminit-openobserve-sso.env","w",encoding="utf-8") as fh:
    env={"O2_DEX_ENABLED":"true","O2_DEX_CLIENT_ID":openobserve_client_id,"O2_DEX_CLIENT_SECRET":openobserve_client_secret,"O2_DEX_BASE_URL":f"{authentik_public_host}/application/o/{openobserve_slug}/","O2_DEX_REDIRECT_URL":f"{logs_host}/config/redirect","O2_CALLBACK_URL":f"{logs_host}/web/cb","O2_DEX_SCOPES":"openid profile email groups offline_access","O2_DEX_GROUP_ATTRIBUTE":"groups","O2_DEX_ROLE_ATTRIBUTE":"groups","O2_DEX_DEFAULT_ORG":"default"}
    for k,v in env.items(): fh.write(f"{k}={v}\n")
with open("/tmp/platforminit-zabbix-saml.json","w",encoding="utf-8") as fh:
    json.dump({"idp_entityid":f"{authentik_public_host}/application/saml/{zabbix_slug}/metadata/","sso_url":f"{authentik_public_host}/application/saml/{zabbix_slug}/sso/binding/redirect/","slo_url":f"{authentik_public_host}/application/saml/{zabbix_slug}/slo/binding/redirect/","sp_entityid":zabbix_host,"username_attribute":"username","bootstrap_user":admin_username},fh)
print("Native Operations SSO Authentik reconciliation complete")
PY
}

configure_openobserve_sso_secret(){
  log "Reconciling OpenObserve Enterprise native SSO secret"
  [[ -f /tmp/platforminit-openobserve-sso.env ]] || die "Missing generated OpenObserve SSO env file"
  kubectl -n "$NAMESPACE" create secret generic openobserve-sso --from-env-file=/tmp/platforminit-openobserve-sso.env --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "OpenObserve SSO secret reconciled; app rollout is handled by Argo CD sync/operations lifecycle, not this SSO workflow"
}
configure_zabbix_saml_secret(){
  log "Reconciling Zabbix SAML IdP certificate secret"
  [[ -f /tmp/platforminit-zabbix-idp.crt ]] || die "Missing generated Zabbix IdP certificate"
  kubectl -n "$NAMESPACE" create secret generic zabbix-saml-certs --from-file=idp.crt=/tmp/platforminit-zabbix-idp.crt --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Zabbix SAML certificate secret reconciled; zabbix-web volume is Argo CD-owned"
}
configure_zabbix_saml_api(){
  log "Configuring Zabbix SAML settings through JSON-RPC API"
  export ZABBIX_API_URL ZABBIX_ADMIN_USER ZABBIX_ADMIN_PASSWORD
  python3 - <<'PY'
import json, os, secrets, urllib.request
api_url=os.environ["ZABBIX_API_URL"]
admin_user=os.environ.get("ZABBIX_ADMIN_USER","Admin")
admin_password=os.environ.get("ZABBIX_ADMIN_PASSWORD","zabbix")
saml=json.load(open("/tmp/platforminit-zabbix-saml.json",encoding="utf-8"))
bootstrap_user=saml.get("bootstrap_user","akadmin")
def rpc(method,params=None,auth=None):
    payload={"jsonrpc":"2.0","method":method,"params":params or {},"id":1}
    if auth: payload["auth"]=auth
    req=urllib.request.Request(api_url,data=json.dumps(payload).encode(),method="POST",headers={"Content-Type":"application/json-rpc"})
    with urllib.request.urlopen(req,timeout=30) as resp: result=json.loads(resp.read().decode())
    if "error" in result: raise RuntimeError(f"Zabbix API {method} failed: {result['error']}")
    return result.get("result")
def login():
    try:
        return rpc("user.login", {"username":admin_user,"password":admin_password})
    except Exception:
        return rpc("user.login", {"user":admin_user,"password":admin_password})
def first(items):
    return items[0] if items else None

token=login()
# Make the Authentik bootstrap user usable for Zabbix SAML. Local Admin remains break-glass.
try:
    groups=rpc("usergroup.get", {"output":["usrgrpid","name"],"filter":{"name":["Zabbix administrators"]}}, token) or []
    group=first(groups) or first(rpc("usergroup.get", {"output":["usrgrpid","name"],"search":{"name":"Admin"}}, token) or [])
    roles=rpc("role.get", {"output":["roleid","name","type"],"filter":{"name":["Super admin role"]}}, token) or []
    role=first(roles) or first([r for r in (rpc("role.get", {"output":["roleid","name","type"]}, token) or []) if str(r.get("type"))=="3" or "super" in str(r.get("name","")).lower()])
    if group and role:
        existing=rpc("user.get", {"output":["userid","username","alias"],"filter":{"username":[bootstrap_user]}}, token) or []
        if not existing:
            try:
                existing=rpc("user.get", {"output":["userid","username","alias"],"filter":{"alias":[bootstrap_user]}}, token) or []
            except Exception:
                existing=[]
        payload={"username":bootstrap_user,"passwd":secrets.token_urlsafe(24),"roleid":role["roleid"],"usrgrps":[{"usrgrpid":group["usrgrpid"]}]}
        if existing:
            userid=existing[0]["userid"]
            rpc("user.update", {"userid":userid,"roleid":role["roleid"],"usrgrps":[{"usrgrpid":group["usrgrpid"]}]}, token)
            print(f"Updated Zabbix SAML bootstrap user {bootstrap_user}")
        else:
            try:
                rpc("user.create", payload, token)
            except Exception:
                payload["alias"]=payload.pop("username")
                rpc("user.create", payload, token)
            print(f"Created Zabbix SAML bootstrap user {bootstrap_user}")
    else:
        print("WARN: Could not find Zabbix admin group/role; SAML auth is configured but user bootstrap was skipped")
except Exception as exc:
    print(f"WARN: Zabbix SAML bootstrap user reconciliation skipped: {exc}")

params={"saml_auth_enabled":1,"saml_idp_entityid":saml["idp_entityid"],"saml_sso_url":saml["sso_url"],"saml_slo_url":saml["slo_url"],"saml_username_attribute":saml["username_attribute"],"saml_sp_entityid":saml["sp_entityid"],"saml_nameid_format":"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified","saml_case_sensitive":0,"saml_jit_status":0}
try:
    rpc("authentication.update", params, token)
except Exception as exc:
    print(f"WARN: full Zabbix SAML update failed, retrying minimal update: {exc}")
    minimal={k:v for k,v in params.items() if k != "saml_jit_status"}
    rpc("authentication.update", minimal, token)
print("Zabbix SAML authentication configured")
PY
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
configure_authentik_native_sso
configure_openobserve_sso_secret
configure_zabbix_saml_secret
start_zabbix_api_port_forward
configure_zabbix_saml_api
log "Operations native SSO prerequisites applied; runtime resources remain Argo CD-owned"
kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null
