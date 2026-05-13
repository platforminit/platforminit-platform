# CH05 Operations Monitoring

Default stack:
- Zabbix -> monitoring + alerts
- Vector -> log collection
- OpenObserve -> searchable logs / RCA
- Authentik -> SSO

## Public UIs
- https://zabbix.<PLATFORM_BASE_DOMAIN>
- https://logs.<PLATFORM_BASE_DOMAIN>
- https://auth.<PLATFORM_BASE_DOMAIN>

## Deprecated
Grafana, VictoriaMetrics, Loki, Alloy, Alertmanager are deprecated as default PlatformInit components.
