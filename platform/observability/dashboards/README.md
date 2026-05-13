# CH05 Dashboard Contract

This directory describes the target dashboard model for PlatformInit operational observability.

## Dashboard set

| Dashboard | Purpose |
|---|---|
| `00 - Platform Overview` | Nagios-style operational landing page |
| `10 - Host Infrastructure` | curated Node Exporter based host health and capacity |
| `20 - Kubernetes / k3s` | cluster and workload health |
| `30 - Argo CD / GitOps` | sync, health and drift visibility |
| `40 - Identity / SSO` | Authentik and SSO provider health |
| `50 - Observability Self-Monitoring` | monitoring system health |
| `60 - Security & Audit` | access elevation and security baseline monitoring |
| `90 - Application Template` | reusable app/customer workload template |

## UX rules

- Landing view must use OK/WARNING/CRITICAL/UNKNOWN states.
- Panels must answer operational questions before exposing raw metrics.
- Every dashboard should include a short description of what it monitors.
- Deep technical panels are allowed, but not on the landing dashboard.
- Dashboard links should guide the operator from summary to root-cause area.

## Common variables

```text
project
environment
host
cluster
namespace
application
severity
lifecycle_ch
```

## Platform Overview success criteria

An operator can determine within 30 seconds:

- whether the platform is healthy;
- which layer is degraded;
- whether the degradation is warning, critical or unknown;
- which dashboard/log view should be opened next.


## Host dashboard policy

`10 - Host Infrastructure` is the curated operator-facing host dashboard. It should use Node Exporter metrics as its source of truth, but it must not become a raw Node Exporter Full style dashboard.

Required sections:

- Node Exporter scrape status;
- CPU, memory, swap and uptime;
- filesystem and inode usage;
- disk IO and network throughput;
- failed systemd units when the collector is available;
- PlatformInit storage contract once CH05.3 textfile metrics are implemented.

Raw upstream Node Exporter dashboards may be useful for deep troubleshooting later, but they should live in an advanced/troubleshooting folder and must not pollute the default PlatformInit operator dashboard list.
