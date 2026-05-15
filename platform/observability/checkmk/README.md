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

The Authentik proxy provider reconciliation must set `invalidation_flow=default-provider-invalidation-flow`; otherwise Authentik rejects `/api/v3/providers/proxy/` create/update requests with HTTP 400.

Host/service discovery and custom Checkmk rules are the next bounded task.

## Trusted-header SSO contract

Checkmk Raw/Community is protected by Authentik at the Traefik layer. The nginx auth-shim forwards only Authentik-approved requests to Checkmk.

Initial CH05 behaviour is intentionally deterministic:

```text
Authentik-approved operator
  -> nginx auth-shim
  -> X-Remote-User: cmkadmin
  -> Checkmk local admin user
```

The original Authentik username is preserved as `X-Remote-Original-User` for diagnostics, but it is not yet used as the Checkmk login principal. This avoids HTTP 500 / unknown-user failures before per-user Checkmk account provisioning exists.

CH05.3 also writes the Checkmk site-level config:

```python
auth_by_http_header = 'X-Remote-User'
```

Future hardening can replace the deterministic `cmkadmin` mapping with explicit Checkmk local user provisioning and group/role mapping.

## Authentik outpost assignment

The Checkmk proxy provider must be assigned to an Authentik proxy outpost. If the
Authentik admin UI shows:

```text
Warning: Provider is not used by any Outpost.
```

then the provider exists, but the outpost does not serve it yet. CH05.3 therefore
reconciles the outpost assignment through the provider-level `providers` field
first and only falls back to the legacy/application-style assignment if required.
This is intentionally fail-fast because Traefik forwardAuth cannot authenticate
`checkmk.<base-domain>` until the outpost owns the provider.

### Authentik embedded outpost API note

CH05.3 uses the outpost `providers` integer list as the source of truth for
forward-auth ownership. Some Authentik versions do not reliably persist or
immediately reflect a partial `PATCH` to the embedded outpost. The reconciler
therefore tries a minimal `PATCH` first, then falls back to a full `PUT` using the
complete OutpostRequest shape (`name`, `type`, `providers`, `service_connection`,
`config`). It also verifies the assignment through the `providers_by_pk` list
filter so the UI warning `Provider is not used by any Outpost` is treated as a
hard failure until the proxy provider is really attached.

### CH05.3 trusted-header config persistence note

The CH05.3 workflow writes `auth_by_http_header = 'X-Remote-User'` into the
Checkmk site from a heredoc executed with `kubectl exec -i`. The `-i` flag is
required because otherwise `bash -s` receives no stdin, exits successfully, and
no configuration file is written. The validator checks the resulting
`platforminit_header_auth.mk` content inside the running Checkmk pod.
