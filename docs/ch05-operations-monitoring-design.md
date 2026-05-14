# CH05 Operations Monitoring Design

CH05 is no longer a Grafana-first observability stack. It is an operator-first operations layer for a small, single-node platform.

## Decision

PlatformInit defaults to:

```text
Zabbix                 -> operational state and alerts
Vector                 -> low-footprint log collection
OpenObserve Enterprise -> searchable logs and RCA
Authentik              -> native app SSO for public WebUIs
```

## Workflow split

| Workflow | Responsibility |
|---|---|
| `05 - Deploy Zabbix Monitoring` | state-first monitoring |
| `05.1 - Deploy OpenObserve` | OpenObserve Enterprise log/RCA backend |
| `05.2 - Deploy Vector Logging` | log collection |
| `05.3 - Onboard External Host` | future n8n/customer host agent onboarding |
| `05.4 - Enable Operations Native SSO` | native Authentik SSO for Zabbix and OpenObserve |

## WebUI rule

Zabbix and OpenObserve must not rely on proxy-only forward-auth as their final authentication model. The desired behavior is native application login through Authentik:

- Zabbix uses Authentik as a SAML IdP.
- OpenObserve uses Enterprise SSO/OIDC with Authentik.
- Vector has no WebUI.

The base deploy creates internal services only. `05.4` creates public ingresses and reconciles native SSO objects.

## OpenObserve Enterprise contract

OpenObserve Enterprise is used because SSO/RBAC are Enterprise features. The Enterprise tier is available free under the documented ingestion allowance, but it is not the same license model as the OSS image.

```text
image: public.ecr.aws/zinclabs/openobserve-enterprise:v0.80.3
public URL: https://logs.<PLATFORM_BASE_DOMAIN>
redirect URL: https://logs.<PLATFORM_BASE_DOMAIN>/config/redirect
callback URL: https://logs.<PLATFORM_BASE_DOMAIN>/web/cb
issuer/base URL: https://auth.<PLATFORM_BASE_DOMAIN>/application/o/platforminit-openobserve/
```

## Zabbix SAML contract

```text
public URL: https://zabbix.<PLATFORM_BASE_DOMAIN>
ACS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?acs
SLS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?sls
SP entity ID: https://zabbix.<PLATFORM_BASE_DOMAIN>
username attribute: username
```

`05.4` reconciles the Authentik SAML provider/application, mounts the Authentik IdP certificate into Zabbix Web, configures Zabbix through its API, and bootstraps the Authentik `akadmin` user as a Zabbix SAML admin. The local Zabbix admin remains the break-glass account.

## A1 access elevation contract

```text
mode: observability
allowed sudo entrypoint: /tmp/platforminit-run/ch05-remote.sh *
```

CH05 workflows must not use generic `sudo -l` validation or ad-hoc runner names.

## TLS contract

Use `issuer_mode=prod` for browser-facing operations UIs. Staging issuer mode is only for ACME/debug testing and intentionally produces an untrusted certificate warning.
