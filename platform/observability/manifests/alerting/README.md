# CH05.2 Alerting Manifests

Alerting is primarily defined by:

```text
platform/observability/manifests/alerts/platform-vmrule.yaml
```

The VictoriaMetrics stack provides VMAlert and Alertmanager. CH05.2 applies the PlatformInit VMRule set and validates that VMAlert and Alertmanager are present.

Current scope:

- host alerts from Node Exporter
- cluster alerts from kube-state-metrics
- Argo CD / GitOps drift alerts
- Authentik availability alerts
- observability self-monitoring alerts

Routing is intentionally conservative in this stage. External notification routing should be added only after the alert set is proven to be low-noise.
