apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ch05-observability
  namespace: argocd
  labels:
    app.kubernetes.io/name: ch05-observability
    app.kubernetes.io/part-of: platforminit
    platforminit.io/chapter: ch05
    platforminit.io/gitops-mode: inventory
  annotations:
    platforminit.io/description: "Registers CH05 observability manifests in Argo CD without taking over Helm-owned releases."
spec:
  project: default
  source:
    repoURL: __REPO_URL__
    targetRevision: __TARGET_REVISION__
    path: platform/observability/manifests
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
