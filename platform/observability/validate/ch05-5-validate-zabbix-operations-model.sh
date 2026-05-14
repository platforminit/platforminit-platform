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
kubectl -n "$NAMESPACE" rollout status deployment/zabbix-web --timeout=120s >/dev/null
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/zabbix-web "${ZABBIX_LOCAL_PORT}:8080" >/tmp/ch05-5-validate-zabbix-port-forward.log 2>&1 &
PF="$!"
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${ZABBIX_LOCAL_PORT}/" >/dev/null 2>&1 && break
  sleep 2
done
python3 - <<'PY'
import json, os, urllib.request
api_url=os.environ["ZABBIX_API_URL"]
admin_user=os.environ.get("ZABBIX_ADMIN_USER","Admin")
admin_password=os.environ.get("ZABBIX_ADMIN_PASSWORD","zabbix")
host_name=os.environ.get("PLATFORM_HOST_NAME","platforminit-dev-01")
agent_endpoint=os.environ.get("ZABBIX_AGENT_ENDPOINT","zabbix-agent2.operations.svc.cluster.local")
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
token=login()
hosts=rpc("host.get", {"output":["hostid","host","name","status"],"selectInterfaces":"extend","selectTags":"extend","filter":{"host":[host_name]}}, token) or []
if not hosts:
    raise SystemExit(f"FATAL: Zabbix host {host_name!r} is missing")
host=hosts[0]
interfaces=host.get("interfaces") or []
agent=[i for i in interfaces if str(i.get("type"))=="1"]
if not agent:
    raise SystemExit(f"FATAL: Zabbix host {host_name!r} has no agent interface")
iface=agent[0]
if str(iface.get("dns")) != agent_endpoint or str(iface.get("useip")) != "0" or str(iface.get("port")) != "10050":
    raise SystemExit(f"FATAL: Zabbix agent interface mismatch: dns={iface.get('dns')} useip={iface.get('useip')} port={iface.get('port')}")
print(f"PASS: Zabbix host {host_name} uses agent endpoint {agent_endpoint}:10050")
print("PASS: Zabbix Operations Model validation completed")
PY
