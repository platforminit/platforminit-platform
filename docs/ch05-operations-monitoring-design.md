# CH05 Operations Monitoring Design

CH05 is no longer a Grafana-first observability stack. It is an operator-first operations layer for a small, single-node platform.

## Decision

PlatformInit defaults to:

```text
Zabbix                 -> operational state and alerts
Vector                 -> low-footprint log collection
OpenObserve Enterprise -> searchable logs and RCA
Authentik              -> native app SSO for public WebUIs
Argo CD                -> runtime resource ownership
```

## Post-CH04 ownership rule

Once CH04 has installed Argo CD, application workloads must not be deployed through long-running SSH workflows. CH05 follows this boundary:

```text
GitHub Actions:
- register Argo CD Application / AppProject
- create or preserve prerequisite secrets
- reconcile Authentik providers/applications through API
- request Argo CD refresh/sync and validate

Argo CD:
- namespace
- deployments / daemonsets
- services
- ingress
- PVCs
- configmaps
```

This avoids timeout-prone `kubectl apply && rollout wait` scripts, reduces A1 sudo exposure and keeps runtime drift visible in Argo CD.

## Workflow split

| Workflow | Responsibility |
|---|---|
| `05 - Register Operations Stack` | apply Operations AppProject and Argo CD Application |
| `05.1 - Reconcile Operations Prerequisites` | create/preserve secrets used by Zabbix/OpenObserve/Vector |
| `05.2 - Sync Operations Stack` | wait for Argo CD to make the stack Synced/Healthy |
| `05.3 - Enable Operations Native SSO` | reconcile Authentik SAML/OIDC and app-level SSO settings; no rollout wait |
| `05.4 - Validate Operations Stack` | runtime and ownership validation |

## WebUI rule

Zabbix and OpenObserve must not rely on proxy-only forward-auth as their final authentication model. The desired behavior is native application login through Authentik:

- Zabbix uses Authentik as a SAML IdP.
- OpenObserve uses Enterprise SSO/OIDC with Authentik.
- Vector has no WebUI.

## OpenObserve Enterprise contract

```text
image: public.ecr.aws/zinclabs/openobserve-enterprise:v0.80.3
public URL: https://logs.<PLATFORM_BASE_DOMAIN>
redirect URL: https://logs.<PLATFORM_BASE_DOMAIN>/config/redirect
callback URL: https://logs.<PLATFORM_BASE_DOMAIN>/web/cb
issuer/base URL: https://auth.<PLATFORM_BASE_DOMAIN>/application/o/platforminit-openobserve/
```

The runtime deployment is GitOps-owned. SSO secret reconciliation must not restart or wait on the OpenObserve deployment.

## Zabbix SAML contract

```text
public URL: https://zabbix.<PLATFORM_BASE_DOMAIN>
ACS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?acs
SLS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?sls
SP entity ID: https://zabbix.<PLATFORM_BASE_DOMAIN>
username attribute: username
```

`05.3` reconciles the Authentik SAML provider/application, writes the Authentik IdP certificate to the `zabbix-saml-certs` secret, configures Zabbix through its API, and bootstraps the Authentik `akadmin` user as a Zabbix SAML admin. The local Zabbix admin remains the break-glass account.

## A1 access elevation contract

```text
mode: observability
allowed sudo entrypoint: /tmp/platforminit-run/ch05-remote.sh *
```

CH05 workflows must not use generic `sudo -l` validation or ad-hoc runner names.

## TLS contract

Browser-facing operations UIs use production certificates by default. Staging issuer mode is only for ACME/debug testing and intentionally produces an untrusted certificate warning.

## CH05 Argo CD sync guardrail

The `operations-stack` Application is registered without automated sync. This is intentional: Zabbix, OpenObserve and Vector depend on non-Git prerequisite secrets created by `05.1 - Reconcile Operations Prerequisites`. The safe lifecycle is:

```text
05   Register Operations Stack    -> creates Argo CD Application only
05.1 Reconcile Operations Prerequisites -> creates required runtime secrets
05.2 Sync Operations Stack        -> explicitly starts Argo CD sync and waits for health
```

If Vector shows `secret "openobserve-root" not found`, run `05.1` and then rerun `05.2`. Do not enable automated sync before prerequisite reconciliation.


## Vector Kubernetes log collection contract

Vector runs as a DaemonSet and uses the `kubernetes_logs` source. The pod must expose `VECTOR_SELF_NODE_NAME` from `spec.nodeName` so Vector can bind itself to the local node. Missing this environment variable causes a collector startup failure and leaves the `operations-stack` Argo CD Application in `Progressing` health even when all manifests are synced.
