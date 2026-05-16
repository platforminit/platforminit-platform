# CH05 - Operations Monitoring

PlatformInit CH05 now uses a minimal Checkmk Community based monitoring layer.

## Architecture

```text
Checkmk Community  -> host/service/state operator console
Authentik          -> SSO gate via Traefik forwardAuth
Nginx auth-shim    -> maps approved Authentik sessions to X-Remote-User
Argo CD            -> owns runtime deployment
```

The retired Zabbix / Vector / OpenObserve implementation has been purged from the active CH05 lifecycle.

## Public endpoint

| URL | Purpose | Auth |
|---|---|---|
| `https://checkmk.<PLATFORM_BASE_DOMAIN>/cmk/` | PlatformInit operations console | Authentik forwardAuth + Checkmk trusted header |

## Workflow lifecycle

```text
00 - Build Platform Artifacts
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.2 - Sync Operations Stack
05.3 - Enable Checkmk Trusted-Header SSO
05.4 - Validate Operations Stack
05.5 - Provision Checkmk Operations Model
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
```

## Storage contract

```text
/srv/observability/data/checkmk -> Checkmk site data (/omd/sites)
```

The generic k3s runtime paths remain unchanged:

```text
/srv/data/k3s
/srv/data/k3s/storage
/srv/platforminit
```

## SSO contract

Checkmk Community/Raw is protected through Authentik forwardAuth. Authentik returns `X-authentik-*` headers. The in-pod auth shim maps approved sessions to the deterministic Checkmk local user for the first Community/Raw SSO proof:

```text
X-Remote-User: cmkadmin
X-Remote-Original-User: <authentik username>
X-Remote-Name: <authentik display name>
X-Remote-Email: <authentik email>
X-Remote-Groups: <authentik groups>
```

Checkmk must have **Authenticate users by incoming HTTP requests** enabled for full trusted-header login. The first implementation keeps local `cmkadmin` as break-glass.


## Operator UX contract

CH05.5 creates the visible host/service model. CH05.6 configures the operator start experience so the Checkmk UI opens on the PlatformInit all-hosts state view instead of the default onboarding page or an empty dashboard selector.

Current CH05.6 entrypoint:

```text
view.py?view_name=allhosts
```

CH05.7 should install and register the Checkmk agent on `platforminit-dev-01` so the same operator view is backed by real host metrics and service discovery.

- Checkmk logout is routed through Authentik `/outpost.goauthentik.io/sign_out` so users return to the SSO/login flow instead of the raw Checkmk 401 page.
