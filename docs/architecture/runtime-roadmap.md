# PlatformInit Runtime Roadmap

This roadmap organizes the next tasks after the current CH04-CH06 runtime stabilization milestone.

## Current baseline

| Area | Status |
|---|---|
| CH04 Platform / TLS / Argo CD baseline | Working |
| CH05 Observability runtime | Working as workflow/Helm-owned runtime |
| CH05 Argo CD visibility | Working as inventory Application |
| CH06.2 Argo CD SSO | Working through Authentik + Dex |
| Argo CD RBAC | Working through `PlatformInit Admins` |
| Release workflow | Deferred |

## Proposed layer model

| Layer | Name | Responsibility |
|---|---|---|
| CH01 | Host Foundation | Hetzner host lifecycle and initial access bootstrap |
| CH02 | Host Baseline | OS baseline, hardening, drift, patching and file integrity |
| CH03 | Kubernetes Foundation | single-node k3s installation and validation |
| CH04 | Platform Core | Traefik, cert-manager, Argo CD baseline and TLS |
| CH04.5 | Identity Foundation | Authentik base runtime, signing key, groups and technical users |
| CH05 | Observability Runtime | Grafana, VictoriaMetrics, Loki and Alloy |
| CH05.1 | Observability UX + Alerting | operator-facing health dashboards and Nagios-style alert views |
| CH05.2 | Logging Taxonomy | CH/component/severity-based Loki/Alloy model |
| CH06 | Access Integrations | target-application SSO bindings |
| CH06.2 | Argo CD SSO | Authentik + Dex binding for Argo CD |
| CH06.3 | Grafana SSO | Authentik OAuth binding for Grafana |
| CH07+ | Release / Productization | release workflow, packaging and customer-facing distribution |

## Task backlog

| Priority | Task | Outcome |
|---:|---|---|
| P0 | Preserve known-good runtime state | Document and tag the current CH04-CH06 dev runtime baseline. |
| P1 | Refactor Identity Foundation into CH04.5 | Make Authentik an early platform service instead of a late integration-only component. |
| P1 | Differentiate Authentik groups and technical users | Replace broad single-admin-group handling with scoped platform and application identities. |
| P1 | Split SSO bindings by target application | Keep Argo CD and Grafana SSO as post-target integration workflows. |
| P1 | Redesign CH05 observability UX | Add operator-facing OK/WARN/CRIT platform health views. |
| P2 | Implement Loki log taxonomy | Make logs searchable by chapter, layer, component, namespace and severity. |
| P2 | Design Argo CD app-of-apps adoption | Move from inventory-only Application visibility toward intentional GitOps ownership. |
| P3 | Evaluate blackbox/status monitoring | Decide later whether a dedicated status layer is needed. |
| P3 | Repair release workflow | Resume only after runtime architecture is stabilized. |

## Recommended execution order

```text
1. Commit and tag the known-good CH04-CH06 runtime state.
2. Introduce CH04.5 Identity Foundation design and documentation.
3. Define scoped Authentik groups and technical users.
4. Keep CH06.2 Argo CD SSO and CH06.3 Grafana SSO as separate integrations.
5. Redesign CH05 dashboards around operator health, not raw telemetry.
6. Add CH/component/severity log taxonomy to Loki/Alloy.
7. Plan app-of-apps/GitOps adoption for platform, identity and observability.
8. Revisit release workflow after runtime correctness is stable.
```

## Decision summary

- Grafana, VictoriaMetrics, Loki and Alloy remain the primary observability stack.
- Do not add a full Nagios system yet.
- Recreate the useful Nagios pattern through Grafana: `OK`, `WARNING`, `CRITICAL`, `UNKNOWN`.
- Authentik should exist earlier than application-specific SSO bindings.
- SSO bindings should run only after the target UI is reachable and has stable TLS.
- Inventory Application registration is useful, but it is not the same as GitOps ownership.
