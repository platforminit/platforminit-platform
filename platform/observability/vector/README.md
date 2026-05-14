# Vector Logging

Vector is the CH05 log collector.

Its job is to collect low-noise logs and forward them to OpenObserve for RCA.

## Sources

- Kubernetes pod logs
- selected host files from `/var/log`
- PlatformInit operational logs under `/srv/observability` when present

## Destination

- OpenObserve HTTP ingestion endpoint inside the `operations` namespace

Vector has no public WebUI.

## Kubernetes node binding

The DaemonSet must set `VECTOR_SELF_NODE_NAME` from `spec.nodeName`.

This is required by the `kubernetes_logs` source. Without it, the Vector pod can enter `CrashLoopBackOff`, while Argo CD remains `Synced` but `Progressing`.
