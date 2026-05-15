#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
export KUBECONFIG
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "test -f /omd/sites/${CHECKMK_SITE}/local/share/platforminit/README.txt"
echo "PASS: Checkmk operations model bootstrap marker exists"
