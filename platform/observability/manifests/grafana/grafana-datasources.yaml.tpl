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
    prune: true
    deleteDatasources:
      - name: Prometheus
        orgId: 1
    datasources:
      # VictoriaMetrics remains the default datasource via the victoria-metrics-k8s-stack chart.
      # This overlay provisions only Loki to avoid multiple default datasources in the same org.
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki-gateway.observability.svc.cluster.local
        isDefault: false
        jsonData:
          maxLines: 1000
