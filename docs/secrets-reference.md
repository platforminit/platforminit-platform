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
