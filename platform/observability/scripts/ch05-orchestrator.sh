#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
VM_CHART_VERSION="${VM_CHART_VERSION:-0.72.5}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-6.55.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.0.0}"

log(){ echo "[CH05][$(date -u +%FT%TZ)] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing binary: $1" >&2; exit 1; }; }

need kubectl
need helm
need awk
need sed
need grep

log "Apply namespace"
kubectl apply -f "$ROOT_DIR/manifests/namespace.yaml"

log "Deploy VictoriaMetrics K8s Stack"
helm upgrade --install vmstack vm/victoria-metrics-k8s-stack   --namespace "$OBS_NAMESPACE"   --create-namespace   --version "$VM_CHART_VERSION"   --values "$ROOT_DIR/values/victoria-metrics-k8s-stack-values.yaml"   --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD"   --wait --timeout 15m

log "Deploy Loki"
helm upgrade --install loki grafana/loki   --namespace "$OBS_NAMESPACE"   --version "$LOKI_CHART_VERSION"   --values "$ROOT_DIR/values/loki-values.yaml"   --wait --timeout 15m

log "Deploy Alloy"
helm upgrade --install alloy grafana/alloy   --namespace "$OBS_NAMESPACE"   --version "$ALLOY_CHART_VERSION"   --values "$ROOT_DIR/values/alloy-values.yaml"   --wait --timeout 15m

log "Apply VMServiceScrape resources"
kubectl apply -f "$ROOT_DIR/manifests/metrics/argocd-vmservicescrape.yaml" || true
kubectl apply -f "$ROOT_DIR/manifests/metrics/cert-manager-vmservicescrape.yaml" || true
kubectl apply -f "$ROOT_DIR/manifests/metrics/traefik-vmservicescrape.yaml" || true

log "Apply VMRule alerts"
kubectl apply -f "$ROOT_DIR/manifests/alerts/platform-vmrule.yaml"

log "Provision Grafana datasources"
bash "$ROOT_DIR/scripts/provision-grafana-datasources.sh"

log "Validate observability baseline"
bash "$ROOT_DIR/validate/ch05-validate-observability.sh"

log "CH05 completed"
