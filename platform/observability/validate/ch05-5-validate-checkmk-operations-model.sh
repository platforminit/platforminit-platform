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

hosts="$(su - "${SITE}" -c "cmk -l")"
echo "$hosts" | grep -Fx "${PLATFORM_HOST}" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible in cmk -l" >&2
  echo "$hosts" >&2
  exit 1
}

nagios_cfg="$(su - "${SITE}" -c "cmk -N")"
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
  echo "$nagios_cfg" | grep -q "service_description[[:space:]]\+${service}" || {
    echo "FATAL: expected Checkmk service is missing from generated core config: ${service}" >&2
    exit 1
  }
done

su - "${SITE}" -c "cmk -R" >/dev/null

echo "PASS: Checkmk host ${PLATFORM_HOST} is visible"
echo "PASS: PlatformInit custom service checks are present in generated core config"
CHECKMK_VALIDATE
