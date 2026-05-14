# Secrets reference

## Current supported secrets

- `AUTOMATION_SSH_PRIVATE_KEY`
- `AUTOMATION_SSH_PUBLIC_KEY`
- `HCLOUD_TOKEN_DEVELOPMENT`
- `HCLOUD_TOKEN_N8N`
- `HCLOUD_TOKEN_PLATFORMINIT`
- `INFRA_SERVER_ID`
- `HOST_LOGIN_USER`
- `DNS_API_TOKEN`
- `PLATFORM_BASE_DOMAIN`
- `TLS_CONTACT_EMAIL`
- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_POSTGRESQL_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_EMAIL` (optional)
- `AUTHENTIK_BOOTSTRAP_TOKEN` (optional)
- `OPENOBSERVE_ROOT_USER_EMAIL` (optional)
- `OPENOBSERVE_ROOT_USER_PASSWORD` (optional)

## Secret model rules

- Do not introduce parallel secrets when an existing secret already covers the use case.
- `AUTOMATION_SSH_PUBLIC_KEY` is used for both `devops` and `itadmin` during bootstrap.
- `HOST_LOGIN_USER` is expected to be `root` before `01.1 - Host Bootstrap`, and `devops` afterwards.
- No `ADMIN_SSH_PUBLIC_KEY` is used in this model.

## Host resolution model

`INFRA_SERVER_ID` is now a legacy fallback. Preferred selection is:

1. `server_id_override` input for break-glass/debug
2. `project` + `host_name` workflow inputs, resolved via Hetzner labels
3. `INFRA_SERVER_ID` fallback for the original single-host setup

Do not create one secret per host unless there is a specific break-glass reason. Prefer Hetzner labels and the shared resolver action.


## CH04.5 identity / SSO secrets

- `AUTHENTIK_SECRET_KEY`: Authentik cryptographic secret key. Generate once and never rotate without a planned Authentik migration.
- `AUTHENTIK_POSTGRESQL_PASSWORD`: Password for the embedded development PostgreSQL database used by the CH04.5 identity baseline.
- `AUTHENTIK_BOOTSTRAP_PASSWORD`: Initial `akadmin` password. Used only during first bootstrap if Authentik has not already been initialized.
- `AUTHENTIK_BOOTSTRAP_EMAIL`: Optional bootstrap email; defaults to `admin@PLATFORM_BASE_DOMAIN` when empty.
- `AUTHENTIK_BOOTSTRAP_TOKEN`: Optional API bootstrap token; preserved from the existing cluster secret when empty, otherwise generated once during first deployment.

Do not commit any generated Authentik secret values. Store them as GitHub repository or environment secrets.


## CH05 operations secrets

- `OPENOBSERVE_ROOT_USER_EMAIL`: Optional root email for first OpenObserve bootstrap. Defaults to `admin@<PLATFORM_BASE_DOMAIN>` when empty.
- `OPENOBSERVE_ROOT_USER_PASSWORD`: Optional root password for first OpenObserve bootstrap. If empty and no existing Kubernetes secret is present, the workflow generates one inside the cluster and stores it in `operations/openobserve-root`.

Do not add Grafana secrets to the default lifecycle. Grafana is not a CH05 default component.


## CH05 Operations SSO optional secrets

| Secret | Purpose | Required |
|---|---|---|
| `OPENOBSERVE_OIDC_CLIENT_SECRET` | Stable Authentik OAuth2 client secret for OpenObserve Enterprise SSO. If omitted, `05.4` generates and stores one in Kubernetes. | no |
| `ZABBIX_ADMIN_USER` | Zabbix break-glass admin username used by `05.4` to configure SAML through the Zabbix API. Defaults to `Admin`. | no |
| `ZABBIX_ADMIN_PASSWORD` | Zabbix break-glass admin password used by `05.4` to configure SAML through the Zabbix API. Defaults to `zabbix`. | no |
