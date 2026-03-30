# platforminit-platform

Turn any VPS into a production-ready platform in minutes.

## Scope

This repository defines:

- Host provisioning and bootstrap
- Secure SSH access and tooling sync
- Host baseline enforcement and drift detection
- File integrity monitoring and AIDE-based validation
- Kubernetes bootstrap with k3s
- Platform enablement with ArgoCD, ingress and TLS
- GitOps-aligned lifecycle management

## Branch Model

| Branch | Purpose |
|---|---|
| `main` | release-ready baseline |
| `staging` | pre-release validation |
| `dev` | active integration branch |
| `feat/*` | isolated feature delivery |

## Principles

- deterministic infrastructure
- GitOps-first workflows
- security baseline enforcement
- non-interactive automation
- production-grade auditability

## Roadmap

- CH05 – Observability
- CH06 – Security & Compliance
- CH07 – Platform Services
- CH08 – Multi-Environment & Promotion
- CH09 – Reliability & Operations
- CH10 – Platform Productization
- CH11 – FinOps & Governance
- CH12 – Identity & Access Platform
- CH13 – Data / AI Ops
- CH14 – Internal Developer Platform
