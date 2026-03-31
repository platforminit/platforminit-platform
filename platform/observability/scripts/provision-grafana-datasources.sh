#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"

log(){ echo "[CH05-DATASOURCE][$(date -u +%FT%TZ)] $*"; }

find_service_by_regex() {
  local regex="$1"
  kubectl -n "$OBS_NAMESPACE" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"
"}{end}'     | grep -E "$regex" | head -n1 || true
}

vm_service="$(find_service_by_regex 'vmstack.*(vmsingle|vmselect)|vmsingle|vmselect')"
loki_service="$(find_service_by_regex '^loki$|^loki-.*|.*loki.*')"

[ -n "$vm_service" ] || { echo "Unable to resolve VictoriaMetrics service in namespace $OBS_NAMESPACE" >&2; kubectl -n "$OBS_NAMESPACE" get svc >&2; exit 1; }
[ -n "$loki_service" ] || { echo "Unable to resolve Loki service in namespace $OBS_NAMESPACE" >&2; kubectl -n "$OBS_NAMESPACE" get svc >&2; exit 1; }

vm_url="http://${vm_service}.${OBS_NAMESPACE}.svc.cluster.local:8428"
loki_url="http://${loki_service}.${OBS_NAMESPACE}.svc.cluster.local:3100"

tmp_render="$(mktemp)"
sed   -e "s#\${VICTORIAMETRICS_URL}#${vm_url}#g"   -e "s#\${LOKI_URL}#${loki_url}#g"   "$ROOT_DIR/manifests/grafana/grafana-datasources.yaml.tpl" > "$tmp_render"

log "Apply datasource ConfigMap"
kubectl apply -f "$tmp_render"
rm -f "$tmp_render"
