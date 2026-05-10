# CH05 Observability

CH05 provides the observability foundation for the single-node k3s PlatformInit environment.

## Scope

- Metrics via VictoriaMetrics stack
- Logs via Loki and Alloy
- Alerting via VMAlert and Alertmanager
- Grafana datasource provisioning
- Beginner-friendly PlatformInit dashboards
- Kubernetes and node baseline telemetry

## Public UI policy

Grafana is the only public CH05 WebUI:

```text
https://grafana.<PLATFORM_BASE_DOMAIN>
```

VictoriaMetrics, Loki and Alloy are internal services. They should be accessed through Grafana or temporary `kubectl port-forward` during debugging.

## Dashboard policy

PlatformInit intentionally disables/prunes noisy upstream dashboards from the VictoriaMetrics Kubernetes stack and provisions the following operational dashboards:

| Dashboard | Purpose |
|---|---|
| `PlatformInit / 00 - Start Here` | first health view after deploy/recreate |
| `PlatformInit / Cluster Overview` | cluster, pod, namespace and restart overview |
| `PlatformInit / Node Overview` | host CPU, RAM, disk, filesystem and network |
| `PlatformInit / Logs Overview` | Loki logs through Grafana |

This keeps the default experience beginner-friendly and avoids kubeadm/control-plane dashboards that are noisy on single-node k3s.

## Deployment

Use:

```text
00 - Build Platform Artifacts
05 - Deploy Observability Stack
```

For normal updates after CH06.1 Grafana SSO has been enabled, prefer:

```text
deploy_mode: reconcile
```

If CH05 is run in `baseline` mode after SSO was enabled, rerun:

```text
06.1 - Enable Grafana SSO
```

## Validation contract

CH05 must validate that Grafana is reachable **and** VictoriaMetrics contains useful data:

```text
VM_QUERY_UP
VM_QUERY_NODE
VM_QUERY_KSM
```

The validation also checks that the PlatformInit beginner dashboards are present and that non-PlatformInit dashboard ConfigMaps have been pruned.

## Documentation

- `docs/ch05-beginner-dashboard-guide.md`
- `docs/ch05-k3s-monitoring-runbook.md`
- `docs/ch05-ch06-sso-interaction.md`

## Grafana datasource policy

VictoriaMetrics remains the single default Grafana datasource. Loki is provisioned as a non-default datasource to avoid Grafana startup failures caused by multiple defaults in the same organization.
