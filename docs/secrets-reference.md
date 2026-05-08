# Secrets reference

## Hetzner project routing

The legacy single-token model is deprecated:

```text
INFRA_API_TOKEN
```

Use project-scoped Hetzner tokens instead:

```text
HCLOUD_TOKEN_DEVELOPMENT
HCLOUD_TOKEN_N8N
HCLOUD_TOKEN_PLATFORMINIT
```

The workflow input `project` is now a real routing key:

| Project input | Hetzner token secret | Registry file |
|---|---|---|
| `development` | `HCLOUD_TOKEN_DEVELOPMENT` | `platform/projects/development.yaml` |
| `n8n` | `HCLOUD_TOKEN_N8N` | `platform/projects/n8n.yaml` |
| `platforminit` | `HCLOUD_TOKEN_PLATFORMINIT` | `platform/projects/platforminit.yaml` |

## SSH automation key

These remain shared GitHub secrets:

```text
AUTOMATION_SSH_PUBLIC_KEY
AUTOMATION_SSH_PRIVATE_KEY
```

Hetzner SSH key objects are project-scoped. The host lifecycle workflow checks the selected Hetzner project and creates/reuses the configured key name from `platform/projects/<project>.yaml`.

## Local secret bootstrap

Local files are never committed:

```text
.local_secrets/
├── development_api_key
├── n8n_api_key
└── platforminit_api_key
```

Each file contains only the raw Hetzner API token.

Upload repo-scoped secrets:

```bash
bash scripts/bootstrap-org-secrets.sh
```

Upload org-scoped selected-repo secrets when the account has org admin permissions:

```bash
SCOPE=org bash scripts/bootstrap-org-secrets.sh
```
