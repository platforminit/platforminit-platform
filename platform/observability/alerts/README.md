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
