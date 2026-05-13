# Identity Layer Refactor

## Decision

Identity is an early platform foundation layer, not a late CH06-only integration layer.

The deployable identity workflow is now:

```text
04.5 - Deploy Identity Foundation
```

This workflow owns both:

1. Authentik core deployment
2. PlatformInit scoped identity foundation bootstrap

Application-specific SSO bindings remain separate follow-up workflows because the target
applications must already exist before they can be integrated:

```text
04.6 - Enable Argo CD SSO
05.5 - Enable Grafana SSO
```

`05.5 - Enable Grafana SSO` is the active Grafana SSO binding workflow after `05.1 - Provision Dashboards`. `05.2`, `05.3` and `05.4` remain planned CH05 implementation steps.

## Rationale

The previous split caused an invalid lifecycle:

```text
04.5 Identity Foundation -> failed because identity namespace did not exist
06 Identity Core -> created the namespace later
```

That model made CH04.5 dependent on CH06, which contradicted the intent of moving
identity earlier in the platform lifecycle.

## Correct lifecycle

For a clean rebuild use:

```text
01.1 - Host Bootstrap
01.2 - Sync Host Access Tooling
02   - Apply Host Baseline
03   - Install Kubernetes Cluster
04   - Enable Platform (Ingress, TLS, ArgoCD)
04.5 - Deploy Identity Foundation
04.6 - Enable Argo CD SSO
05   - Deploy Observability Stack
05.5 - Enable Grafana SSO
```

## Compatibility

The old `06 - Deploy Identity Stack` workflow is kept temporarily for compatibility,
but it is deprecated. New lifecycle runs should use `04.5 - Deploy Identity Foundation`.
