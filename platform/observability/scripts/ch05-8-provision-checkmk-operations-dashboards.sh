#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
EXPECTED_MIN_SERVICES="${EXPECTED_MIN_SERVICES:-20}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

log "Provisioning PlatformInit Checkmk operations dashboard entrypoints in pod/${POD} host=${PLATFORM_HOST}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$EXPECTED_MIN_SERVICES" <<'CHECKMK_DASHBOARDS'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
EXPECTED_MIN_SERVICES="$3"
SITE_ROOT="/omd/sites/${SITE}"
START_URL="dashboard.py?name=main&owner="
MAIN_DASHBOARD_URL="dashboard.py?name=main&owner="
PROBLEMS_DASHBOARD_URL="dashboard.py?name=problems&owner="
SIMPLE_PROBLEMS_DASHBOARD_URL="dashboard.py?name=simple_problems&owner="
HOST_STATUS_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"
HOST_GRAPHS_URL="view.py?view_name=host_graphs&host=${PLATFORM_HOST}&site=${SITE}"
ALL_HOSTS_URL="view.py?view_name=allhosts"
ALL_SERVICES_URL="view.py?view_name=allservices"
SERVICE_PROBLEMS_URL="view.py?view_name=svcproblems"
INDEX_START_URL="check_mk/index.py?start_url=dashboard.py%3Fname%3Dmain%26owner%3D"

# CH05.8 intentionally uses Checkmk-native dashboards/views instead of creating
# version-sensitive dashboard object files. Checkmk 2.5 dashboard internals are
# Vue/API-driven and the Community edition already ships stable dashboards for
# the exact operator flows PlatformInit needs: main overview, problems, service
# problem list, host detail and host/service graphs.
test -d "${SITE_ROOT}/etc/check_mk/multisite.d/wato"
test -d "${SITE_ROOT}/var/check_mk/web/cmkadmin"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

su - "${SITE}" -c "cmk --version" > "${TMP_DIR}/cmk-version.txt" || true
su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible; run CH05.5 first" >&2
  cat "${TMP_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/host-model.txt"
if ! grep -Fq '[agent:cmk-agent]' "${TMP_DIR}/host-model.txt" || ! grep -Fq '[tcp:tcp]' "${TMP_DIR}/host-model.txt" || ! grep -Fq 'TCP:' "${TMP_DIR}/host-model.txt"; then
  echo "FATAL: ${PLATFORM_HOST} is not a Checkmk TCP agent target; run CH05.7 before CH05.8" >&2
  cat "${TMP_DIR}/host-model.txt" >&2
  exit 1
fi

su - "${SITE}" -c "cmk -N" > "${TMP_DIR}/nagios.cfg"
service_count="$(awk -v host="${PLATFORM_HOST}" '
  /^define service[[:space:]]*\{/ { in_block=1; block_host=""; block_service=""; next }
  in_block && $1 == "host_name" { block_host=$2; next }
  in_block && $1 == "service_description" { $1=""; sub(/^ +/, ""); block_service=$0; next }
  in_block && /^}/ {
    if (block_host == host && block_service != "") count++
    in_block=0
  }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"
if [[ "${service_count}" -lt "${EXPECTED_MIN_SERVICES}" ]]; then
  echo "FATAL: expected at least ${EXPECTED_MIN_SERVICES} services for ${PLATFORM_HOST}, got ${service_count}" >&2
  exit 1
fi

cat > "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" <<PLATFORMINIT_UI
# Managed by PlatformInit CH05.8.
# Make the Checkmk main dashboard the deterministic operator start page now
# that CH05.7 native agent discovery and graph rendering are stable.
start_url = '${START_URL}'
PLATFORMINIT_UI

cat > "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" <<PLATFORMINIT_USER_START
# Managed by PlatformInit CH05.8.
start_url = '${START_URL}'
PLATFORMINIT_USER_START

mkdir -p "${SITE_ROOT}/local/share/platforminit"
cat > "${SITE_ROOT}/local/share/platforminit/checkmk-operations-dashboards.txt" <<PLATFORMINIT_DASHBOARDS
Managed by PlatformInit CH05.8

Primary operator dashboard:
  /${SITE}/check_mk/${MAIN_DASHBOARD_URL}

Problem-oriented dashboards:
  Problems dashboard:
    /${SITE}/check_mk/${PROBLEMS_DASHBOARD_URL}
  Host & service problems:
    /${SITE}/check_mk/${SIMPLE_PROBLEMS_DASHBOARD_URL}

Operational drill-down views:
  PlatformInit host status:
    /${SITE}/check_mk/${HOST_STATUS_URL}
  PlatformInit host graphs:
    /${SITE}/check_mk/${HOST_GRAPHS_URL}
  All hosts:
    /${SITE}/check_mk/${ALL_HOSTS_URL}
  All services:
    /${SITE}/check_mk/${ALL_SERVICES_URL}
  Service problems:
    /${SITE}/check_mk/${SERVICE_PROBLEMS_URL}

Runtime contract:
  host=${PLATFORM_HOST}
  services>=${EXPECTED_MIN_SERVICES}
  start_url=${START_URL}
  tcp_agent=true
  graph_ajax_content_type_preserved=true

Rationale:
  CH05.8 keeps dashboard provisioning conservative. It promotes stable
  Checkmk-native dashboards and drill-down views instead of writing internal
  dashboard object files whose format may change between Checkmk releases.
  The custom PlatformInit operator model remains in CH05.5/CH05.7, while
  CH05.8 configures the dashboard landing experience and validates that the
  dashboard and graph paths are usable through the trusted-header WebUI path.
PLATFORMINIT_DASHBOARDS

chown "${SITE}:${SITE}" \
  "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" \
  "${SITE_ROOT}/local/share/platforminit/checkmk-operations-dashboards.txt"

omd restart "${SITE}" >/dev/null

probe_url() {
  local name="$1"
  local path="$2"
  local output="${TMP_DIR}/${name}.html"
  local code
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${output}" -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${path}" || true)"
  case "${code}" in
    200|302|303)
      ;;
    *)
      echo "FATAL: Checkmk dashboard/view probe failed: ${name} HTTP=${code} path=${path}" >&2
      head -n 100 "${output}" >&2 || true
      exit 1
      ;;
  esac
  if grep -Fq "graph_recipe" "${output}"; then
    echo "FATAL: Checkmk dashboard/view probe still contains graph_recipe error: ${name}" >&2
    exit 1
  fi
  echo "PASS: ${name} responds with HTTP=${code}"
}

for attempt in 1 2 3 4 5 6; do
  if curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-dashboard-ready.html -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${MAIN_DASHBOARD_URL}" | grep -Eq '^(200|302|303)$'; then
    break
  fi
  sleep 5
  [[ "${attempt}" != "6" ]] || {
    echo "FATAL: Checkmk main dashboard did not become reachable after omd restart" >&2
    head -n 80 /tmp/platforminit-dashboard-ready.html >&2 || true
    exit 1
  }
done

probe_url "dashboard-main" "${MAIN_DASHBOARD_URL}"
probe_url "dashboard-problems" "${PROBLEMS_DASHBOARD_URL}"
probe_url "dashboard-simple-problems" "${SIMPLE_PROBLEMS_DASHBOARD_URL}"
probe_url "host-status" "${HOST_STATUS_URL}"
probe_url "host-graphs" "${HOST_GRAPHS_URL}"
probe_url "all-hosts" "${ALL_HOSTS_URL}"
probe_url "all-services" "${ALL_SERVICES_URL}"
probe_url "service-problems" "${SERVICE_PROBLEMS_URL}"

# Spot-check representative native service detail pages after CH05.7. Exact
# service names can vary slightly by agent version, so prefer discovered names.
awk -v host="${PLATFORM_HOST}" '
  /^define service[[:space:]]*\{/ { in_block=1; block_host=""; block_service=""; next }
  in_block && $1 == "host_name" { block_host=$2; next }
  in_block && $1 == "service_description" { $1=""; sub(/^ +/, ""); block_service=$0; next }
  in_block && /^}/ {
    if (block_host == host && block_service != "") print block_service
    in_block=0
  }
' "${TMP_DIR}/nagios.cfg" > "${TMP_DIR}/services.txt"

for pattern in "CPU" "Memory" "Filesystem" "Uptime"; do
  service="$(grep -E "${pattern}" "${TMP_DIR}/services.txt" | head -n1 || true)"
  [[ -n "${service}" ]] || continue
  encoded_service="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${service}")"
  probe_url "service-${pattern}" "view.py?view_name=service&host=${PLATFORM_HOST}&service=${encoded_service}"
done

cat <<SUMMARY
PASS: PlatformInit Checkmk dashboard start URL set to ${START_URL}
PASS: ${PLATFORM_HOST} is a TCP Checkmk agent target
PASS: ${PLATFORM_HOST} has ${service_count} generated services
PASS: Checkmk native dashboards and PlatformInit drill-down views respond
PASS: Dashboard and graph probes are free from graph_recipe errors
SUMMARY
CHECKMK_DASHBOARDS

log "Checkmk operations dashboard entrypoints provisioned"
