# CH04-CH06 Known-Good Runtime State

This document captures the current known-good development runtime baseline after the full host rebuild and CH04-CH06 stabilization work.

## Scope

This state is a runtime checkpoint, not a product release.

| Layer | Runtime status | Notes |
|---|---|---|
| CH04 Platform services | Known-good | Traefik, cert-manager, Argo CD baseline objects and Argo CD TLS are functional. |
| CH05 Observability runtime | Known-good | Grafana, VictoriaMetrics, Loki and Alloy are deployed and healthy as Helm-managed releases. |
| CH05 Argo CD visibility | Known-good | `ch05-observability` is registered as a non-destructive Argo CD inventory Application. |
| CH06 Identity runtime | Known-good | Authentik is deployed and reachable through `auth.<base-domain>`. |
| CH06.2 Argo CD SSO | Known-good | Authentik + Dex + Argo CD SSO works. Argo CD sync permission works through the `PlatformInit Admins` group. |
| Release workflow | Deferred | Release path is intentionally parked until runtime model, identity, GitOps ownership and observability UX are stabilized. |

## Runtime evidence checklist

Use these checks before promoting or tagging a known-good state.

```bash
kubectl get ns
kubectl get pods -A
helm list -A
kubectl get ingress -A
kubectl get applications.argoproj.io -A
kubectl -n argocd get cm argocd-cm argocd-rbac-cm -o yaml
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' | wc -c
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n argocd rollout status deployment/argocd-dex-server --timeout=180s
kubectl -n identity rollout status deployment/authentik-server --timeout=180s
kubectl -n observability get pods
```

Expected high-level result:

```text
Argo CD UI loads.
Argo CD SSO login succeeds.
Argo CD sync is permitted for a user in PlatformInit Admins.
Grafana UI loads.
Authentik UI loads.
ch05-observability is visible in Argo CD.
No critical platform pod is in CrashLoopBackOff.
```

## Suggested tag after merge

After this document is merged and the runtime checks pass on `dev`, preserve the checkpoint with a Git tag from a clean local checkout:

```bash
git checkout dev
git pull --ff-only
git tag -a known-good-ch04-ch06-dev-runtime -m "known-good: CH04-CH06 dev runtime baseline"
git push origin known-good-ch04-ch06-dev-runtime
```

## Do not treat this as final GitOps ownership

At this point, CH05 remains workflow/Helm-owned. The Argo CD `ch05-observability` Application is intentionally an inventory view and should not be used as proof that Argo CD owns all Helm release resources.

The next architecture work should decide how to move from inventory visibility to app-of-apps/GitOps ownership without destructively adopting existing Helm-managed resources.
