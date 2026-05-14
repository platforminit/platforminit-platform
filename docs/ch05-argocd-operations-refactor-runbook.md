# CH05 Argo CD Operations Stack Refactor Runbook

## Purpose

CH05 is now an Argo CD-owned platform workload. GitHub Actions must not run long SSH/kubectl deployment loops for Zabbix, OpenObserve or Vector.

## Host rebuild requirement

A full host rebuild is not required for this refactor.

Recommended cleanup level for the current broken CH05 state:

```text
keep host
keep CH01-CH04.6
keep k3s
keep Argo CD
keep Authentik
reset only CH05 operations namespace/resources if needed
```

A host rebuild is only justified if CH03/k3s itself is inconsistent, the k3s data-dir contract is wrong, or the node has severe unrecoverable storage drift.

## Optional one-time CH05 cleanup

This deletes current CH05 runtime state, including Zabbix/OpenObserve PVC-backed data. Use it only if the current CH05 stack is already considered disposable.

```bash
kubectl -n argocd delete application operations-stack ch05-observability --ignore-not-found=true
kubectl delete ns operations --ignore-not-found=true
kubectl delete clusterrole platforminit-vector --ignore-not-found=true
kubectl delete clusterrolebinding platforminit-vector --ignore-not-found=true
```

Wait until the namespace is gone:

```bash
kubectl get ns operations
```

## New run order

```text
00 - Build Platform Artifacts
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.3 - Enable Operations Native SSO
05.2 - Sync Operations Stack
05.4 - Validate Operations Stack
```

For an already deployed but broken stack, `05.3` may require Zabbix to be reachable through the in-cluster service. If Zabbix is not running yet, run `05.2` first, then `05.3`, then `05.2` again.

## Ownership contract

```text
GitHub Actions:
- short sudo entrypoint only
- prerequisite secrets
- Authentik API reconciliation
- Argo CD Application registration
- sync/health validation

Argo CD:
- operations namespace
- Zabbix deployments/services/PVCs/ingress
- OpenObserve deployment/service/PVC/ingress
- Vector DaemonSet/RBAC/config
```

## Timeout rule

`05.3 - Enable Operations Native SSO` must not wait for OpenObserve or Zabbix rollout. It may request a non-blocking restart after SSO secret changes, but readiness belongs to the Argo CD sync/operations lifecycle and final validation.

## CH05 Argo CD sync guardrail

The `operations-stack` Application is registered without automated sync. This is intentional: Zabbix, OpenObserve and Vector depend on non-Git prerequisite secrets created by `05.1 - Reconcile Operations Prerequisites`. The safe lifecycle is:

```text
05   Register Operations Stack    -> creates Argo CD Application only
05.1 Reconcile Operations Prerequisites -> creates required runtime secrets
05.2 Sync Operations Stack        -> explicitly starts Argo CD sync and waits for health
```

If Vector shows `secret "openobserve-root" not found`, run `05.1` and then rerun `05.2`. Do not enable automated sync before prerequisite reconciliation.

