#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${NAMESPACE:-operations}"
ZABBIX_LOCAL_PORT="${ZABBIX_LOCAL_PORT:-18086}"
ZABBIX_API_URL="http://127.0.0.1:${ZABBIX_LOCAL_PORT}/api_jsonrpc.php"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-zabbix}"
PLATFORM_HOST_NAME="${PLATFORM_HOST_NAME:-platforminit-dev-01}"
ZABBIX_AGENT_ENDPOINT="${ZABBIX_AGENT_ENDPOINT:-zabbix-agent2.operations.svc.cluster.local}"
ZABBIX_AGENT_PORT="${ZABBIX_AGENT_PORT:-10050}"

export KUBECONFIG ZABBIX_API_URL ZABBIX_ADMIN_USER ZABBIX_ADMIN_PASSWORD PLATFORM_HOST_NAME ZABBIX_AGENT_ENDPOINT ZABBIX_AGENT_PORT

revision_matches(){
  local expected="$1"
  local actual="$2"
  [[ -z "$expected" ]] && return 0
  [[ -z "$actual" ]] && return 1
  [[ "$actual" == "$expected" ]] && return 0
  [[ "$actual" == "$expected"* ]] && return 0
  [[ "$expected" == "$actual"* ]] && return 0
  return 1
}

ensure_operations_stack_source_ready(){
  log "Checking Argo CD operations-stack source before Zabbix API provisioning"
  local app_json target_revision expected_revision
  app_json="$(kubectl -n argocd get application.argoproj.io operations-stack -o json 2>/dev/null)" || die "Missing Argo CD Application operations-stack. Run 05 - Register Operations Stack and 05.2 before 05.5."
  target_revision="$(printf '%s' "$app_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("source",{}).get("targetRevision", ""))')"
  expected_revision="${TARGET_REVISION:-}"
  if ! revision_matches "$expected_revision" "$target_revision"; then
    die "operations-stack targetRevision=${target_revision} does not match this artifact targetRevision=${expected_revision}. Run 05 - Register Operations Stack and 05.2 with the current 00 artifact before 05.5."
  fi
  APP_JSON="$app_json" python3 - <<'PY_APP_CHECK'
import json, os
app=json.loads(os.environ['APP_JSON'])
resources=app.get("status", {}).get("resources", []) or []
match=None
for r in resources:
    if r.get("kind") == "Service" and r.get("namespace") == "operations" and r.get("name") == "zabbix-agent2":
        match=r
        break
if not match:
    raise SystemExit("FATAL: zabbix-agent2 Service is not tracked by operations-stack. Run 05.2 after merging the Argo-owned zabbix-agent2 Service manifest; do not let 05.5 depend on an ad-hoc Service.")
status=match.get("status")
health=(match.get("health") or {}).get("status", "")
if status != "Synced":
    msg=match.get("message", "")
    raise SystemExit(f"FATAL: zabbix-agent2 Service is not Argo-owned/Synced: status={status} health={health} message={msg}")
print(f"PASS: zabbix-agent2 Service is Argo-tracked status={status} health={health or 'n/a'}")
PY_APP_CHECK
}

ZABBIX_PORT_FORWARD_PID=""
cleanup(){
  [[ -n "${ZABBIX_PORT_FORWARD_PID:-}" ]] && kill "${ZABBIX_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_zabbix_api_port_forward(){
  log "Starting temporary Zabbix API port-forward on 127.0.0.1:${ZABBIX_LOCAL_PORT}"
  kubectl -n "${NAMESPACE}" rollout status deployment/zabbix-web --timeout=120s >/dev/null
  kubectl -n "${NAMESPACE}" port-forward --address 127.0.0.1 svc/zabbix-web "${ZABBIX_LOCAL_PORT}:8080" >/tmp/ch05-5-zabbix-port-forward.log 2>&1 &
  ZABBIX_PORT_FORWARD_PID="$!"
  export ZABBIX_PORT_FORWARD_PID
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${ZABBIX_LOCAL_PORT}/api_jsonrpc.php" >/dev/null 2>&1 || curl -fsS "http://127.0.0.1:${ZABBIX_LOCAL_PORT}/" >/dev/null 2>&1; then
      log "Zabbix frontend/API is reachable"
      return 0
    fi
    sleep 2
  done
  cat /tmp/ch05-5-zabbix-port-forward.log >&2 || true
  die "Zabbix frontend/API was not reachable through port-forward"
}

provision_zabbix_operations_model(){
  log "Provisioning PlatformInit Zabbix operations model"
  python3 - <<'PY'
import json, os, urllib.request
api_url=os.environ["ZABBIX_API_URL"]
admin_user=os.environ.get("ZABBIX_ADMIN_USER","Admin")
admin_password=os.environ.get("ZABBIX_ADMIN_PASSWORD","zabbix")
host_name=os.environ.get("PLATFORM_HOST_NAME","platforminit-dev-01")
agent_endpoint=os.environ.get("ZABBIX_AGENT_ENDPOINT","zabbix-agent2.operations.svc.cluster.local")
agent_port=str(os.environ.get("ZABBIX_AGENT_PORT","10050"))

def rpc(method, params=None, auth=None):
    payload={"jsonrpc":"2.0","method":method,"params":params or {},"id":1}
    if auth:
        payload["auth"]=auth
    req=urllib.request.Request(api_url,data=json.dumps(payload).encode(),method="POST",headers={"Content-Type":"application/json-rpc"})
    with urllib.request.urlopen(req,timeout=45) as resp:
        result=json.loads(resp.read().decode())
    if "error" in result:
        raise RuntimeError(f"Zabbix API {method} failed: {result['error']}")
    return result.get("result")

def login():
    try:
        return rpc("user.login", {"username":admin_user,"password":admin_password})
    except Exception:
        return rpc("user.login", {"user":admin_user,"password":admin_password})

def ensure_hostgroup(name, token):
    found=rpc("hostgroup.get", {"output":["groupid","name"],"filter":{"name":[name]}}, token) or []
    if found:
        return found[0]["groupid"]
    result=rpc("hostgroup.create", {"name":name}, token)
    return result["groupids"][0]

def find_template(names, token):
    for name in names:
        for field in ("host","name"):
            found=rpc("template.get", {"output":["templateid","host","name"],"filter":{field:[name]}}, token) or []
            if found:
                return found[0]
    return None

def find_host(token):
    candidates=[host_name,"Zabbix server","Zabbix server docker"]
    for candidate in candidates:
        for field in ("host","name"):
            found=rpc("host.get", {"output":["hostid","host","name","status"],"selectInterfaces":"extend","selectParentTemplates":["templateid","host","name"],"filter":{field:[candidate]}}, token) or []
            if found:
                return found[0]
    return None

def ensure_agent_interface(host, token):
    interfaces=host.get("interfaces") or []
    agent=None
    for iface in interfaces:
        if str(iface.get("type")) == "1":
            agent=iface
            break
    if agent:
        rpc("hostinterface.update", {
            "interfaceid": agent["interfaceid"],
            "main": 1,
            "type": 1,
            "useip": 0,
            "ip": "",
            "dns": agent_endpoint,
            "port": agent_port,
        }, token)
        return agent["interfaceid"]
    result=rpc("hostinterface.create", {
        "hostid": host["hostid"],
        "main": 1,
        "type": 1,
        "useip": 0,
        "ip": "",
        "dns": agent_endpoint,
        "port": agent_port,
    }, token)
    return result["interfaceids"][0]

def ensure_host(token):
    groups=[
        {"groupid": ensure_hostgroup("PlatformInit / Hosts", token)},
        {"groupid": ensure_hostgroup("PlatformInit / Operations", token)},
    ]
    template=find_template(["Linux by Zabbix agent","Template OS Linux by Zabbix agent","Linux by Zabbix agent active"], token)
    templates=[{"templateid":template["templateid"]}] if template else []
    host=find_host(token)
    tags=[
        {"tag":"platforminit","value":"true"},
        {"tag":"component","value":"host"},
        {"tag":"service","value":"platforminit-dev"},
        {"tag":"scope","value":"availability"},
    ]
    inventory={"type":"PlatformInit single-node host","name":host_name}
    if not host:
        payload={
            "host": host_name,
            "name": host_name,
            "groups": groups,
            "interfaces": [{"type":1,"main":1,"useip":0,"ip":"","dns":agent_endpoint,"port":agent_port}],
            "tags": tags,
            "inventory_mode": 1,
            "inventory": inventory,
        }
        if templates:
            payload["templates"]=templates
        result=rpc("host.create", payload, token)
        hostid=result["hostids"][0]
        print(f"Created PlatformInit host {host_name} hostid={hostid} agent={agent_endpoint}:{agent_port}")
        return rpc("host.get", {"output":["hostid","host","name"],"selectInterfaces":"extend","filter":{"host":[host_name]}}, token)[0]
    hostid=host["hostid"]
    update={
        "hostid": hostid,
        "host": host_name,
        "name": host_name,
        "status": 0,
        "groups": groups,
        "tags": tags,
        "inventory_mode": 1,
        "inventory": inventory,
    }
    if templates:
        update["templates"] = templates
    rpc("host.update", update, token)
    refreshed=rpc("host.get", {"output":["hostid","host","name"],"selectInterfaces":"extend","filter":{"host":[host_name]}}, token)
    if not refreshed:
        refreshed=rpc("host.get", {"output":["hostid","host","name"],"selectInterfaces":"extend","hostids":[hostid]}, token)
    host=refreshed[0]
    ensure_agent_interface(host, token)
    print(f"Updated PlatformInit host {host_name} hostid={hostid} agent={agent_endpoint}:{agent_port}")
    return host

def ensure_problem_dashboard(token):
    name="PlatformInit - Operations Overview"
    try:
        existing=rpc("dashboard.get", {"output":["dashboardid","name"],"filter":{"name":[name]}}, token) or []
        if existing:
            print(f"Dashboard already exists: {name}")
        else:
            print("Dashboard provisioning intentionally deferred until the host/agent baseline is stable")
    except Exception as exc:
        print(f"WARN: dashboard check skipped: {exc}")

token=login()
version=rpc("apiinfo.version")
print(f"Detected Zabbix API version: {version}")
ensure_host(token)
ensure_problem_dashboard(token)
print("PlatformInit Zabbix operations model provisioned")
PY
}

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
need kubectl
need curl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl -n "$NAMESPACE" get deploy/zabbix-web deploy/zabbix-server >/dev/null
ensure_operations_stack_source_ready
kubectl -n "$NAMESPACE" get service zabbix-agent2 >/dev/null || die "Missing zabbix-agent2 Service. Run 05.2 after merging the updated manifest."
start_zabbix_api_port_forward
provision_zabbix_operations_model
log "Zabbix Operations Model provisioning finished"
