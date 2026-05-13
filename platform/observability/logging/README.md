# CH05 Logging Contract

Loki logging must be structured around operator navigation, not raw container log dumping.

## Required labels

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

## Security labels

Security and audit streams additionally use:

```text
category="security"
event_type
```

## High-cardinality values must not be labels

Do not label by:

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

These values remain in the log body.

## Lifecycle navigation

| lifecycle_ch | Scope |
|---|---|
| `ch01` | host lifecycle / bootstrap |
| `ch02` | host baseline, security and file integrity |
| `ch03` | k3s cluster |
| `ch04` | platform services, ingress, TLS, Argo CD |
| `ch04.5` | identity foundation |
| `ch04.6` | Argo CD SSO |
| `ch05` | observability stack |
| `ch05.1` | dashboards |
| `ch05.2` | alerting |
| `ch05.3` | security and audit monitoring |
| `ch05.4` | external host onboarding |
| `ch05.5` | Grafana SSO |

## Grafana Explore shortcuts

Target saved/linked searches:

```logql
{project="$project", environment="$environment", severity=~"error|critical"}
{project="$project", environment="$environment", lifecycle_ch="$lifecycle_ch"}
{project="$project", namespace="$namespace", application="$application"}
{category="security", severity=~"warning|critical|unknown"}
```

## Retention baseline

| Environment | Logs | Metrics |
|---|---:|---:|
| development | 7-14 days | 15-30 days |
| n8n | 14-30 days | 30 days |
| production | 30+ days | 90 days |
