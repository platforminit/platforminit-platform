# CH06 - Identity & SSO Foundation

CH06 introduces the PlatformInit identity layer based on Authentik.

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

After the identity stack is healthy:

1. Create an OIDC provider/application pair for Grafana.
2. Test Grafana SSO with a non-admin user.
3. Create an OIDC provider/application pair for Argo CD.
4. Test Argo CD SSO while retaining local admin as break-glass.
5. Decide whether Traefik ForwardAuth should protect any future non-OIDC services.


## CH06.1 Grafana SSO

After Authentik is reachable and the `akadmin` account works, use `06.1 - Enable Grafana SSO` to configure Grafana Generic OAuth from code. This keeps local Grafana login enabled as a break-glass path and applies SSO via Helm values rather than manual Grafana UI changes.

Credential ownership model:

- The workflow reads `identity/authentik-bootstrap` for the Authentik API token.
- The workflow creates or reuses `observability/grafana-authentik-oauth`.
- No `GRAFANA_OIDC_CLIENT_ID` or `GRAFANA_OIDC_CLIENT_SECRET` GitHub secrets are required for the normal path.

Default Authentik provider/application slug: `grafana`.

## CH06.2 Argo CD SSO

After Authentik is reachable and Grafana SSO has been validated, use `06.2 - Enable Argo CD SSO` to configure Argo CD OIDC from code. This keeps the local Argo CD `admin` account available as a break-glass path and stores the OIDC client secret in Kubernetes, not in GitHub secrets.

Credential ownership model:

- The workflow reads `identity/authentik-bootstrap` for the Authentik API token.
- The workflow creates or reuses `argocd/argocd-authentik-oidc`.
- The workflow patches `argocd/argocd-secret` with `oidc.authentik.clientSecret`.
- No `ARGOCD_OIDC_CLIENT_ID` or `ARGOCD_OIDC_CLIENT_SECRET` GitHub secrets are required for the normal path.

Default Authentik provider/application slug: `argocd`.
Default admin group mapping: `PlatformInit Admins` → `role:admin`.


## Planned CH04.5 Identity Foundation refactor

The current CH06 identity deployment works as the runtime identity layer, but the next architecture step is to split base identity from target-specific SSO bindings.

See `docs/ch04-5-identity-foundation.md` for the proposed model:

- Authentik base runtime earlier as CH04.5.
- Differentiated platform and application groups.
- Bootstrap and technical users suitable for validation.
- Argo CD and Grafana SSO kept as later CH06.x bindings.
