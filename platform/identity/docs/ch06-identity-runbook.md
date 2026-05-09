# CH06 Identity Runbook

## Objective

Deploy an Authentik-backed identity layer and prepare the platform for SSO-based access to Grafana and Argo CD.

## Deployment workflow

Use workflow:

```text
06 - Deploy Identity Stack
```

Recommended inputs for first test:

| Input | Value |
|---|---|
| `project` | `development` |
| `host_name` | `platforminit-dev-01` |
| `deploy_mode` | `baseline` |
| `issuer_mode` | `staging` |
| `authentik_chart_version` | `2026.2.2` |

## Required secrets

```text
AUTHENTIK_SECRET_KEY
AUTHENTIK_POSTGRESQL_PASSWORD
AUTHENTIK_BOOTSTRAP_PASSWORD
```

Generate safe values locally:

```bash
openssl rand -base64 60 | tr -d '\n'; echo
```

Use a password manager for `AUTHENTIK_BOOTSTRAP_PASSWORD`.

## Validation commands

```bash
kubectl -n identity get pods -o wide
kubectl -n identity get ingress,certificate,secrets
kubectl -n identity rollout status deploy/authentik-server
kubectl -n identity rollout status deploy/authentik-worker
```

Expected public endpoint:

```text
https://auth.<PLATFORM_BASE_DOMAIN>/
```

Expected admin user:

```text
akadmin
```

Expected password source:

```text
AUTHENTIK_BOOTSTRAP_PASSWORD
```

## Break-glass rule

Do not remove local admin login from Grafana or Argo CD during CH06. SSO is introduced as the normal login path, while local admin remains a recovery path.
