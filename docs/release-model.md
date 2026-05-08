# PlatformInit release model

PlatformInit uses two output types deliberately:

- **GitHub Actions artifacts**: temporary run evidence such as smoke logs, validation reports, lifecycle summaries, and debug bundles.
- **GitHub Releases**: immutable deployable packages tied to a Git tag and checksum.

## Release groups

| Release tag | Scope | Main asset |
|---|---|---|
| `ch01-vX.Y.Z` | host lifecycle, bootstrap, host baseline, drift/security/FIM/AIDE tooling | `ch01-vX.Y.Z.tar.gz` |
| `ch02-vX.Y.Z` | k3s install, kubeconfig, cluster smoke tooling | `ch02-vX.Y.Z.tar.gz` |
| `ch03-vX.Y.Z` | platform services: ingress, cert-manager, Cloudflare DNS-01, Argo CD TLS | `ch03-vX.Y.Z.tar.gz` |
| `ch04-vX.Y.Z` | GitOps runtime / Argo CD app skeletons | `ch04-vX.Y.Z.tar.gz` |
| `ch05-vX.Y.Z` | observability: Grafana, VictoriaMetrics, Loki, Alloy, dashboards/alerts | `ch05-vX.Y.Z.tar.gz` |
| `platforminit-development-vX.Y.Z` | tested umbrella snapshot for the development project | `platforminit-development-vX.Y.Z.tar.gz` |
| `platforminit-n8n-vX.Y.Z` | future n8n project snapshot | `platforminit-n8n-vX.Y.Z.tar.gz` |
| `platforminit-platforminit-vX.Y.Z` | future customer-facing production snapshot | `platforminit-platforminit-vX.Y.Z.tar.gz` |

## Workflow

Use **06 - Publish Platform Release** to create module or umbrella releases.

Recommended flow:

1. Develop and validate with CH workflows.
2. Keep run logs and validation output as Actions artifacts.
3. Publish a CH release when that chapter is stable.
4. Publish an umbrella `platforminit-development-vX.Y.Z` release when CH01-CH05 work together.

## Versioning

- Release candidates: `0.1.0-rc1`, `0.1.0-rc2`
- Stable chapter: `ch05-v0.1.0`
- Stable umbrella baseline: `platforminit-development-v0.1.0`
