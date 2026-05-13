# PlatformInit Platform

Turn a fresh VPS into a production-ready single-node platform with deterministic automation.

This repository is the PlatformInit monorepo for the DevOps Homelab / PlatformInit roadmap. It provisions a Hetzner Cloud host, bootstraps a hardened Ubuntu baseline, installs k3s, enables ingress/TLS/GitOps services, deploys identity, and adds a lightweight operations layer.

## Current platform model

| Layer | Purpose |
|---|---|
| CH01 / 01.x | host lifecycle, bootstrap and host access tooling |
| CH02 / 02.x | host baseline, drift checks, OS security and file integrity |
| CH03 | single-node k3s cluster installation |
| CH04 | platform services: ingress, TLS and Argo CD |
| CH04.5 | identity foundation: Authentik, identity namespace, groups, technical users and validation |
| CH04.6 | Argo CD SSO integration with Authentik |
| CH05 | operations monitoring: Zabbix, Vector, OpenObserve and Authentik-gated WebUIs |
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
| 15 | `05 - Deploy Zabbix Monitoring` | `observability-release-*` |
| 16 | `05.1 - Deploy OpenObserve` | `observability-release-*` |
| 17 | `05.2 - Deploy Vector Logging` | `observability-release-*` |
| 18 | `05.3 - Onboard External Host` | `observability-release-*` |
| 19 | `05.4 - Enable Operations SSO` | `observability-release-*` |

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

## CH05 operations monitoring

CH05 is an operator-first replacement for the previous Grafana/VictoriaMetrics/Loki/Alloy default stack.

```text
Zabbix      -> what is broken?
Vector      -> collect logs
OpenObserve -> why did it break?
Authentik   -> mandatory login gate for public operations WebUIs
```

Public operations WebUIs:

| URL | Purpose | Login |
|---|---|---|
| `https://zabbix.<PLATFORM_BASE_DOMAIN>` | operational alert/state console | Authentik |
| `https://logs.<PLATFORM_BASE_DOMAIN>` | log search and RCA | Authentik |

The base CH05 deploys create internal services first. Public ingresses are created only by `05.4 - Enable Operations SSO`.

Removed as default components:

- Grafana
- VictoriaMetrics
- VMAgent
- VMAlert
- Alertmanager
- Loki
- Alloy
- provisioned Grafana dashboards

## Storage contract

k3s must use:

```text
/srv/data/k3s
```

The old fallback to `/srv/k3s` or `/var/lib/rancher/k3s` is treated as legacy/stale state. Use the CH03 validation output and host storage audit commands when troubleshooting disk growth.

## Identity and SSO

Identity is deployed early in the lifecycle.

| Workflow | Binding | Notes |
|---|---|---|
| `04.5 - Deploy Identity Foundation` | Authentik core | required before app SSO |
| `04.6 - Enable Argo CD SSO` | Argo CD → Authentik | GitOps UI login |
| `05.4 - Enable Operations SSO` | Zabbix/OpenObserve → Authentik forward-auth | operations WebUIs |


CH05 workflow privilege contract:

```text
A1 mode: observability
Allowed privileged entrypoint: /tmp/platforminit-run/ch05-remote.sh *
```

CH05 workflows must not use generic `sudo -l` validation or ad-hoc runner names. The A1 grant is command-scoped and non-interactive.

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

Recommended branch for this redesign:

```bash
git checkout dev
git checkout -b feat/ch05-operations-stack-redesign
```

## Documentation index

| Area | Document |
|---|---|
| Secrets | `docs/secrets-reference.md` |
| Multi-project routing | `docs/multi-project-routing.md` |
| Host discovery and volume layout | `docs/multi-project-host-discovery-and-volume-layout.md` |
| Day-2 operations | `docs/day2-ops.md` |
| Release model | `docs/release-model.md` |
| CH05 operations monitoring design | `docs/ch05-operations-monitoring-design.md` |
| CH05 migration from previous stack | `docs/ch05-migration-from-grafana-stack.md` |
| Zabbix monitoring | `platform/observability/zabbix/README.md` |
| Vector logging | `platform/observability/vector/README.md` |
| OpenObserve RCA logs | `platform/observability/openobserve/README.md` |
| Operations SSO | `platform/observability/sso/README.md` |
| Operations rule system | `platform/observability/rules/platforminit-operations-rules.md` |

## Principles

- deterministic infrastructure
- immutable rebuild preference
- GitOps-first platform ownership
- no hardcoded secrets
- no standing sudo for runtime automation users
- public UIs only where they provide operator value
- Authentik login required for public WebUIs
- low-resource single-node defaults
- clear operator alerts over raw telemetry dashboards
