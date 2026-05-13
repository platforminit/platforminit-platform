# PlatformInit Platform

Turn a fresh VPS into a production-ready single-node platform with deterministic automation.

This repository is the PlatformInit monorepo for the DevOps Homelab / PlatformInit roadmap. It provisions a Hetzner Cloud host, bootstraps a hardened Ubuntu baseline, installs k3s, enables ingress/TLS/GitOps services, and deploys observability and identity layers.

## Current platform model

| Layer | Purpose |
|---|---|
| CH01 / 01.x | host lifecycle, bootstrap and host access tooling |
| CH02 / 02.x | host baseline, drift checks, OS security and file integrity |
| CH03 | single-node k3s cluster installation |
| CH04 | platform services: ingress, TLS and Argo CD |
| CH04.5 | identity foundation: Authentik, identity namespace, groups, technical users and validation |
| CH04.6 | Argo CD SSO integration with Authentik |
| CH05 | operations monitoring: Zabbix, Vector, OpenObserve and external host onboarding |
| CH05.x | operations split: monitoring, logging, RCA search, external host onboarding and SSO |
| CH06 | deprecated identity compatibility workflow; do not use for normal lifecycle execution |

## User-facing workflow order

| Order | Workflow | Artifact required |
|---:|---|---|
| 0 | `00 - Build Platform Artifacts` | none |
| 1 | `01 - Create or Rebuild Host` | none |
| 2 | `01.1 - Host Bootstrap` | none |
| 3 | `01.2 - Sync Host Access Tooling` | none |
| 4 | `02 - Apply Host Baseline` | `host-baseline-release-*` |
| 5 | `02.1 - Drift Check` | host-baseline artifact where requested |
| 6 | `02.3 - OS Security Check` | host-baseline artifact where requested |
| 7 | `02.4 - OS Security Apply` | host-baseline artifact where requested |
| 8 | `02.5 - File Integrity Check` | host-baseline artifact where requested |
| 9 | `02.5.1 - Initialize AIDE Database` | host-baseline artifact where requested |
| 10 | `02.5.2 - Run AIDE Check` | host-baseline artifact where requested |
| 11 | `03 - Install Kubernetes Cluster` | `cluster-release-*` |
| 12 | `04 - Enable Platform (Ingress, TLS, ArgoCD)` | `platform-services-release-*` |
| 13 | `04.5 - Deploy Identity Foundation` | `identity-release-*` |
| 14 | `04.6 - Enable Argo CD SSO` | `identity-release-*` |
| 15 | `05 - Deploy Observability Stack` | `observability-release-*` |
| 16 | `05.1 - Provision Dashboards` | `observability-release-*` |
| 17 | `05.2 - Provision Alerting` | `observability-release-*` |
| 18 | `05.4 - Enable Operations SSO` | `identity-release-*` |

Target CH05 redesign order:

| Target order | Workflow | Purpose |
|---:|---|---|
| 15 | `05 - Deploy Observability Stack` | base observability backend and Grafana |
| 16 | `05.1 - Provision Dashboards` | operational dashboard set and navigation |
| 17 | `05.2 - Provision Alerting` | OK/WARNING/CRITICAL/UNKNOWN alert model |
| 18 | `05.3 - Provision Security & Audit Monitoring` | access elevation, sudo, SSH, UFW and AIDE/FIM visibility |
| 19 | `05.4 - Onboard External Host` | n8n and future host telemetry onboarding |
| 20 | `05.4 - Enable Operations SSO` | Authentik Grafana SSO integration |

Each deploy workflow accepts the producing build workflow run ID and the specific artifact ID from `00 - Build Platform Artifacts`.

## Active environment contract

| Item | Current value |
|---|---|
| Provider | Hetzner Cloud |
| Active project | `development` |
| Development host | `platforminit-dev-01` |
| Base domain | `sysadminhomelab.hu` |
| Kubernetes | single-node k3s |
| Public operational UI | Zabbix + OpenObserve |
| Public identity UI | Authentik |

Deprecated development host aliases must not be used; the only valid development host contract is `platforminit-dev-01`.

## CH05 operational observability

CH05 is being redesigned from a raw metrics dashboard layer into a Platform Operations Console. The deployment stack remains Grafana, VictoriaMetrics, VMAgent, Loki, Alloy and Alertmanager, but the UX goal is Nagios-style operational clarity.

Public WebUI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>
```

Internal backends:

| Component | Public WebUI? | Usage |
|---|---:|---|
| Grafana | yes | dashboards, logs, alerts and operator console |
| VictoriaMetrics | no | metrics backend / internal debug API |
| VMAgent | no | scrape and remote-write pipeline |
| Loki | no | log backend queried from Grafana |
| Alloy | no | Kubernetes and host log collector |
| Alertmanager | no by default | internal alert grouping and routing |

Target dashboard entrypoint:

```text
Dashboards → PlatformInit → 00 - Platform Overview
```

Target dashboard set:

| Dashboard | Purpose |
|---|---|
| `00 - Platform Overview` | OK/WARNING/CRITICAL/UNKNOWN landing dashboard |
| `10 - Host Infrastructure` | CPU, RAM, disk, inode, swap, network, disk IO, uptime and failed services |
| `20 - Kubernetes / k3s` | node, pod, workload, PVC and cluster resource health |
| `30 - Argo CD / GitOps` | Argo CD components, sync failures, unhealthy apps and drift |
| `40 - Identity / SSO` | Authentik, providers, login failures and SSO health |
| `50 - Observability Self-Monitoring` | Grafana, VictoriaMetrics, Loki, VMAgent, Alloy and Alertmanager health |
| `60 - Security & Audit` | access elevation, sudo, SSH, UFW, AIDE/FIM and RBAC security visibility |
| `90 - Application Template` | reusable dashboard for n8n and future workloads |

Security & Audit Monitoring is part of the CH05 redesign. The platform already uses approval-gated temporary access elevation, so CH05 must make elevation grants, sudo activity, SSH anomalies, UFW drift and AIDE/FIM status visible in Grafana.

See:

- `docs/ch05-operational-observability-design.md`
- `platform/observability/dashboards/README.md`
- `platform/observability/logging/README.md`
- `platform/observability/alerts/README.md`
- `platform/observability/security/README.md`
- `platform/observability/external-hosts/README.md`
- `platform/observability/workflows/README.md`

## Identity and SSO

Identity has been promoted into the early platform lifecycle. Authentik is deployed by CH04.5, Argo CD SSO is enabled by CH04.6 and Grafana SSO has moved to CH05.5 so dashboards and alerting exist before the final operator login polish.

Public identity UI:

```text
https://auth.<PLATFORM_BASE_DOMAIN>
```

Current SSO bindings:

| Workflow | Binding | Notes |
|---|---|---|
| `04.6 - Enable Argo CD SSO` | Argo CD → Authentik | browser login validated during identity refactor |
| `05.4 - Enable Operations SSO` | Grafana → Authentik | run after CH05, CH05.1 and CH05.2 are healthy |

After running CH05 in `baseline` mode, rerun `05.4 - Enable Operations SSO` if the Grafana SSO button disappears.

## Privilege model

- `01 - Create or Rebuild Host` provisions the machine and injects the automation key for initial root access.
- `01.1 - Host Bootstrap` creates `devops` and `itadmin`, disables root login and password auth, and installs the scoped privilege helper.
- `01.2 - Sync Host Access Tooling` updates the host-side grant tooling without rebuilding the host.
- `A1 - Access Elevation` is the approval-gated elevation path for time-bound workflow sudo.
- `devops` should not have standing sudo.

## Branch model

| Branch | Purpose |
|---|---|
| `main` | release-ready baseline |
| `staging` | pre-release validation |
| `dev` | active integration branch |
| `feat/*` / `fix/*` | isolated delivery branches |

## Documentation index

| Area | Document |
|---|---|
| Secrets | `docs/secrets-reference.md` |
| Multi-project routing | `docs/multi-project-routing.md` |
| Host discovery and volume layout | `docs/multi-project-host-discovery-and-volume-layout.md` |
| Day-2 operations | `docs/day2-ops.md` |
| Release model | `docs/release-model.md` |
| CH05 operational observability design | `docs/ch05-operational-observability-design.md` |
| CH05 dashboard contract | `platform/observability/dashboards/README.md` |
| CH05 logging contract | `platform/observability/logging/README.md` |
| CH05 alerting contract | `platform/observability/alerts/README.md` |
| CH05 security & audit monitoring | `platform/observability/security/README.md` |
| CH05 external host onboarding | `platform/observability/external-hosts/README.md` |
| CH05 workflow restructuring | `platform/observability/workflows/README.md` |
| CH05 dashboard guide | `platform/observability/docs/ch05-beginner-dashboard-guide.md` |
| CH05 k3s monitoring runbook | `platform/observability/docs/ch05-k3s-monitoring-runbook.md` |
| CH05/CH05.1 SSO interaction | `platform/observability/docs/ch05-ch05-1-sso-interaction.md` |

## Principles

- deterministic infrastructure
- immutable rebuild preference
- GitOps-first platform ownership
- no hardcoded secrets
- no standing sudo for runtime automation users
- public UIs only where they provide operator value
- beginner-friendly defaults with deeper debug paths available when needed

## Current lifecycle note

Identity has been promoted into the early platform lifecycle. Use `04.5 - Deploy Identity Foundation` for Authentik core deployment plus PlatformInit scoped identity group bootstrap. The old `06 - Deploy Identity Stack` workflow is deprecated and retained only for compatibility. Application SSO bindings remain separate as `04.6 - Enable Argo CD SSO` and the transitional `05.1 - Enable Grafana SSO`.

CH05 is now being redesigned as an operational observability layer with dashboard, alerting, logging, security/audit and external-host onboarding contracts. The target CH05 split moves Grafana SSO to `05.4 - Enable Operations SSO`.

See:

- `docs/identity-layer-refactor.md`
- `docs/ch05-operational-observability-design.md`


## CH05 redesign (current direction)

PlatformInit is moving away from the previous Grafana/VictoriaMetrics/Loki/Alloy stack due to operator UX complexity, storage growth and poor root-cause clarity.

New target architecture:

```
Zabbix -> what is broken
Vector -> collect logs
OpenObserve -> why it broke
Authentik -> SSO for all operational UIs
```

Removed as default components:
- Grafana
- VictoriaMetrics
- vmagent
- vmalert
- Alertmanager
- Loki
- Alloy

These may return later as optional advanced modules, but they are no longer PlatformInit defaults.
