#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
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
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."

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

def user_details(user):
    pk=user.get("pk") or user.get("id")
    if not pk:
        return user
    try:
        return request("GET",f"/api/v3/core/users/{pk}/")
    except Exception:
        return user

def sync_operations_group_membership(group_pk,group_name,admin_username):
    """Make the intended Authentik operators explicit before provisioning app users.

    The Zabbix SAML integration is intentionally not JIT-driven yet. Zabbix
    only lets a SAML login complete when the incoming username already exists
    with a valid role/group. To avoid the recurring "authorized via SSO, but
    logging in to Zabbix failed" error, every active Authentik superuser and
    the configured bootstrap admin are placed into PlatformInit Operations and
    later mirrored into Zabbix.
    """
    for user in paginated_results("/api/v3/core/users/?page_size=200"):
        username=user.get("username")
        if not username:
            continue
        is_superuser=bool(user.get("is_superuser"))
        is_active=user.get("is_active", True)
        if username == admin_username or (is_superuser and is_active):
            ensure_user_in_group(username,group_pk,group_name)

def operations_user_records(group_pk,admin_username):
    records={}
    for user in paginated_results("/api/v3/core/users/?page_size=200"):
        username=user.get("username")
        if not username:
            continue
        detail=user_details(user)
        groups=group_pk_list(detail.get("groups",[]))
        if group_pk in groups or username == admin_username:
            records[username]={
                "username":username,
                "name":detail.get("name") or username,
                "email":detail.get("email") or "",
                "is_superuser":bool(detail.get("is_superuser")),
            }
    if admin_username and admin_username not in records:
        records[admin_username]={"username":admin_username,"name":admin_username,"email":"","is_superuser":False}
    return [records[k] for k in sorted(records)]

def write_zabbix_user_sync_file(group_pk,admin_username):
    users=operations_user_records(group_pk,admin_username)
    with open("/tmp/platforminit-zabbix-users.json","w",encoding="utf-8") as fh:
        json.dump(users,fh)
    print("Prepared Zabbix SAML user sync list: "+", ".join(u["username"] for u in users))

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
def canonicalize_certificate_pem(raw):
    """Return exactly one PEM certificate block without API wrappers or comments.

    Zabbix/SimpleSAML is strict here. Extra text around the PEM block can produce:
    "Unable to extract public key".
    """
    import re
    if not isinstance(raw, str):
        return None
    match=re.search(r"-----BEGIN CERTIFICATE-----\s+.*?\s+-----END CERTIFICATE-----", raw, re.S)
    if not match:
        return None
    lines=[line.strip() for line in match.group(0).strip().splitlines() if line.strip()]
    return "\n".join(lines)+"\n"

def certificate_pem_from_pair(pair):
    for key in ("data","certificate_data","certificate","certificate_pem","cert","public_certificate","certificate_chain"):
        pem=canonicalize_certificate_pem(pair.get(key))
        if pem:
            return pem
    pk=pair.get("pk") or pair.get("uuid")
    if pk:
        for path in (f"/api/v3/crypto/certificatekeypairs/{pk}/view_certificate/", f"/api/v3/crypto/certificatekeypairs/{pk}/"):
            try:
                raw=request("GET",path,accept_json=False)
                pem=canonicalize_certificate_pem(raw)
                if pem:
                    return pem
                try:
                    obj=json.loads(raw)
                    for key in ("data","certificate_data","certificate","certificate_pem","cert","public_certificate","certificate_chain"):
                        pem=canonicalize_certificate_pem(obj.get(key))
                        if pem:
                            return pem
                except Exception:
                    pass
            except Exception:
                pass
    return None
def generate_platforminit_saml_keypair():
    """Create a dedicated Authentik signing keypair when the default one is unreadable.

    Some Authentik versions expose certificate-keypair metadata in the list API but
    not the PEM block directly. The supported fallback is the generate endpoint,
    then reading the generated keypair through view_certificate.
    """
    payload={"common_name":"platforminit-zabbix-saml","subject_alt_name":"authentik.platforminit.local","validity_days":3650,"alg":"rsa"}
    try:
        created=request("POST","/api/v3/crypto/certificatekeypairs/generate/",payload)
    except Exception as exc:
        print(f"WARN: full Authentik certificate generation payload failed, retrying minimal payload: {exc}",file=sys.stderr)
        created=request("POST","/api/v3/crypto/certificatekeypairs/generate/",{"common_name":"platforminit-zabbix-saml","validity_days":3650})
    pk=created.get("pk") or created.get("uuid")
    if not pk:
        raise RuntimeError(f"Generated Authentik certificate/keypair response had no pk: {created}")
    # Give the generated keypair a stable, human-readable name when supported.
    try:
        request("PATCH",f"/api/v3/crypto/certificatekeypairs/{pk}/",{"name":"PlatformInit Zabbix SAML Signing Certificate"})
    except Exception as exc:
        print(f"WARN: could not rename generated Authentik signing keypair: {exc}",file=sys.stderr)
    refreshed=request("GET",f"/api/v3/crypto/certificatekeypairs/{pk}/")
    pem=certificate_pem_from_pair(refreshed) or certificate_pem_from_pair(created)
    if not pem:
        raise RuntimeError("Generated Authentik certificate/keypair but could not read its public certificate")
    print(f"Generated dedicated Authentik SAML signing keypair pk={pk}")
    return pk,pem

def signing_keypair():
    pairs=paginated_results("/api/v3/crypto/certificatekeypairs/?page_size=200")
    ordered=[]
    preferred_names=("platforminit zabbix saml", "authentik self-signed", "authentik")
    for needle in preferred_names:
        for p in pairs:
            if p in ordered: continue
            if needle in str(p.get("name") or "").lower(): ordered.append(p)
    ordered.extend([p for p in pairs if p not in ordered])
    unreadable=[]
    for p in ordered:
        pk=p.get("pk") or p.get("uuid")
        if not pk: continue
        pem=certificate_pem_from_pair(p)
        if pem:
            return pk,pem
        unreadable.append(str(p.get("name") or pk))
    print("WARN: no readable Authentik certificate PEM found in existing keypairs; attempting to generate a dedicated SAML signing keypair",file=sys.stderr)
    if unreadable:
        print("WARN: unreadable keypairs: "+", ".join(unreadable),file=sys.stderr)
    return generate_platforminit_saml_keypair()
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
        fh.write(canonicalize_certificate_pem(cert_pem) or cert_pem.strip()+"\n")
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
sync_operations_group_membership(ops_group_pk,operations_group_name,admin_username)
write_zabbix_user_sync_file(ops_group_pk,admin_username)
cleanup_proxy_provider("PlatformInit Zabbix")
cleanup_proxy_provider("PlatformInit OpenObserve")
ensure_saml_provider(authorization_flow,invalidation_flow)
ensure_oauth2_provider(authorization_flow,invalidation_flow)
with open("/tmp/platforminit-openobserve-sso.env","w",encoding="utf-8") as fh:
    # OpenObserve builds the OIDC discovery URL from O2_DEX_BASE_URL.
    # Authentik's OpenID Configuration endpoint is application-scoped:
    #   /application/o/<application-slug>/.well-known/openid-configuration
    # Auth/token remain global Authentik OAuth2 endpoints, while JWKS is
    # application-scoped. Keep the relative suffixes explicit so the final
    # endpoints match Authentik's OAuth2 endpoint contract.
    openobserve_issuer_base=f"{authentik_public_host}/application/o/{openobserve_slug}"
    env={"O2_DEX_ENABLED":"true","O2_DEX_CLIENT_ID":openobserve_client_id,"O2_DEX_CLIENT_SECRET":openobserve_client_secret,"O2_DEX_BASE_URL":openobserve_issuer_base,"O2_DEX_AUTH_EP_SUFFIX":"/../authorize/","O2_DEX_TOKEN_EP_SUFFIX":"/../token/","O2_DEX_KEYS_EP_SUFFIX":"/jwks/","O2_DEX_REDIRECT_URL":f"{logs_host}/config/redirect","O2_CALLBACK_URL":f"{logs_host}/web/cb","O2_DEX_SCOPES":"openid profile email groups offline_access","O2_DEX_GROUP_ATTRIBUTE":"groups","O2_DEX_ROLE_ATTRIBUTE":"groups","O2_DEX_DEFAULT_ORG":"default"}
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
  # Zabbix/SimpleSAML requires a clean PEM certificate. Validate before storing it in Kubernetes.
  openssl x509 -in /tmp/platforminit-zabbix-idp.crt -noout -subject >/tmp/ch05-zabbix-idp-cert-check.txt 2>&1 || {
    cat /tmp/ch05-zabbix-idp-cert-check.txt >&2 || true
    die "Generated Authentik IdP certificate is not a valid PEM certificate"
  }
  cp /tmp/platforminit-zabbix-idp.crt /tmp/platforminit-zabbix-sp.crt
  kubectl -n "$NAMESPACE" create secret generic zabbix-saml-certs     --from-file=idp.crt=/tmp/platforminit-zabbix-idp.crt     --from-file=sp.crt=/tmp/platforminit-zabbix-sp.crt     --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Zabbix SAML certificate secret reconciled; zabbix-web will be restarted without waiting"
}

request_operations_runtime_restart(){
  log "Requesting non-blocking Operations runtime restart after SSO secret updates"
  # CH05.3 remains an identity binding workflow: it requests restarts but does not wait for rollout.
  # CH05.2 / CH05.4 are responsible for Argo CD health and readiness validation.
  kubectl -n "$NAMESPACE" rollout restart deployment/openobserve >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" rollout restart deployment/zabbix-web >/dev/null 2>&1 || true
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
# Mirror Authentik PlatformInit Operations users into Zabbix for SAML login.
# Local Admin remains break-glass. SAML login in Zabbix fails unless the
# incoming username already exists with a valid frontend role/group.
def load_saml_users():
    try:
        users=json.load(open("/tmp/platforminit-zabbix-users.json",encoding="utf-8"))
        if isinstance(users,list) and users:
            return users
    except Exception as exc:
        print(f"WARN: Could not read Authentik/Zabbix SAML user sync file: {exc}")
    return [{"username":bootstrap_user,"name":bootstrap_user,"email":""}]

def split_display_name(value, fallback):
    value=(value or "").strip()
    if not value or value == fallback:
        return "", fallback
    parts=value.split()
    if len(parts) == 1:
        return "", parts[0]
    return " ".join(parts[:-1]), parts[-1]

def ensure_zabbix_saml_users():
    groups=rpc("usergroup.get", {"output":["usrgrpid","name"],"filter":{"name":["Zabbix administrators"]}}, token) or []
    group=first(groups) or first(rpc("usergroup.get", {"output":["usrgrpid","name"],"search":{"name":"Admin"}}, token) or [])
    roles=rpc("role.get", {"output":["roleid","name","type"],"filter":{"name":["Super admin role"]}}, token) or []
    role=first(roles) or first([r for r in (rpc("role.get", {"output":["roleid","name","type"]}, token) or []) if str(r.get("type"))=="3" or "super" in str(r.get("name","")).lower()])
    if not group or not role:
        print("WARN: Could not find Zabbix admin group/role; SAML user sync was skipped")
        return
    for user in load_saml_users():
        username=(user.get("username") or "").strip()
        if not username:
            continue
        display_name=user.get("name") or username
        name,surname=split_display_name(display_name, username)
        existing=rpc("user.get", {"output":["userid","username","alias"],"filter":{"username":[username]}}, token) or []
        if not existing:
            try:
                existing=rpc("user.get", {"output":["userid","username","alias"],"filter":{"alias":[username]}}, token) or []
            except Exception:
                existing=[]
        payload={
            "username":username,
            "roleid":role["roleid"],
            "usrgrps":[{"usrgrpid":group["usrgrpid"]}],
            "name":name,
            "surname":surname,
        }
        if existing:
            userid=existing[0]["userid"]
            update_payload={"userid":userid,"roleid":role["roleid"],"usrgrps":[{"usrgrpid":group["usrgrpid"]}],"name":name,"surname":surname}
            rpc("user.update", update_payload, token)
            print(f"Updated Zabbix SAML user {username}")
        else:
            create_payload=dict(payload)
            create_payload["passwd"]=secrets.token_urlsafe(24)
            try:
                rpc("user.create", create_payload, token)
            except Exception:
                create_payload["alias"]=create_payload.pop("username")
                rpc("user.create", create_payload, token)
            print(f"Created Zabbix SAML user {username}")

try:
    ensure_zabbix_saml_users()
except Exception as exc:
    print(f"WARN: Zabbix SAML user reconciliation skipped: {exc}")

def api_version():
    try:
        return rpc("apiinfo.version")
    except Exception:
        return "unknown"

def ensure_saml_userdirectory():
    """Zabbix >= 6.4 stores SAML IdP details in userdirectory, not authentication.update."""
    payload={
        "idp_type":2,
        "name":"PlatformInit Authentik SAML",
        "idp_entityid":saml["idp_entityid"],
        "sso_url":saml["sso_url"],
        "slo_url":saml["slo_url"],
        "sp_entityid":saml["sp_entityid"],
        "username_attribute":saml["username_attribute"],
        "nameid_format":"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
        "sign_messages":0,
        "sign_assertions":0,
        "sign_authn_requests":0,
        "sign_logout_requests":0,
        "sign_logout_responses":0,
        "encrypt_nameid":0,
        "encrypt_assertions":0,
        "scim_status":0,
        "provision_status":0,
        "group_name":"groups",
        "user_username":"username",
        "user_lastname":"",
    }
    try:
        dirs=rpc("userdirectory.get", {"output":"extend"}, token) or []
    except Exception as exc:
        print(f"WARN: Zabbix userdirectory API unavailable; falling back to legacy authentication.update: {exc}")
        return None
    existing=None
    for item in dirs:
        if str(item.get("idp_type"))=="2" or item.get("name")==payload["name"]:
            existing=item
            break
    if existing:
        payload["userdirectoryid"]=existing["userdirectoryid"]
        try:
            rpc("userdirectory.update", payload, token)
        except Exception as exc:
            reduced={k:v for k,v in payload.items() if k not in {"group_name","user_username","user_lastname"}}
            rpc("userdirectory.update", reduced, token)
            print(f"WARN: Zabbix SAML user directory updated with reduced payload after full update failed: {exc}")
        print(f"Updated Zabbix SAML user directory userdirectoryid={existing['userdirectoryid']}")
        return existing["userdirectoryid"]
    try:
        result=rpc("userdirectory.create", payload, token)
    except Exception as exc:
        reduced={k:v for k,v in payload.items() if k not in {"name","group_name","user_username","user_lastname"}}
        result=rpc("userdirectory.create", reduced, token)
        print(f"WARN: Zabbix SAML user directory created with reduced payload after full create failed: {exc}")
    userdirectoryid=(result.get("userdirectoryids") or [None])[0]
    print(f"Created Zabbix SAML user directory userdirectoryid={userdirectoryid}")
    return userdirectoryid

version=api_version()
print(f"Detected Zabbix API version: {version}")
userdirectoryid=ensure_saml_userdirectory()
# In Zabbix 6.4+/7.x, authentication.update only toggles SAML on/off and global SAML options.
# IdP URLs/entity IDs live under userdirectory.*. Legacy saml_* IdP fields are only valid for older APIs.
for payload in (
    {"saml_auth_enabled":1,"saml_case_sensitive":0,"saml_jit_status":0},
    {"saml_auth_enabled":1,"saml_case_sensitive":0},
    {"saml_auth_enabled":1},
):
    try:
        rpc("authentication.update", payload, token)
        print(f"Enabled Zabbix SAML authentication with payload keys: {sorted(payload)}")
        break
    except Exception as exc:
        last_exc=exc
else:
    raise RuntimeError(f"Could not enable Zabbix SAML authentication: {last_exc}")
print("Zabbix SAML authentication configured")
PY
}


[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
ensure_cluster
need curl
need python3
need openssl
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
# Configure Zabbix through the currently healthy frontend before requesting any restart.
# Restarting first can invalidate the port-forward target and produce: network namespace is closed.
kubectl -n "$NAMESPACE" rollout status deployment/zabbix-web --timeout=90s >/dev/null || die "Zabbix web deployment is not ready before API configuration"
start_zabbix_api_port_forward
configure_zabbix_saml_api
request_operations_runtime_restart
log "Operations native SSO prerequisites applied; runtime resources remain Argo CD-owned"
kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null
