# Merge into the Grafana section of the CH05 VictoriaMetrics stack values after creating
# an Authentik OAuth2/OIDC provider for Grafana.

grafana:
  envFromSecret: grafana-authentik-oauth
  grafana.ini:
    auth:
      disable_login_form: false
    auth.generic_oauth:
      enabled: true
      name: Authentik
      allow_sign_up: true
      auto_login: false
      scopes: openid email profile groups
      client_id: __GRAFANA_OIDC_CLIENT_ID__
      client_secret: $__env{GRAFANA_OIDC_CLIENT_SECRET}
      auth_url: https://auth.__BASE_DOMAIN__/application/o/__GRAFANA_PROVIDER_SLUG__/authorize/
      token_url: https://auth.__BASE_DOMAIN__/application/o/__GRAFANA_PROVIDER_SLUG__/token/
      api_url: https://auth.__BASE_DOMAIN__/application/o/__GRAFANA_PROVIDER_SLUG__/userinfo/
      role_attribute_path: contains(groups[*], 'platform-admins') && 'Admin' || contains(groups[*], 'platform-editors') && 'Editor' || 'Viewer'
