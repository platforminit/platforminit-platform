# Checkmk CH05 layer

This directory documents the PlatformInit Checkmk replacement for the retired Zabbix/OpenObserve/Vector CH05 stack.

## Operator model

```text
HOST: platforminit-dev-01
SERVICE: SSH
STATE: OK

HOST: platforminit-dev-01
SERVICE: Kubernetes API
STATE: OK/WARNING/CRITICAL

HOST: platforminit-dev-01
SERVICE: Observability storage
STATE: OK/WARNING/CRITICAL
```

## Current scope

The first Checkmk patch creates the runtime, storage, ingress, Authentik forwardAuth middleware and trusted-header shim.

Host/service discovery and custom Checkmk rules are the next bounded task.
