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
