apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: operations
spec:
  forwardAuth:
    # The PlatformInit Authentik Helm deployment exposes the embedded proxy outpost
    # through the authentik-server service. Do not depend on a separate
    # ak-outpost-* Kubernetes service unless CH04.5 explicitly deploys one later.
    address: http://authentik-server.identity.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: zabbix
  namespace: operations
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-__ISSUER_MODE__
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: operations-authentik-forward-auth@kubernetescrd
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - zabbix.__BASE_DOMAIN__
      secretName: zabbix-tls
  rules:
    - host: zabbix.__BASE_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: zabbix-web
                port:
                  number: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openobserve
  namespace: operations
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-__ISSUER_MODE__
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: operations-authentik-forward-auth@kubernetescrd
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - logs.__BASE_DOMAIN__
      secretName: openobserve-tls
  rules:
    - host: logs.__BASE_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: openobserve
                port:
                  number: 5080
