# CH05 Node Exporter Contract

Node Exporter is the first-class host telemetry source for PlatformInit CH05.

The operator experience should not expose a raw, noisy upstream Node Exporter dashboard as the default view. The default view is the curated PlatformInit dashboard:

```text
PlatformInit / 10 - Host Infrastructure
```

## Responsibilities

Node Exporter provides the raw host metrics for:

- CPU usage and load;
- memory and swap usage;
- filesystem and inode usage;
- disk IO;
- network throughput and errors;
- host uptime;
- node availability;
- future PlatformInit textfile collector metrics.

## Default CH05 policy

```text
Keep Node Exporter enabled.
Hide/prune noisy raw dashboards from the default operator folder.
Build curated dashboards and alerts on top of Node Exporter metrics.
```

## Required baseline metrics

CH05 validation should prove at least:

```promql
node_uname_info or node_cpu_seconds_total
up{job=~".*node-exporter.*|platform-node-exporter"} == 1
```

## Future CH05.3 textfile collector

CH05.3 should add a host-side textfile collector directory:

```text
/var/lib/node_exporter/textfile_collector
```

Recommended PlatformInit metrics:

```prometheus
platforminit_storage_split_layout_ok 1
platforminit_srv_data_mounted 1
platforminit_srv_db_mounted 1
platforminit_srv_observability_mounted 1
platforminit_reboot_required 0
platforminit_failed_systemd_units 0
platforminit_access_elevation_active 0
platforminit_audit_log_present 1
```

These metrics allow the same host dashboard and alert rules to show PlatformInit-specific host compliance, not only generic Linux capacity.

## External host onboarding

Future `05.4 - Onboard External Host` should install Node Exporter on n8n and other non-cluster hosts using the same label contract:

```text
project
environment
host
role
owner
lifecycle_ch
```

This keeps development, n8n and later production host views consistent.
