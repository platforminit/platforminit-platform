# CH05 Dashboard Contract

This directory describes the target dashboard model for PlatformInit operational observability.

## Dashboard set

| Dashboard | Purpose |
|---|---|
| `00 - Platform Overview` | Nagios-style operational landing page |
| `10 - Host Infrastructure` | host health and capacity |
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


## Noise policy

CH05.1 intentionally prunes raw upstream / community Grafana dashboards from the main dashboard list. They are useful for deep troubleshooting, but they must not be the operator landing experience. The active operator set is the numbered `PlatformInit / NN - ...` dashboard family.
