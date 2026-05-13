#!/usr/bin/env bash
set -euo pipefail

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
EXPECTED_PROVIDER_SLUG="${GRAFANA_OIDC_PROVIDER_SLUG:-grafana}"

kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && \
  pass "AUTHENTIK_ROLLOUT" "authentik-server rollout is healthy" || fail "AUTHENTIK_ROLLOUT" "authentik-server rollout is not healthy"

kubectl -n "${OBS_NAMESPACE}" get secret grafana-authentik-oauth >/dev/null 2>&1 && \
  pass "GRAFANA_OAUTH_SECRET" "grafana-authentik-oauth secret exists" || fail "GRAFANA_OAUTH_SECRET" "missing grafana-authentik-oauth secret"

client_id_present="$(kubectl -n "${OBS_NAMESPACE}" get secret grafana-authentik-oauth -o jsonpath='{.data.GRAFANA_OIDC_CLIENT_ID}' 2>/dev/null || true)"
client_secret_present="$(kubectl -n "${OBS_NAMESPACE}" get secret grafana-authentik-oauth -o jsonpath='{.data.GRAFANA_OIDC_CLIENT_SECRET}' 2>/dev/null || true)"
[[ -n "${client_id_present}" ]] && pass "GRAFANA_CLIENT_ID" "client ID is stored in Kubernetes secret" || fail "GRAFANA_CLIENT_ID" "missing client ID"
[[ -n "${client_secret_present}" ]] && pass "GRAFANA_CLIENT_SECRET" "client secret is stored in Kubernetes secret" || fail "GRAFANA_CLIENT_SECRET" "missing client secret"

kubectl -n "${OBS_NAMESPACE}" rollout status deploy/observability-vmstack-grafana --timeout=10s >/dev/null 2>&1 && \
  pass "GRAFANA_ROLLOUT" "Grafana rollout is healthy" || fail "GRAFANA_ROLLOUT" "Grafana rollout is not healthy"

config_text="$(kubectl -n "${OBS_NAMESPACE}" get configmap observability-vmstack-grafana -o jsonpath='{.data.grafana\.ini}' 2>/dev/null || true)"

echo "${config_text}" | grep -q '\[auth.generic_oauth\]' && \
  pass "GRAFANA_OAUTH_BLOCK" "auth.generic_oauth block is rendered" || fail "GRAFANA_OAUTH_BLOCK" "auth.generic_oauth block missing"

echo "${config_text}" | grep -q '^enabled = true' && \
  pass "GRAFANA_OAUTH_ENABLED" "Generic OAuth is enabled" || fail "GRAFANA_OAUTH_ENABLED" "Generic OAuth not enabled"

echo "${config_text}" | grep -q "auth.${BASE_DOMAIN}/application/o/authorize/" && \
  pass "GRAFANA_AUTH_URL" "auth URL points to Authentik authorize endpoint" || fail "GRAFANA_AUTH_URL" "auth URL mismatch"

echo "${config_text}" | grep -q "auth.${BASE_DOMAIN}/application/o/token/" && \
  pass "GRAFANA_TOKEN_URL" "token URL points to Authentik token endpoint" || fail "GRAFANA_TOKEN_URL" "token URL mismatch"

echo "${config_text}" | grep -q "auth.${BASE_DOMAIN}/application/o/userinfo/" && \
  pass "GRAFANA_USERINFO_URL" "userinfo URL points to Authentik userinfo endpoint" || fail "GRAFANA_USERINFO_URL" "userinfo URL mismatch"

echo "${config_text}" | grep -q '^disable_login_form = false' && \
  pass "LOCAL_LOGIN_FORM" "local login form remains enabled for break-glass access" || warn "LOCAL_LOGIN_FORM" "could not confirm local login form remains enabled"

# External HTTP checks are intentionally soft because ACME/DNS convergence and local network ACLs can vary.
if command -v curl >/dev/null 2>&1; then
  if curl -fsSIk "https://grafana.${BASE_DOMAIN}/login" >/dev/null 2>&1; then
    pass "GRAFANA_HTTPS" "Grafana login URL responds over HTTPS"
  else
    warn "GRAFANA_HTTPS" "Grafana HTTPS login check failed from host; verify DNS/TLS externally"
  fi
fi
