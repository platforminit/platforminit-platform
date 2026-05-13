# CH05 Migration from the Previous Grafana Stack

The previous default CH05 stack has been removed from the active lifecycle:

- Grafana
- VictoriaMetrics
- VMAgent
- VMAlert
- Alertmanager
- Loki
- Alloy
- provisioned Grafana dashboards

## New default

```text
Zabbix + Vector + OpenObserve + Authentik-gated WebUIs
```

## Host storage audit

Run these before and after removing old releases/PVCs:

```bash
sudo du -xh /srv | sort -hr | head -50
sudo du -xh /srv/data | sort -hr | head -50
sudo du -xh /srv/data/k3s | sort -hr | head -50
sudo du -xh /var/lib/rancher/k3s 2>/dev/null | sort -hr | head -50 || true
```

## Kubernetes audit

```bash
kubectl get ns
kubectl get pvc -A
kubectl get pods -A | grep -Ei 'grafana|victoria|vmagent|vmalert|alertmanager|loki|alloy' || true
helm list -A | grep -Ei 'grafana|victoria|loki|alloy' || true
```

## Removal rule

Do not remove old PVCs until the new CH05 stack is validated and any required logs/metrics have been intentionally discarded or exported.
