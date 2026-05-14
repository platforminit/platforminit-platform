# Zabbix Monitoring

Zabbix is the primary PlatformInit operational monitoring UI.

## Public access

`05.2 - Sync Operations Stack` exposes `https://zabbix.<PLATFORM_BASE_DOMAIN>` through the Argo CD-owned ingress. `05.3 - Enable Operations Native SSO` configures native SAML login through Authentik and the Zabbix API before requesting any runtime restart, avoiding port-forward loss against terminating pods. It does not wait for rollout; readiness remains owned by `05.2`/`05.4`.

```text
ACS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?acs
SLS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?sls
SP entity ID: https://zabbix.<PLATFORM_BASE_DOMAIN>
Username attribute: username
```

The local Zabbix admin remains the break-glass account.

## CH05.5 - Zabbix Operations Model

PlatformInit does not treat a plain Zabbix installation as operator-ready. The `05.5 - Provision Zabbix Operations Model` workflow is the first opinionated Zabbix provisioning layer.

Current scope is intentionally narrow:

- expose `zabbix-agent2` through a stable Kubernetes Service;
- stop using `127.0.0.1:10050` as the monitored host interface;
- reconcile the primary host as `platforminit-dev-01`;
- point the Zabbix agent interface to `zabbix-agent2.operations.svc.cluster.local:10050`;
- create PlatformInit host groups and tags used later by dashboards/services.

This is the foundation for the Nagios-like operator view. It should make the default `Linux: Zabbix agent is not available` problem disappear after the next polling interval.

Target operator language:

```text
HOST: platforminit-dev-01
SERVICE: Kubernetes runtime storage
STATE: OK / WARNING / CRITICAL
DETAIL: /srv/data/k3s usage and availability

HOST: platforminit-dev-01
SERVICE: Observability storage
STATE: OK / WARNING / CRITICAL
DETAIL: /srv/observability/data usage and availability
```

Do not add more dashboards before the host/agent endpoint and baseline problems are correct.

