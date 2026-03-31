#!/usr/bin/env bash
set -euo pipefail
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"

log(){ echo "[CH05-VALIDATE][$(date -u +%FT%TZ)] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing binary: $1" >&2; exit 1; }; }
need kubectl

log "Wait for key workloads"
kubectl -n "$OBS_NAMESPACE" rollout status deploy/vmstack-grafana --timeout=10m || true
kubectl -n "$OBS_NAMESPACE" rollout status sts/loki --timeout=10m || true
kubectl -n "$OBS_NAMESPACE" rollout status ds/alloy --timeout=10m || true

log "Print workload inventory"
kubectl -n "$OBS_NAMESPACE" get pods -o wide
kubectl -n "$OBS_NAMESPACE" get svc
kubectl -n "$OBS_NAMESPACE" get vmservicescrape || true
kubectl -n "$OBS_NAMESPACE" get vmrule || true

log "Verify Grafana datasource config"
kubectl -n "$OBS_NAMESPACE" get configmap grafana-datasources-platforminit >/dev/null

log "Verify helm releases"
helm -n "$OBS_NAMESPACE" list

log "Validation finished"
