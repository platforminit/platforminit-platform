apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.__BASE_DOMAIN__
  oidc.config: |
    name: Authentik
    issuer: __AUTHENTIK_OIDC_ISSUER__
    clientID: __ARGOCD_OIDC_CLIENT_ID__
    clientSecret: $oidc.authentik.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
    requestedIDTokenClaims:
      groups:
        essential: true
