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


## CH06.1 - Grafana SSO implementation policy

Grafana SSO is configured by the `06.1 - Enable Grafana SSO` workflow. The workflow does not click through the Grafana UI. It applies a Helm values overlay to the existing `observability-vmstack` release and stores the OAuth client ID/secret in the Kubernetes secret `observability/grafana-authentik-oauth`.

The Authentik provider/application is reconciled through the Authentik API using the bootstrap token stored in `identity/authentik-bootstrap`. `GRAFANA_OIDC_CLIENT_ID` and `GRAFANA_OIDC_CLIENT_SECRET` are intentionally not GitHub secrets in the normal path.

Because Grafana is deployed by CH05, CH05 remains the owner of the base `observability-vmstack` release. CH06.1 owns the SSO overlay. If CH05 is rerun in `baseline` mode after SSO is enabled, rerun CH06.1 afterwards. If CH05 is rerun in `reconcile` mode, the workflow preserves post-CH05 overlays with Helm `--reuse-values`.

## CH06.2 - Argo CD SSO implementation policy

Argo CD SSO is configured by the `06.2 - Enable Argo CD SSO` workflow. The workflow reconciles the Authentik provider/application through the Authentik API, stores the generated client credentials in Kubernetes, patches `argocd-secret`, applies `argocd-cm` OIDC configuration and applies `argocd-rbac-cm` group mapping.

`ARGOCD_OIDC_CLIENT_ID` and `ARGOCD_OIDC_CLIENT_SECRET` are intentionally not GitHub secrets in the normal path. The local Argo CD admin account must remain available as a break-glass path during CH06.2.

The default admin group is `PlatformInit Admins`. Change it only if the Authentik group name is already standardized differently.

