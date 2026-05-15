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

kubectl -n "$NAMESPACE" get service authentik-embedded-outpost >/dev/null || die "Missing operations-local ExternalName service for Authentik embedded outpost"
external_name="$(kubectl -n "$NAMESPACE" get service authentik-embedded-outpost -o jsonpath='{.spec.externalName}')"
case "$external_name" in
  *ak-outpost-authentik-embedded-outpost*.*.svc.cluster.local) ;;
  *) die "Unexpected Authentik outpost ExternalName: $external_name" ;;
esac
addr="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')"
case "$addr" in
  *outpost.goauthentik.io/auth/traefik*) ;;
  *) die "Checkmk middleware does not point to Authentik Traefik forwardAuth endpoint: $addr" ;;
esac
kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk -o yaml | grep -q 'checkmk-authentik-forward-auth' || die "Checkmk IngressRoute is not protected by Authentik middleware"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o yaml | grep -qi 'X-authentik-username' || die "Checkmk forwardAuth middleware does not forward X-authentik-username"

shim_conf="$(kubectl -n "$NAMESPACE" get configmap checkmk-nginx-auth-shim -o jsonpath='{.data.default\.conf}')"
[[ -n "$shim_conf" ]] || die "Checkmk auth shim ConfigMap does not contain default.conf"

printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-User[[:space:]]+\$http_x_authentik_username;' \
  || die "Checkmk auth shim does not map Authentik username to X-Remote-User"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Email[[:space:]]+\$http_x_authentik_email;' \
  || die "Checkmk auth shim does not map Authentik email header"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Groups[[:space:]]+\$http_x_authentik_groups;' \
  || die "Checkmk auth shim does not map Authentik groups header"

echo "PASS: Checkmk trusted-header SSO Kubernetes contract exists"
