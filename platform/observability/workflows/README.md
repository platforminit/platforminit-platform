# CH05 Workflow Restructuring Plan

The current CH05 deploy is technically functional, but the operational observability layer should be split into smaller workflows.

## Target workflows

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Observability Stack` | base stack: Grafana, VictoriaMetrics, Loki, Alloy, Alertmanager |
| `05.1 - Provision Dashboards` | dashboard folders, dashboards, landing page and navigation |
| `05.2 - Provision Alerting` | VMRule, Alertmanager routes, inhibition and runbook links |
| `05.3 - Provision Security & Audit Monitoring` | audit log ingestion, security dashboards and security alerts |
| `05.4 - Onboard External Host` | n8n and future host collector onboarding |
| `05.5 - Enable Grafana SSO` | Authentik OAuth integration and break-glass validation |

## Transitional state

The repository may still contain a `05.1 - Enable Grafana SSO` workflow during the transition. The target lifecycle moves Grafana SSO to `05.5` because dashboards, alerting and security/audit visibility should exist before SSO polish.

## Validation philosophy

Each workflow should produce a validation artifact with PASS/WARN/FAIL sections and operator-readable summaries.
