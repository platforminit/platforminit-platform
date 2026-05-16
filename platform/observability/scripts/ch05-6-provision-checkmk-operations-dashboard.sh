#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

log "Provisioning PlatformInit Checkmk operations dashboard entrypoint in pod/${POD} host=${PLATFORM_HOST}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_DASHBOARD'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"
START_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"
INDEX_START_URL="check_mk/index.py?start_url=view.py%3Fview_name%3Dhoststatus%26host%3D${PLATFORM_HOST}"

# CH05.6 is deliberately conservative: Checkmk Raw/Community already provides
# the useful host/service state views. We make the PlatformInit host view the
# deterministic landing page and keep deep links documented for operators.
test -d "${SITE_ROOT}/etc/check_mk/multisite.d/wato"
test -d "${SITE_ROOT}/var/check_mk/web/cmkadmin"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible; run CH05.5 first" >&2
  cat "${TMP_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -N" > "${TMP_DIR}/nagios.cfg"
service_count="$(awk -v host="${PLATFORM_HOST}" '
  $1 == "host_name" && $2 == host { in_service=1 }
  in_service && $1 == "service_description" { count++; in_service=0 }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"
if [[ "${service_count}" -lt 10 ]]; then
  echo "FATAL: expected at least 10 services for ${PLATFORM_HOST}, got ${service_count}" >&2
  exit 1
fi

cat > "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" <<PLATFORMINIT_UI
# Managed by PlatformInit CH05.6.
# Make the PlatformInit host/service state view the deterministic operator start page.
# The URL is intentionally a Checkmk-native view rather than a custom fragile dashboard object.
start_url = '${START_URL}'
PLATFORMINIT_UI

cat > "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" <<PLATFORMINIT_USER_START
# Managed by PlatformInit CH05.6.
start_url = '${START_URL}'
PLATFORMINIT_USER_START

mkdir -p "${SITE_ROOT}/local/share/platforminit"
cat > "${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt" <<PLATFORMINIT_LINKS
Managed by PlatformInit CH05.6

Primary operator entrypoint:
  /${SITE}/check_mk/${INDEX_START_URL}

Useful Checkmk-native views:
  Host overview:
    /${SITE}/check_mk/view.py?view_name=hoststatus&host=${PLATFORM_HOST}
  Services for host:
    /${SITE}/check_mk/view.py?view_name=service&host=${PLATFORM_HOST}
  All hosts:
    /${SITE}/check_mk/view.py?view_name=allhosts
  All services:
    /${SITE}/check_mk/view.py?view_name=allservices
  Service problems:
    /${SITE}/check_mk/view.py?view_name=svcproblems

Current CH05.6 success contract:
  host=${PLATFORM_HOST}
  services>=10
  start_url=${START_URL}

CH05.7 should add the Checkmk agent so this view becomes full host metrics/service discovery instead of synthetic active checks only.
PLATFORMINIT_LINKS

chown "${SITE}:${SITE}" \
  "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" \
  "${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt"

# Restart the site so Multisite picks up the UI/start-url configuration deterministically.
omd restart "${SITE}" >/dev/null

# Smoke the configured operator view through the local Checkmk frontend.
for attempt in 1 2 3 4 5 6; do
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-operations-view.html -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=hoststatus&host=${PLATFORM_HOST}" || true)"
  case "${code}" in
    200|302|303) break ;;
  esac
  sleep 5
done
case "${code}" in
  200|302|303) ;;
  *)
    echo "FATAL: PlatformInit Checkmk operator view did not respond successfully, HTTP=${code}" >&2
    head -n 80 /tmp/platforminit-operations-view.html >&2 || true
    exit 1
    ;;
esac

echo "PASS: PlatformInit Checkmk operator start URL set to ${START_URL}"
echo "PASS: PlatformInit Checkmk operator view responds with HTTP=${code}"
echo "PASS: ${PLATFORM_HOST} has ${service_count} generated services"
CHECKMK_DASHBOARD

log "Checkmk operations dashboard entrypoint provisioned"
