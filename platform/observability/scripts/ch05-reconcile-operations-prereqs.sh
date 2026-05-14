#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
ZABBIX_DB_NAME="${ZABBIX_DB_NAME:-zabbix}"
ZABBIX_DB_USER="${ZABBIX_DB_USER:-zabbix}"
ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD:-}"
OPENOBSERVE_ROOT_USER_EMAIL="${OPENOBSERVE_ROOT_USER_EMAIL:-admin@${BASE_DOMAIN}}"
OPENOBSERVE_ROOT_USER_PASSWORD="${OPENOBSERVE_ROOT_USER_PASSWORD:-}"
OPENOBSERVE_OIDC_CLIENT_ID="${OPENOBSERVE_OIDC_CLIENT_ID:-platforminit-openobserve}"
OPENOBSERVE_OIDC_CLIENT_SECRET="${OPENOBSERVE_OIDC_CLIENT_SECRET:-}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE" >/dev/null
rand(){ openssl rand -base64 32 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}
get_secret_key(){ kubectl -n "$NAMESPACE" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true; }
if kubectl -n "$NAMESPACE" get secret zabbix-postgres >/dev/null 2>&1; then
  log "Preserving existing zabbix-postgres secret"
else
  ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD:-$(rand)}"
  log "Creating zabbix-postgres secret"
  kubectl -n "$NAMESPACE" create secret generic zabbix-postgres \
    --from-literal=POSTGRES_DB="$ZABBIX_DB_NAME" \
    --from-literal=POSTGRES_USER="$ZABBIX_DB_USER" \
    --from-literal=POSTGRES_PASSWORD="$ZABBIX_DB_PASSWORD" >/dev/null
fi
if kubectl -n "$NAMESPACE" get secret openobserve-root >/dev/null 2>&1; then
  log "Preserving existing openobserve-root secret"
else
  OPENOBSERVE_ROOT_USER_PASSWORD="${OPENOBSERVE_ROOT_USER_PASSWORD:-$(rand)}"
  log "Creating openobserve-root secret"
  kubectl -n "$NAMESPACE" create secret generic openobserve-root \
    --from-literal=ZO_ROOT_USER_EMAIL="$OPENOBSERVE_ROOT_USER_EMAIL" \
    --from-literal=ZO_ROOT_USER_PASSWORD="$OPENOBSERVE_ROOT_USER_PASSWORD" >/dev/null
fi
if ! kubectl -n "$NAMESPACE" get secret openobserve-sso >/dev/null 2>&1; then
  OPENOBSERVE_OIDC_CLIENT_SECRET="${OPENOBSERVE_OIDC_CLIENT_SECRET:-$(rand)}"
  log "Creating placeholder openobserve-sso secret; 05.3 will replace it with Authentik-native values"
  kubectl -n "$NAMESPACE" create secret generic openobserve-sso \
    --from-literal=O2_DEX_ENABLED="false" \
    --from-literal=O2_DEX_CLIENT_ID="$OPENOBSERVE_OIDC_CLIENT_ID" \
    --from-literal=O2_DEX_CLIENT_SECRET="$OPENOBSERVE_OIDC_CLIENT_SECRET" >/dev/null
else
  log "Preserving existing openobserve-sso secret"
fi
if ! kubectl -n "$NAMESPACE" get secret zabbix-saml-certs >/dev/null 2>&1; then
  log "Creating placeholder zabbix-saml-certs secret; 05.3 will replace it with Authentik IdP certificate"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
      -subj "/CN=platforminit-placeholder-idp" \
      -keyout "$tmp/idp.key" -out "$tmp/idp.crt" >/dev/null 2>&1
  else
    python3 - <<'PY' > "$tmp/idp.crt"
print("""-----BEGIN CERTIFICATE-----\nMIIC4jCCAcqgAwIBAgIUVY8xD7O3dscN9AjY5aR1L6sDlP4wDQYJKoZIhvcNAQEL\nBQAwHzEdMBsGA1UEAwwUcGxhdGZvcm1pbml0LWhvbGRlciAwHhcNMjYwMTAxMDAw\nMDAwWhcNMjYwMTAzMDAwMDAwWjAfMR0wGwYDVQQDDBRwbGF0Zm9ybWluaXQtaG9s\nZGVyIDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALp5z8L5Jg7o9L6z\nV9EN9m7bFLq+JrON1TH0oXJf6G1U4q0iK6A4nFQ5YwGjvUOVaIqS+zTJH0xqWm5Z\n9u8uGm2XWAv9Jx35YBY0J8zSSsCErf8V9dO5QewvU2uZ7rfE7hY3fTt2IVGq5uNk\nT1qJtZL9h4O0IGsINe6Yx3RJl2jhAFOQ33uRyQDcS4tM9yH41sbrFJ2OBUO+Izvd\nAc7cERdg68G1APn4QWm3+KfvJ6tDgFkQuY+UkkaWf4Sz6Cy+Q7Y1Py/sReSgoSE5\nC4wL3yd9cXXYfY5y0m8Hq2DlnPU0ce1b4FcFcR5vh8kDkjyQEQBwqJXstA0CAwEA\nAaNTMFEwHQYDVR0OBBYEFHt+V6rMCbiU9MtL0gJhjdbKxZQjMB8GA1UdIwQYMBaA\nFHt+V6rMCbiU9MtL0gJhjdbKxZQjMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcN\nAQELBQADggEBAGoMbnm5aNf4X0drfT7Fv0eRlsQpZ1ypP2iJ8Q6QGFDhFcv1GBkH\nCBgWZ5fln91YCvtC4mQd3a6+Ar6nR9ymROrsM4+MH59PIZnO6p0/lcQj5bdxZVyO\nO/90TkrGEXH9W76SxqULPse1LeWf5c+6yQ9GEEoSsvZs/5VmcI9J6iwFUE2BSEsD\naA+U2yJVcgDY1SCEeUeS3OiDCe3GzIHRiyiy59HwoiH2G+h3VFC2SpfTrLz+w8ZR\nB7m8hnvCbqTbw9lFoHVFa8y5SfYrF7ssRlxH4E5lIcm9xC8gD6vij/35MXqQ/xAe\n28zm1V8IlX+1pmc89WwF8oI=\n-----END CERTIFICATE-----""")
PY
  fi
  kubectl -n "$NAMESPACE" create secret generic zabbix-saml-certs --from-file=idp.crt="$tmp/idp.crt" >/dev/null
else
  log "Preserving existing zabbix-saml-certs secret"
fi
log "Operations prerequisites reconciled"
kubectl -n "$NAMESPACE" get secret zabbix-postgres openobserve-root openobserve-sso zabbix-saml-certs >/dev/null
# Recover pods that may have been created by an earlier accidental/automated Argo sync before prerequisites existed.
if kubectl -n "$NAMESPACE" get daemonset vector >/dev/null 2>&1; then
  log "Restarting Vector pods after prerequisite reconciliation"
  kubectl -n "$NAMESPACE" delete pod -l app.kubernetes.io/name=vector --ignore-not-found=true >/dev/null 2>&1 || true
fi
