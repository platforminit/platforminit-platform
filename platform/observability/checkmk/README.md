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


## ForwardAuth service contract

The CH04.5 Authentik deployment currently serves the embedded outpost paths from
`authentik-server.identity.svc.cluster.local`. There is no separate
`ak-outpost-authentik-embedded-outpost` Service in the identity namespace. CH05
therefore creates an operations-local ExternalName Service named
`authentik-forward-auth` that points to:

```text
authentik-server.identity.svc.cluster.local:80
```

Traefik forwardAuth and the `/outpost.goauthentik.io/` IngressRoute path must use
that reachable service. Pointing CH05 at a non-existent outpost Service causes
Traefik to return HTTP 500 before the request reaches the Checkmk backend; this
shows up in Traefik access logs with the Checkmk router selected but service `-`.

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

## CH05.3 Argo CD ownership guardrail

The Checkmk auth-shim `ConfigMap` is Argo CD-owned through the CH05 operations-stack
manifest. CH05.3 must not patch or rollout-restart this `ConfigMap` directly because
that creates Argo CD drift and makes `05.4 - Validate Operations Stack` fail with
`operations-stack is not Synced`.

If the trusted-header mapping changes in Git, run the lifecycle in this order:

```text
00 - Build Platform Artifacts
05.2 - Sync Operations Stack
05.3 - Enable Checkmk Trusted-Header SSO
05.4 - Validate Operations Stack
```

CH05.3 is allowed to reconcile Authentik API objects, create/update the `checkmk-sso`
Secret, and persist Checkmk site-local header authentication inside the Checkmk site.
Runtime Kubernetes manifests remain owned by Argo CD.

## Trusted-header bridge hardening note

The Checkmk Community trusted-header SSO proof intentionally keeps the
`checkmk-nginx-auth-shim` request to the Checkmk upstream minimal:

- `proxy_pass_request_headers off` prevents arbitrary browser/Authentik headers
  and stale Checkmk cookies from being forwarded into the site Apache process.
- `Cookie ""` avoids stale `auth_cmk` cookies from older native-login attempts.
- `Authorization ""` avoids leaking unrelated browser credentials to Checkmk.
- `X-Forwarded-Proto https` reflects the public TLS entrypoint used by Traefik.
- `X-Remote-User cmkadmin` maps approved Authentik sessions to the deterministic
  local Checkmk administrator until per-user Checkmk provisioning is introduced.

Because this ConfigMap is part of the Argo CD-owned runtime manifest, any change
requires `05.2 - Sync Operations Stack` before `05.3` and `05.4` validation.

## CH05.2 sync-only contract

`05.2 - Sync Operations Stack` is intentionally limited to Argo CD synchronization and health convergence. It must not run the full `ch05-validate-operations-stack.sh` release gate, because public SSO and runtime validation are owned by `05.4 - Validate Operations Stack`.

This separation keeps the lifecycle clear:

```text
05.2 = sync desired manifests and wait until operations-stack is Synced/Healthy
05.3 = reconcile Checkmk trusted-header SSO API/runtime configuration
05.4 = validate runtime or runtime_with_sso
```

If `05.2` fails, troubleshoot Argo CD sync/health only. Do not treat a browser/public SSO problem as a `05.2` concern.


## CH05.5 visible operations model

`05.5 - Provision Checkmk Operations Model` must not be treated as successful just
because the workflow exits with code `0`. The success contract is visible Checkmk
runtime state:

```text
cmk -l contains platforminit-dev-01
cmk -N contains PlatformInit custom services
Checkmk UI shows Hosts > 0 and Services > 0
```

The first Checkmk model uses Checkmk `custom_checks` in the Checkmk 2.x dict-rule format with a small Nagios-compatible
plugin generated into the site-local plugin directory. The checks are intentionally
operator-facing and named after services rather than raw metric keys:

```text
Host availability
SSH
Kubernetes API
Checkmk WebUI
Argo CD WebUI
Authentik WebUI
Root filesystem
Kubernetes runtime storage
Kubernetes PVC storage
Checkmk storage
Platform runtime artifacts
```

Storage checks read host paths through read-only `hostPath` mounts in the Checkmk
container. This means any change to the mounted path contract requires `05.2 - Sync
Operations Stack` before rerunning `05.5`.

### CH05.5 Checkmk 2.x rule format note

CH05.5 must not write deprecated tuple-style `custom_checks` rules such as
`({value}, [], [host])`. Checkmk 2.2+ expects dict-style rules with `id`,
`value`, `condition`, and `options`. The PlatformInit bootstrap therefore writes
only dict-style `custom_checks` entries and keeps the first model minimal to
avoid legacy tuple-rule conversion failures during `cmk -R`.

### CH05.5 heredoc safety

The Checkmk operations model writes `platforminit_hosts.mk` through a shell heredoc. The `PLATFORMINIT_MK` terminator must stay on its own line; otherwise the shell appends the rest of the script into the generated Checkmk configuration and the workflow can report a misleading partial success before validation fails.

### Checkmk command output safety

Do not pipe Checkmk Python-backed commands such as `cmk -N` directly into `grep -q`.
When `grep -q` exits early after a match, Checkmk can hit a Python `BrokenPipeError` while flushing stdout and return rc=120 even though the generated core configuration is valid.
Capture command output to a temporary file first, then grep the file.

## CH05.6 operator start experience

`05.6 - Configure Checkmk Operations Entry Point` is not a synthetic dashboard
object generator. The first implementation tried to use dashboard naming/start
URLs, but that leads to an empty dashboard selector in Checkmk Community/Raw and
is not an acceptable operator experience.

CH05.6 now uses a conservative Checkmk-native service-list view as the landing
page. This is closer to the desired Checkmk/Nagios mental model because it shows
host -> services -> state directly.

The workflow writes:

```text
/omd/sites/cmk/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk
/omd/sites/cmk/var/check_mk/web/cmkadmin/start_url.mk
/omd/sites/cmk/local/share/platforminit/checkmk-operations-entrypoints.txt
```

The configured start URL is:

```text
view.py?view_name=service&host=platforminit-dev-01
```

The host status page is kept as a secondary deep link only:

```text
view.py?view_name=hoststatus&host=platforminit-dev-01
```

This intentionally avoids the default `Welcome to Checkmk` page and the empty
`dashboard.py` selector. Operators land on the concrete list of PlatformInit
services and can drill into current state from there.

The success contract is:

```text
platforminit-dev-01 is visible in cmk -l
at least 10 generated services exist in cmk -N
cmkadmin has a PlatformInit start URL
local Checkmk frontend returns HTTP 200/302/303 for the hoststatus view
```

CH05.6 does not install the Checkmk agent. CH05.7 should add the host agent and
run service discovery so this landing page becomes a full host metrics and
service-discovery view rather than a synthetic active-check view.
