# CH05 Operational Observability Redesign

CH05 is the PlatformInit operational observability layer. Its purpose is not only to deploy Grafana, VictoriaMetrics, Loki, Alloy and Alertmanager, but to provide a clear operator console for deciding whether the platform is healthy, degraded, broken or unknown.

## Design goal

An operator should be able to answer these questions within 30 seconds:

- Is the platform OK, WARNING, CRITICAL or UNKNOWN?
- Which layer is affected: host, cluster, platform services, identity, observability, security or application?
- What is the likely impact?
- Where should troubleshooting start?
- Are the metrics and logs themselves trustworthy?

## Stack decision

The current stack remains correct for the PlatformInit roadmap.

| Component | Decision | Reason |
|---|---|---|
| Grafana | keep | best operational UI and provisioning target |
| VictoriaMetrics | keep | efficient metrics backend for single-node and small multi-project setups |
| VMAgent | keep | scrape and remote-write model supports future external hosts |
| Loki | keep | good enough log backend when labels and retention are controlled |
| Alloy | keep | collector and relabeling layer for Kubernetes and future hosts |
| Alertmanager | keep | alert grouping, routing and inhibition remain required |
| Argo CD | keep | GitOps inventory and drift visibility |

The problem is not the component choice. The problem is the current UX: dashboards are too close to raw engineering dashboards and do not provide Nagios-style operational clarity.

## Operational state model

All high-level dashboards and alerts must use a common state language.

| State | Meaning |
|---|---|
| OK | service or layer is healthy |
| WARNING | degraded or risky but still available |
| CRITICAL | service impact, data loss risk or unsafe state |
| UNKNOWN | monitoring cannot determine health or telemetry is missing |

`UNKNOWN` is not neutral. Missing telemetry must be visible because it means the platform cannot be trusted.

## Dashboard model

The dashboard set should be rebuilt around operator workflows.

| Dashboard | Purpose |
|---|---|
| `00 - Platform Overview` | landing page with OK/WARNING/CRITICAL/UNKNOWN status |
| `10 - Host Infrastructure` | CPU, RAM, disk, inode, swap, network, disk IO, uptime, failed services |
| `20 - Kubernetes / k3s` | node, pod, workload, PVC and cluster resource health |
| `30 - Argo CD / GitOps` | Argo components, sync state, unhealthy apps and drift |
| `40 - Identity / SSO` | Authentik, providers, login failures and SSO callback health |
| `50 - Observability Self-Monitoring` | Grafana, VictoriaMetrics, Loki, VMAgent, Alloy and Alertmanager |
| `60 - Security & Audit` | access elevation, sudo, SSH, UFW, AIDE/FIM and auth security signals |
| `90 - Application Template` | reusable dashboard for n8n and future workloads |

All dashboards should expose these variables where applicable:

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

## Platform Overview dashboard contract

The landing dashboard must be simple, not exhaustive.

Required panels:

| Panel | Description |
|---|---|
| Overall Platform Status | single OK/WARNING/CRITICAL/UNKNOWN state |
| Active Alerts | total critical, warning and unknown alerts |
| Platform Uptime | host and k3s uptime summary |
| Infrastructure Health | host/node health summary |
| Kubernetes Health | pod and workload summary |
| GitOps Health | synced/healthy/out-of-sync application summary |
| Identity Health | Authentik and SSO status |
| Observability Health | whether monitoring components are healthy |
| Security & Audit Health | access elevation and security baseline status |
| Quick Links | direct links to deeper dashboards and log views |

The first screen must not require PromQL knowledge.

## Logging model

Loki must be redesigned around stable labels and navigation.

Required stable labels:

```text
project
environment
host
cluster
namespace
application
component
severity
lifecycle_ch
source
```

Security-specific logs add:

```text
category="security"
event_type
```

Do not use high-cardinality values as Loki labels:

```text
pod_uid
container_id
request_id
trace_id
user_id
ip_address
url_path
full_command
full_error_message
```

These values belong in the log body.

## Lifecycle log mapping

| Source | lifecycle_ch |
|---|---|
| host bootstrap and baseline | `ch01` / `ch02` |
| k3s and Kubernetes system | `ch03` |
| Traefik, cert-manager, Argo CD | `ch04` |
| Authentik foundation | `ch04.5` |
| Argo CD SSO | `ch04.6` |
| observability stack | `ch05` |
| dashboards | `ch05.1` |
| alerting | `ch05.2` |
| security and audit monitoring | `ch05.3` |
| external host onboarding | `ch05.4` |
| Grafana SSO | `ch05.5` |
| future n8n application layer | `app/n8n` or later CH label |

## Security & Audit monitoring

Security monitoring is part of CH05 because the platform already has approval-gated temporary access elevation. Operators must be able to see when elevation was granted, what scope was granted, whether it expired and whether the security baseline is still trustworthy.

Primary audit source:

```text
/srv/platforminit/audit/security.log
```

Required event families:

| Family | Examples |
|---|---|
| access elevation | grant requested, granted, expired, failed |
| sudo | allowed sudo, denied sudo, unexpected sudo |
| SSH | failed login, root login attempt, root login success |
| firewall | UFW disabled, UFW drift |
| file integrity | AIDE/FIM drift, missing baseline |
| identity | Authentik login/provider/callback failures |
| RBAC | Argo CD and Grafana permission failures |
| telemetry | security log missing or collector down |

This is operational security monitoring, not a full SIEM or long-term forensic archive.

## Alert model

Alerts must be actionable. No alert should exist without a clear operator action.

Required alert labels:

```yaml
severity: warning|critical|unknown
category: host|cluster|platform|identity|observability|security|application
project: development|n8n|platforminit
environment: dev|prod
lifecycle_ch: ch05
service: grafana|loki|victoriametrics|alloy|alertmanager|...
owner: platform
```

Required annotations:

```yaml
summary: human readable one-liner
impact: what is affected
action: what the operator should do first
runbook_url: link to the relevant runbook
```

Noise reduction rules:

- use `for:` windows for noisy resource alerts
- group alerts by project, environment, category and service
- inhibit dependent alerts when a parent layer is down
- suppress warning alerts when a critical alert for the same service is active
- prefer fewer actionable alerts over many raw metric alerts

## Multi-project monitoring model

Use a hybrid architecture.

| Project | Recommendation |
|---|---|
| development | full CH05 stack; can receive telemetry from non-production external hosts |
| n8n | lightweight collectors only at first; send metrics/logs to development monitoring |
| platforminit production | separate production monitoring boundary; do not depend on development monitoring |

This avoids deploying a full stack everywhere while preserving production isolation.

## Workflow target model

The CH05 lifecycle should be split by responsibility.

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Observability Stack` | Grafana, VictoriaMetrics, Loki, Alloy, Alertmanager base stack |
| `05.1 - Provision Dashboards` | dashboard folders, JSON dashboards and navigation |
| `05.2 - Provision Alerting` | VMRule, Alertmanager routes and runbook links |
| `05.3 - Provision Security & Audit Monitoring` | audit log ingestion, security dashboards and security alerts |
| `05.4 - Onboard External Host` | n8n and future host collectors |
| `05.5 - Enable Grafana SSO` | Authentik OAuth integration and break-glass validation |

`05.5 - Enable Grafana SSO` is the active Grafana SSO workflow after dashboard provisioning. `05.2`, `05.3` and `05.4` remain planned implementation steps.

## Reuse vs rebuild

Reuse:

- Helm-based installation
- Grafana
- VictoriaMetrics
- VMAgent
- Loki
- Alloy
- Alertmanager
- Grafana ingress/TLS
- Argo CD inventory registration

Rebuild:

- dashboard information architecture
- Loki label strategy
- Alloy relabeling configuration
- alert rule model
- Alertmanager routing and inhibition
- Security & Audit dashboard
- dashboard provisioning workflow
- alert provisioning workflow
- validation reports for operator UX

## Implementation phases

| Phase | Branch suggestion | Outcome |
|---|---|---|
| Design | `design/ch05-operational-observability` | documentation and contracts |
| Dashboards | `feat/ch05-operational-dashboards` | new operator dashboard set |
| Logging | `feat/ch05-loki-label-strategy` | structured Loki labels and log navigation |
| Alerting | `feat/ch05-alerting-model` | OK/WARNING/CRITICAL/UNKNOWN alert model |
| Security | `feat/ch05-security-audit-monitoring` | access elevation and baseline security visibility |
| External hosts | `feat/ch05-external-host-onboarding` | n8n/future host telemetry onboarding |
