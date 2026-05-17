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
05.7D - Diagnose Checkmk Agent Discovery
05.7 - Install Checkmk Agent and Discover Services
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
05.8D - Diagnose Checkmk Graph Rendering
05.8 - Configure Checkmk Operations Dashboards
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

CH05.7 native Checkmk agent discovery is part of the stable checkpoint after the TCP agent tag fix and first-run PEND validation adjustment. Checkmk graph rendering is fixed by preserving `Content-Type` through the nginx auth-shim. CH05.8 then configures the operator dashboard landing experience on Checkmk-native dashboards and drill-down views.

- Checkmk logout is routed through the public Authentik `/if/flow/default-invalidation-flow/` logout flow so users do not remain silently logged in after leaving Checkmk.

### CH05.7 root-cause note

The 05.7D artifact showed that raw TCP access to the host agent worked, but `cmk -D platforminit-dev-01` still reported `Agent mode: No agent` and `cmk -d` returned empty output. The fix is to keep CH05.5 on the stable synthetic service model while writing the host with explicit raw Checkmk agent tags: `cmk-agent|tcp|prod|lan`. The `tcp` tag is required so Checkmk treats the host as a normal TCP agent target instead of a piggyback/PING-only object.


### 2026-05-16 diagnostic finding

The CH05.7D artifact confirmed that the host is now a real TCP Checkmk agent target: `cmk -D` shows a TCP agent on `62.238.5.243:6556`, `cmk -d platforminit-dev-01` returns Linux agent sections, and `cmk --debug -vvn` fetches/parses data via the TCP datasource. Do not add pre-discovery assertions that expect native Linux service status lines before `cmk -I` has created autochecks.


### CH05 graph_recipe fix

The CH05.8D artifact showed Checkmk WebUI graph rendering requests failing in `ajax_render_graph_content.py` with `KeyError: graph_recipe`. The fix keeps `proxy_pass_request_headers off` for security, but explicitly preserves `Content-Type` so Checkmk can parse JSON/AJAX POST bodies.

## CH05.8 operations dashboards

`05.8 - Configure Checkmk Operations Dashboards` configures the Checkmk main dashboard as the operator start page and records a PlatformInit dashboard catalog inside the Checkmk site. It intentionally uses Checkmk-native dashboards/views instead of writing raw internal dashboard object files.

Primary start URL:

```text
dashboard.py?name=main&owner=
```

Validated dashboard/drill-down routes:

```text
dashboard.py?name=main&owner=
dashboard.py?name=problems&owner=
dashboard.py?name=simple_problems&owner=
view.py?view_name=hoststatus&host=platforminit-dev-01
view.py?view_name=host_graphs&host=platforminit-dev-01&site=cmk
view.py?view_name=allhosts
view.py?view_name=allservices
view.py?view_name=svcproblems
```


### CH05.8D dashboard visibility extension

`05.8D - Diagnose Checkmk Graph Rendering` also collects data for the case where built-in Checkmk dashboards return HTTP 200 but render as an empty/spinning dashboard selector. It compares direct Checkmk backend responses with nginx auth-shim responses, captures dashboard-related files/user state, probes candidate dashboard AJAX/API endpoints, and records the auth-shim header contract.
