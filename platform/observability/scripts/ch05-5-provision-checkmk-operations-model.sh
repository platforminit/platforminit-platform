#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
export KUBECONFIG
[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"
log "Preparing PlatformInit Checkmk site helper files in pod/${POD}"
kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "
set -euo pipefail
omd status ${CHECKMK_SITE} >/dev/null
mkdir -p /omd/sites/${CHECKMK_SITE}/local/share/platforminit
cat > /omd/sites/${CHECKMK_SITE}/local/share/platforminit/README.txt <<'EOF'
PlatformInit CH05 Checkmk layer

Operator model:
- Host/service/state is owned by Checkmk.
- Authentik protects the Checkmk URL through forwardAuth.
- The auth-shim container translates X-authentik-username to X-Remote-User.

Next provisioning stage:
- Add platforminit-dev-01 as a host.
- Add SSH, Kubernetes API, Argo CD, Authentik and storage checks.
EOF
" >/dev/null
log "Checkmk operations model bootstrap marker created"
