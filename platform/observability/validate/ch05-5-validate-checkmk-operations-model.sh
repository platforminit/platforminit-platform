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

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"

test -x "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"
test -f "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_hosts.mk"
test -f "${SITE_ROOT}/local/share/platforminit/README.txt"
test -f "${SITE_ROOT}/local/lib/python3/cmk_addons/plugins/platforminit_synthetic/graphing/platforminit_synthetic.py"

# Synthetic PlatformInit services must only emit explicitly namespaced metrics
# with matching Checkmk Graphing API definitions. Generic ad-hoc perfdata such
# as time=0.02s caused service detail pages to fail with graph_recipe errors.
if grep -Eq '(^|[^a-zA-Z0-9_])time=' "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"; then
  echo "FATAL: PlatformInit synthetic plugin must not emit generic time= perfdata" >&2
  exit 1
fi
plugin_output="$(${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service --mode path-usage --service 'Graph sanity' --path / --warn 80 --crit 90)"
case "${plugin_output}" in
  *'| platforminit_path_used_percent='*) ;;
  *)
    echo "FATAL: PlatformInit synthetic plugin did not emit the expected namespaced path metric: ${plugin_output}" >&2
    exit 1
    ;;
esac

grep -F 'name="platforminit_check_duration"' "${SITE_ROOT}/local/lib/python3/cmk_addons/plugins/platforminit_synthetic/graphing/platforminit_synthetic.py" >/dev/null
grep -F 'name="platforminit_path_used_percent"' "${SITE_ROOT}/local/lib/python3/cmk_addons/plugins/platforminit_synthetic/graphing/platforminit_synthetic.py" >/dev/null
su - "${SITE}" -c "cmk-validate-plugins" >/dev/null

CHECKMK_VALIDATE_DIR="$(mktemp -d)"
trap 'rm -rf "${CHECKMK_VALIDATE_DIR}"' EXIT

su - "${SITE}" -c "cmk -l" > "${CHECKMK_VALIDATE_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${CHECKMK_VALIDATE_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible in cmk -l" >&2
  cat "${CHECKMK_VALIDATE_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -N" > "${CHECKMK_VALIDATE_DIR}/nagios.cfg"
for service in \
  "Host availability" \
  "SSH" \
  "Kubernetes API" \
  "Checkmk WebUI" \
  "Argo CD WebUI" \
  "Authentik WebUI" \
  "Root filesystem" \
  "Kubernetes runtime storage" \
  "Kubernetes PVC storage" \
  "Checkmk storage" \
  "Platform runtime artifacts"
do
  grep -q "service_description[[:space:]]\+${service}" "${CHECKMK_VALIDATE_DIR}/nagios.cfg" || {
    echo "FATAL: expected Checkmk service is missing from generated core config: ${service}" >&2
    exit 1
  }
done

su - "${SITE}" -c "cmk -R" >/dev/null

echo "PASS: Checkmk host ${PLATFORM_HOST} is visible"
echo "PASS: PlatformInit custom service checks are present in generated core config"
echo "PASS: PlatformInit synthetic metrics are namespaced and have graph definitions"
CHECKMK_VALIDATE
