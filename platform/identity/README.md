# CH04.5 - Identity Foundation

CH04.5 introduces the PlatformInit identity foundation based on Authentik. The legacy CH06 workflow is retained only for compatibility.

## Scope

- Deploy Authentik into the `identity` namespace.
- Publish the Authentik Web UI at `https://auth.<PLATFORM_BASE_DOMAIN>`.
- Keep Argo CD and Grafana local admin accounts as break-glass access.
- Prepare OIDC integration templates for Grafana and Argo CD.
- Do not automatically switch existing workloads to SSO until provider/client credentials are created and tested.

## Runtime model

| Component | Namespace | Public ingress | Notes |
|---|---|---:|---|
| Authentik server | `identity` | yes | `https://auth.<base-domain>` |
| Authentik worker | `identity` | no | background jobs and bootstrap |
| PostgreSQL | `identity` | no | embedded chart for development/homelab baseline |

## Required GitHub secrets

- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_POSTGRESQL_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`

## Optional GitHub secrets

- `AUTHENTIK_BOOTSTRAP_EMAIL`
- `AUTHENTIK_BOOTSTRAP_TOKEN`

If `AUTHENTIK_BOOTSTRAP_EMAIL` is empty, the deploy workflow uses `admin@<PLATFORM_BASE_DOMAIN>`.
If `AUTHENTIK_BOOTSTRAP_TOKEN` is empty, the remote deploy script preserves the existing cluster secret if present, otherwise generates a token once.

## First login

After deployment, log in at:

```text
https://auth.<PLATFORM_BASE_DOMAIN>/
```

Default administrative user:

```text
akadmin
```

Password:

```text
AUTHENTIK_BOOTSTRAP_PASSWORD
```

If the automated bootstrap did not run because Authentik was previously initialized, use the existing `akadmin` password or perform the initial setup flow:

```text
https://auth.<PLATFORM_BASE_DOMAIN>/if/flow/initial-setup/
```

Keep the trailing slash.

## Next phase

After the identity foundation is healthy:

1. Run `04.6 - Enable Argo CD SSO` because Argo CD already exists after CH04.
2. Run `05 - Deploy Observability Stack`.
3. Run `05.1 - Enable Grafana SSO` after Grafana exists. This numbering is transitional; the CH05 redesign target is `05.5 - Enable Grafana SSO`.
4. Keep local Argo CD and Grafana admin accounts as break-glass paths.
5. Decide later whether Traefik ForwardAuth should protect any future non-OIDC services.


## CH05.1 Grafana SSO

After Authentik is reachable and the `akadmin` account works, use `05.1 - Enable Grafana SSO` to configure Grafana Generic OAuth from code. This keeps local Grafana login enabled as a break-glass path and applies SSO via Helm values rather than manual Grafana UI changes.

Credential ownership model:

- The workflow reads `identity/authentik-bootstrap` for the Authentik API token.
- The workflow creates or reuses `observability/grafana-authentik-oauth`.
- No `GRAFANA_OIDC_CLIENT_ID` or `GRAFANA_OIDC_CLIENT_SECRET` GitHub secrets are required for the normal path.

Default Authentik provider/application slug: `grafana`.

## CH04.6 Argo CD SSO

After Authentik is reachable and the identity foundation has been validated, use `04.6 - Enable Argo CD SSO` to configure Argo CD OIDC from code. This keeps the local Argo CD `admin` account available as a break-glass path and stores the OIDC client secret in Kubernetes, not in GitHub secrets.

Credential ownership model:

- The workflow reads `identity/authentik-bootstrap` for the Authentik API token.
- The workflow creates or reuses `argocd/argocd-authentik-oidc`.
- The workflow patches `argocd/argocd-secret` with `oidc.authentik.clientSecret`.
- No `ARGOCD_OIDC_CLIENT_ID` or `ARGOCD_OIDC_CLIENT_SECRET` GitHub secrets are required for the normal path.

Default Authentik provider/application slug: `argocd`.
Default admin group mapping: `PlatformInit Admins` → `role:admin`.

