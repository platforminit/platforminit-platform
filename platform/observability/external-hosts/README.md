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
