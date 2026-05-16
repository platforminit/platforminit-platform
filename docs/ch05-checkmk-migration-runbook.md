# CH05 Checkmk Community Migration Runbook

## Purpose

This runbook replaces the retired CH05 Zabbix/OpenObserve/Vector proof with a simpler operator-first monitoring layer:

```text
Checkmk Community -> host/service/state operations console
Authentik         -> SSO via Traefik forwardAuth
Nginx auth-shim   -> X-authentik-* to X-Remote-User header bridge
```

The goal is to restore the straightforward CheckMK/Nagios-like workflow:

```text
HOST -> SERVICE -> STATE -> DETAIL
```

## WSL + VS Code branch flow

Run from WSL inside the repository checkout:

```bash
git checkout dev
git pull --ff-only

git checkout -b feat/ch05-checkmk-community-operations-layer
code .
```

## Purge the old CH05 runtime layer

These commands remove the old CH05 runtime objects and keep the rest of the platform intact.

> Safety rule: move old persistent data aside first. Only delete it after the Checkmk layer is validated.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export RETIRED_DIR="/srv/observability/data/_retired-$(date -u +%Y%m%dT%H%M%SZ)"

kubectl -n argocd delete application operations-stack --ignore-not-found=true
kubectl -n argocd delete appproject operations --ignore-not-found=true

kubectl -n operations delete ingressroute --all --ignore-not-found=true
kubectl -n operations delete middleware --all --ignore-not-found=true
kubectl -n operations delete certificate --all --ignore-not-found=true
kubectl -n operations delete deployment --all --ignore-not-found=true
kubectl -n operations delete daemonset --all --ignore-not-found=true
kubectl -n operations delete statefulset --all --ignore-not-found=true
kubectl -n operations delete service --all --ignore-not-found=true
kubectl -n operations delete configmap --all --ignore-not-found=true
kubectl -n operations delete secret --all --ignore-not-found=true
kubectl -n operations delete pvc --all --ignore-not-found=true

kubectl delete pv \
  platforminit-zabbix-postgres-data \
  platforminit-openobserve-data \
  platforminit-vector-data \
  platforminit-checkmk-sites \
  --ignore-not-found=true

sudo mkdir -p "$RETIRED_DIR"
for old_path in \
  /srv/observability/data/zabbix-postgres \
  /srv/observability/data/openobserve \
  /srv/observability/data/vector \
  /srv/observability/data/checkmk
  do
    if [ -e "$old_path" ]; then
      sudo mv "$old_path" "$RETIRED_DIR/"
    fi
  done

sudo mkdir -p /srv/observability/data/checkmk
sudo chmod 0750 /srv/observability/data/checkmk
```

Optional destructive cleanup after the new layer is validated:

```bash
sudo rm -rf "$RETIRED_DIR"
```

## Deploy the new Checkmk-based CH05 layer

CH05.7 native agent discovery is currently paused. Use the `05.7D - Diagnose Checkmk Agent Discovery` workflow before attempting another install/discovery implementation. The stable baseline is 05.5 + 05.6.

Run the GitHub Actions workflows in this order:

```text
00 - Build Platform Artifacts
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.2 - Sync Operations Stack
05.3 - Enable Checkmk Trusted-Header SSO
05.4 - Validate Operations Stack
05.5 - Provision Checkmk Operations Model
05.7D - Diagnose Checkmk Agent Discovery
05.6 - Configure Checkmk Operations Entry Point
```

Use `05.4` with:

```text
validation_mode=runtime
```

Then repeat with:

```text
validation_mode=runtime_with_sso
```

## Manual Checkmk SSO activation checkpoint

Checkmk Community/Raw supports the trusted-header pattern, but Checkmk itself must trust incoming HTTP authentication.

After first deploy, log in once with the local `cmkadmin` break-glass account and enable:

```text
Setup -> General -> Global Settings -> User Interface
Authenticate users by incoming HTTP requests
Activate HTTP header authentication
```

Expected trusted header:

```text
X-Remote-User
```

The PlatformInit auth-shim maps Authentik headers as follows:

```text
X-authentik-username -> X-Remote-User
X-authentik-name     -> X-Remote-Name
X-authentik-email    -> X-Remote-Email
X-authentik-groups   -> X-Remote-Groups
```

## WSL + VS Code enterprise commit flow

```bash
git status --short
git diff --stat
git diff -- .github/workflows platform/observability docs README.md

git add \
  .github/workflows/build-platform-artifacts.yml \
  .github/workflows/deploy-05-register-operations-stack.yml \
  .github/workflows/deploy-05-1-reconcile-operations-prereqs.yml \
  .github/workflows/deploy-05-2-sync-operations-stack.yml \
  .github/workflows/deploy-05-3-enable-checkmk-sso.yml \
  .github/workflows/deploy-05-4-validate-operations-stack.yml \
  .github/workflows/deploy-05-5-provision-checkmk-operations-model.yml \
  .github/workflows/deploy-05-7d-diagnose-checkmk-agent.yml \
  .github/workflows/deploy-05-6-provision-checkmk-operations-dashboard.yml \
  platform/observability \
  docs \
  README.md

git commit -m "feat(ch05): replace observability proof with Checkmk operations layer" \
  -m "Purge the retired Zabbix/OpenObserve/Vector CH05 proof from the active lifecycle and introduce a Checkmk Community based operations console." \
  -m "Add Authentik forwardAuth integration through Traefik and an auth-shim that maps X-authentik identity headers to the X-Remote-User trusted-header contract used by Checkmk Raw/Community." \
  -m "Keep CH05 Argo CD-owned and preserve a local cmkadmin break-glass path while documenting the runtime purge and validation sequence."
```

## Acceptance criteria

```text
https://checkmk.<base-domain>/cmk/ opens through Traefik
Unauthenticated browser is redirected to Authentik
Authenticated request reaches Checkmk
Checkmk local cmkadmin login remains available as break-glass
operations-stack Argo CD application is Synced/Healthy
/srv/observability/data/checkmk is the only CH05 persistent data path
```


## CH05.8D graph_recipe diagnostic and fix

The service graph UI error was investigated through the diagnostic-only workflow:

```text
05.8D - Diagnose Checkmk Graph Rendering
```

Observed symptom:

```text
Loading graph failed: (Status: 1)
'graph_recipe'
```

The diagnostic artifact showed Checkmk graph AJAX requests failing because the auth-shim stripped `Content-Type` from JSON POST requests. The fix explicitly preserves `Content-Type` while keeping broad request-header stripping.


## CH05.8 - Configure Checkmk Operations Dashboards

Run after the graph Content-Type fix and stable CH05.5/05.7/05.6/05.4 checkpoint.

```text
00 - Build Platform Artifacts
05.8 - Configure Checkmk Operations Dashboards
```

This workflow sets the Checkmk main dashboard as the operator start page and validates the main, problems, host status, host graphs, all hosts, all services and service problems routes through the trusted-header WebUI path. It does not change the Checkmk runtime deployment or native service discovery.
