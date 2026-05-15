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
for kind, name in (("Service", "zabbix-agent2"), ("DaemonSet", "zabbix-agent2")):
    match=None
    for r in resources:
        if r.get("kind") == kind and r.get("namespace") == "operations" and r.get("name") == name:
            match=r
            break
    if not match:
        raise SystemExit(f"FATAL: {kind}/{name} is not tracked by operations-stack. Run 05.2 after merging the Argo-owned zabbix-agent2 manifest; do not let 05.5 depend on an ad-hoc runtime patch.")
    status=match.get("status")
    health=(match.get("health") or {}).get("status", "")
    if status != "Synced":
        msg=match.get("message", "")
        raise SystemExit(f"FATAL: {kind}/{name} is not Argo-owned/Synced: status={status} health={health} message={msg}")
    print(f"PASS: {kind}/{name} is Argo-tracked status={status} health={health or 'n/a'}")
PY_APP_CHECK
}

ZABBIX_PORT_FORWARD_PID=""
cleanup(){ [[ -n "${ZABBIX_PORT_FORWARD_PID:-}" ]] && kill "${ZABBIX_PORT_FORWARD_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT


wait_for_agent_daemonset(){
  log "Waiting for zabbix-agent2 DaemonSet rollout"
  if kubectl -n "$NAMESPACE" rollout status daemonset/zabbix-agent2 --timeout=180s >/dev/null; then
    log "zabbix-agent2 DaemonSet rollout completed"
    return 0
  fi
  echo "WARN: zabbix-agent2 DaemonSet rollout did not complete within timeout; collecting diagnostics" >&2
  kubectl -n "$NAMESPACE" get daemonset/zabbix-agent2 -o wide >&2 || true
  kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=zabbix-agent2 -o wide >&2 || true
  kubectl -n "$NAMESPACE" describe daemonset/zabbix-agent2 >&2 || true
  kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name=zabbix-agent2 --all-containers=true --tail=120 --prefix=true >&2 || true
  die "zabbix-agent2 DaemonSet did not become ready. Check the diagnostics above before provisioning the Zabbix API model."
}

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

assert_agent_active_mode(){
  log "Checking zabbix-agent2 active-mode DaemonSet contract"
  wait_for_agent_daemonset
  local ds_json
  ds_json="$(kubectl -n "$NAMESPACE" get daemonset/zabbix-agent2 -o json)"
  DS_JSON="$ds_json" python3 - <<'PY_DS_CHECK'
import json, os
obj=json.loads(os.environ["DS_JSON"])
containers=obj.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
agent=next((c for c in containers if c.get("name") == "zabbix-agent2"), None)
if not agent:
    raise SystemExit("FATAL: zabbix-agent2 container is missing from DaemonSet")
env={e.get("name"): e.get("value", "<fieldRef>") for e in agent.get("env", [])}
expected={"ZBX_ACTIVE_ALLOW":"true","ZBX_ACTIVESERVERS":"zabbix-server.operations.svc.cluster.local:10051","ZBX_PASSIVE_ALLOW":"false"}
if "ZBX_SERVER_HOST" in env:
    raise SystemExit("FATAL: ZBX_SERVER_HOST must not be set in active-agent-only mode; use ZBX_ACTIVESERVERS only")
for key, value in expected.items():
    if env.get(key) != value:
        raise SystemExit(f"FATAL: {key} mismatch: expected={value!r} actual={env.get(key)!r}")
print("PASS: zabbix-agent2 DaemonSet is configured for active checks")
PY_DS_CHECK
}

provision_zabbix_operations_model(){
  log "Provisioning PlatformInit active Zabbix operations model"
  python3 - <<'PY'
import json, os, urllib.request
api_url=os.environ["ZABBIX_API_URL"]
admin_user=os.environ.get("ZABBIX_ADMIN_USER","Admin")
admin_password=os.environ.get("ZABBIX_ADMIN_PASSWORD","zabbix")
host_name=os.environ.get("PLATFORM_HOST_NAME","platforminit-dev-01")
agent_endpoint=os.environ.get("ZABBIX_AGENT_ENDPOINT","zabbix-agent2.operations.svc.cluster.local")
agent_port=str(os.environ.get("ZABBIX_AGENT_PORT","10050"))

HOST_GROUPS = ["PlatformInit / Hosts","PlatformInit / Kubernetes","PlatformInit / Applications","PlatformInit / Security","PlatformInit / Storage","PlatformInit / Operations"]
ITEMS = [
    {"key":"agent.ping", "name":"Host availability", "type":7, "value_type":3, "delay":"30s", "tags":{"component":"Host","service":"Agent health"}},
    {"key":"system.hostname", "name":"System hostname", "type":7, "value_type":1, "delay":"5m", "tags":{"component":"Host","service":"Inventory"}},
    {"key":"system.uptime", "name":"System uptime", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Host","service":"Uptime"}},
    {"key":"system.cpu.load[all,avg1]", "name":"CPU load average 1m", "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Host","service":"CPU"}},
    {"key":"vm.memory.size[pavailable]", "name":"Memory available percentage", "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Host","service":"Memory"}},
    {"key":"vfs.fs.size[/host-root,pused]", "name":"Root filesystem usage (/)" , "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Storage","service":"Root filesystem","path":"/"}},
    {"key":"vfs.fs.size[/srv/data/k3s,pused]", "name":"Kubernetes runtime storage usage (/srv/data/k3s)", "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Storage","service":"Kubernetes runtime storage","path":"/srv/data/k3s"}},
    {"key":"vfs.fs.size[/srv/data/k3s/storage,pused]", "name":"Kubernetes PVC storage usage (/srv/data/k3s/storage)", "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Storage","service":"Kubernetes PVC storage","path":"/srv/data/k3s/storage"}},
    {"key":"vfs.fs.size[/srv/observability/data,pused]", "name":"Observability storage usage (/srv/observability/data)", "type":7, "value_type":0, "delay":"1m", "tags":{"component":"Storage","service":"Observability storage","path":"/srv/observability/data"}},
    {"key":"vfs.fs.size[/srv/platforminit,pused]", "name":"Platform runtime artifacts usage (/srv/platforminit)", "type":7, "value_type":0, "delay":"5m", "tags":{"component":"Storage","service":"Platform runtime artifacts","path":"/srv/platforminit"}},
    {"key":"net.tcp.service[ssh,127.0.0.1,22]", "name":"SSH availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Security","service":"SSH"}},
    {"key":"net.tcp.service[tcp,127.0.0.1,6443]", "name":"Kubernetes API availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Kubernetes","service":"Kubernetes API"}},
    {"key":"net.tcp.service[tcp,zabbix-server.operations.svc.cluster.local,10051]", "name":"Zabbix server trapper availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Monitoring","service":"Zabbix server"}},
    {"key":"net.tcp.service[tcp,openobserve.operations.svc.cluster.local,5080]", "name":"OpenObserve service availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Logs","service":"OpenObserve"}},
    {"key":"net.tcp.service[tcp,argocd-server.argocd.svc.cluster.local,80]", "name":"Argo CD WebUI service availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"GitOps","service":"Argo CD WebUI"}},
    {"key":"net.tcp.service[tcp,authentik-server.identity.svc.cluster.local,80]", "name":"Authentik WebUI service availability", "type":7, "value_type":3, "delay":"1m", "tags":{"component":"Identity","service":"Authentik WebUI"}},
]
TRIGGERS = [
    {"description":"Host availability data is stale", "expression":f"nodata(/{host_name}/agent.ping,5m)=1", "priority":4, "comments":"No active agent data has arrived recently. Check zabbix-agent2 DaemonSet logs and active server connectivity to zabbix-server:10051.", "tags":{"component":"Host","service":"Agent health","state":"CRITICAL"}},
    {"description":"SSH availability failed", "expression":f"max(/{host_name}/net.tcp.service[ssh,127.0.0.1,22],3m)=0", "priority":4, "comments":"SSH on the PlatformInit host is not reachable from the host-network agent. Check sshd, UFW and host access baseline.", "tags":{"component":"Security","service":"SSH","state":"CRITICAL"}},
    {"description":"Kubernetes API availability failed", "expression":f"max(/{host_name}/net.tcp.service[tcp,127.0.0.1,6443],3m)=0", "priority":4, "comments":"The local k3s API port is not reachable. Check k3s service status and /srv/data/k3s runtime data.", "tags":{"component":"Kubernetes","service":"Kubernetes API","state":"CRITICAL"}},
    {"description":"Zabbix server trapper unavailable", "expression":f"max(/{host_name}/net.tcp.service[tcp,zabbix-server.operations.svc.cluster.local,10051],3m)=0", "priority":4, "comments":"The agent cannot reach the Zabbix server active-check/trapper endpoint inside the operations namespace.", "tags":{"component":"Monitoring","service":"Zabbix server","state":"CRITICAL"}},
    {"description":"OpenObserve service unavailable", "expression":f"max(/{host_name}/net.tcp.service[tcp,openobserve.operations.svc.cluster.local,5080],3m)=0", "priority":3, "comments":"OpenObserve service is not reachable from the operations agent. Check OpenObserve deployment, service and storage.", "tags":{"component":"Logs","service":"OpenObserve","state":"CRITICAL"}},
    {"description":"Argo CD WebUI service unavailable", "expression":f"max(/{host_name}/net.tcp.service[tcp,argocd-server.argocd.svc.cluster.local,80],3m)=0", "priority":3, "comments":"Argo CD WebUI service is not reachable from the operations agent. Check argocd-server rollout and service.", "tags":{"component":"GitOps","service":"Argo CD WebUI","state":"CRITICAL"}},
    {"description":"Authentik WebUI service unavailable", "expression":f"max(/{host_name}/net.tcp.service[tcp,authentik-server.identity.svc.cluster.local,80],3m)=0", "priority":3, "comments":"Authentik WebUI service is not reachable from the operations agent. Check identity namespace runtime and service.", "tags":{"component":"Identity","service":"Authentik WebUI","state":"CRITICAL"}},
    {"description":"Root filesystem usage high", "expression":f"min(/{host_name}/vfs.fs.size[/host-root,pused],5m)>85", "priority":2, "comments":"Root filesystem usage is above 85%. Check package/cache growth and host baseline artifacts.", "tags":{"component":"Storage","service":"Root filesystem","path":"/","state":"WARNING"}},
    {"description":"Root filesystem usage critical", "expression":f"min(/{host_name}/vfs.fs.size[/host-root,pused],5m)>95", "priority":4, "comments":"Root filesystem usage is above 95%. Free space before kubelet/container runtime instability occurs.", "tags":{"component":"Storage","service":"Root filesystem","path":"/","state":"CRITICAL"}},
    {"description":"Kubernetes runtime storage usage high", "expression":f"min(/{host_name}/vfs.fs.size[/srv/data/k3s,pused],5m)>80", "priority":2, "comments":"/srv/data/k3s is above 80%. Check k3s runtime data, image/cache growth and local-path storage consumers.", "tags":{"component":"Storage","service":"Kubernetes runtime storage","path":"/srv/data/k3s","state":"WARNING"}},
    {"description":"Kubernetes runtime storage usage critical", "expression":f"min(/{host_name}/vfs.fs.size[/srv/data/k3s,pused],5m)>90", "priority":4, "comments":"/srv/data/k3s is above 90%. Kubernetes runtime may become unstable if the volume fills up.", "tags":{"component":"Storage","service":"Kubernetes runtime storage","path":"/srv/data/k3s","state":"CRITICAL"}},
    {"description":"Kubernetes PVC storage usage high", "expression":f"min(/{host_name}/vfs.fs.size[/srv/data/k3s/storage,pused],5m)>80", "priority":2, "comments":"/srv/data/k3s/storage is above 80%. Check local-path PVC consumers.", "tags":{"component":"Storage","service":"Kubernetes PVC storage","path":"/srv/data/k3s/storage","state":"WARNING"}},
    {"description":"Kubernetes PVC storage usage critical", "expression":f"min(/{host_name}/vfs.fs.size[/srv/data/k3s/storage,pused],5m)>90", "priority":4, "comments":"/srv/data/k3s/storage is above 90%. PVC-backed workloads may fail writes.", "tags":{"component":"Storage","service":"Kubernetes PVC storage","path":"/srv/data/k3s/storage","state":"CRITICAL"}},
    {"description":"Observability storage usage high", "expression":f"min(/{host_name}/vfs.fs.size[/srv/observability/data,pused],5m)>80", "priority":2, "comments":"/srv/observability/data is above 80%. Check Zabbix PostgreSQL, OpenObserve and Vector storage growth.", "tags":{"component":"Storage","service":"Observability storage","path":"/srv/observability/data","state":"WARNING"}},
    {"description":"Observability storage usage critical", "expression":f"min(/{host_name}/vfs.fs.size[/srv/observability/data,pused],5m)>90", "priority":4, "comments":"/srv/observability/data is above 90%. Zabbix/OpenObserve writes may fail soon.", "tags":{"component":"Storage","service":"Observability storage","path":"/srv/observability/data","state":"CRITICAL"}},
    {"description":"Memory available low", "expression":f"max(/{host_name}/vm.memory.size[pavailable],5m)<10", "priority":2, "comments":"Available memory is below 10%. Check k3s workloads and operations stack resource pressure.", "tags":{"component":"Host","service":"Memory","state":"WARNING"}},
    {"description":"CPU load high", "expression":f"min(/{host_name}/system.cpu.load[all,avg1],5m)>6", "priority":2, "comments":"CPU load is high for the single-node PlatformInit host. Check noisy workloads and operations stack pods.", "tags":{"component":"Host","service":"CPU","state":"WARNING"}},
]

def rpc(method, params=None, auth=None):
    payload={"jsonrpc":"2.0","method":method,"params":params or {},"id":1}
    if auth: payload["auth"]=auth
    req=urllib.request.Request(api_url,data=json.dumps(payload).encode(),method="POST",headers={"Content-Type":"application/json-rpc"})
    with urllib.request.urlopen(req,timeout=45) as resp: result=json.loads(resp.read().decode())
    if "error" in result: raise RuntimeError(f"Zabbix API {method} failed: {result['error']}")
    return result.get("result")
def login():
    try: return rpc("user.login", {"username":admin_user,"password":admin_password})
    except Exception: return rpc("user.login", {"user":admin_user,"password":admin_password})
def tags(payload): return [{"tag": k, "value": v} for k, v in payload.items()]
def ensure_hostgroup(name, token):
    found=rpc("hostgroup.get", {"output":["groupid","name"],"filter":{"name":[name]}}, token) or []
    if found: return found[0]["groupid"]
    return rpc("hostgroup.create", {"name":name}, token)["groupids"][0]
def get_host(token):
    found=rpc("host.get", {"output":["hostid","host","name","status"],"selectInterfaces":"extend","selectParentTemplates":["templateid","host","name"],"filter":{"host":[host_name]}}, token) or []
    return found[0] if found else None
def ensure_agent_interface(host, token):
    agent=next((i for i in (host.get("interfaces") or []) if str(i.get("type")) == "1"), None)
    payload={"main":1,"type":1,"useip":0,"ip":"","dns":agent_endpoint,"port":agent_port}
    if agent:
        payload["interfaceid"]=agent["interfaceid"]
        rpc("hostinterface.update", payload, token)
        return agent["interfaceid"]
    payload["hostid"]=host["hostid"]
    return rpc("hostinterface.create", payload, token)["interfaceids"][0]
def clear_parent_templates(host, token):
    templates=host.get("parentTemplates") or []
    if not templates:
        print("PASS: host has no linked default templates to clear")
        return
    rpc("host.update", {"hostid": host["hostid"], "templates_clear": [{"templateid": t["templateid"]} for t in templates]}, token)
    print("Cleared linked templates from PlatformInit host to avoid default Zabbix noise: " + ", ".join(t.get("host") or t.get("name") or t["templateid"] for t in templates))
def ensure_host(token):
    group_refs=[{"groupid": ensure_hostgroup(name, token)} for name in HOST_GROUPS]
    host_tags=tags({"platforminit":"true","component":"host","service":"platforminit-dev","scope":"operations","check_model":"active-agent"})
    inventory={"type":"PlatformInit single-node host","name":host_name}
    host=get_host(token)
    if not host:
        payload={"host":host_name,"name":host_name,"groups":group_refs,"interfaces":[{"type":1,"main":1,"useip":0,"ip":"","dns":agent_endpoint,"port":agent_port}],"tags":host_tags,"inventory_mode":1,"inventory":inventory}
        hostid=rpc("host.create", payload, token)["hostids"][0]
        print(f"Created PlatformInit host {host_name} hostid={hostid} active_model=true")
        return get_host(token)
    rpc("host.update", {"hostid":host["hostid"],"host":host_name,"name":host_name,"status":0,"groups":group_refs,"tags":host_tags,"inventory_mode":1,"inventory":inventory}, token)
    host=get_host(token)
    ensure_agent_interface(host, token)
    clear_parent_templates(host, token)
    print(f"Updated PlatformInit host {host_name} hostid={host['hostid']} active_model=true")
    return get_host(token)
def get_item(hostid, key, token):
    found=rpc("item.get", {"output":["itemid","key_","name","type","value_type"],"hostids":[hostid],"filter":{"key_":[key]}}, token) or []
    return found[0] if found else None
def ensure_item(hostid, spec, token):
    existing=get_item(hostid, spec["key"], token)
    payload={"name":spec["name"],"key_":spec["key"],"type":spec["type"],"value_type":spec["value_type"],"delay":spec["delay"],"status":0,"history":"14d","trends":"90d" if spec["value_type"] in (0,3) else "0","tags":tags(spec.get("tags",{}))}
    if existing:
        update={k:v for k,v in payload.items() if k not in ("key_","type","value_type")}
        update["itemid"]=existing["itemid"]
        try:
            rpc("item.update", update, token)
            print(f"Updated active item: {spec['name']} [{spec['key']}]")
        except Exception as exc:
            print(f"WARN: item update skipped for {spec['key']}: {exc}")
        return existing["itemid"]
    payload["hostid"]=hostid
    itemid=rpc("item.create", payload, token)["itemids"][0]
    print(f"Created active item: {spec['name']} [{spec['key']}] itemid={itemid}")
    return itemid
def ensure_trigger(hostid, spec, token):
    found=rpc("trigger.get", {"output":["triggerid","description"],"hostids":[hostid],"filter":{"description":[spec["description"]]}}, token) or []
    payload={"description":spec["description"],"expression":spec["expression"],"priority":spec["priority"],"status":0,"comments":spec.get("comments",""),"tags":tags(spec.get("tags",{}))}
    if found:
        payload["triggerid"]=found[0]["triggerid"]
        rpc("trigger.update", payload, token)
        print(f"Updated trigger: {spec['description']}")
        return found[0]["triggerid"]
    triggerid=rpc("trigger.create", payload, token)["triggerids"][0]
    print(f"Created trigger: {spec['description']} triggerid={triggerid}")
    return triggerid
def widget_field(field_type, name, value):
    return {"type": field_type, "name": name, "value": value}

def problems_widget(name, x, y, width, height, hostid, severities=None, tag_filter=None):
    fields=[
        widget_field(0,"rf_rate",60),
        widget_field(0,"show",3),
        widget_field(3,"hostids.0",hostid),
        widget_field(0,"show_tags",3),
        widget_field(0,"tag_name_format",1),
        widget_field(1,"tag_priority","component,service,path,state"),
    ]
    for idx, severity in enumerate(severities or []):
        fields.append(widget_field(0,f"severities.{idx}",severity))
    if tag_filter:
        fields.extend([
            widget_field(0,"evaltype",0),
            widget_field(1,"tags.0.tag",tag_filter[0]),
            widget_field(0,"tags.0.operator",1),
            widget_field(1,"tags.0.value",tag_filter[1]),
        ])
    return {"type":"problems","name":name,"x":x,"y":y,"width":width,"height":height,"fields":fields}

def ensure_problem_dashboard(token, hostid):
    """Create a curated operator landing page instead of relying on the noisy default dashboard."""
    name="PlatformInit - Operations Overview"
    pages=[{
        "name":"Operations",
        "widgets":[
            problems_widget("Current critical problems",0,0,36,8,hostid,[4,5]),
            problems_widget("Current warnings",36,0,36,8,hostid,[2,3]),
            problems_widget("Storage status",0,8,36,8,hostid,[2,3,4,5],("component","Storage")),
            problems_widget("Platform service status",36,8,36,8,hostid,[2,3,4,5]),
            problems_widget("Recent problems / changes",0,16,72,8,hostid,[0,1,2,3,4,5]),
        ],
    }]
    existing=rpc("dashboard.get", {"output":["dashboardid","name"],"filter":{"name":[name]}}, token) or []
    payload={"name":name,"private":0,"pages":pages}
    if existing:
        payload["dashboardid"]=existing[0]["dashboardid"]
        rpc("dashboard.update", payload, token)
        print(f"Updated dashboard: {name}")
    else:
        dashboardid=rpc("dashboard.create", payload, token)["dashboardids"][0]
        print(f"Created dashboard: {name} dashboardid={dashboardid}")

token=login()
print(f"Detected Zabbix API version: {rpc('apiinfo.version')}")
host=ensure_host(token)
hostid=host["hostid"]
for item in ITEMS: ensure_item(hostid, item, token)
for trigger in TRIGGERS: ensure_trigger(hostid, trigger, token)
ensure_problem_dashboard(token, hostid)
print("PlatformInit active Zabbix operations model provisioned")
PY
}

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
need kubectl
need curl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl -n "$NAMESPACE" get deploy/zabbix-web deploy/zabbix-server daemonset/zabbix-agent2 >/dev/null
ensure_operations_stack_source_ready
kubectl -n "$NAMESPACE" get service zabbix-agent2 >/dev/null || die "Missing zabbix-agent2 Service. Run 05.2 after merging the updated manifest."
assert_agent_active_mode
start_zabbix_api_port_forward
provision_zabbix_operations_model
log "Zabbix Operations Model provisioning finished"
