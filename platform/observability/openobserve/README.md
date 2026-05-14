# OpenObserve Enterprise RCA Logs

OpenObserve is the searchable log backend for CH05.

## Edition

PlatformInit uses the OpenObserve Enterprise image because native SSO/RBAC are Enterprise features.

```text
public.ecr.aws/zinclabs/openobserve-enterprise:v0.80.3
```

## Public access

`05.4 - Enable Operations Native SSO` creates `https://logs.<PLATFORM_BASE_DOMAIN>` and configures Authentik OIDC through the `operations/openobserve-sso` Kubernetes Secret.

```text
Redirect URL: https://logs.<PLATFORM_BASE_DOMAIN>/config/redirect
Callback URL: https://logs.<PLATFORM_BASE_DOMAIN>/web/cb
Issuer/Base URL: https://auth.<PLATFORM_BASE_DOMAIN>/application/o/platforminit-openobserve/
```
