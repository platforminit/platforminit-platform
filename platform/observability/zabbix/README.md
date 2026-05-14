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

## PlatformInit Operations Model

`05.5 - Provision Zabbix Operations Model` is the opinionated Zabbix bootstrap for the Nagios-like operator view.

Current model decision:

```text
zabbix-agent2 active -> zabbix-server
```

Reason:

- the previous passive model depended on `zabbix-server -> zabbix-agent2` connectivity through Kubernetes networking;
- source IP and allow-list behaviour made passive checks noisy and fragile;
- active checks let the host-network DaemonSet initiate traffic to `zabbix-server.operations.svc.cluster.local:10051`;
- the Zabbix host keeps an agent interface for inventory/debug, but the PlatformInit service state is based on active agent items.

The agent DaemonSet contract is:

```text
ZBX_ACTIVE_ALLOW=true
ZBX_ACTIVESERVERS=zabbix-server.operations.svc.cluster.local:10051
ZBX_PASSIVE_ALLOW=false
ZBX_HOSTNAME=<nodeName>
```

Do not set `ZBX_SERVER_HOST` in this active-agent-only DaemonSet. The PlatformInit agent uses `ZBX_ACTIVESERVERS` as the single active-server source of truth and does not expose `hostPort: 10050`.

Do not use `zabbix_get` as the CH05.5 release gate. Passive checks are intentionally disabled for this model.

## PlatformInit host groups

`05.5` creates/keeps these groups:

```text
PlatformInit / Hosts
PlatformInit / Kubernetes
PlatformInit / Applications
PlatformInit / Security
PlatformInit / Storage
PlatformInit / Operations
```

## First active checks

The first CH05.5 active model provisions explicit, human-readable items instead of linking the noisy default Linux passive template.

Examples:

```text
Host availability
SSH availability
Kubernetes API availability
Zabbix server trapper availability
OpenObserve service availability
Argo CD WebUI service availability
Authentik WebUI service availability
Root filesystem usage (/)
Kubernetes runtime storage usage (/srv/data/k3s)
Kubernetes PVC storage usage (/srv/data/k3s/storage)
Observability storage usage (/srv/observability/data)
Platform runtime artifacts usage (/srv/platforminit)
Memory available percentage
CPU load average 1m
System uptime
```

## Storage naming contract

Use these names in Zabbix item and trigger labels:

```text
Kubernetes runtime storage -> /srv/data/k3s
Kubernetes PVC storage     -> /srv/data/k3s/storage
Observability storage      -> /srv/observability/data
Platform runtime artifacts -> /srv/platforminit
```

The agent mounts these host paths read-only where needed, so Zabbix checks the intended host storage paths rather than only the container filesystem.

## Trigger naming contract

Trigger names must be operator-readable.

Bad:

```text
vfs.fs.size[/srv/observability/data,pused] > 80
```

Good:

```text
Observability storage usage high
DETAIL: /srv/observability/data is above 80%
```

## Dashboard status

`PlatformInit - Operations Overview` is intentionally not created as a full dashboard until the active host data baseline is stable. The first release gate is reliable active data for host, service and storage checks.
