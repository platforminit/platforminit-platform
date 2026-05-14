#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${NAMESPACE:-operations}"
ZABBIX_LOCAL_PORT="${ZABBIX_LOCAL_PORT:-18087}"
ZABBIX_API_URL="http://127.0.0.1:${ZABBIX_LOCAL_PORT}/api_jsonrpc.php"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-zabbix}"
PLATFORM_HOST_NAME="${PLATFORM_HOST_NAME:-platforminit-dev-01}"
ZABBIX_AGENT_ENDPOINT="${ZABBIX_AGENT_ENDPOINT:-zabbix-agent2.operations.svc.cluster.local}"
export KUBECONFIG ZABBIX_API_URL ZABBIX_ADMIN_USER ZABBIX_ADMIN_PASSWORD PLATFORM_HOST_NAME ZABBIX_AGENT_ENDPOINT
PF=""
cleanup(){ [[ -n "${PF:-}" ]] && kill "$PF" >/dev/null 2>&1 || true; }
trap cleanup EXIT
need kubectl
need curl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl -n "$NAMESPACE" get service zabbix-agent2 >/dev/null || die "Missing operations/zabbix-agent2 Service"
kubectl -n "$NAMESPACE" rollout status daemonset/zabbix-agent2 --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/zabbix-web --timeout=120s >/dev/null
DS_JSON="$(kubectl -n "$NAMESPACE" get daemonset/zabbix-agent2 -o json)" python3 - <<'PY_DS_CHECK'
import json, os
obj=json.loads(os.environ["DS_JSON"])
containers=obj.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
agent=next((c for c in containers if c.get("name") == "zabbix-agent2"), None)
if not agent: raise SystemExit("FATAL: zabbix-agent2 container is missing from DaemonSet")
env={e.get("name"): e.get("value", "<fieldRef>") for e in agent.get("env", [])}
expected={"ZBX_ACTIVE_ALLOW":"true","ZBX_ACTIVESERVERS":"zabbix-server.operations.svc.cluster.local:10051","ZBX_PASSIVE_ALLOW":"false"}
for key, value in expected.items():
    if env.get(key) != value: raise SystemExit(f"FATAL: {key} mismatch: expected={value!r} actual={env.get(key)!r}")
print("PASS: zabbix-agent2 DaemonSet active-check contract is present")
PY_DS_CHECK
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/zabbix-web "${ZABBIX_LOCAL_PORT}:8080" >/tmp/ch05-5-validate-zabbix-port-forward.log 2>&1 &
PF="$!"
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${ZABBIX_LOCAL_PORT}/" >/dev/null 2>&1 && break
  sleep 2
done
python3 - <<'PY'
import json, os, time, urllib.request
api_url=os.environ["ZABBIX_API_URL"]
admin_user=os.environ.get("ZABBIX_ADMIN_USER","Admin")
admin_password=os.environ.get("ZABBIX_ADMIN_PASSWORD","zabbix")
host_name=os.environ.get("PLATFORM_HOST_NAME","platforminit-dev-01")
agent_endpoint=os.environ.get("ZABBIX_AGENT_ENDPOINT","zabbix-agent2.operations.svc.cluster.local")
required_groups={"PlatformInit / Hosts","PlatformInit / Kubernetes","PlatformInit / Applications","PlatformInit / Security","PlatformInit / Storage","PlatformInit / Operations"}
required_active_items={"agent.ping","system.hostname","system.uptime","system.cpu.load[all,avg1]","vm.memory.size[pavailable]","vfs.fs.size[/host-root,pused]","vfs.fs.size[/srv/data/k3s,pused]","vfs.fs.size[/srv/data/k3s/storage,pused]","vfs.fs.size[/srv/observability/data,pused]","net.tcp.service[ssh,127.0.0.1,22]","net.tcp.service[tcp,127.0.0.1,6443]","net.tcp.service[tcp,zabbix-server.operations.svc.cluster.local,10051]","net.tcp.service[tcp,openobserve.operations.svc.cluster.local,5080]","net.tcp.service[tcp,argocd-server.argocd.svc.cluster.local,80]","net.tcp.service[tcp,authentik-server.identity.svc.cluster.local,80]"}
first_data_keys={"agent.ping","system.hostname","system.cpu.load[all,avg1]","vm.memory.size[pavailable]","vfs.fs.size[/srv/data/k3s,pused]","vfs.fs.size[/srv/observability/data,pused]"}
def rpc(method,params=None,auth=None):
    payload={"jsonrpc":"2.0","method":method,"params":params or {},"id":1}
    if auth: payload["auth"]=auth
    req=urllib.request.Request(api_url,data=json.dumps(payload).encode(),method="POST",headers={"Content-Type":"application/json-rpc"})
    with urllib.request.urlopen(req,timeout=30) as resp: result=json.loads(resp.read().decode())
    if "error" in result: raise RuntimeError(f"{method}: {result['error']}")
    return result.get("result")
def login():
    try: return rpc("user.login", {"username":admin_user,"password":admin_password})
    except Exception: return rpc("user.login", {"user":admin_user,"password":admin_password})
def get_host(token):
    hosts=rpc("host.get", {"output":["hostid","host","name","status"],"selectInterfaces":"extend","selectTags":"extend","selectGroups":["name"],"selectParentTemplates":["host","name"],"filter":{"host":[host_name]}}, token) or []
    if not hosts: raise SystemExit(f"FATAL: Zabbix host {host_name!r} is missing")
    return hosts[0]
def get_items(token, hostid): return rpc("item.get", {"output":["itemid","key_","name","type","lastvalue","lastclock"],"hostids":[hostid]}, token) or []
token=login(); host=get_host(token); hostid=host["hostid"]
agent=[i for i in (host.get("interfaces") or []) if str(i.get("type"))=="1"]
if not agent: raise SystemExit(f"FATAL: Zabbix host {host_name!r} has no agent interface")
iface=agent[0]
if str(iface.get("dns")) != agent_endpoint or str(iface.get("useip")) != "0" or str(iface.get("port")) != "10050":
    raise SystemExit(f"FATAL: Zabbix agent interface mismatch: dns={iface.get('dns')} useip={iface.get('useip')} port={iface.get('port')}")
print(f"PASS: Zabbix host {host_name} keeps inventory agent endpoint {agent_endpoint}:10050")
missing_groups=required_groups-{g.get("name") for g in host.get("groups", [])}
if missing_groups: raise SystemExit(f"FATAL: missing PlatformInit host groups: {sorted(missing_groups)}")
print("PASS: PlatformInit host groups are present")
parent_templates=host.get("parentTemplates") or []
noisy=[t for t in parent_templates if "Linux by Zabbix agent" in (t.get("host") or t.get("name") or "") and "active" not in (t.get("host") or t.get("name") or "").lower()]
if noisy: raise SystemExit(f"FATAL: passive Linux template still linked: {noisy}")
print("PASS: passive Linux template noise is not linked")
items=get_items(token, hostid); by_key={i["key_"]:i for i in items}
missing=required_active_items-set(by_key)
if missing: raise SystemExit(f"FATAL: missing active items: {sorted(missing)}")
wrong_type=[key for key in required_active_items if str(by_key[key].get("type")) != "7"]
if wrong_type: raise SystemExit(f"FATAL: items are not active-agent type=7: {wrong_type}")
print(f"PASS: {len(required_active_items)} PlatformInit active items exist")
deadline=time.time()+240
while True:
    items=get_items(token, hostid); by_key={i["key_"]:i for i in items}; missing_data=[]; now=int(time.time())
    for key in first_data_keys:
        item=by_key.get(key); lastclock=int(item.get("lastclock") or 0) if item else 0; lastvalue=str(item.get("lastvalue", "")) if item else ""
        if lastclock <= 0 or now-lastclock > 900 or lastvalue == "": missing_data.append(key)
    if not missing_data: break
    if time.time() >= deadline:
        detail={key:{"lastclock":by_key.get(key,{}).get("lastclock"),"lastvalue":by_key.get(key,{}).get("lastvalue")} for key in sorted(missing_data)}
        raise SystemExit(f"FATAL: active agent data did not arrive for required baseline items: {json.dumps(detail, sort_keys=True)}")
    print(f"WAIT: active data not ready yet for {sorted(missing_data)}"); time.sleep(15)
print("PASS: active agent baseline data is arriving")
if str(by_key["agent.ping"].get("lastvalue")) != "1": raise SystemExit(f"FATAL: agent.ping lastvalue expected 1, got {by_key['agent.ping'].get('lastvalue')!r}")
hostname=str(by_key["system.hostname"].get("lastvalue"))
if hostname != host_name: raise SystemExit(f"FATAL: system.hostname expected {host_name!r}, got {hostname!r}")
print(f"PASS: agent.ping=1 and system.hostname={hostname}")
print("PASS: Zabbix Operations Model validation completed")
PY
