apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: observability
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
    datasources:
      - name: VictoriaMetrics
        uid: victoriametrics
        type: prometheus
        access: proxy
        url: http://observability-vmstack-vmsingle.observability.svc.cluster.local:8428
        isDefault: true
        jsonData:
          timeInterval: 30s
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki-gateway.observability.svc.cluster.local
        jsonData:
          maxLines: 1000
