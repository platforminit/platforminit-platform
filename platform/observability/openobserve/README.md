# OpenObserve Enterprise RCA Logs

OpenObserve is the searchable log backend for CH05.

## Edition

PlatformInit uses the OpenObserve Enterprise image because native SSO/RBAC are Enterprise features.

```text
public.ecr.aws/zinclabs/openobserve-enterprise:v0.80.3
```

## Public access

`05.2 - Sync Operations Stack` exposes `https://logs.<PLATFORM_BASE_DOMAIN>` through the Argo CD-owned ingress. `05.3 - Enable Operations Native SSO` configures Authentik OIDC through the `operations/openobserve-sso` Kubernetes Secret and may request a non-blocking runtime restart after secret updates. It must not wait for rollout; readiness remains owned by `05.2`/`05.4`.

```text
Redirect URL: https://logs.<PLATFORM_BASE_DOMAIN>/config/redirect
Callback URL: https://logs.<PLATFORM_BASE_DOMAIN>/web/cb
Base URL: https://auth.<PLATFORM_BASE_DOMAIN>
Authorize suffix: /application/o/authorize/
Token suffix: /application/o/token/
JWKS suffix: /application/o/platforminit-openobserve/jwks/
```

OpenObserve appends the suffixes above to `O2_DEX_BASE_URL`. Keep the base at the Authentik public host; do not use parent-directory endpoint rewrites, because they can route browsers to an Authentik Not Found page.
