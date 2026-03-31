# CH05 – Observability foundation

This chapter introduces the first deployable observability baseline for the platform.

## Scope

- Grafana for dashboards and visualization
- VictoriaMetrics K8s Stack for metrics, `vmagent`, `vmalert`, `Alertmanager`, `kube-state-metrics`, and `node-exporter`
- Loki for log storage
- Grafana Alloy for Kubernetes log collection and forwarding to Loki
- Grafana datasource provisioning for VictoriaMetrics and Loki
- Baseline `VMRule` alerts and `VMServiceScrape` objects for platform signals

## Resource model

The baseline is sized for a single-node homelab cluster with conservative requests and limits:

- Grafana: `100m / 500m`, `256Mi / 512Mi`
- VictoriaMetrics: `500m / 1500m`, `1Gi / 2Gi`
- vmagent: `200m / 500m`, `256Mi / 512Mi`
- vmalert: `100m / 300m`, `128Mi / 256Mi`
- Alertmanager: `100m / 300m`, `128Mi / 256Mi`
- Loki: `300m / 1000m`, `512Mi / 2Gi`
- Alloy: `100m / 500m`, `128Mi / 512Mi`
- kube-state-metrics: `100m / 200m`, `128Mi / 256Mi`
- node-exporter: `50m / 100m`, `64Mi / 128Mi`

## Deployment model

This chapter follows the existing artifact-based deployment pattern:

1. `00 - Build Platform Artifacts` packages `platform/observability`
2. `05 - Deploy Observability Stack` downloads the selected artifact
3. The workflow stages the chapter under `/srv/platforminit/observability/<sha>`
4. Helm installs or upgrades the baseline releases in the `observability` namespace
5. Kubernetes manifests provision datasources, service scrapes, and alert rules
6. Validation confirms baseline readiness

## Helm releases

- `vmstack` → `victoria-metrics-k8s-stack`
- `loki` → `loki`
- `alloy` → `alloy`

## Files

- `values/victoria-metrics-k8s-stack-values.yaml`
- `values/loki-values.yaml`
- `values/alloy-values.yaml`
- `manifests/grafana/grafana-datasources.yaml.tpl`
- `manifests/alerts/platform-vmrule.yaml`
- `manifests/metrics/*.yaml`
- `scripts/ch05-orchestrator.sh`
- `validate/ch05-validate-observability.sh`
