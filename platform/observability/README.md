# CH05 - Operations Monitoring

CH05 is the PlatformInit operations layer. It uses an operator-first model instead of the previous Grafana/VictoriaMetrics/Loki/Alloy stack.

## Default architecture

```text
Zabbix                 -> what is broken?
Vector                 -> collect platform, Kubernetes and host logs
OpenObserve Enterprise -> why did it break? searchable RCA logs
Authentik              -> native application SSO
Argo CD                -> owner of runtime Kubernetes resources
```

## GitOps ownership boundary

CH05 is a post-CH04 platform workload. Runtime resources must be Argo CD-owned:

```text
Argo CD owns:
- Namespace
- Deployments / DaemonSets
- Services
- Ingresses
- PVCs
- ConfigMaps

GitHub Actions owns only:
- prerequisite secrets
- Authentik provider/application reconciliation
- Argo CD Application registration
- sync request / validation
```

## Public WebUIs

| URL | Purpose | Auth model |
|---|---|---|
| `https://zabbix.<PLATFORM_BASE_DOMAIN>` | operational alert/state console | native Authentik SAML |
| `https://logs.<PLATFORM_BASE_DOMAIN>` | log search and RCA | OpenObserve Enterprise OIDC via Authentik |

Vector has no public WebUI.

## Workflow order

| Order | Workflow | Purpose |
|---:|---|---|
| 15 | `05 - Register Operations Stack` | create/update Argo CD AppProject + Application |
| 16 | `05.1 - Reconcile Operations Prerequisites` | create/preserve DB/root/SSO prerequisite secrets |
| 17 | `05.2 - Sync Operations Stack` | let Argo CD reconcile Zabbix, OpenObserve and Vector |
| 18 | `05.3 - Enable Operations Native SSO` | reconcile Authentik SAML/OIDC bindings and app-level SSO settings; no rollout wait |
| 19 | `05.4 - Validate Operations Stack` | validate Argo CD ownership, runtime health, ingress and SSO prerequisites |

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

## CH05 Argo CD sync guardrail

The `operations-stack` Application is registered without automated sync. This is intentional: Zabbix, OpenObserve and Vector depend on non-Git prerequisite secrets created by `05.1 - Reconcile Operations Prerequisites`. The safe lifecycle is:

```text
05   Register Operations Stack    -> creates Argo CD Application only
05.1 Reconcile Operations Prerequisites -> creates required runtime secrets
05.2 Sync Operations Stack        -> explicitly starts Argo CD sync and waits for health
```

If Vector shows `secret "openobserve-root" not found`, run `05.1` and then rerun `05.2`. Do not enable automated sync before prerequisite reconciliation.

