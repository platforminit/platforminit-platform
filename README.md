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
| CH05 | observability: Grafana, VictoriaMetrics, Loki and Alloy |
| CH06 | identity: Authentik SSO foundation |
| CH05.1 | Grafana SSO integration with Authentik |

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
| 13 | `05 - Deploy Observability Stack` | `observability-release-*` |
| 14 | `06 - Deploy Identity Stack` | `identity-release-*` |
| 15 | `05.1 - Enable Grafana SSO` | `identity-release-*` |

Each deploy workflow accepts the producing build workflow run ID and the specific artifact ID from `00 - Build Platform Artifacts`.

## Active environment contract

| Item | Current value |
|---|---|
| Provider | Hetzner Cloud |
| Active project | `development` |
| Development host | `platforminit-dev-01` |
| Base domain | `sysadminhomelab.hu` |
| Kubernetes | single-node k3s |
| Public operational UI | Grafana |
| Public identity UI | Authentik |

Deprecated development host aliases must not be used; the only valid development host contract is `platforminit-dev-01`.

## CH05 observability UX

CH05 is intentionally beginner-friendly by default.

Public WebUI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>
```

Internal backends:

| Component | Public WebUI? | Usage |
|---|---:|---|
| Grafana | yes | dashboards, logs and alerts |
| VictoriaMetrics | no | metrics backend / internal debug API |
| Loki | no | log backend queried from Grafana |
| Alloy | no | collector / internal debug endpoint |
| Alertmanager | no by default | internal alert routing |

Default dashboard entrypoint:

```text
Dashboards → PlatformInit → 00 - Start Here
```

PlatformInit provisions a focused dashboard set and prunes noisy upstream dashboard ConfigMaps during CH05 deploy:

| Dashboard | Purpose |
|---|---|
| `PlatformInit / 00 - Start Here` | first green/red operational view |
| `PlatformInit / Cluster Overview` | pods, namespaces, nodes and restarts |
| `PlatformInit / Node Overview` | host CPU, memory, disk, filesystem and network |
| `PlatformInit / Logs Overview` | Loki logs through Grafana |

Generic upstream dashboards for etcd, scheduler and controller-manager can show expected `No data` on single-node k3s and are not part of the default beginner UX.

See `platform/observability/docs/ch05-beginner-dashboard-guide.md`.

## CH06 identity and SSO

CH06 deploys Authentik:

```text
https://auth.<PLATFORM_BASE_DOMAIN>
```

CH05.1 enables Grafana Generic OAuth against Authentik while keeping local Grafana admin login as the break-glass path.

After running CH05 in `reconcile` mode, CH05.1 usually does not need to be rerun. After CH05 `baseline` mode, rerun `05.1 - Enable Grafana SSO` if the Grafana SSO button disappears.

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
| CH05 dashboard guide | `platform/observability/docs/ch05-beginner-dashboard-guide.md` |
| CH05 k3s monitoring runbook | `platform/observability/docs/ch05-k3s-monitoring-runbook.md` |
| CH05/CH06 SSO interaction | `platform/observability/docs/ch05-ch05-1-sso-interaction.md` |

## Principles

- deterministic infrastructure
- immutable rebuild preference
- GitOps-first platform ownership
- no hardcoded secrets
- no standing sudo for runtime automation users
- public UIs only where they provide operator value
- beginner-friendly defaults with deeper debug paths available when needed

## Current lifecycle note

Identity has been promoted into the early platform lifecycle. Use `04.5 - Deploy Identity Foundation` for Authentik core deployment plus PlatformInit scoped identity group bootstrap. The old `06 - Deploy Identity Stack` workflow is deprecated and retained only for compatibility. Application SSO bindings remain separate as `05.1 - Enable Grafana SSO` and `04.6 - Enable Argo CD SSO`.

See `docs/identity-layer-refactor.md`.
