#!/usr/bin/env bash
set -euo pipefail

ns="${NAMESPACE:-observability}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

pass(){ echo "PASS | $1 | $2"; }
fail(){ echo "FAIL | $1 | $2"; exit 1; }
warn(){ echo "WARN | $1 | $2"; }

command -v kubectl >/dev/null 2>&1 || fail "KUBECTL" "kubectl is missing"
command -v python3 >/dev/null 2>&1 || fail "PYTHON" "python3 is missing"
[ -f "${KUBECONFIG}" ] || fail "KUBECONFIG" "missing kubeconfig: ${KUBECONFIG}"

kubectl get ns "$ns" >/dev/null 2>&1 && pass "NAMESPACE" "$ns namespace exists" || fail "NAMESPACE" "$ns namespace missing"
kubectl get crd vmrules.operator.victoriametrics.com >/dev/null 2>&1 && pass "VMRULE_CRD" "VMRule CRD exists" || fail "VMRULE_CRD" "VMRule CRD missing"

if kubectl -n "$ns" get vmrule platform-rules >/dev/null 2>&1; then
  pass "VMRULE" "platform-rules VMRule exists"
else
  fail "VMRULE" "platform-rules VMRule missing"
fi

rule_json="$(kubectl -n "$ns" get vmrule platform-rules -o json)"
RULE_JSON="$rule_json" python3 - <<'PY'
import json, os, sys
payload = json.loads(os.environ['RULE_JSON'])
groups = payload.get('spec', {}).get('groups', [])
if not groups:
    print('no rule groups', file=sys.stderr)
    sys.exit(1)
required_label_keys = {'severity', 'category', 'project', 'environment', 'lifecycle_ch', 'service', 'owner'}
required_annotation_keys = {'summary', 'impact', 'action', 'runbook_url'}
alerts = []
missing = []
severities = set()
categories = set()
for group in groups:
    for rule in group.get('rules', []):
        name = rule.get('alert')
        if not name:
            continue
        alerts.append(name)
        labels = rule.get('labels') or {}
        annotations = rule.get('annotations') or {}
        severities.add(labels.get('severity'))
        categories.add(labels.get('category'))
        missing_labels = sorted(required_label_keys - set(labels))
        missing_annotations = sorted(required_annotation_keys - set(annotations))
        if missing_labels or missing_annotations:
            missing.append((name, missing_labels, missing_annotations))
if len(alerts) < 10:
    print(f'expected at least 10 alerts, found {len(alerts)}', file=sys.stderr)
    sys.exit(1)
if missing:
    for name, labels, annotations in missing:
        print(f'{name}: missing labels={labels} annotations={annotations}', file=sys.stderr)
    sys.exit(1)
if not {'warning', 'critical'}.issubset(severities):
    print(f'missing warning/critical coverage, severities={sorted(x for x in severities if x)}', file=sys.stderr)
    sys.exit(1)
needed_categories = {'host', 'cluster', 'platform', 'identity', 'observability'}
if not needed_categories.issubset(categories):
    print(f'missing categories: {sorted(needed_categories - categories)}', file=sys.stderr)
    sys.exit(1)
print(f'validated {len(alerts)} alert rules across {len(groups)} groups')
PY
pass "ALERT_CONTRACT" "VMRule labels and annotations follow PlatformInit alert contract"

if kubectl -n "$ns" get pods -o name 2>/dev/null | grep -qE '/.*vmalert.*'; then
  ready_count="$(kubectl -n "$ns" get pods -o json 2>/dev/null | python3 -c 'import json, sys; payload=json.load(sys.stdin); count=0
for item in payload.get("items", []):
    name=item.get("metadata", {}).get("name", "")
    if "vmalert" not in name:
        continue
    conds=item.get("status", {}).get("conditions", [])
    if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds):
        count += 1
print(count)')"
  if [[ "${ready_count}" -gt 0 ]]; then
    pass "VMALERT_READY" "VMAlert pod is Ready"
  else
    warn "VMALERT_READY" "VMAlert pod exists but readiness was not confirmed"
  fi
else
  warn "VMALERT_READY" "VMAlert pod was not found by name; check chart-generated workload names"
fi

if kubectl -n "$ns" get pods -o name 2>/dev/null | grep -qE '/.*alertmanager.*'; then
  pass "ALERTMANAGER_POD" "Alertmanager pod exists"
else
  warn "ALERTMANAGER_POD" "Alertmanager pod not found; alert routing may be unavailable"
fi

if kubectl -n "$ns" get configmap grafana-dashboard-05-alert-operations-center >/dev/null 2>&1; then
  pass "ALERT_OPS_DASHBOARD" "Alert Operations Center dashboard exists"
else
  warn "ALERT_OPS_DASHBOARD" "Alert Operations Center dashboard missing; run 05.1 - Provision Dashboards"
fi

# Verify VictoriaMetrics can expose ALERTS after VMAlert evaluation. This is a
# soft check because a newly created rule set may need one evaluation interval.
find_vm_service() {
  kubectl -n "$ns" get svc --no-headers 2>/dev/null \
    | awk '/vmsingle|victoria-metrics-single|vmselect/ { print $1; exit }'
}

svc="$(find_vm_service || true)"
if [[ -n "$svc" ]]; then
  port="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    local_port="18429"
    kubectl -n "$ns" port-forward "svc/${svc}" "${local_port}:${port}" >/tmp/ch05-2-vm-port-forward.log 2>&1 &
    pf_pid="$!"
    trap 'kill "$pf_pid" >/dev/null 2>&1 || true' EXIT
    for _ in $(seq 1 20); do
      if curl -fsS "http://127.0.0.1:${local_port}/api/v1/query?query=up" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if curl -fsSG --max-time 10 --data-urlencode 'query=ALERTS' "http://127.0.0.1:${local_port}/api/v1/query" \
      | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if "data" in p else 1)' >/dev/null 2>&1; then
      pass "ALERTS_QUERY" "VictoriaMetrics accepts ALERTS query"
    else
      warn "ALERTS_QUERY" "ALERTS query did not return a normal response yet"
    fi
  else
    warn "VM_SERVICE_PORT" "could not discover VictoriaMetrics service port"
  fi
else
  warn "VM_SERVICE" "could not discover VictoriaMetrics service"
fi

pass "CH05_2_ALERTING" "alerting provisioning validation completed"
