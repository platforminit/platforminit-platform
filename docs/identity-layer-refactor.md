# Identity Layer Refactor

Identity is an early platform lifecycle layer.

## Current model

| Workflow | Purpose |
|---|---|
| `04.5 - Deploy Identity Foundation` | Deploy Authentik and bootstrap PlatformInit identity groups |
| `04.6 - Enable Argo CD SSO` | Configure Argo CD OIDC login through Authentik |
| `05.4 - Enable Operations SSO` | Protect CH05 Zabbix/OpenObserve WebUIs through Authentik forward-auth |

## Deprecated model

The old Grafana SSO path was removed from the active lifecycle when CH05 moved to Zabbix + Vector + OpenObserve.

Do not add new Grafana SSO workflows to the default PlatformInit lifecycle.
