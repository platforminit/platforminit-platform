# CH05 Observability

Observability foundation layer for the platform.

## Scope
- Metrics via VictoriaMetrics stack
- Logs via Loki + Alloy
- Alerting via VMAlert + Alertmanager
- Grafana datasource provisioning
- Kubernetes and node baseline telemetry

## Deployment
Use:
- `00 - Build Platform Artifacts`
- `05 - Deploy Observability Stack`


## Grafana datasource policy

VictoriaMetrics remains the single default Grafana datasource. Loki is provisioned as a non-default datasource to avoid Grafana startup failures caused by multiple defaults in the same organization.
