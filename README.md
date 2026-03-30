# feat/aide

## Overview
Production-ready AIDE initialization and non-blocking integrity checks

---

## Feature Documentation

# PlatformInit Platform

Monorepo for PlatformInit's step-by-step VPS to platform automation.

## User-facing workflow order

1. **01 - Create or Rebuild Host**
2. **02 - Configure Host Baseline**
3. **03 - Install Kubernetes Cluster**
4. **04 - Enable Platform (Ingress, TLS, ArgoCD)**
5. **05 - Deploy Observability Stack**

## Current implementation scope

- Provider implementation: **Hetzner Cloud**
- Active development domain: **sysadminhomelab.hu**
- Product brand: **PlatformInit**

## Secret contract

See `docs/secrets-reference.md`.


## Policy-driven v2 additions

This version keeps the existing 00/01/02/03/04 workflow UX and adds 02.1–02.5 security workflows.
Legacy CH01 capture/restore content is preserved under `platform/host-baseline/archive/legacy-v1/`.


## Privilege model

- `01 - Create or Rebuild Host` provisions the machine and injects the automation key for initial root access.
- `01.1 - Host Bootstrap` creates `devops` and `itadmin`, installs the shared SSH public key for both users, disables root login and password auth, and installs the scoped privilege helper.
- `A1 - Access Elevation` is the only supported elevation path. It is approval-gated through the `privileged-ops` environment and grants a 15-minute time-bound sudo window scoped to the target workflow path.
- `HOST_LOGIN_USER` should be switched to `devops` after `01.1` completes successfully.


## Current operating model

- `01 - Create or Rebuild Host`
- `01.1 - Host Bootstrap`
- `A1 - Access Elevation`
- `A2 - Security Patching`
- `02 - Apply Host Baseline`
- `03 - Install Kubernetes Cluster`
- `04 - Enable Platform`

Security model:
- shared automation key pair for this iteration
- `root` bootstrap only
- `devops` runtime user without standing sudo
- `itadmin` scoped privilege broker
- deterministic dependency layer with pinned `yq` install
- policy-driven FIM (no AIDE baseline database)


## Host access tooling lifecycle

- `01.1 - Host Bootstrap` installs the initial broker tooling.
- `01.2 - Sync Host Access Tooling` updates `platforminit-grant-sudo`, `platforminit-sync-host-access`, and `lib-policy.sh` in place without rebuilding the host.
- Destructive infrastructure actions remain the customer's backup/snapshot responsibility.

## Artifact contract

- `02 - Apply Host Baseline` requires the **host-baseline** build artifact.
- `03 - Install Kubernetes Cluster` requires the **cluster** build artifact.
- `04 - Enable Platform` requires the **platform-services** build artifact.
- Each deploy workflow now accepts both the producing **workflow run ID** and the specific **artifact ID**.


## Day-2 operations

See `docs/day2-ops.md`.

---

## Platform Context

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
