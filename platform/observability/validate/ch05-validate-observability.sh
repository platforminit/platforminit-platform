#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
[ -f "${KUBECONFIG}" ] || { echo "FAIL | KUBECONFIG | missing kubeconfig ${KUBECONFIG}"; exit 1; }


pass(){ echo "PASS | $1 | $2"; }
fail(){ echo "FAIL | $1 | $2"; exit 1; }

NS="${NAMESPACE:-observability}"

kubectl get ns "${NS}" >/dev/null 2>&1 && pass NAMESPACE "observability namespace exists" || fail NAMESPACE "namespace missing"
kubectl -n "${NS}" get pods >/dev/null 2>&1 && pass POD_LIST "pods listed" || fail POD_LIST "cannot list pods"

for deploy in observability-vmstack-grafana alloy; do
  kubectl -n "${NS}" get deploy "${deploy}" >/dev/null 2>&1 && pass "DEPLOY_${deploy}" "deployment exists" || true
done

kubectl -n "${NS}" get statefulset observability-vmstack-vmsingle >/dev/null 2>&1 && pass VM_SINGLE "VictoriaMetrics present" || fail VM_SINGLE "VictoriaMetrics statefulset missing"
kubectl -n "${NS}" get statefulset loki >/dev/null 2>&1 && pass LOKI "Loki present" || fail LOKI "Loki statefulset missing"
kubectl -n "${NS}" get configmap grafana-datasources >/dev/null 2>&1 && pass GRAFANA_DS "Grafana datasources configmap present" || fail GRAFANA_DS "Grafana datasources configmap missing"
kubectl -n "${NS}" get vmrule platform-rules >/dev/null 2>&1 && pass VMRULE "VMRule present" || fail VMRULE "VMRule missing"