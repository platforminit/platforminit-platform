# CH05 - Operations Monitoring

CH05 is the PlatformInit operations layer. It intentionally replaces the previous Grafana/VictoriaMetrics/Loki/Alloy default stack with a smaller operator-first model.

## Default architecture

```text
Zabbix      -> what is broken?
Vector      -> collect platform, Kubernetes and host logs
OpenObserve -> why did it break? searchable RCA logs
Authentik   -> mandatory login gate for public operational WebUIs
```

## Public WebUIs

Public WebUIs are exposed only after `05.4 - Enable Operations SSO` applies the Authentik forward-auth middleware.

| URL | Purpose | Auth model |
|---|---|---|
| `https://zabbix.<PLATFORM_BASE_DOMAIN>` | operational alert/state console | Authentik forward-auth |
| `https://logs.<PLATFORM_BASE_DOMAIN>` | log search and RCA | Authentik forward-auth |

Vector has no public WebUI.

## Workflow order

| Order | Workflow | Purpose |
|---:|---|---|
| 15 | `05 - Deploy Zabbix Monitoring` | deploy Zabbix DB, server, web UI service and agent baseline |
| 16 | `05.1 - Deploy OpenObserve` | deploy searchable logs backend |
| 17 | `05.2 - Deploy Vector Logging` | deploy Vector DaemonSet and log shipping config |
| 18 | `05.3 - Onboard External Host` | reserve onboarding contract for n8n/future hosts |
| 19 | `05.4 - Enable Operations SSO` | expose Zabbix/OpenObserve through Authentik-gated ingresses |

## Removed default components

The following components are not PlatformInit defaults anymore:

- Grafana
- VictoriaMetrics
- VMAgent
- VMAlert
- Alertmanager
- Loki
- Alloy
- provisioned Grafana dashboards

They may return later as optional advanced modules, but they must not be part of the default CH05 lifecycle.

## Storage contract

CH05 must avoid uncontrolled growth under the Kubernetes data directory. Persistent application data is stored through k3s PVCs, and the k3s data directory itself must be under `/srv/data/k3s`.

Expected host layout:

```text
/srv/data/k3s        -> k3s data-dir and local-path PVC backing storage
/srv/db              -> reserved DB volume mount
/srv/observability   -> release artifacts, validation logs, operational reports
```

## Documentation

- `docs/ch05-operations-monitoring-design.md`
- `docs/ch05-migration-from-grafana-stack.md`
- `platform/observability/zabbix/README.md`
- `platform/observability/vector/README.md`
- `platform/observability/openobserve/README.md`
- `platform/observability/sso/README.md`
- `platform/observability/rules/platforminit-operations-rules.md`
