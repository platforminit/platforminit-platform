# Secrets reference

## Current supported secrets

- `AUTOMATION_SSH_PRIVATE_KEY`
- `AUTOMATION_SSH_PUBLIC_KEY`
- `INFRA_API_TOKEN`
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
