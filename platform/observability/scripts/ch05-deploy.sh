#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
sudo --preserve-env=GRAFANA_ADMIN_PASSWORD,OBS_NAMESPACE,VM_CHART_VERSION,LOKI_CHART_VERSION,ALLOY_CHART_VERSION bash "$ROOT_DIR/scripts/ch05-orchestrator.sh"
