#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${REPO_ROOT}/manifests/grafana/grafana-datasources.yaml.tpl"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
[ -f "${KUBECONFIG}" ] || { echo "Missing kubeconfig: ${KUBECONFIG}" >&2; exit 1; }

kubectl apply -f "${TEMPLATE}"
