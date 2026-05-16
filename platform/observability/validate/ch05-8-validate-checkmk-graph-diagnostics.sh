#!/usr/bin/env bash
set -uo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }

log "Diagnostic-only CH05.8 graph validation hook completed."
log "This workflow intentionally does not change Checkmk graphing, metrics, RRD state, autochecks or service discovery."
log "Use the uploaded operations-graph artifact to inspect service page probes, graph_recipe traces, metric plugins, RRD/perfdata state and Checkmk logs."
exit 0
