# CH05 Operations Monitoring Design

CH05 is no longer a Grafana-first observability stack. It is an operator-first operations layer for a small, single-node platform.

## Decision

PlatformInit defaults to:

```text
Zabbix      -> operational state and alerts
Vector      -> low-footprint log collection
OpenObserve -> searchable logs and RCA
Authentik   -> mandatory login for public WebUIs
```

## Why the previous model was removed

The previous Grafana/VictoriaMetrics/Loki/Alloy model solved telemetry collection but did not solve the operator workflow:

```text
what failed?
where did it fail?
why did it fail?
what should I inspect next?
```

It also introduced too many moving parts for the default single-node PlatformInit use case.

## Workflow split

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Zabbix Monitoring` | state-first monitoring |
| `05.1 - Deploy OpenObserve` | searchable RCA logs |
| `05.2 - Deploy Vector Logging` | log collection |
| `05.3 - Onboard External Host` | future n8n/customer host agent onboarding |
| `05.4 - Enable Operations SSO` | Authentik-gated public WebUIs |

## WebUI rule

Zabbix and OpenObserve must not be exposed publicly without Authentik.

The base deploy creates internal services only. `05.4` creates the public ingresses and attaches the Authentik forward-auth middleware.

## Storage rule

k3s data must be stored under `/srv/data/k3s`. This prevents accidental growth under the wrong partition and makes PVC-backed storage easier to audit.
