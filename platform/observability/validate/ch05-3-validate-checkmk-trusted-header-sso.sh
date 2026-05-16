#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG
[[ -n "$BASE_DOMAIN" ]] || die "Missing BASE_DOMAIN"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth >/dev/null || die "Missing Checkmk Authentik forwardAuth middleware"
kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk >/dev/null || die "Missing Checkmk IngressRoute"
kubectl -n "$NAMESPACE" get secret checkmk-sso >/dev/null || die "Missing checkmk-sso secret"

kubectl -n "$NAMESPACE" get service authentik-forward-auth >/dev/null || die "Missing operations-local ExternalName service for Authentik forwardAuth"
external_name="$(kubectl -n "$NAMESPACE" get service authentik-forward-auth -o jsonpath='{.spec.externalName}')"
case "$external_name" in
  authentik-server.*.svc.cluster.local) ;;
  *) die "Unexpected Authentik forwardAuth ExternalName: $external_name" ;;
esac
addr="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')"
case "$addr" in
  *authentik-forward-auth.operations.svc.cluster.local*/outpost.goauthentik.io/auth/traefik*) ;;
  *) die "Checkmk middleware does not point to the operations-local Authentik forwardAuth endpoint: $addr" ;;
esac
kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk -o yaml | grep -q 'checkmk-authentik-forward-auth' || die "Checkmk IngressRoute is not protected by Authentik middleware"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o yaml | grep -qi 'X-authentik-username' || die "Checkmk forwardAuth middleware does not forward X-authentik-username"

shim_conf="$(kubectl -n "$NAMESPACE" get configmap checkmk-nginx-auth-shim -o jsonpath='{.data.default\.conf}')"
[[ -n "$shim_conf" ]] || die "Checkmk auth shim ConfigMap does not contain default.conf"

if ! printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-User[[:space:]]+cmkadmin;'; then
  printf '%s\n' "=== checkmk-nginx-auth-shim default.conf ===" >&2
  printf '%s\n' "$shim_conf" >&2
  die "Checkmk auth shim does not map approved Authentik sessions to deterministic Checkmk user cmkadmin"
fi
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_pass_request_headers[[:space:]]+off;' \
  || die "Checkmk auth shim still forwards all browser/Authentik headers"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Cookie[[:space:]]+"";' \
  || die "Checkmk auth shim does not clear stale browser cookies"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Authorization[[:space:]]+"";' \
  || die "Checkmk auth shim does not clear browser Authorization headers"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-Proto[[:space:]]+https;' \
  || die "Checkmk auth shim does not force HTTPS scheme for the upstream Checkmk GUI"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Original-User[[:space:]]+\$http_x_authentik_username;' \
  || die "Checkmk auth shim does not preserve original Authentik username"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Email[[:space:]]+\$http_x_authentik_email;' \
  || die "Checkmk auth shim does not map Authentik email header"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Groups[[:space:]]+\$http_x_authentik_groups;' \
  || die "Checkmk auth shim does not map Authentik groups header"

printf '%s\n' "$shim_conf" | grep -Eq 'location[[:space:]]*=[[:space:]]*/cmk/check_mk/logout\.py' \
  || die "Checkmk auth shim does not intercept the native Checkmk logout endpoint"
printf '%s\n' "$shim_conf" | grep -Eq '/outpost\.goauthentik\.io/sign_out' \
  || die "Checkmk logout is not redirected to the Authentik proxy sign_out endpoint"

checkmk_pod="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$checkmk_pod" ]] || die "Could not resolve Checkmk pod"
checkmk_auth_conf="$(kubectl -n "$NAMESPACE" exec "$checkmk_pod" -c checkmk -- bash -lc "grep -R 'auth_by_http_header' /omd/sites/cmk/etc/check_mk/multisite.d/wato 2>/dev/null || true")"
echo "$checkmk_auth_conf" | grep -q "X-Remote-User" || die "Checkmk site is not configured for X-Remote-User trusted-header authentication"

echo "PASS: Checkmk trusted-header SSO Kubernetes contract exists"
