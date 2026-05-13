#!/usr/bin/env bash
set -euo pipefail

ns="${NAMESPACE:-observability}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

command -v kubectl >/dev/null 2>&1 || fail "KUBECTL" "kubectl is missing"
command -v python3 >/dev/null 2>&1 || fail "PYTHON" "python3 is missing"
[ -f "${KUBECONFIG}" ] || fail "KUBECONFIG" "missing kubeconfig: ${KUBECONFIG}"

kubectl get ns "$ns" >/dev/null 2>&1 && pass "NAMESPACE" "$ns namespace exists" || fail "NAMESPACE" "$ns namespace missing"

EXPECTED_DASHBOARDS=(
  grafana-dashboard-00-platform-overview
  grafana-dashboard-05-alert-operations-center
  grafana-dashboard-10-host-infrastructure
  grafana-dashboard-20-kubernetes-k3s
  grafana-dashboard-30-argocd-gitops
  grafana-dashboard-40-identity-sso
  grafana-dashboard-50-observability-self-monitoring
  grafana-dashboard-60-security-audit
  grafana-dashboard-90-application-template
)

for cm in "${EXPECTED_DASHBOARDS[@]}"; do
  if kubectl -n "$ns" get configmap "$cm" >/dev/null 2>&1; then
    pass "DASHBOARD_CONFIGMAP" "$cm exists"
  else
    fail "DASHBOARD_CONFIGMAP" "$cm missing"
  fi

  label_value="$(kubectl -n "$ns" get configmap "$cm" -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null || true)"
  if [[ "$label_value" == "1" ]]; then
    pass "DASHBOARD_LABEL" "$cm has grafana_dashboard=1"
  else
    fail "DASHBOARD_LABEL" "$cm missing grafana_dashboard=1"
  fi

  json_payload="$(kubectl -n "$ns" get configmap "$cm" -o jsonpath='{.data}' 2>/dev/null || true)"
  if JSON_PAYLOAD="$json_payload" python3 - <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ.get('JSON_PAYLOAD', '{}'))
    if not data:
        raise ValueError('empty data map')
    payload = next(iter(data.values()))
    dashboard = json.loads(payload)
    for key in ('uid', 'title', 'panels'):
        if key not in dashboard:
            raise ValueError(f'missing {key}')
    if not dashboard['panels']:
        raise ValueError('dashboard has no panels')
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
PY
  then
    pass "DASHBOARD_JSON" "$cm contains valid Grafana dashboard JSON"
  else
    fail "DASHBOARD_JSON" "$cm contains invalid dashboard JSON"
  fi
done

if kubectl -n "$ns" get deploy observability-vmstack-grafana >/dev/null 2>&1; then
  if kubectl -n "$ns" rollout status deploy/observability-vmstack-grafana --timeout=30s >/dev/null 2>&1; then
    pass "GRAFANA_ROLLOUT" "Grafana deployment is rolled out"
  else
    warn "GRAFANA_ROLLOUT" "Grafana deployment did not confirm rollout within 30s"
  fi
else
  fail "GRAFANA_ROLLOUT" "Grafana deployment missing"
fi

if kubectl -n "$ns" get configmap grafana-datasources >/dev/null 2>&1; then
  pass "GRAFANA_DATASOURCES" "Grafana datasource ConfigMap exists"
else
  warn "GRAFANA_DATASOURCES" "Grafana datasource ConfigMap missing; Loki dashboard panels may not work until CH05 base deploy reconciles datasources"
fi

security_cm="grafana-dashboard-60-security-audit"
if kubectl -n "$ns" get configmap "$security_cm" >/dev/null 2>&1; then
  pass "SECURITY_DASHBOARD" "Security & Audit dashboard is provisioned"
else
  fail "SECURITY_DASHBOARD" "Security & Audit dashboard is missing"
fi

# CH05.3 will make host-side audit ingestion first-class. Until then this is
# explicitly UNKNOWN/WARN rather than a hard failure so dashboard provisioning
# can be validated independently from host collector onboarding.
# The operator view should not be polluted by upstream/raw engineering dashboards.
# CH05.1 intentionally keeps only PlatformInit operational dashboards visible.
allowed_dashboards="grafana-dashboard-00-platform-overview grafana-dashboard-05-alert-operations-center grafana-dashboard-10-host-infrastructure grafana-dashboard-20-kubernetes-k3s grafana-dashboard-30-argocd-gitops grafana-dashboard-40-identity-sso grafana-dashboard-50-observability-self-monitoring grafana-dashboard-60-security-audit grafana-dashboard-90-application-template"
stray_count=0
while IFS= read -r cm_name; do
  [[ -z "$cm_name" ]] && continue
  case " $allowed_dashboards " in
    *" $cm_name "*) ;;
    *)
      warn "DASHBOARD_NOISE" "unexpected Grafana dashboard ConfigMap remains: $cm_name"
      stray_count=$((stray_count + 1))
      ;;
  esac
done < <(kubectl -n "$ns" get configmap -l grafana_dashboard=1 -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ "$stray_count" -eq 0 ]]; then
  pass "DASHBOARD_NOISE" "only PlatformInit operational dashboards are exposed"
fi

if kubectl -n "$ns" get configmap grafana-dashboard-05-alert-operations-center >/dev/null 2>&1; then
  pass "ALERT_OPERATIONS_DASHBOARD" "Alert Operations Center dashboard is provisioned"
else
  fail "ALERT_OPERATIONS_DASHBOARD" "Alert Operations Center dashboard is missing"
fi

warn "SECURITY_AUDIT_SOURCE" "host audit ingestion is designed but not yet enforced by CH05.3; implement CH05.3 next"
