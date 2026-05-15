#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

secret_value(){
  local key="$1"
  kubectl -n "$NAMESPACE" get secret openobserve-sso -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}
validate_openobserve_oidc_secret(){
  local expected_base="https://auth.${BASE_DOMAIN}"
  local base auth_suffix token_suffix keys_suffix
  base="$(secret_value O2_DEX_BASE_URL)"
  auth_suffix="$(secret_value O2_DEX_AUTH_EP_SUFFIX)"
  token_suffix="$(secret_value O2_DEX_TOKEN_EP_SUFFIX)"
  keys_suffix="$(secret_value O2_DEX_KEYS_EP_SUFFIX)"
  [[ "$base" == "$expected_base" ]] || die "OpenObserve O2_DEX_BASE_URL is invalid: '${base:-missing}'. Expected '${expected_base}'. OpenObserve appends endpoint suffixes to the Authentik public host; parent-directory suffixes can route to an Authentik Not Found page."
  [[ "$auth_suffix" == "/application/o/authorize/" ]] || die "OpenObserve O2_DEX_AUTH_EP_SUFFIX is invalid: '${auth_suffix:-missing}'"
  [[ "$token_suffix" == "/application/o/token/" ]] || die "OpenObserve O2_DEX_TOKEN_EP_SUFFIX is invalid: '${token_suffix:-missing}'"
  [[ "$keys_suffix" == "/application/o/platforminit-openobserve/jwks/" ]] || die "OpenObserve O2_DEX_KEYS_EP_SUFFIX is invalid: '${keys_suffix:-missing}'"
  log "PASS: OpenObserve OIDC endpoints use Authentik documented paths: ${base}"
}
kubectl -n "$NAMESPACE" get ingress zabbix openobserve >/dev/null
kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null
kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q 'openobserve-enterprise' || die "OpenObserve is not using the Enterprise image"
kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}' | grep -q 'openobserve-sso' || die "OpenObserve SSO secret is not mounted"
validate_openobserve_oidc_secret
kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q 'ZBX_SSO_SETTINGS' || die "Zabbix SAML runtime env is missing"
kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' | grep -q 'zabbix-saml-certs' || die "Zabbix SAML certificate volume is not mounted"
if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
  die "Stale forward-auth middleware exists; CH05.3 must use native app SSO, not proxy-only access gate"
fi
for host in "zabbix.${BASE_DOMAIN}" "logs.${BASE_DOMAIN}"; do
  kubectl -n "$NAMESPACE" get ingress -o json | grep -q "$host" || die "Missing ingress host: $host"
done
log "PASS: Operations WebUI native SSO prerequisites are configured without app rollout in CH05.3"
