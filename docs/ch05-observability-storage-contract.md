# CH05 observability storage contract

CH05 runtime data must be separated from generic k3s runtime data.

## Contract

| Data class | Path |
|---|---|
| k3s runtime and container runtime data | `/srv/data/k3s` |
| k3s local-path default PVC storage | `/srv/data/k3s/storage` |
| CH05 observability persistent data | `/srv/observability/data` |
| Zabbix PostgreSQL data | `/srv/observability/data/zabbix-postgres` |
| OpenObserve data | `/srv/observability/data/openobserve` |
| Vector buffer/checkpoint data | `/srv/observability/data/vector` |

CH05 uses static hostPath PersistentVolumes with `Retain` reclaim policy for Zabbix PostgreSQL and OpenObserve. This prevents observability database/log data from being silently mixed into the generic local-path storage tree.

## Important note

`/srv/observability` should ideally be a dedicated mounted volume in split volume layouts. If it is not a dedicated mount, CH05 still uses the correct path, but the data may live on the root filesystem.

Check the current host:

```bash
findmnt -T /srv/observability || true
df -hT /srv/observability /srv/data /srv/data/k3s /srv/data/k3s/storage
sudo du -h /srv/observability --max-depth=3 | sort -hr | head -50
```

## Rebuild note

If CH05 was previously deployed with local-path PVCs, recreate only the operations layer after this change:

```bash
kubectl -n argocd delete application operations-stack --ignore-not-found=true
kubectl delete ns operations --ignore-not-found=true
kubectl delete clusterrole platforminit-vector --ignore-not-found=true
kubectl delete clusterrolebinding platforminit-vector --ignore-not-found=true
```

Then run:

```text
00 -> 05 -> 05.1 -> 05.2 -> 05.3 -> 05.2 -> 05.4
```
