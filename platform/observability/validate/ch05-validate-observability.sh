#!/usr/bin/env bash
set -euo pipefail

ns="observability"

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }

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
