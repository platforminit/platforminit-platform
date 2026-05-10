# CH05 k3s Monitoring Runbook

## Purpose

CH05 uses `victoria-metrics-k8s-stack` as the base observability stack. The chart name and bundled dashboards use the generic `vm-k8s-stack` naming because they are upstream VictoriaMetrics Kubernetes dashboards, not because the environment is expected to be a multi-node VM cluster.

For PlatformInit the target is still a single-node k3s cluster. The platform must therefore validate real metric ingestion, not only that Grafana and VictoriaMetrics pods are running.

## Expected public UI

- Grafana: `https://grafana.<PLATFORM_BASE_DOMAIN>`

## Expected core metric signals

| Signal | Query | Purpose |
|---|---|---|
| Scrape health | `up` | Confirms VMAgent writes data to VictoriaMetrics |
| Host/system | `node_uname_info or node_cpu_seconds_total` | Confirms node-exporter is scraped |
| Kubernetes objects | `kube_node_info or kube_pod_info` | Confirms kube-state-metrics is scraped |
| Containers | `container_cpu_usage_seconds_total` | Confirms k3s kubelet/cAdvisor path is scraped |
| API server | `apiserver_request_total` | Confirms API server scrape where available |

`apiserver_request_total` may be WARN instead of FAIL because k3s control-plane exposure differs from a kubeadm-style control plane.

## Why some upstream dashboards can show `No data`

The default dashboards bundled with the VictoriaMetrics Kubernetes stack are generic Kubernetes dashboards. On k3s, dashboards for etcd, scheduler, controller-manager, or some API-server internals may be empty because:

- single-node k3s often does not run external etcd;
- some control-plane components are embedded;
- some metrics bind differently from kubeadm defaults;
- dashboard variables may select a label value that is not present in this cluster.

This is not enough to declare CH05 healthy. CH05 health is based on the validation queries above.

## Fast checks

```bash
kubectl -n observability get pods -o wide
kubectl -n observability get vmagent,vmsingle,vmservicescrape
kubectl -n observability logs deploy/observability-vmstack-grafana --tail=50
kubectl -n observability get secret vmagent-additional-scrape -o yaml
```

Discover VictoriaMetrics service:

```bash
kubectl -n observability get svc | grep -E 'vmsingle|victoria-metrics-single|vmselect'
```

Port-forward and query:

```bash
kubectl -n observability port-forward svc/<VM_SERVICE> 18428:<VM_SERVICE_PORT>
```

Then in another shell:

```bash
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=up'
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=node_uname_info or node_cpu_seconds_total'
curl -G 'http://127.0.0.1:18428/api/v1/query' --data-urlencode 'query=kube_node_info or kube_pod_info'
```

## Grafana dashboard to use first

Start with:

```text
PlatformInit / Node Overview
```

This dashboard uses the PlatformInit baseline queries instead of the upstream control-plane dashboards.

## Expected workflow behavior

`05 - Deploy Observability Stack` must fail if there is no `up{}` data or no node/kube-state-metrics data. This prevents false-green observability deployments where Grafana is reachable but the metric pipeline is empty.

## 2026-05 VMAgent Secret Contract

`vmagent.spec.additionalScrapeConfigs` is treated as a Secret-backed selector.
CH05 must create `observability/vmagent-additional-scrape` as a Kubernetes Secret
before `observability-vmstack` is installed or upgraded. A ConfigMap with the same
name is not sufficient and can leave the VMAgent CR present while no VMAgent pod is
materialized by the VictoriaMetrics Operator.

Expected quick checks:

```bash
kubectl -n observability get secret vmagent-additional-scrape
kubectl -n observability get vmagent
kubectl -n observability get pods -o wide | grep -i vmagent
```
