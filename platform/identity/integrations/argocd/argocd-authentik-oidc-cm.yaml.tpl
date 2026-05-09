apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  oidc.config: |
    name: Authentik
    issuer: https://auth.__BASE_DOMAIN__/application/o/__ARGOCD_PROVIDER_SLUG__/
    clientID: __ARGOCD_OIDC_CLIENT_ID__
    clientSecret: $oidc.authentik.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
