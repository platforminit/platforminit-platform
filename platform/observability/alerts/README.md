# CH05 Alerting Contract

CH05 alerting must provide Nagios-style operational clarity: OK, WARNING, CRITICAL and UNKNOWN.

## Alert states

| State | Meaning |
|---|---|
| OK | healthy |
| WARNING | degraded or risky but still available |
| CRITICAL | service impact, unsafe state or data loss risk |
| UNKNOWN | telemetry missing or health cannot be determined |

## Categories

```text
host
cluster
platform
identity
observability
security
application
```

## Required labels

```yaml
severity: warning|critical|unknown
category: host|cluster|platform|identity|observability|security|application
project: development|n8n|platforminit
environment: dev|prod
host: platforminit-dev-01
service: grafana|loki|victoriametrics|alloy|alertmanager|...
lifecycle_ch: ch05
owner: platform
```

## Required annotations

```yaml
summary: Short human-readable alert title
impact: What is affected
action: First troubleshooting action
runbook_url: Relative runbook path
```

## Noise reduction

- Alerts must be actionable.
- Use `for:` windows for transient conditions.
- Inhibit child alerts when a parent layer is down.
- Group notifications by project, environment, category and service.
- Suppress warning alerts when a critical alert for the same service is active.

## CH05.2 implementation baseline

`05.2 - Provision Alerting` applies `platform/observability/manifests/alerts/platform-vmrule.yaml`.

The first implementation focuses on actionable platform operations alerts:

| Category | Examples | Source |
|---|---|---|
| host | Node Exporter down, CPU high, memory pressure, disk/inode usage | Node Exporter |
| cluster | node not ready, crashlooping pods, pending/failed pods, unavailable deployments, PVC usage | kube-state-metrics / kubelet |
| platform | Argo CD unavailable, Argo CD application drift | kube-state-metrics / Argo CD metrics |
| identity | Authentik deployment unavailable | kube-state-metrics |
| observability | Grafana, VMAgent, VictoriaMetrics, Loki and Alertmanager availability | kube-state-metrics / up{} |

The rule set intentionally prioritizes clear operator signals over exhaustive raw metric coverage.

## Routing status

CH05.2 v1 provisions alert rules and validates Alertmanager presence. Notification routing remains conservative: alerts are visible in Grafana and Alertmanager, but external notification fanout should be added later when the alert noise budget is proven.


## Alert Operations Center v2

The Alert Operations Center is not a raw alert counter dashboard. It must behave like an operational/Nagios-style console:

- show CRITICAL, UNKNOWN and WARNING queues separately;
- show the affected layer, service, namespace/pod/instance when available;
- expose a short next action and runbook reference directly in the table;
- keep counters only as status headers, not as the main information source;
- fail validation if the dashboard regresses to a label dump without operator context.

The dashboard reads active alerts from the `ALERTS{alertstate="firing"}` metric. Because annotations are not reliably exposed as Prometheus labels, every PlatformInit alert rule also carries compact operational labels such as `operator_hint`, `runbook`, `category`, `service` and `lifecycle_ch`. These labels are intentionally static and low-cardinality.
