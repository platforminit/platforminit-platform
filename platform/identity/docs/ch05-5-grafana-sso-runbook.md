# CH05.5 - Grafana SSO Runbook

## Goal

Enable Grafana login through Authentik using Grafana Generic OAuth while keeping the local Grafana login form enabled as a break-glass path.

## Why Grafana needs its own configuration

Authentik only provides the OAuth2/OIDC provider and application. Grafana is the relying party, so Grafana must also be configured with:

- `auth.generic_oauth.enabled=true`
- Authentik authorization, token, and userinfo URLs
- the OAuth client ID and client secret
- the callback URL `/login/generic_oauth`
- role mapping policy

Without this, browsing to `/login/generic_oauth` can produce `OAuth client is disabled`.

## Authentik application/provider bootstrap

The workflow reconciles the Grafana OAuth2/OIDC provider and application in Authentik through the Authentik API. Do not create GitHub secrets for the Grafana client ID or client secret.

Credential ownership model:

| Value | Owner | Storage |
|---|---|---|
| Grafana OAuth client ID | CH05.5 automation | `observability/grafana-authentik-oauth` Kubernetes secret |
| Grafana OAuth client secret | CH05.5 automation | `observability/grafana-authentik-oauth` Kubernetes secret |
| Authentik API token | CH04.5 identity foundation | `identity/authentik-bootstrap` Kubernetes secret |

The workflow input `grafana_provider_slug` controls the Authentik application slug. The default is `grafana`.

The reconciled Authentik values are:

| Field | Value |
|---|---|
| Application name | `Grafana` |
| Application slug | `grafana` by default |
| Provider type | `OAuth2/OpenID Connect` |
| Redirect URI mode | `Strict` |
| Redirect URI | `https://grafana.<PLATFORM_BASE_DOMAIN>/login/generic_oauth` |
| Logout URI | `https://grafana.<PLATFORM_BASE_DOMAIN>/logout` |
| Logout method | `Front-channel` |
| Scopes | `openid`, `email`, `profile`, `entitlements` |

## Workflow

Run:

```text
05.5 - Enable Grafana SSO
```

Required inputs:

| Input | Recommended value |
|---|---|
| `artifact_run_id` | latest successful `00 - Build Platform Artifacts` run ID |
| `artifact_id` | identity artifact ID |
| `project` | `development` |
| `host_name` | `platforminit-dev-01` |
| `grafana_provider_slug` | `grafana` |
| `vm_stack_chart_version` | same pin as CH05, currently `0.72.5` |

## Validation

After the workflow succeeds:

```bash
kubectl -n observability get secret grafana-authentik-oauth
kubectl -n observability rollout status deploy/observability-vmstack-grafana
kubectl -n observability get configmap observability-vmstack-grafana -o jsonpath='{.data.grafana\.ini}' | sed -n '/auth.generic_oauth/,+25p'
```

Browser test:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>/login
```

Expected result: the login page shows an Authentik OAuth option, while username/password login remains available for break-glass access.


## Lifecycle note

`05.5 - Enable Grafana SSO` is the active Grafana SSO workflow. It intentionally runs after the CH05 base stack and `05.1 - Provision Dashboards`.
