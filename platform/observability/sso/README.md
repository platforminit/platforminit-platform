# Operations Native SSO

All public CH05 WebUIs must use Authentik as the identity provider. The target is native application SSO, not only reverse-proxy access gating.

## Model

```text
Zabbix WebUI      -> Authentik SAML
OpenObserve UI   -> OpenObserve Enterprise OIDC/SSO with Authentik
Vector           -> no WebUI
```

## Authentik objects reconciled by `05.4`

`05.4 - Enable Operations Native SSO` must:

- create/update the `PlatformInit Operations` Authentik group
- create/update the `PlatformInit Zabbix` SAML provider and application
- create/update the `PlatformInit OpenObserve` OAuth2/OIDC provider and application
- create/update `operations/openobserve-sso` for OpenObserve Enterprise
- configure Zabbix SAML through the Zabbix API
- create public Traefik ingresses for Zabbix and OpenObserve

## Why forward-auth was removed

The previous proxy-provider model only verified the browser at Traefik. It did not create a native Zabbix/OpenObserve session, so clicking the app in Authentik did not log the user into the target application.

## Zabbix break-glass

The local Zabbix admin account remains available as break-glass. `ZABBIX_ADMIN_USER` and `ZABBIX_ADMIN_PASSWORD` may be provided as GitHub secrets for SAML automation; otherwise the workflow tries `Admin` / `zabbix`. The Authentik `akadmin` user is reconciled as a Zabbix SAML bootstrap admin so the Authentik application tile can open a usable Zabbix session.
