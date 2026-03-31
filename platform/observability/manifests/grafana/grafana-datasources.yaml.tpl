apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources-platforminit
  namespace: observability
  labels:
    grafana_datasource: "1"
    app.kubernetes.io/part-of: platforminit
    platforminit.io/chapter: ch05
data:
  platforminit-datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        uid: victoriametrics
        type: prometheus
        access: proxy
        url: ${VICTORIAMETRICS_URL}
        isDefault: true
        editable: false
        jsonData:
          timeInterval: 30s
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: ${LOKI_URL}
        editable: false
