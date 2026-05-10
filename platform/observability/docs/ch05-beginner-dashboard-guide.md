# CH05 Beginner-Friendly Dashboard Guide

## Purpose

CH05 intentionally exposes **one public user interface**: Grafana. VictoriaMetrics, Loki and Alloy stay internal/back-end services. Grafana is the place where operators read metrics and logs.

The goal of the PlatformInit dashboard layer is to answer the first operational questions without requiring deep PromQL, Loki, VictoriaMetrics or Kubernetes control-plane knowledge.

## Dashboard policy

PlatformInit disables/prunes the noisy upstream dashboard bundle from `victoria-metrics-k8s-stack` during CH05 deploy and provisions a small set of beginner-friendly dashboards instead.

This avoids confusion caused by generic Kubernetes dashboards that assume kubeadm-style control-plane components. In a single-node k3s cluster, dashboards for etcd, scheduler, controller-manager or some API-server internals can legitimately show `No data`.

## Start here

Open dashboards in this order:

| Order | Dashboard | Use for |
|---:|---|---|
| 1 | `PlatformInit / 00 - Start Here` | first green/red health view |
| 2 | `PlatformInit / Cluster Overview` | nodes, pods, namespaces, restarts, resource pressure |
| 3 | `PlatformInit / Node Overview` | host CPU, memory, disk, filesystem and network |
| 4 | `PlatformInit / Logs Overview` | Loki logs through Grafana |

## What is public and what is not

| Component | Public WebUI | Notes |
|---|---:|---|
| Grafana | yes | main UI for metrics, dashboards and logs |
| VictoriaMetrics | no | internal metrics backend / debug API only |
| Loki | no | internal log backend, queried from Grafana |
| Alloy | no | internal collector/debug endpoint only |
| Alertmanager | no by default | can be exposed later behind SSO if needed |

## What should be green first

The `00 - Start Here` dashboard should show useful data for:

- scrape targets up;
- Kubernetes node count;
- running pods;
- CPU busy percentage;
- memory used percentage;
- filesystem usage;
- recent restarts;
- firing alerts.

A few scrape targets can be down without making the platform unusable, but CH05 validation must still pass these core signals:

```text
VM_QUERY_UP
VM_QUERY_NODE
VM_QUERY_KSM
```

## Expected No data cases

After this refinement, normal daily dashboards should be mostly useful. If you manually import or re-enable upstream dashboards, the following `No data` cases are expected on single-node k3s and should not be treated as immediate failures:

- etcd dashboard;
- scheduler dashboard;
- controller-manager dashboard;
- some kubeadm-specific API-server internals;
- panels requiring labels that do not exist in this cluster.

## Troubleshooting path

Use this order:

```bash
kubectl -n observability get pods -o wide
kubectl -n observability get vmagent,vmsingle,vmservicescrape
kubectl -n observability get configmap -l grafana_dashboard=1
kubectl -n observability get secret vmagent-additional-scrape
```

Then query VictoriaMetrics if the dashboard looks empty:

```bash
kubectl -n observability port-forward svc/<VM_SERVICE> 18428:<VM_SERVICE_PORT>
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=up'
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=node_cpu_seconds_total'
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=kube_pod_info'
```
