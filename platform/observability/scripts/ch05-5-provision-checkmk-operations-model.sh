#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG
[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -n "$BASE_DOMAIN" ]] || die "BASE_DOMAIN is required for PlatformInit Checkmk service checks"

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

HOST_IPV4="${HOST_IPV4:-$(hostname -I | awk '{print $1}') }"
HOST_IPV4="${HOST_IPV4%% }"
[[ -n "$HOST_IPV4" ]] || HOST_IPV4="127.0.0.1"

log "Provisioning visible PlatformInit Checkmk host/service model in pod/${POD} host=${PLATFORM_HOST} host_ipv4=${HOST_IPV4} base_domain=${BASE_DOMAIN}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$BASE_DOMAIN" <<'CHECKMK_MODEL'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
BASE_DOMAIN="$4"
SITE_ROOT="/omd/sites/${SITE}"

omd status "$SITE" >/dev/null

mkdir -p \
  "${SITE_ROOT}/local/lib/nagios/plugins" \
  "${SITE_ROOT}/local/share/platforminit" \
  "${SITE_ROOT}/etc/check_mk/conf.d/platforminit"

cat > "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service" <<'PYPLUGIN'
#!/usr/bin/env python3
import argparse
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request


def emit(code: int, state: str, service: str, detail: str, perfdata: str = "") -> int:
    if perfdata:
        print(f"{state} - {service}: {detail} | {perfdata}")
    else:
        print(f"{state} - {service}: {detail}")
    return code


def check_tcp(args) -> int:
    start = time.time()
    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout):
            elapsed = time.time() - start
        return emit(0, "OK", args.service, f"TCP {args.host}:{args.port} reachable in {elapsed:.3f}s", f"time={elapsed:.3f}s")
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"TCP {args.host}:{args.port} failed: {exc}")


def check_http(args) -> int:
    codes = {int(x.strip()) for x in args.ok_codes.split(',') if x.strip()}
    req = urllib.request.Request(args.url, method="GET", headers={"User-Agent": "PlatformInit-Checkmk/1.0"})
    ctx = ssl._create_unverified_context()
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=args.timeout, context=ctx) as resp:
            code = resp.getcode()
            elapsed = time.time() - start
    except urllib.error.HTTPError as exc:
        code = exc.code
        elapsed = time.time() - start
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"HTTP check failed for {args.url}: {exc}")
    if code in codes:
        return emit(0, "OK", args.service, f"HTTP {code} from {args.url} in {elapsed:.3f}s", f"time={elapsed:.3f}s")
    return emit(2, "CRITICAL", args.service, f"Unexpected HTTP {code} from {args.url}")


def check_path_usage(args) -> int:
    path = args.path
    if not os.path.exists(path):
        return emit(2, "CRITICAL", args.service, f"Path does not exist: {path}")
    try:
        st = os.statvfs(path)
        total = st.f_blocks * st.f_frsize
        available = st.f_bavail * st.f_frsize
        used = total - available
        used_pct = (used / total * 100.0) if total else 0.0
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"Could not stat {path}: {exc}")
    state = "OK"
    code = 0
    if used_pct >= args.crit:
        state, code = "CRITICAL", 2
    elif used_pct >= args.warn:
        state, code = "WARNING", 1
    detail = f"{path} usage is {used_pct:.2f}% ({used // (1024**2)} MiB used of {total // (1024**2)} MiB)"
    perf = f"used={used_pct:.2f}%;{args.warn};{args.crit};0;100"
    return emit(code, state, args.service, detail, perf)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["ok", "tcp", "http", "path-usage"], required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--detail", default="PlatformInit synthetic service check is active")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--url")
    parser.add_argument("--path")
    parser.add_argument("--warn", type=float, default=80.0)
    parser.add_argument("--crit", type=float, default=90.0)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--ok-codes", default="200,301,302,401,403")
    args = parser.parse_args()

    if args.mode == "ok":
        return emit(0, "OK", args.service, args.detail)
    if args.mode == "tcp":
        if not args.host or not args.port:
            return emit(3, "UNKNOWN", args.service, "tcp mode requires --host and --port")
        return check_tcp(args)
    if args.mode == "http":
        if not args.url:
            return emit(3, "UNKNOWN", args.service, "http mode requires --url")
        return check_http(args)
    if args.mode == "path-usage":
        if not args.path:
            return emit(3, "UNKNOWN", args.service, "path-usage mode requires --path")
        return check_path_usage(args)
    return emit(3, "UNKNOWN", args.service, "unsupported mode")


if __name__ == "__main__":
    sys.exit(main())
PYPLUGIN
chmod 0755 "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"
chown "${SITE}:${SITE}" "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"

cat > "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_hosts.mk" <<PLATFORMINIT_MK
# Managed by PlatformInit CH05.5.
# This file intentionally defines a small, operator-first Checkmk model.

globals().setdefault("all_hosts", [])
globals().setdefault("ipaddresses", {})
globals().setdefault("define_hostgroups", {})
globals().setdefault("host_groups", [])
globals().setdefault("custom_checks", [])

all_hosts += [
    "${PLATFORM_HOST}|prod|lan",
]

ipaddresses.update({
    "${PLATFORM_HOST}": "${HOST_IPV4}",
})

extra_host_conf.setdefault("alias", [])
extra_host_conf["alias"] += [
    ("PlatformInit development host", ["${PLATFORM_HOST}"]),
]

extra_host_conf.setdefault("check_command", [])
extra_host_conf["check_command"] += [
    ("check-mk-dummy", ["${PLATFORM_HOST}"]),
]

define_hostgroups.update({
    "platforminit_hosts": "PlatformInit / Hosts",
    "platforminit_kubernetes": "PlatformInit / Kubernetes",
    "platforminit_operations": "PlatformInit / Operations",
    "platforminit_storage": "PlatformInit / Storage",
})

host_groups += [
    ("platforminit_hosts", [], ["${PLATFORM_HOST}"]),
]

custom_checks += [
    ({"command_name": "platforminit-host-availability", "service_description": "Host availability", "command_line": "\$USER2\$/platforminit_check_service --mode ok --service 'Host availability' --detail 'PlatformInit Checkmk host object is active'", "has_perfdata": False}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-ssh", "service_description": "SSH", "command_line": "\$USER2\$/platforminit_check_service --mode tcp --service 'SSH' --host ${HOST_IPV4} --port 22", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-kubernetes-api", "service_description": "Kubernetes API", "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Kubernetes API' --url https://kubernetes.default.svc/healthz --ok-codes 200,401,403", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-checkmk-webui", "service_description": "Checkmk WebUI", "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Checkmk WebUI' --url http://127.0.0.1:5000/${SITE}/ --ok-codes 200,301,302,401,403", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-argocd-webui", "service_description": "Argo CD WebUI", "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Argo CD WebUI' --url https://argocd.${BASE_DOMAIN}/ --ok-codes 200,301,302,401,403", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-authentik-webui", "service_description": "Authentik WebUI", "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Authentik WebUI' --url https://auth.${BASE_DOMAIN}/ --ok-codes 200,301,302,401,403", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-root-filesystem", "service_description": "Root filesystem", "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Root filesystem' --path /platforminit-host/root --warn 80 --crit 90", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-k3s-runtime-storage", "service_description": "Kubernetes runtime storage", "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Kubernetes runtime storage' --path /platforminit-host/srv-data-k3s --warn 80 --crit 90", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-k3s-pvc-storage", "service_description": "Kubernetes PVC storage", "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Kubernetes PVC storage' --path /platforminit-host/srv-data-k3s-storage --warn 80 --crit 90", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-checkmk-storage", "service_description": "Checkmk storage", "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Checkmk storage' --path /platforminit-host/srv-observability-data --warn 80 --crit 90", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
    ({"command_name": "platforminit-platform-runtime-artifacts", "service_description": "Platform runtime artifacts", "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Platform runtime artifacts' --path /platforminit-host/srv-platforminit --warn 80 --crit 90", "has_perfdata": True}, [], ["${PLATFORM_HOST}"]),
]
PLATFORMINIT_MK
chown -R "${SITE}:${SITE}" "${SITE_ROOT}/etc/check_mk/conf.d/platforminit" "${SITE_ROOT}/local/share/platforminit"

cat > "${SITE_ROOT}/local/share/platforminit/README.txt" <<PLATFORMINIT_README
PlatformInit CH05 Checkmk layer

Provisioned host:
- ${PLATFORM_HOST}

Provisioned services:
- Host availability
- SSH
- Kubernetes API
- Checkmk WebUI
- Argo CD WebUI
- Authentik WebUI
- Root filesystem
- Kubernetes runtime storage
- Kubernetes PVC storage
- Checkmk storage
- Platform runtime artifacts
PLATFORMINIT_README
chown "${SITE}:${SITE}" "${SITE_ROOT}/local/share/platforminit/README.txt"

su - "${SITE}" -c "cmk -R"
su - "${SITE}" -c "cmk -l" | grep -Fx "${PLATFORM_HOST}" >/dev/null
su - "${SITE}" -c "cmk -N" | grep -q "host_name[[:space:]]\+${PLATFORM_HOST}"
su - "${SITE}" -c "cmk -N" | grep -q "service_description[[:space:]]\+SSH"
CHECKMK_MODEL

log "Checkmk operations model provisioned and core configuration reloaded"
