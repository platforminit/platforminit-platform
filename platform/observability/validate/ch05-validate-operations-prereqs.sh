#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
export KUBECONFIG
kubectl -n "$NAMESPACE" get secret zabbix-postgres openobserve-root openobserve-sso zabbix-saml-certs >/dev/null
echo "PASS: operations prerequisite secrets exist"
