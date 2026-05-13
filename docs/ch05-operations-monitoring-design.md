# CH05 Operations Monitoring Design

CH05 is no longer a Grafana-first observability stack. It is an operator-first operations layer for a small, single-node platform.

## Decision

PlatformInit defaults to:

```text
Zabbix      -> operational state and alerts
Vector      -> low-footprint log collection
OpenObserve -> searchable logs and RCA
Authentik   -> mandatory login for public WebUIs
```

## Why the previous model was removed

The previous Grafana/VictoriaMetrics/Loki/Alloy model solved telemetry collection but did not solve the operator workflow:

```text
what failed?
where did it fail?
why did it fail?
what should I inspect next?
```

It also introduced too many moving parts for the default single-node PlatformInit use case.

## Workflow split

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Zabbix Monitoring` | state-first monitoring |
| `05.1 - Deploy OpenObserve` | searchable RCA logs |
| `05.2 - Deploy Vector Logging` | log collection |
| `05.3 - Onboard External Host` | future n8n/customer host agent onboarding |
| `05.4 - Enable Operations SSO` | Authentik-gated public WebUIs |

## WebUI rule

Zabbix and OpenObserve must not be exposed publicly without Authentik.

The base deploy creates internal services only. `05.4` creates the public ingresses and attaches the Authentik forward-auth middleware.


## Authentik operations SSO contract

`05.4 - Enable Operations SSO` uses the existing `authentik-server` service from CH04.5 as the embedded outpost endpoint:

```text
http://authentik-server.identity.svc.cluster.local/outpost.goauthentik.io/auth/traefik
```

The default PlatformInit identity deployment does not require a separate `ak-outpost-*` service. `05.4` reconciles Authentik proxy providers/applications for Zabbix and OpenObserve, then creates the Traefik middleware and public ingresses. The proxy provider payload must include both `authorization_flow` and `invalidation_flow` because current Authentik provider APIs require both fields for proxy providers.

## Storage rule

k3s data must be stored under `/srv/data/k3s`. This prevents accidental growth under the wrong partition and makes PVC-backed storage easier to audit.

## A1 access elevation contract

All CH05 operations workflows must use the existing scoped sudo contract from A1 Access Elevation.

Required contract:

```text
mode: observability
allowed sudo entrypoint: /tmp/platforminit-run/ch05-remote.sh *
```

Workflow rules:

- do not call `sudo -n -l` as a validation step; scoped NOPASSWD rules may still require a password for generic sudo listing
- do not execute `/tmp/platforminit-run/ch05-runner.sh` or any other ad-hoc sudo entrypoint
- every CH05 workflow must upload the generated privileged runner as `/tmp/platforminit-run/ch05-remote.sh`
- the final privileged call must be `sudo -n /tmp/platforminit-run/ch05-remote.sh ...`

This preserves the non-interactive, temporary and audit-friendly A1 model while avoiding standing sudo for the `devops` user.

