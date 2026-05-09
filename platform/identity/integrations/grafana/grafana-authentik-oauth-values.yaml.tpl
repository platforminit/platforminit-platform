# CH06.1 Grafana SSO values overlay.
# Rendered by scripts/ch06-enable-grafana-sso.sh and merged into the existing
# observability-vmstack Helm release with --reuse-values.
# This file intentionally contains no real secret values.

grafana:
  envFromSecret: grafana-authentik-oauth
  grafana.ini:
    server:
      root_url: https://grafana.__BASE_DOMAIN__
    auth:
      disable_login_form: false
      oauth_auto_login: false
      signout_redirect_url: https://auth.__BASE_DOMAIN__/application/o/__GRAFANA_PROVIDER_SLUG__/end-session/
    auth.generic_oauth:
      enabled: true
      name: Authentik
      allow_sign_up: true
      auto_login: false
      use_pkce: true
      scopes: openid profile email entitlements
      client_id: $__env{GRAFANA_OIDC_CLIENT_ID}
      client_secret: $__env{GRAFANA_OIDC_CLIENT_SECRET}
      auth_url: https://auth.__BASE_DOMAIN__/application/o/authorize/
      token_url: https://auth.__BASE_DOMAIN__/application/o/token/
      api_url: https://auth.__BASE_DOMAIN__/application/o/userinfo/
      login_attribute_path: preferred_username
      email_attribute_path: email
      name_attribute_path: name
      role_attribute_path: contains(entitlements[*], 'Grafana Admins') && 'Admin' || contains(entitlements[*], 'Grafana Editors') && 'Editor' || 'Viewer'
      role_attribute_strict: false
      allow_assign_grafana_admin: false
      skip_org_role_sync: false
