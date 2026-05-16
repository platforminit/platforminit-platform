# CH05 Checkmk Operations Dashboards

CH05.8 configures the Checkmk operations dashboard landing experience after the stable Checkmk checkpoint and the graph AJAX Content-Type fix.

## Purpose

The workflow promotes Checkmk-native dashboards and stable drill-down views instead of writing internal Checkmk dashboard object files. This keeps the dashboard layer compatible with Checkmk Community while still giving operators a clear starting point.

## Workflow

```text
00 - Build Platform Artifacts
05.8 - Configure Checkmk Operations Dashboards
```

Prerequisites:

```text
05.5 - Provision Checkmk Operations Model
05.7 - Install Checkmk Agent and Discover Services
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
```

## Dashboard entrypoints

The workflow sets the Checkmk user/global start URL to:

```text
dashboard.py?name=main&owner=
```

It also records a PlatformInit dashboard catalog inside the Checkmk site:

```text
/omd/sites/cmk/local/share/platforminit/checkmk-operations-dashboards.txt
```

The catalog contains:

- Main dashboard
- Problems dashboard
- Host & service problems dashboard
- PlatformInit host status view
- PlatformInit host graphs view
- All hosts view
- All services view
- Service problems view

## Validation

CH05.8 validates that:

- `platforminit-dev-01` is a TCP Checkmk agent target.
- the host has at least the expected number of generated services after CH05.7 discovery.
- the configured dashboard start URL exists.
- dashboard and drill-down URLs respond through the trusted-header WebUI path.
- graph pages no longer contain `graph_recipe` errors.

## Design note

Checkmk Community already ships standard dashboards and view widgets suitable for this stage. CH05.8 therefore avoids creating version-sensitive raw dashboard object definitions. A later advanced UI layer can build custom dashboards after the stable Checkmk-native dashboard contract is proven.
