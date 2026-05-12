#!/usr/bin/env bash
set -euo pipefail

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
EXPECTED_PROVIDER_SLUG="${ARGOCD_OIDC_PROVIDER_SLUG:-argocd}"
EXPECTED_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"

kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && \
  pass "AUTHENTIK_ROLLOUT" "authentik-server rollout is healthy" || fail "AUTHENTIK_ROLLOUT" "authentik-server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc >/dev/null 2>&1 && \
  pass "ARGOCD_OIDC_SECRET" "argocd-authentik-oidc secret exists" || fail "ARGOCD_OIDC_SECRET" "missing argocd-authentik-oidc secret"

client_id_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null || true)"
client_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_SECRET}' 2>/dev/null || true)"
server_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null || true)"
argocd_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.oidc\.authentik\.clientSecret}' 2>/dev/null || true)"
[[ -n "${client_id_present}" ]] && pass "ARGOCD_CLIENT_ID" "client ID is stored in Kubernetes secret" || fail "ARGOCD_CLIENT_ID" "missing client ID"
[[ -n "${client_secret_present}" ]] && pass "ARGOCD_CLIENT_SECRET" "client secret is stored in Kubernetes secret" || fail "ARGOCD_CLIENT_SECRET" "missing client secret"
[[ -n "${server_secret_present}" ]] && pass "ARGOCD_SERVER_SECRETKEY" "argocd-secret contains stable server.secretkey" || fail "ARGOCD_SERVER_SECRETKEY" "missing argocd-secret server.secretkey"
[[ -n "${argocd_secret_present}" ]] && pass "ARGOCD_SECRET_REFERENCE" "argocd-secret contains oidc.authentik.clientSecret" || fail "ARGOCD_SECRET_REFERENCE" "missing argocd-secret OIDC clientSecret key"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_ROLLOUT" "Argo CD server rollout is healthy" || fail "ARGOCD_ROLLOUT" "Argo CD server rollout is not healthy"

config_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null || true)"
direct_oidc_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null || true)"
rbac_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)"
scopes_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.scopes}' 2>/dev/null || true)"

[[ -z "${direct_oidc_text}" ]] && \
  pass "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is absent because CH06.2 uses Dex-backed SSO" || fail "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is still present"

echo "${config_text}" | grep -q 'name: Authentik' && \
  pass "ARGOCD_DEX_CONNECTOR_NAME" "Argo CD Dex connector is named Authentik" || fail "ARGOCD_DEX_CONNECTOR_NAME" "Dex connector missing Authentik name"

echo "${config_text}" | grep -q 'type: oidc' && \
  pass "ARGOCD_DEX_CONNECTOR_TYPE" "Argo CD Dex connector type is oidc" || fail "ARGOCD_DEX_CONNECTOR_TYPE" "Dex connector type is not oidc"

echo "${config_text}" | grep -q "issuer: https://auth.${BASE_DOMAIN}/application/o/${EXPECTED_PROVIDER_SLUG}/" && \
  pass "ARGOCD_ISSUER" "Dex connector issuer points to Authentik provider" || fail "ARGOCD_ISSUER" "Dex connector issuer mismatch"

echo "${config_text}" | grep -q "clientID: ${client_id_value}" && \
  pass "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID matches stored client ID" || fail "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID mismatch"

echo "${config_text}" | grep -q 'clientSecret: \$dex.authentik.clientSecret' && \
  pass "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret uses argocd-secret reference" || fail "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret reference mismatch"

echo "${config_text}" | grep -q 'insecureEnableGroups: true' && \
  pass "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector enables groups claim handling" || fail "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector missing insecureEnableGroups"

client_id_value="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)"
echo "${config_text}" | grep -A3 'allowedAudiences:' | grep -q -- "- ${client_id_value}" && \
  pass "ARGOCD_ALLOWED_AUDIENCE" "OIDC allowedAudiences includes client ID" || fail "ARGOCD_ALLOWED_AUDIENCE" "OIDC allowedAudiences does not include client ID"

echo "${config_text}" | grep -q 'skipAudienceCheckWhenTokenHasNoAudience: true' && \
  pass "ARGOCD_AUDIENCE_COMPAT" "audience compatibility flag is enabled" || fail "ARGOCD_AUDIENCE_COMPAT" "missing audience compatibility flag"

echo "${config_text}" | grep -q -- '- groups' && \
  pass "ARGOCD_GROUP_SCOPE" "groups scope is requested" || fail "ARGOCD_GROUP_SCOPE" "groups scope missing"

echo "${rbac_text}" | grep -q "g, ${EXPECTED_ADMIN_GROUP}, role:admin" && \
  pass "ARGOCD_RBAC_ADMIN_GROUP" "admin group maps to role:admin" || warn "ARGOCD_RBAC_ADMIN_GROUP" "admin group mapping not found"

echo "${scopes_text}" | grep -q 'groups' && \
  pass "ARGOCD_RBAC_SCOPES" "RBAC scopes include groups" || warn "ARGOCD_RBAC_SCOPES" "RBAC scopes do not include groups"

if command -v curl >/dev/null 2>&1; then
  if curl -fsSIk "https://argocd.${BASE_DOMAIN}" >/dev/null 2>&1; then
    pass "ARGOCD_HTTPS" "Argo CD URL responds over HTTPS"
  else
    warn "ARGOCD_HTTPS" "Argo CD HTTPS check failed from host; verify DNS/TLS externally"
  fi
fi
