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


## Host alert source

Host alerts must be built primarily from Node Exporter metrics. The first CH05.2 alerting implementation should cover:

| Alert | Severity | Source | Intent |
|---|---|---|---|
| `HostNodeExporterDown` | critical | `up{job=~".*node-exporter.*|platform-node-exporter"}` | host telemetry unavailable |
| `HostCpuHigh` | warning | `node_cpu_seconds_total` | sustained CPU pressure |
| `HostMemoryPressure` | warning | `node_memory_*` | low available memory |
| `HostDiskUsageHigh` | warning/critical | `node_filesystem_*` | filesystem capacity risk |
| `HostInodeUsageHigh` | warning/critical | `node_filesystem_files*` | inode exhaustion risk |
| `HostDiskIoPressure` | warning | `node_disk_*` | IO saturation investigation |
| `HostNetworkErrors` | warning | `node_network_*_err*` | interface or network quality issue |
| `HostRebootRequired` | warning | CH05.3 textfile metric | pending reboot after security patching |
| `PlatformInitSplitStorageBroken` | critical | CH05.3 textfile metric | `/srv/data`, `/srv/db` or `/srv/observability` mount contract broken |

Raw metric alerts should be grouped into human-facing OK/WARNING/CRITICAL/UNKNOWN states in the Alert Operations Center dashboard.
