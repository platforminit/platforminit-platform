# CH06 SSO Integration Notes

CH06 deploys Authentik first. Grafana and Argo CD SSO should be enabled only after Authentik itself is healthy and the `akadmin` account is accessible.

## Grafana OIDC provider

Create an Authentik OAuth2/OIDC provider and application for Grafana.

Recommended redirect URI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>/login/generic_oauth
```

Recommended logout URI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>/logout
```

After creating the provider, use the client ID, client secret and slug to configure Grafana. A template is provided under:

```text
platform/identity/integrations/grafana/grafana-authentik-oauth-values.yaml.tpl
```

## Argo CD OIDC provider

Create a separate Authentik OAuth2/OIDC provider and application for Argo CD.

Recommended redirect URI:

```text
https://argocd.<PLATFORM_BASE_DOMAIN>/auth/callback
```

After creating the provider, use the client ID, client secret and slug to configure Argo CD. A template is provided under:

```text
platform/identity/integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl
```

## Rollout policy

1. Enable Grafana SSO first because rollback is low risk.
2. Confirm local Grafana admin still works.
3. Enable Argo CD SSO second.
4. Confirm local Argo CD admin still works.
5. Only then consider Traefik ForwardAuth for services without native OIDC.
