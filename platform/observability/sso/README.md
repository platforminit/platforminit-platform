# Operations SSO

All public CH05 WebUIs must require Authentik login.

## Model

The default model is edge authentication through Traefik and the Authentik embedded proxy outpost endpoint:

```text
browser -> Traefik ingress -> Authentik forward-auth -> Zabbix/OpenObserve service
```

PlatformInit's CH04.5 Authentik deployment exposes the embedded outpost endpoint through the existing Kubernetes service:

```text
authentik-server.identity.svc.cluster.local/outpost.goauthentik.io/auth/traefik
```

Do not require a separate `ak-outpost-*` Kubernetes service for the default PlatformInit install unless CH04.5 is explicitly changed to deploy a standalone outpost later.

## Protected UIs

- `https://zabbix.<PLATFORM_BASE_DOMAIN>`
- `https://logs.<PLATFORM_BASE_DOMAIN>`

## Authentik objects reconciled by `05.4`

`05.4 - Enable Operations SSO` must:

- verify `identity/authentik-server` is healthy
- read the `identity/authentik-bootstrap` API token
- reconcile Authentik proxy providers and applications for Zabbix and OpenObserve
- set both provider authorization and provider invalidation flows (`default-provider-authorization-implicit-consent`, `default-provider-invalidation-flow`)
- attach the providers to the embedded proxy outpost when the outpost is visible through the API
- create Traefik forward-auth middleware and public ingresses

## Dependency

`04.5 - Deploy Identity Foundation` must be healthy before `05.4 - Enable Operations SSO` is executed.

Operational note: validation must query Traefik middleware using the fully qualified Kubernetes resource `middleware.traefik.io`. Do not use the ambiguous short resource name `middleware`, because clusters that still expose legacy Traefik CRDs may resolve it to `middlewares.traefik.containo.us` and report false NotFound errors after applying the current `traefik.io/v1alpha1` object.
