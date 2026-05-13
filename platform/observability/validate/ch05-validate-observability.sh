#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
PLATFORMINIT_OBSERVABILITY_PATH="${PLATFORMINIT_OBSERVABILITY_PATH:-/srv/observability}"

ns="observability"

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

kubectl get ns "$ns" >/dev/null 2>&1 && pass "NAMESPACE" "observability namespace exists" || fail "NAMESPACE" "missing"

kubectl -n "$ns" get pods >/dev/null 2>&1 && pass "POD_LIST" "pods listed" || fail "POD_LIST" "no pods"

kubectl -n "$ns" get deploy observability-vmstack-grafana >/dev/null 2>&1 && \
  pass "GRAFANA" "grafana deployment exists" || fail "GRAFANA" "missing"

if kubectl -n "$ns" get vmsingle >/dev/null 2>&1; then
  pass "VM_SINGLE" "VMSingle CR exists"
elif kubectl -n "$ns" get pods -l app.kubernetes.io/name=victoria-metrics-single-server >/dev/null 2>&1; then
  pass "VM_SINGLE" "VictoriaMetrics pod present"
else
  fail "VM_SINGLE" "VictoriaMetrics not detected"
fi

if kubectl -n "$ns" get vmagent >/dev/null 2>&1; then
  pass "VMAGENT_CR" "VMAgent CR exists"
else
  fail "VMAGENT_CR" "VMAgent CR missing"
fi

if kubectl -n "$ns" get secret vmagent-additional-scrape >/dev/null 2>&1; then
  pass "VMAGENT_SCRAPE_SECRET" "vmagent additional scrape Secret exists"
else
  fail "VMAGENT_SCRAPE_SECRET" "vmagent additional scrape Secret missing"
fi

vmagent_pod="$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep -E '/.*vmagent.*' | head -n1 || true)"
if [[ -n "$vmagent_pod" ]]; then
  if kubectl -n "$ns" get "$vmagent_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    pass "VMAGENT_POD" "VMAgent pod is Ready (${vmagent_pod#pod/})"
  else
    fail "VMAGENT_POD" "VMAgent pod exists but is not Ready (${vmagent_pod#pod/})"
  fi
else
  kubectl -n "$ns" get pods -o wide >&2 || true
  kubectl -n "$ns" get vmagent -o yaml >&2 || true
  fail "VMAGENT_POD" "VMAgent pod missing"
fi

if kubectl -n "$ns" get pods -l app.kubernetes.io/name=kube-state-metrics --no-headers 2>/dev/null | grep -q .; then
  pass "KUBE_STATE_METRICS" "kube-state-metrics pod exists"
else
  fail "KUBE_STATE_METRICS" "kube-state-metrics pod missing"
fi

if kubectl -n "$ns" get pods -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null | grep -q .; then
  pass "NODE_EXPORTER" "node-exporter pod exists"
else
  fail "NODE_EXPORTER" "node-exporter pod missing"
fi


PLATFORM_DASHBOARDS=(
  grafana-dashboard-platform-start-here
  grafana-dashboard-platform-cluster-overview
  grafana-dashboard-platform-node-overview
  grafana-dashboard-platform-logs-overview
)
for dashboard_cm in "${PLATFORM_DASHBOARDS[@]}"; do
  if kubectl -n "$ns" get configmap "$dashboard_cm" >/dev/null 2>&1; then
    pass "PLATFORM_DASHBOARD" "$dashboard_cm exists"
  else
    fail "PLATFORM_DASHBOARD" "$dashboard_cm missing"
  fi
done

noise_dashboards="$(kubectl -n "$ns" get configmap \
  -l 'grafana_dashboard=1,app.kubernetes.io/part-of notin (platforminit)' \
  --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
if [[ -n "${noise_dashboards// }" ]]; then
  fail "DASHBOARD_NOISE_POLICY" "non-PlatformInit dashboard ConfigMaps still present: ${noise_dashboards}"
else
  pass "DASHBOARD_NOISE_POLICY" "only PlatformInit beginner dashboards are provisioned"
fi

if kubectl -n "$ns" get ingress grafana >/dev/null 2>&1; then
  pass "GRAFANA_INGRESS" "grafana ingress exists"
else
  fail "GRAFANA_INGRESS" "grafana ingress missing"
fi

if kubectl -n "$ns" get certificate grafana-tls >/dev/null 2>&1; then
  pass "GRAFANA_TLS" "grafana certificate exists"
else
  fail "GRAFANA_TLS" "grafana certificate missing"
fi

# CH05.1 may enable Grafana SSO after the CH05 baseline deploy. CH05 itself does
# not require SSO, but it should make auth overlay drift visible when the OAuth
# credential secret exists and Grafana no longer renders the Generic OAuth block.
if kubectl -n "$ns" get secret grafana-authentik-oauth >/dev/null 2>&1; then
  grafana_ini="$(kubectl -n "$ns" get configmap observability-vmstack-grafana -o jsonpath='{.data.grafana\.ini}' 2>/dev/null || true)"
  if echo "$grafana_ini" | grep -q '\[auth.generic_oauth\]' && echo "$grafana_ini" | grep -q '^enabled = true'; then
    pass "GRAFANA_SSO_OVERLAY" "Grafana SSO overlay is present"
  else
    warn "GRAFANA_SSO_OVERLAY" "grafana-authentik-oauth secret exists, but Grafana Generic OAuth is not enabled; run 05.1 after CH05 baseline"
  fi
fi

find_vm_service() {
  kubectl -n "$ns" get svc --no-headers 2>/dev/null \
    | awk '/vmsingle|victoria-metrics-single|vmselect/ { print $1; exit }'
}

vm_query_nonempty() {
  local query="$1"
  local body=""
  body="$(curl -fsSG --max-time 10 --data-urlencode "query=${query}" "http://127.0.0.1:${VM_LOCAL_PORT}/api/v1/query")" || return 1
  python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(2)
result = payload.get("data", {}).get("result", [])
sys.exit(0 if result else 1)
' <<<"$body"
}

validate_metric_data() {
  local svc=""
  local svc_port=""
  local pf_pid=""

  svc="$(find_vm_service || true)"
  if [[ -z "$svc" ]]; then
    fail "VM_QUERY_SERVICE" "could not discover VictoriaMetrics service"
  fi
  pass "VM_QUERY_SERVICE" "using service ${svc}"

  svc_port="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')"
  if [[ -z "$svc_port" ]]; then
    fail "VM_QUERY_SERVICE_PORT" "could not discover VictoriaMetrics service port"
  fi

  export VM_LOCAL_PORT="18428"
  kubectl -n "$ns" port-forward "svc/${svc}" "${VM_LOCAL_PORT}:${svc_port}" >/tmp/ch05-vm-port-forward.log 2>&1 &
  pf_pid="$!"
  trap 'kill "$pf_pid" >/dev/null 2>&1 || true' RETURN

  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${VM_LOCAL_PORT}/health" >/dev/null 2>&1 || \
       curl -fsS "http://127.0.0.1:${VM_LOCAL_PORT}/api/v1/status/buildinfo" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if vm_query_nonempty 'up'; then
    pass "VM_QUERY_UP" "VictoriaMetrics has scrape target data"
  else
    fail "VM_QUERY_UP" "VictoriaMetrics has no up{} series; scrape pipeline is not working"
  fi

  if vm_query_nonempty 'node_uname_info or node_cpu_seconds_total'; then
    pass "VM_QUERY_NODE" "node-exporter/system metrics are present"
  else
    fail "VM_QUERY_NODE" "node-exporter/system metrics are missing"
  fi

  if vm_query_nonempty 'up{job=~".*node-exporter.*|platform-node-exporter"} == 1'; then
    pass "NODE_EXPORTER_SCRAPE" "node-exporter scrape target is up"
  else
    fail "NODE_EXPORTER_SCRAPE" "node-exporter scrape target is not up; host dashboards and host alerts are not trustworthy"
  fi

  if vm_query_nonempty 'kube_node_info or kube_pod_info'; then
    pass "VM_QUERY_KSM" "kube-state-metrics Kubernetes object metrics are present"
  else
    fail "VM_QUERY_KSM" "kube-state-metrics data is missing"
  fi

  if vm_query_nonempty 'container_cpu_usage_seconds_total'; then
    pass "VM_QUERY_CADVISOR" "cAdvisor/container metrics are present"
  else
    warn "VM_QUERY_CADVISOR" "cAdvisor/container metrics are missing; k3s node proxy permissions may need review"
  fi

  if vm_query_nonempty 'apiserver_request_total'; then
    pass "VM_QUERY_APISERVER" "API server metrics are present"
  else
    warn "VM_QUERY_APISERVER" "API server metrics are missing; some generic Kubernetes control-plane dashboards may show No data on k3s"
  fi
}

validate_metric_data
