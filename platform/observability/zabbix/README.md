# Zabbix Monitoring

Zabbix is the primary PlatformInit operational monitoring UI.

Its job is to answer:

```text
What is broken?
Where is it broken?
How severe is it?
Since when?
```

## Role

- host/service state monitoring
- Nagios-like problem list
- severity-driven alerts
- storage, CPU, memory and service checks
- future external host onboarding

## Public access

Zabbix is not exposed directly by the base deploy. `05.4 - Enable Operations SSO` creates `https://zabbix.<PLATFORM_BASE_DOMAIN>` and protects it with Authentik forward-auth.

## Storage

Zabbix PostgreSQL uses a PVC. On the PlatformInit k3s contract, the backing local-path storage must live under `/srv/data/k3s`.
