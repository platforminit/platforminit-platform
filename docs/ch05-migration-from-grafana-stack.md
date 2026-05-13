# CH05 Migration

Remove:
- Grafana
- VictoriaMetrics
- Loki
- Alloy
- Alertmanager

Deploy:
- Zabbix
- Vector
- OpenObserve

Before removal inspect storage:
```bash
sudo du -xh /srv | sort -hr | head -50
sudo du -xh /var/lib/rancher/k3s | sort -hr | head -50
```
