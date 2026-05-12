# CH04.5 Identity Foundation Design

## Purpose

Identity should become a platform foundation layer before application-specific SSO bindings are enabled.

The desired model is:

```text
Identity Foundation early
SSO bindings late
```

Authentik should be installed and configured as a stable platform service after CH04 platform core is available, while Argo CD and Grafana SSO should remain separate workflows that run only after the target applications are reachable.

## Scope

CH04.5 Identity Foundation should own:

- Authentik installation in the `identity` namespace.
- Authentik ingress and TLS at `https://auth.<PLATFORM_BASE_DOMAIN>`.
- Stable signing key configuration suitable for OIDC/Dex integrations.
- Base authorization and authentication flows.
- Scoped platform and application groups.
- Bootstrap and technical users for validation.
- A safe break-glass model.

CH04.5 should not automatically bind every target application to SSO. That remains the responsibility of CH06.x workflows.

## Identity model

### Platform groups

| Group | Intended use |
|---|---|
| `PlatformInit Admins` | Full platform administrator role across PlatformInit-managed UIs. |
| `PlatformInit Operators` | Day-2 operational access without unrestricted administration. |
| `PlatformInit Viewers` | Read-only platform visibility. |

### Application groups

| Group | Intended use |
|---|---|
| `ArgoCD Admins` | Argo CD admin/sync privileges. |
| `ArgoCD Viewers` | Argo CD read-only visibility. |
| `Grafana Admins` | Grafana organization administrator. |
| `Grafana Editors` | Grafana dashboard editing. |
| `Grafana Viewers` | Grafana dashboard viewing. |
| `Authentik Admins` | Authentik administration only. |

### Bootstrap and technical users

| User | Purpose | Long-term handling |
|---|---|---|
| `platforminit-bootstrap-admin` | Initial break-glass/bootstrap identity. | Disable or restrict after real users exist. |
| `argocd-admin` | Argo CD SSO and RBAC validation. | Disable after real admins are onboarded. |
| `argocd-viewer` | Argo CD readonly validation. | Disable after real viewers are onboarded. |
| `grafana-admin` | Grafana SSO admin validation. | Disable after real admins are onboarded. |
| `grafana-viewer` | Grafana readonly validation. | Disable after real viewers are onboarded. |

This mirrors an enterprise pattern where application-specific technical identities exist during bootstrap and validation but can later be disabled when real user onboarding is complete.

## Argo CD mapping recommendation

The current emergency unblock used `PlatformInit Admins` directly for Argo CD admin/sync access.

For the next iteration, prefer explicit application groups:

```text
g, ArgoCD Admins, role:admin
g, PlatformInit Admins, role:admin
g, ArgoCD Viewers, role:readonly
g, PlatformInit Viewers, role:readonly
```

This keeps platform-level administration possible while making the application-specific authorization model clearer.

## Grafana mapping recommendation

Grafana SSO should map groups into explicit Grafana roles:

| Authentik group | Grafana role |
|---|---|
| `Grafana Admins` | Admin |
| `Grafana Editors` | Editor |
| `Grafana Viewers` | Viewer |
| `PlatformInit Admins` | Admin |
| `PlatformInit Viewers` | Viewer |

## Workflow split

| Workflow | Responsibility |
|---|---|
| `04.5 - Deploy Identity Foundation` | Install Authentik and reconcile base groups/users/flows/signing key. |
| `06.2 - Enable Argo CD SSO` | Bind Argo CD to Authentik through Dex. |
| `06.3 - Enable Grafana SSO` | Bind Grafana to Authentik Generic OAuth. |

## Safety rules

- Do not rely on one broad Authentik admin group for all application access.
- Keep break-glass local admin paths for Argo CD and Grafana.
- Keep technical users scoped and documented.
- Make technical users easy to disable later.
- Keep application-specific SSO integrations idempotent and separately runnable.
