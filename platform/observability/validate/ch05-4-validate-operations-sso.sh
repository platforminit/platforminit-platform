#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ensure_cluster(){ need kubectl; [ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"; kubectl get nodes >/dev/null; }
ensure_cluster
kubectl -n "$NAMESPACE" get ingress zabbix openobserve >/dev/null
kubectl -n "$NAMESPACE" get secret openobserve-sso zabbix-saml-certs >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/openobserve --timeout=60s >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/zabbix-web --timeout=60s >/dev/null
kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q 'openobserve-enterprise' || die "OpenObserve is not using the Enterprise image"
kubectl -n "$NAMESPACE" get deploy/openobserve -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}' | grep -q 'openobserve-sso' || die "OpenObserve SSO secret is not mounted"
kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q 'ZBX_SSO_SETTINGS' || die "Zabbix SAML runtime env is missing"
kubectl -n "$NAMESPACE" get deploy/zabbix-web -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' | grep -q 'zabbix-saml-certs' || die "Zabbix SAML certificate volume is not mounted"
if kubectl -n "$NAMESPACE" get middleware.traefik.io authentik-forward-auth >/dev/null 2>&1; then
  die "Stale forward-auth middleware exists; CH05.4 must use native app SSO, not proxy-only access gate"
fi
for host in "zabbix.${BASE_DOMAIN}" "logs.${BASE_DOMAIN}"; do
  kubectl -n "$NAMESPACE" get ingress -o json | grep -q "$host" || die "Missing ingress host: $host"
done
echo "PASS: Operations WebUIs use native SSO model (Zabbix SAML + OpenObserve Enterprise OIDC)"
