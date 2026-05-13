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
