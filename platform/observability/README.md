# CH05 Observability

CH05 provides the PlatformInit operational observability foundation for the single-node k3s environment and future multi-project expansion.

The goal is not only to deploy metrics and logging components. CH05 must provide an operator-friendly Platform Operations Console with clear OK/WARNING/CRITICAL/UNKNOWN status, useful logs, actionable alerts and security/audit visibility.

## Scope

- Metrics via VictoriaMetrics stack and VMAgent
- Logs via Loki and Alloy
- Alerting via VMAlert and Alertmanager
- Grafana datasource provisioning
- Operational dashboard set
- Kubernetes and node baseline telemetry
- Observability self-monitoring
- Security & Audit Monitoring
- External host onboarding design for n8n and future hosts

## Public UI policy

Grafana is the only public CH05 WebUI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>
```

VictoriaMetrics, Loki, VMAgent, Alloy and Alertmanager are internal services. They should be accessed through Grafana or temporary `kubectl port-forward` during debugging.

## Stack decision

The current stack is retained.

| Component | Decision | Purpose |
|---|---|---|
| Grafana | keep | dashboards, logs, alerts, operator console |
| VictoriaMetrics | keep | metrics backend |
| VMAgent | keep | scrape and remote-write pipeline |
| Loki | keep | log backend |
| Alloy | keep | Kubernetes and host log collector |
| Alertmanager | keep | alert grouping and routing |
| Argo CD inventory app | keep | GitOps visibility for CH05 resources |

The redesign focuses on UX, labels, dashboards, alerts and security monitoring rather than replacing the stack.

## Operational state model

CH05 uses a Nagios-style state model.

| State | Meaning |
|---|---|
| OK | healthy |
| WARNING | degraded or risky but service still available |
| CRITICAL | service impact, unsafe state or data loss risk |
| UNKNOWN | telemetry missing or health cannot be determined |

## Target dashboard policy

Target dashboard entrypoint:

```text
Dashboards → PlatformInit → 00 - Platform Overview
```

Target dashboard set:

| Dashboard | Purpose |
|---|---|
| `00 - Platform Overview` | first operational health view |
| `10 - Host Infrastructure` | host CPU, memory, disk, inode, swap, network, IO, uptime and failed services |
| `20 - Kubernetes / k3s` | node, pod, deployment, daemonset, statefulset, PVC and resource health |
| `30 - Argo CD / GitOps` | Argo components, sync failures, unhealthy apps and GitOps drift |
| `40 - Identity / SSO` | Authentik server/worker, login failures, provider failures and SSO health |
| `50 - Observability Self-Monitoring` | Grafana, VictoriaMetrics, VMAgent, Loki, Alloy and Alertmanager health |
| `60 - Security & Audit` | access elevation, sudo, SSH, UFW, AIDE/FIM and RBAC events |
| `90 - Application Template` | reusable dashboard for n8n and future workloads |

The existing beginner dashboards are a temporary baseline. The target implementation should replace the default experience with the operational dashboard set above.

## Logging policy

Loki labels must support structured navigation by project, environment, host, namespace, application, severity and lifecycle stage.

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

Security logs add:

```text
category="security"
event_type
```

High-cardinality values such as request IDs, user IDs, IP addresses and full commands must remain in the log body, not in labels.

## Alerting policy

Alerts must be actionable and categorized by:

```text
host
cluster
platform
identity
observability
security
application
```

Every alert should include:

- severity;
- category;
- project/environment labels;
- lifecycle stage;
- impact annotation;
- first action annotation;
- runbook link.

## Security & Audit Monitoring

Security visibility is a first-class CH05 responsibility.

Primary target source:

```text
/srv/platforminit/audit/security.log
```

Target visibility:

- access elevation grants and failures;
- active or expired temporary grants;
- sudo activity;
- SSH failures and root login attempts;
- UFW state and drift;
- AIDE/FIM status;
- Authentik provider and login failures;
- Argo CD and Grafana RBAC failures;
- missing security telemetry.

This is operational security monitoring, not a full SIEM.

## Deployment

Current deployment:

```text
00 - Build Platform Artifacts
05 - Deploy Observability Stack
```

For normal updates after Grafana SSO has been enabled, prefer:

```text
deploy_mode: reconcile
```

If CH05 is run in `baseline` mode after SSO was enabled, rerun the Grafana SSO workflow if the SSO button disappears.

## Target workflow split

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Observability Stack` | base stack |
| `05.1 - Provision Dashboards` | operational dashboard set |
| `05.2 - Provision Alerting` | alert rules, routing and inhibition |
| `05.3 - Provision Security & Audit Monitoring` | audit log ingestion, security dashboards and security alerts |
| `05.4 - Onboard External Host` | n8n and future host telemetry onboarding |
| `05.5 - Enable Grafana SSO` | Authentik Grafana OAuth integration |

`05.5 - Enable Grafana SSO` is the active Grafana SSO workflow. `05.2`, `05.3` and `05.4` are still planned.

## Validation contract

CH05 must validate that Grafana is reachable and VictoriaMetrics contains useful data:

```text
VM_QUERY_UP
VM_QUERY_NODE
VM_QUERY_KSM
```

The redesigned validator should also report:

- platform overview dashboard present;
- host dashboard present;
- Kubernetes dashboard present;
- Argo CD dashboard present;
- identity dashboard present;
- observability self-monitoring dashboard present;
- security & audit dashboard present;
- Loki label contract sanity;
- Alertmanager reachable;
- security audit source present or explicitly reported UNKNOWN.

## Argo CD inventory registration

CH05 deploys the observability stack with Helm from the GitHub Actions workflow. After deployment, `scripts/ch05-register-argocd-apps.sh` registers a non-destructive Argo CD `Application` named `ch05-observability` so the layer is visible in the Argo CD UI.

The registered Application tracks only the Kubernetes manifests under `platform/observability/manifests`. Helm-owned releases such as `observability-vmstack`, `loki`, and `alloy` remain workflow-owned until a separate GitOps migration intentionally moves those releases under Argo CD ownership.

## Documentation

- `../../docs/ch05-operational-observability-design.md`
- `dashboards/README.md`
- `logging/README.md`
- `alerts/README.md`
- `security/README.md`
- `external-hosts/README.md`
- `workflows/README.md`
- `docs/ch05-beginner-dashboard-guide.md`
- `docs/ch05-k3s-monitoring-runbook.md`
- `docs/ch05-ch05-5-sso-interaction.md`
