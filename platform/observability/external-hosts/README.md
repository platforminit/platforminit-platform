# CH05 External Host Onboarding

External host onboarding supports future project hosts such as n8n without deploying a full monitoring stack on every host.

## Target model

| Project | Monitoring model |
|---|---|
| development | full CH05 stack |
| n8n | lightweight collectors sending telemetry to development monitoring initially |
| platforminit production | separate production monitoring boundary |

## Onboarded host components

A future `05.4 - Onboard External Host` workflow should install and validate:

- node-exporter;
- Node Exporter textfile collector directory for PlatformInit host state;
- Alloy;
- remote metrics write or scrape access;
- Loki log shipping;
- host labels;
- firewall rules;
- health validation;
- audit/security log shipping where applicable.

## Required host labels

```text
project
environment
host
role
owner
lifecycle_ch
```

## Security boundary

Development monitoring may receive telemetry from development and non-production utility hosts. Production telemetry must not depend on the development monitoring stack.


## Node Exporter onboarding contract

Every external host must expose the same host telemetry model as the Kubernetes node. For n8n and future utility hosts, `05.4 - Onboard External Host` should install Node Exporter with:

```text
--collector.filesystem
--collector.netdev
--collector.diskstats
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

The onboarding workflow should also create/update a PlatformInit textfile metric such as:

```text
platforminit_host_info{project="n8n",environment="dev",host="n8n-dev-01",role="automation"} 1
platforminit_audit_log_present 1
platforminit_reboot_required 0
```

This allows the same `10 - Host Infrastructure` dashboard and host alert rules to work for the current dev host and future external hosts.
