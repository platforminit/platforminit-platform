# CH05.1 Observability UX and Alerting Redesign

## Problem statement

The current observability stack is technically deployed, but the operator experience is still too raw.

Grafana, VictoriaMetrics, Loki and Alloy provide the telemetry substrate, but the current dashboards do not yet answer the first operational question clearly:

```text
What is broken, where, and how serious is it?
```

## Decision

Keep Grafana, VictoriaMetrics, Loki and Alloy as the primary observability stack.

Do not introduce a full Nagios deployment yet. Instead, implement a Nagios-style operator layer in Grafana using simple health states:

```text
OK / WARNING / CRITICAL / UNKNOWN
```

## Target dashboard set

| Dashboard | Purpose |
|---|---|
| `PlatformInit / 00 - Start Here` | landing page with global platform health |
| `PlatformInit / CH Health Matrix` | CH01-CH06 layer status in one view |
| `PlatformInit / Workload Health` | namespace/workload/pod readiness, restart and reason panels |
| `PlatformInit / Platform Services` | Traefik, cert-manager, Argo CD and TLS health |
| `PlatformInit / Identity` | Authentik server/worker, login path and SSO health |
| `PlatformInit / Observability Self-Health` | Grafana, Loki, VictoriaMetrics, Alloy and Alertmanager health |
| `PlatformInit / Logs Explorer` | solution-driven Loki views by chapter, component and severity |

## First operator panels

| Panel | Source | Desired state |
|---|---|---|
| CH01 Host baseline | future validation metric/report | OK when latest baseline validation passed |
| CH02 Kubernetes | kube-state-metrics/node-exporter | OK when node and system pods are ready |
| CH03 Platform core | kube-state-metrics/cert-manager metrics | OK when Traefik and cert-manager are ready |
| CH04 Argo CD | kube-state-metrics + Argo CD metrics | OK when server/dex/repo/controller are ready |
| CH05 Observability | kube-state-metrics + self metrics | OK when Grafana/Loki/VictoriaMetrics/Alloy are ready |
| CH06 Identity | kube-state-metrics + Authentik checks | OK when Authentik server/worker are ready |
| CrashLoopBackOff list | kube-state-metrics/events/logs | CRITICAL when any platform pod is crashing |
| OOMKilled/restarts | kube-state-metrics | WARNING/CRITICAL based on restart rate |
| TLS certificates | cert-manager metrics | WARNING before expiry, CRITICAL when invalid |

## Loki taxonomy

Logs should stop being an undifferentiated stream. The target label/search model is:

| Label | Examples |
|---|---|
| `chapter` | `ch03`, `ch04`, `ch05`, `ch06` |
| `layer` | `platform`, `identity`, `observability`, `gitops` |
| `component` | `argocd`, `authentik`, `grafana`, `loki`, `victoria`, `traefik`, `cert-manager` |
| `namespace` | `argocd`, `identity`, `observability`, `kube-system`, `cert-manager` |
| `severity` | `debug`, `info`, `warn`, `error`, `critical` |

Example target queries:

```text
Show CH06 identity errors from the last 30 minutes.
Show Argo CD Dex authentication failures.
Show Grafana OAuth warnings.
Show platform CrashLoopBackOff-related logs.
```

## Alert UX principles

- Alerts must answer a user-facing operational question.
- Avoid noisy raw upstream alerts until they are mapped to a clear PlatformInit health state.
- Prefer concise titles: `CRITICAL - Argo CD Dex authentication failed`.
- Prefer one operator action link per alert: runbook, dashboard, or filtered log view.
- Alerts should map to platform layers and components, not only low-level Kubernetes object names.

## Deferred options

A separate Nagios/Checkmk/Uptime Kuma-style layer may be useful later for external blackbox monitoring:

- `argocd.<domain>` HTTP reachability
- `grafana.<domain>` HTTP reachability
- `auth.<domain>` HTTP reachability
- TLS certificate validity
- login endpoint availability

Do not add that layer until the Grafana-based CH05.1 operator UX is improved.
