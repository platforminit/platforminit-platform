#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
export KUBECONFIG

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "FATAL: no Checkmk pod found" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_DASHBOARD_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"
START_URL="view.py?view_name=allhosts"
HOST_STATUS_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"

UI_FILE="${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk"
USER_START_FILE="${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk"
ENTRYPOINTS="${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt"

test -f "${UI_FILE}"
test -f "${USER_START_FILE}"
test -f "${ENTRYPOINTS}"
grep -F "start_url = '${START_URL}'" "${UI_FILE}" >/dev/null
grep -F "start_url = '${START_URL}'" "${USER_START_FILE}" >/dev/null
grep -F "view.py?view_name=allhosts" "${ENTRYPOINTS}" >/dev/null
grep -F "view.py?view_name=hoststatus&host=${PLATFORM_HOST}" "${ENTRYPOINTS}" >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible" >&2
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

code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-operations-view-validate.html -w '%{http_code}' \
  "http://127.0.0.1:5000/${SITE}/check_mk/${START_URL}" || true)"
case "${code}" in
  200|302|303) ;;
  *)
    echo "FATAL: operator all-hosts view returned HTTP=${code}" >&2
    head -n 80 /tmp/platforminit-operations-view-validate.html >&2 || true
    exit 1
    ;;
esac

# Synthetic CH05.5 services are state-only. The service detail page must not
# expose the old custom perfdata graph failure seen as: Loading graph failed:
# 'graph_recipe'. The native agent layer in CH05.7 will provide real graphs.
service_detail_code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-service-detail-graph-sanity.html -w '%{http_code}' \
  "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=service&host=${PLATFORM_HOST}&service=Argo%20CD%20WebUI" || true)"
case "${service_detail_code}" in
  200|302|303) ;;
  *)
    echo "FATAL: PlatformInit Checkmk service detail graph sanity page returned HTTP=${service_detail_code}" >&2
    head -n 80 /tmp/platforminit-service-detail-graph-sanity.html >&2 || true
    exit 1
    ;;
esac
if grep -Fq "graph_recipe" /tmp/platforminit-service-detail-graph-sanity.html; then
  echo "FATAL: PlatformInit Checkmk service detail still contains graph_recipe error; run CH05.5 state-only model provisioning and retry" >&2
  exit 1
fi

echo "PASS: PlatformInit Checkmk start URL is configured"
echo "PASS: PlatformInit Checkmk all-hosts operator view responds with HTTP=${code}"
echo "PASS: ${PLATFORM_HOST} is visible with ${service_count} generated services"
echo "PASS: PlatformInit service detail page has no stale graph_recipe error"
CHECKMK_DASHBOARD_VALIDATE
