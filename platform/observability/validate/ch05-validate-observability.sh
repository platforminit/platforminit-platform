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

kubectl -n "$ns" get deploy observability-vmstack-grafana >/dev/null 2>&1 &&   pass "GRAFANA" "grafana deployment exists" || fail "GRAFANA" "missing"

if kubectl -n "$ns" get vmsingle >/dev/null 2>&1; then
  pass "VM_SINGLE" "VMSingle CR exists"
elif kubectl -n "$ns" get pods -l app.kubernetes.io/name=victoria-metrics-single-server >/dev/null 2>&1; then
  pass "VM_SINGLE" "VictoriaMetrics pod present"
else
  fail "VM_SINGLE" "VictoriaMetrics not detected"
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


# CH06.1 may enable Grafana SSO after the CH05 baseline deploy. CH05 itself does
# not require SSO, but it should make auth overlay drift visible when the OAuth
# credential secret exists and Grafana no longer renders the Generic OAuth block.
if kubectl -n "$ns" get secret grafana-authentik-oauth >/dev/null 2>&1; then
  grafana_ini="$(kubectl -n "$ns" get configmap observability-vmstack-grafana -o jsonpath='{.data.grafana\.ini}' 2>/dev/null || true)"
  if echo "$grafana_ini" | grep -q '\[auth.generic_oauth\]' && echo "$grafana_ini" | grep -q '^enabled = true'; then
    pass "GRAFANA_SSO_OVERLAY" "Grafana SSO overlay is present"
  else
    warn "GRAFANA_SSO_OVERLAY" "grafana-authentik-oauth secret exists, but Grafana Generic OAuth is not enabled; run 06.1 after CH05 baseline"
  fi
fi
