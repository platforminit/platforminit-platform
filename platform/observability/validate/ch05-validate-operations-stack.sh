#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
warn(){ echo "WARN: $*" >&2; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
VALIDATION_MODE="${VALIDATION_MODE:-runtime}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
CHECKMK_LOCAL_PORT="${CHECKMK_LOCAL_PORT:-18085}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
case "$VALIDATION_MODE" in runtime|runtime_with_sso) ;; *) die "Invalid VALIDATION_MODE=${VALIDATION_MODE}. Use runtime or runtime_with_sso." ;; esac
need kubectl
need curl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

diag(){
  log "Operations diagnostics"
  kubectl -n "$NAMESPACE" get pods,svc,ingressroute,pvc,certificate,middleware 2>/dev/null || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -80 || true
  kubectl -n "$NAMESPACE" logs deploy/checkmk --all-containers --tail=160 || true
}
trap 'rc=$?; [[ $rc -eq 0 ]] || diag; exit $rc' EXIT

log "Validating Argo CD operations-stack health"
kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD app ${APP_NAME}"
sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
if [[ "$sync_status" != "Synced" ]]; then
  kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME"     -o jsonpath='{range .status.resources[*]}{.kind}{"/"}{.name}{" sync="}{.status}{" health="}{.health.status}{"
"}{end}' 2>/dev/null || true
  die "operations-stack is not Synced: ${sync_status:-unknown}. Run 05.2 - Sync Operations Stack after CH05 manifest/config changes before validating."
fi
[[ "$health_status" == "Healthy" ]] || die "operations-stack is not Healthy: ${health_status:-unknown}"

log "Validating Checkmk runtime resources"
kubectl -n "$NAMESPACE" get secret checkmk-admin checkmk-sso >/dev/null
kubectl -n "$NAMESPACE" get pvc checkmk-sites >/dev/null
kubectl -n "$NAMESPACE" get svc checkmk >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=240s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"
kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "omd status ${CHECKMK_SITE}" >/tmp/ch05-checkmk-omd-status.txt || { cat /tmp/ch05-checkmk-omd-status.txt >&2 || true; die "Checkmk site status failed"; }

log "Validating Checkmk frontend through service port-forward"
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:5000" >/tmp/ch05-checkmk-port-forward.log 2>&1 &
PF="$!"
cleanup(){ kill "$PF" >/dev/null 2>&1 || true; }
trap 'rc=$?; cleanup; [[ $rc -eq 0 ]] || diag; exit $rc' EXIT
for _ in $(seq 1 45); do
  code="$(curl -sS -o /tmp/ch05-checkmk.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
  [[ "$code" =~ ^(200|302|401|403)$ ]] && break
  sleep 2
done
code="$(curl -sS -o /tmp/ch05-checkmk.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
[[ "$code" =~ ^(200|302|401|403)$ ]] || { cat /tmp/ch05-checkmk-port-forward.log >&2 || true; die "Checkmk frontend did not answer; HTTP=${code}"; }
log "PASS: Checkmk frontend answered HTTP ${code}"

if [[ "$VALIDATION_MODE" == "runtime_with_sso" ]]; then
  log "Validating Checkmk Authentik trusted-header SSO Kubernetes contract"
  kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth >/dev/null || die "Missing Authentik forwardAuth middleware"
  kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk >/dev/null || die "Missing Checkmk IngressRoute"
  kubectl -n "$NAMESPACE" get certificate checkmk-tls >/dev/null || die "Missing Checkmk TLS Certificate"
  addr="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')"
  [[ "$addr" == *outpost.goauthentik.io/auth/traefik* ]] || die "Unexpected forwardAuth endpoint: $addr"
  kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk -o yaml | grep -q 'checkmk-authentik-forward-auth' || die "Checkmk IngressRoute is not protected by Authentik middleware"
  log "PASS: Checkmk trusted-header SSO Kubernetes contract is present"
fi

log "PASS: CH05 Checkmk operations stack validation succeeded mode=${VALIDATION_MODE}"
