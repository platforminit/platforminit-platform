# Multi-project host discovery and volume layout

## Branch

`feat/multi-project-host-discovery-volume-layout`

## Commit

`feat(infra): add label-based host discovery and volume layouts`

## Design summary

PlatformInit no longer needs to rely on one global `INFRA_SERVER_ID` for every workflow.

Resolution order is now:

1. `server_id_override`
2. Hetzner label discovery using `project` + `host_name`
3. legacy `secrets.INFRA_SERVER_ID` fallback

Every created server receives these labels:

```text
platforminit.project=<project>
platforminit.host=<host_name>
platforminit.role=primary
platforminit.volume_layout=<none|single|split>
```

## Volume layouts

### `none`

No extra Hetzner volume is created.

### `single`

Creates one persistent volume:

```text
platforminit-<project>-<host_name>-srv -> /srv
```

### `split`

Creates three persistent volumes:

```text
platforminit-<project>-<host_name>-data          -> /srv/data
platforminit-<project>-<host_name>-db            -> /srv/db
platforminit-<project>-<host_name>-observability -> /srv/observability
```

## Host context

`01 - Create or Rebuild Host` writes:

```text
/etc/platforminit/host-context.env
/etc/platforminit/volume-layout.tsv
```

Other workflows should not guess the layout. They should resolve the host through `.github/actions/resolve-target-host` and, on the host, source:

```bash
source /etc/platforminit/host-context.env
```

## Workflow impact

All operational workflows now expose `project` and `host_name` inputs and pass them into the shared resolver action.

This keeps old single-host operation working while enabling multiple hosts/projects without multiplying repository secrets.
