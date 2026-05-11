# CH06.2 - Argo CD SSO Runbook

## Goal

Enable Argo CD login through Authentik using OAuth2/OIDC while keeping the local Argo CD admin account as a break-glass path.

## Authentik application/provider bootstrap

The workflow reconciles the Argo CD OAuth2/OIDC provider and application in Authentik through the Authentik API. Do not create GitHub secrets for the Argo CD client ID or client secret.

Credential ownership model:

| Value | Owner | Storage |
|---|---|---|
| Argo CD OAuth client ID | CH06.2 automation | `argocd/argocd-authentik-oidc` Kubernetes secret |
| Argo CD OAuth client secret | CH06.2 automation | `argocd/argocd-authentik-oidc` and `argocd/argocd-secret` Kubernetes secrets |
| Authentik API token | CH06 baseline | `identity/authentik-bootstrap` Kubernetes secret |

The workflow input `argocd_provider_slug` controls the Authentik application slug. The default is `argocd`.

The reconciled Authentik values are:

| Field | Value |
|---|---|
| Application name | `Argo CD` |
| Application slug | `argocd` by default |
| Provider type | `OAuth2/OpenID Connect` |
| Redirect URI mode | `Strict` |
| Redirect URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/auth/callback` |
| Logout URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/logout` |
| Logout method | `Front-channel` |
| Scopes | `openid`, `email`, `profile`, `entitlements` |

## Argo CD RBAC model

Default mapping:

```text
g, PlatformInit Admins, role:admin
```

The workflow input `argocd_admin_group` controls the group name. Keep this group small and use local `admin` only for break-glass recovery.

## Workflow

Run:

```text
06.2 - Enable Argo CD SSO
```

Recommended inputs:

| Input | Recommended value |
|---|---|
| `artifact_run_id` | latest successful `00 - Build Platform Artifacts` run ID |
| `artifact_id` | identity artifact ID |
| `project` | `development` |
| `host_name` | `platforminit-dev-01` |
| `argocd_provider_slug` | `argocd` |
| `argocd_admin_group` | `PlatformInit Admins` |

## Validation

After the workflow succeeds:

```bash
kubectl -n argocd get secret argocd-authentik-oidc
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.oidc\.authentik\.clientSecret}' | wc -c
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.oidc\.config}'
kubectl -n argocd get cm argocd-rbac-cm -o yaml
kubectl -n argocd rollout status deploy/argocd-server
```

Browser test:

```text
https://argocd.<PLATFORM_BASE_DOMAIN>/login
```

Expected result: the login page shows an Authentik login option, while the local Argo CD admin account remains available for break-glass access.

## Emergency recovery note

If Argo CD SSO configuration causes `argocd-server` to enter `CrashLoopBackOff`, CH06.2 now removes the temporary OIDC configuration and clears the `kubectl.kubernetes.io/restartedAt` pod-template annotation. This avoids repeatedly creating new broken ReplicaSets and lets the Deployment converge back to the last known stable server pod/template instead of relying on Kubernetes revision history alone.


## Current hardening note

CH06.2 validates the Authentik OIDC discovery document before writing `oidc.config` into `argocd-cm`. The rendered Argo CD issuer is taken from the discovery document instead of being guessed from the provider slug. This prevents repeated `argocd-server` CrashLoopBackOff rollouts caused by malformed or incompatible OIDC startup configuration.

## Group scope requirement

CH06.2 requests the `groups` OIDC scope explicitly and requires the Authentik groups scope mapping to be attached to the Argo CD OAuth provider. This is required for the `PlatformInit Admins -> role:admin` RBAC mapping to work reliably.

After changing OIDC config, clear stale browser cookies for `argocd.<domain>` and retry the login flow if the browser shows `failed to verify the token`.
