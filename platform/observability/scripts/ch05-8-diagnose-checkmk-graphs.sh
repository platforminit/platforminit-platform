#!/usr/bin/env bash
set -uo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
SAMPLE_SERVICE_LIMIT="${SAMPLE_SERVICE_LIMIT:-25}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
DASHBOARD_SAMPLE_NAMES="${DASHBOARD_SAMPLE_NAMES:-main checkmk problems simple_problems}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -f "$KUBECONFIG" ]] || die "Missing kubeconfig at ${KUBECONFIG}"
command -v kubectl >/dev/null || die "kubectl is required"

section "diagnostic scope"
cat <<EOF
mode: data-collection-only
purpose: Checkmk graph_recipe and built-in dashboard UI diagnostics
platform_host: ${PLATFORM_HOST}
namespace: ${NAMESPACE}
checkmk_site: ${CHECKMK_SITE}
sample_service_limit: ${SAMPLE_SERVICE_LIMIT}
base_domain: ${BASE_DOMAIN:-unset}
dashboard_sample_names: ${DASHBOARD_SAMPLE_NAMES}
notes:
  - This workflow is intentionally read-only.
  - It does not change Checkmk configuration, service discovery, graph templates, RRD files, dashboards or autochecks.
  - It collects Checkmk graphing config, metric inventory, RRD/perfdata state, WebUI page probes and log excerpts.
  - It also compares built-in Checkmk dashboard rendering through the direct Checkmk backend and the nginx auth-shim.
EOF

section "kubernetes operations status"
kubectl -n "$NAMESPACE" get deploy,pod,svc,endpoints,cm,secret -o wide 2>&1 || true
kubectl -n argocd get application operations-stack -o wide 2>&1 || true
kubectl -n "$NAMESPACE" get ingressroute.traefik.io,middleware.traefik.io -o wide 2>&1 || true

POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  die "No Checkmk pod found in namespace ${NAMESPACE}; cannot collect graph diagnostics"
fi

section "selected Checkmk pod"
echo "pod=${POD}"
kubectl -n "$NAMESPACE" describe pod "$POD" 2>&1 | sed -n '1,220p' || true

section "auth-shim runtime nginx header contract"
kubectl -n "$NAMESPACE" exec "$POD" -c auth-shim -- sh -lc '
  nginx -T 2>/dev/null | grep -nE "proxy_pass_request_headers|proxy_set_header|Content-Type|Accept|X-Requested-With|Referer|Origin|Cookie|Authorization|X-Remote" -A2 -B2 || true
' 2>&1 || true

section "Checkmk graph and dashboard diagnostics from site"
kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$SAMPLE_SERVICE_LIMIT" "$BASE_DOMAIN" "$DASHBOARD_SAMPLE_NAMES" <<'CHECKMK_GRAPH_DIAG'
set -uo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SAMPLE_SERVICE_LIMIT="$3"
BASE_DOMAIN="$4"
DASHBOARD_SAMPLE_NAMES="$5"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

section(){ printf '\n----- %s -----\n' "$*"; }
print_limited(){
  local file="$1"
  local lines="${2:-260}"
  if [[ -s "$file" ]]; then
    local count
    count="$(wc -l < "$file" | tr -d ' ')"
    sed -n "1,${lines}p" "$file"
    if [[ "${count}" -gt "${lines}" ]]; then
      echo "... output truncated: ${count} lines total; tail follows ..."
      tail -n 100 "$file"
    fi
  else
    echo "(empty)"
  fi
}
run_site(){
  local label="$1"
  local cmd="$2"
  section "$label"
  echo "+ su - ${SITE} -c ${cmd}"
  su - "${SITE}" -c "$cmd" >"${TMP_DIR}/${label}.out" 2>"${TMP_DIR}/${label}.err"
  local rc=$?
  echo "RC=${rc}"
  echo "--- stdout ---"
  print_limited "${TMP_DIR}/${label}.out"
  echo "--- stderr ---"
  print_limited "${TMP_DIR}/${label}.err"
  return 0
}

if [[ ! -d "${SITE_ROOT}" ]]; then
  echo "FATAL: missing site root ${SITE_ROOT}"
  exit 0
fi

section "site/version/status"
id "${SITE}" || true
omd version 2>&1 || true
omd status "${SITE}" 2>&1 || true
ls -ld "${SITE_ROOT}" "${SITE_ROOT}/etc/check_mk" "${SITE_ROOT}/var/check_mk" "${SITE_ROOT}/tmp/check_mk" 2>&1 || true

run_site "cmk-version" "cmk -V && cmk --version"
run_site "cmk-host-configuration" "cmk -D '${PLATFORM_HOST}'"
run_site "cmk-core-config-host" "cmk -N '${PLATFORM_HOST}'"
run_site "cmk-cache-runtime-check" "cmk --cache -nv '${PLATFORM_HOST}'"
run_site "cmk-debug-cache-runtime-check" "cmk --debug --cache -vvn '${PLATFORM_HOST}'"

section "service inventory from generated core config"
su - "${SITE}" -c "cmk -N '${PLATFORM_HOST}'" >"${TMP_DIR}/core.cfg" 2>"${TMP_DIR}/core.err" || true
python3 - <<PY
from pathlib import Path
import re
text = Path('${TMP_DIR}/core.cfg').read_text(errors='replace')
services = re.findall(r'service_description\s+(.+)', text)
print(f'total_service_descriptions={len(services)}')
for idx, service in enumerate(services[:120], 1):
    print(f'{idx:03d} {service}')
PY

echo "--- native-looking service descriptions ---"
grep -Ei "service_description\s+(CPU|Memory|Filesystem|Interface|Uptime|Disk|Kernel|Systemd|Mount|TCP|Check_MK|Checkmk)" "${TMP_DIR}/core.cfg" | sed -n '1,180p' || true

echo "--- PlatformInit synthetic service descriptions ---"
grep -Ei "service_description\s+(Host availability|SSH|Kubernetes API|Checkmk WebUI|Argo CD WebUI|Authentik WebUI|Root filesystem|Kubernetes runtime storage|Kubernetes PVC storage|Checkmk storage|Platform runtime artifacts)" "${TMP_DIR}/core.cfg" | sed -n '1,180p' || true

section "Checkmk graphing and metric plugin files"
for dir in \
  "${SITE_ROOT}/local/share/check_mk/web/plugins/metrics" \
  "${SITE_ROOT}/share/check_mk/web/plugins/metrics" \
  "${SITE_ROOT}/local/lib/python3/cmk/gui/plugins/metrics" \
  "${SITE_ROOT}/lib/python3/cmk/gui/plugins/metrics" \
  "${SITE_ROOT}/local/lib/python3/cmk/gui/plugins/graphing" \
  "${SITE_ROOT}/lib/python3/cmk/gui/plugins/graphing" \
  "${SITE_ROOT}/local/lib/check_mk/base/plugins/agent_based" \
  "${SITE_ROOT}/lib/check_mk/base/plugins/agent_based"; do
  echo "--- ${dir} ---"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 3 -type f | sort | sed -n '1,240p'
  else
    echo "(missing)"
  fi
done

echo "--- local platforminit graph/metric references ---"
find "${SITE_ROOT}/local" -type f 2>/dev/null | sort | while read -r file; do
  if grep -qEi "platforminit|graph_recipe|metric|perfdata|graph" "$file" 2>/dev/null; then
    echo "### ${file}"
    grep -nEi "platforminit|graph_recipe|metric|perfdata|graph" "$file" | sed -n '1,120p'
  fi
done

section "RRD, PNP and graph cache state for host"
for dir in \
  "${SITE_ROOT}/var/check_mk/rrd" \
  "${SITE_ROOT}/var/pnp4nagios/perfdata" \
  "${SITE_ROOT}/var/check_mk/graphing" \
  "${SITE_ROOT}/tmp/check_mk" \
  "${SITE_ROOT}/var/check_mk/web"; do
  echo "--- ${dir} ---"
  if [[ -d "$dir" ]]; then
    find "$dir" \( -path "*${PLATFORM_HOST}*" -o -name "*graph*" -o -name "*.rrd" \) 2>/dev/null | sort | sed -n '1,260p'
  else
    echo "(missing)"
  fi
done

section "Checkmk logs containing graph, dashboard or ajax failures"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph|dashboard|ajax|sidebar|snapin|csrf|invalid" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph|dashboard|ajax|sidebar|snapin|csrf|invalid" "$log_file" | tail -n 180
    fi
  done
else
  echo "missing ${SITE_ROOT}/var/log"
fi

section "dashboard inventory, definitions and user state"
echo "--- dashboard sample names ---"
printf '%s\n' ${DASHBOARD_SAMPLE_NAMES} 2>/dev/null || true

echo "--- dashboard-related files under site root ---"
find "${SITE_ROOT}" \( -path "${SITE_ROOT}/var/check_mk/core/*" -o -path "${SITE_ROOT}/var/check_mk/rrd/*" -o -path "${SITE_ROOT}/var/pnp4nagios/*" -o -path "${SITE_ROOT}/tmp/*" \) -prune -o \
  -type f \( -iname '*dashboard*' -o -iname '*dashboards*' -o -iname '*sidebar*' -o -iname '*snapin*' -o -iname '*user_*dashboard*' \) -print 2>/dev/null | sort | sed -n '1,320p'

echo "--- dashboard/view config snippets ---"
for file in \
  "${SITE_ROOT}/etc/check_mk/multisite.mk" \
  "${SITE_ROOT}/etc/check_mk/conf.d/wato/global.mk" \
  "${SITE_ROOT}/etc/check_mk/conf.d/wato/tags.mk"; do
  echo "### ${file}"
  if [[ -f "$file" ]]; then
    grep -nEi "dashboard|start_url|sidebar|snapin|view" "$file" | sed -n '1,180p' || true
  else
    echo "(missing)"
  fi
done

echo "--- per-user Checkmk web files for cmkadmin ---"
if [[ -d "${SITE_ROOT}/var/check_mk/web/cmkadmin" ]]; then
  find "${SITE_ROOT}/var/check_mk/web/cmkadmin" -maxdepth 2 -type f | sort | while read -r file; do
    echo "### ${file}"
    grep -nEi "dashboard|start_url|sidebar|snapin|main|checkmk|problem|select|bookmark" "$file" 2>/dev/null | sed -n '1,140p' || true
  done
else
  echo "(missing ${SITE_ROOT}/var/check_mk/web/cmkadmin)"
fi

section "dashboard page probes: direct backend versus auth-shim"
python3 - <<PY >"${TMP_DIR}/dashboard_probe_urls.sh"
from urllib.parse import quote
names = '${DASHBOARD_SAMPLE_NAMES}'.split()
paths = ['dashboard.py']
for name in names:
    paths.append('dashboard.py?name=' + quote(name, safe='') + '&owner=')
paths.extend([
    'index.py?start_url=' + quote('/cmk/dashboard.py?name=main&owner=', safe=''),
    'view.py?view_name=allhosts',
    'view.py?view_name=hoststatus&host=' + quote('${PLATFORM_HOST}', safe=''),
])
seen = []
for path in paths:
    if path not in seen:
        seen.append(path)
for path in seen:
    print(path)
PY
cat "${TMP_DIR}/dashboard_probe_urls.sh"
probe_dashboard_path(){
  local mode="$1"
  local path="$2"
  local safe
  safe="$(echo "$mode-$path" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  local out="${TMP_DIR}/dashboard-${safe}.html"
  local hdr="${TMP_DIR}/dashboard-${safe}.headers"
  local jar="${TMP_DIR}/dashboard-${mode}.cookies"
  local url
  local -a headers
  if [[ "$mode" == "direct" ]]; then
    url="http://127.0.0.1:5000/cmk/${path}"
    headers=(
      -H 'Host: checkmk.local'
      -H 'X-Remote-User: cmkadmin'
      -H 'X-Remote-Original-User: cmkadmin'
      -H 'X-Remote-Email: cmkadmin@localhost'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.8'
      -H 'Referer: http://checkmk.local/cmk/index.py'
    )
  else
    url="http://127.0.0.1:8080/cmk/${path}"
    headers=(
      -H 'Host: checkmk.local'
      -H 'X-authentik-username: cmkadmin'
      -H 'X-authentik-name: cmkadmin'
      -H 'X-authentik-email: cmkadmin@localhost'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.8'
      -H 'Referer: http://checkmk.local/cmk/index.py'
    )
  fi
  echo "--- dashboard ${mode}: /cmk/${path} ---"
  curl -ksS -L -D "$hdr" -o "$out" -b "$jar" -c "$jar" "${headers[@]}" -w 'HTTP=%{http_code} CONTENT_TYPE=%{content_type} REDIRECT=%{redirect_url}\n' "$url" 2>&1 || true
  echo "headers:"; sed -n '1,80p' "$hdr" 2>/dev/null || true
  echo "page_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)"
  echo "signals:"
  grep -nEi "Main dashboard|Select dashboard|Dashboard|Welcome|Loading|spinner|ajax|fetch|XMLHttpRequest|rest/|api/|dashboard.py|graph_recipe|Traceback|Exception|permission|login" "$out" | sed -n '1,180p' || true
  echo "script/assets:"
  grep -oE "(src|href)=['\"][^'\"]+" "$out" | sed -n '1,140p' || true
  echo "candidate ajax/dashboard endpoints:"
  grep -oE '([A-Za-z0-9_./-]*(ajax|dashboard|sidebar|snapin|widget|view|api|rest)[A-Za-z0-9_./?&=:%;+,-]*)' "$out" | sort -u | sed -n '1,180p' || true
}
while read -r path; do
  [[ -n "$path" ]] || continue
  probe_dashboard_path direct "$path"
  probe_dashboard_path shim "$path"
done <"${TMP_DIR}/dashboard_probe_urls.sh"

section "dashboard AJAX/API candidate probes"
python3 - <<PY >"${TMP_DIR}/dashboard_candidate_paths.txt"
from pathlib import Path
import re
candidates = set()
for path in Path('${TMP_DIR}').glob('dashboard-*.html'):
    text = path.read_text(errors='replace')
    for match in re.findall(r'[A-Za-z0-9_./-]*(?:ajax|dashboard|sidebar|snapin|widget|view|api|rest)[A-Za-z0-9_./?&=:%;+,-]*', text):
        if not match or match.startswith(('http://', 'https://', 'data:')):
            continue
        if match.startswith('/cmk/'):
            match = match[len('/cmk/'):]
        match = match.lstrip('./')
        if any(token in match for token in ('ajax', 'dashboard', 'sidebar', 'snapin', 'widget')):
            candidates.add(match)
for extra in [
    'dashboard.py?name=main&owner=',
    'dashboard.py?name=checkmk&owner=',
    'ajax_graph_images.py',
    'ajax_render_graph_content.py',
]:
    candidates.add(extra)
for item in sorted(candidates)[:120]:
    print(item)
PY
cat "${TMP_DIR}/dashboard_candidate_paths.txt"
while read -r path; do
  [[ -n "$path" ]] || continue
  safe="$(echo "candidate-$path" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  out="${TMP_DIR}/candidate-${safe}.body"
  hdr="${TMP_DIR}/candidate-${safe}.headers"
  echo "--- candidate GET via auth-shim: /cmk/${path} ---"
  curl -ksS -D "$hdr" -o "$out" \
    -H 'Host: checkmk.local' \
    -H 'X-authentik-username: cmkadmin' \
    -H 'X-authentik-name: cmkadmin' \
    -H 'X-authentik-email: cmkadmin@localhost' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'Referer: http://checkmk.local/cmk/dashboard.py?name=main&owner=' \
    -w 'HTTP=%{http_code} CONTENT_TYPE=%{content_type}\n' \
    "http://127.0.0.1:8080/cmk/${path}" 2>&1 || true
  sed -n '1,50p' "$hdr" 2>/dev/null || true
  echo "body_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)"
  grep -nEi "dashboard|ajax|graph_recipe|Traceback|Exception|Not Found|permission|login|error|Select dashboard|Main dashboard|csrf|invalid" "$out" | sed -n '1,120p' || true
done <"${TMP_DIR}/dashboard_candidate_paths.txt"

section "dashboard-related Checkmk logs after probes"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "dashboard|snapin|sidebar|ajax|graph_recipe|exception|traceback|permission|invalid|csrf" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "dashboard|snapin|sidebar|ajax|graph_recipe|exception|traceback|permission|invalid|csrf" "$log_file" | tail -n 260
    fi
  done
fi

section "WebUI service-page probes through trusted header"
python3 - <<PY >"${TMP_DIR}/probe_urls.sh"
from pathlib import Path
from urllib.parse import quote
import re
core = Path('${TMP_DIR}/core.cfg').read_text(errors='replace')
services = re.findall(r'service_description\s+(.+)', core)
try:
    limit = int('${SAMPLE_SERVICE_LIMIT}' or '25')
except ValueError:
    limit = 25
seen = []
for service in services:
    if service not in seen:
        seen.append(service)
for service in seen[:limit]:
    qs = 'view.py?view_name=service&host=' + quote('${PLATFORM_HOST}', safe='') + '&service=' + quote(service, safe='')
    print('probe_service ' + quote(service) + ' ' + quote(qs, safe='/:?=&%'))
print('probe_hostgraphs ' + quote('host_graphs') + ' ' + quote('view.py?view_name=host_graphs&host=' + '${PLATFORM_HOST}', safe='/:?=&%'))
PY
cat "${TMP_DIR}/probe_urls.sh"
while read -r kind encoded_name encoded_path; do
  [[ -n "${kind:-}" ]] || continue
  name="$(python3 - <<PY
from urllib.parse import unquote
print(unquote('${encoded_name}'))
PY
)"
  path="$(python3 - <<PY
from urllib.parse import unquote
print(unquote('${encoded_path}'))
PY
)"
  safe="$(echo "$kind-$name" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  out="${TMP_DIR}/ui-${safe}.html"
  echo "--- ${kind}: ${name} -> /cmk/${path} ---"
  curl -ksS \
    -H 'X-Remote-User: cmkadmin' \
    -H 'X-Remote-Original-User: cmkadmin' \
    -H 'X-Remote-Email: cmkadmin@localhost' \
    -o "$out" \
    -w 'HTTP=%{http_code}\n' \
    "http://127.0.0.1:5000/cmk/${path}" 2>&1 || true
  echo "page_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)"
  grep -nEi "graph_recipe|Loading graph failed|Traceback|Exception|ajax.*graph|render.*graph|metric|rrd" "$out" | sed -n '1,120p' || true
  grep -oE '[-A-Za-z0-9_/\.]*ajax[-A-Za-z0-9_/\.]*graph[-A-Za-z0-9_/?&=%.;:+]*' "$out" | sort -u | sed -n '1,80p' || true
done <"${TMP_DIR}/probe_urls.sh"

section "post-probe Checkmk logs containing graph, dashboard or ajax failures"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph|dashboard|ajax|sidebar|snapin|csrf|invalid" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph|dashboard|ajax|sidebar|snapin|csrf|invalid" "$log_file" | tail -n 260
    fi
  done
fi
CHECKMK_GRAPH_DIAG

section "Checkmk pod logs after WebUI probes"
kubectl -n "$NAMESPACE" logs "$POD" -c checkmk --tail=260 2>&1 || true
kubectl -n "$NAMESPACE" logs "$POD" -c auth-shim --tail=180 2>&1 || true

log "CH05.8D graph/dashboard diagnostic collection completed. Review uploaded operations-graph-* artifact before making dashboard or graph UI changes."
