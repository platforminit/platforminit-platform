# CH05 Local Break-Glass and Optional SSO Decision

## Decision

CH05 runtime health is independent from native Authentik SSO browser login.

The operations stack is considered operational when:

- `operations-stack` is `Synced` and `Healthy` in Argo CD;
- Zabbix runtime is healthy;
- OpenObserve runtime is healthy;
- Vector is running and collecting logs;
- Zabbix and OpenObserve WebUIs are reachable through their services and public ingresses;
- local break-glass login remains available for both public WebUIs.

Native Authentik SSO remains supported, but it is an optional integration layer.

## Rationale

Local login was verified manually for both Zabbix and OpenObserve. That proves the application layer is healthy. Current SSO issues are therefore integration/mapping problems rather than runtime failures.

The platform must remain operable during SSO regressions. A broken SAML/OIDC mapping must not block an operator from using the monitoring and log-search UIs.

## Validation modes

`05.4 - Validate Operations Stack` defaults to runtime validation:

```text
validation_mode=runtime
```

This validates runtime health and local break-glass reachability.

Strict SSO validation is explicit:

```text
validation_mode=runtime_with_sso
```

This additionally requires native SSO prerequisites to be present. Use it only when the release gate is specifically about SSO readiness.

## Operator rule

Every public operations WebUI must have:

1. a local break-glass login path;
2. an optional Authentik SSO path;
3. documentation explaining which path is currently the support boundary.

