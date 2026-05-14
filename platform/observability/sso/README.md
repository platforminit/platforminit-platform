# Operations Native SSO

All public CH05 WebUIs must use Authentik as the identity provider. The target is native application SSO, not only reverse-proxy access gating.

## Model

```text
Zabbix WebUI      -> Authentik SAML
OpenObserve UI   -> OpenObserve Enterprise OIDC/SSO with Authentik
Vector           -> no WebUI
```

## Authentik objects reconciled by `05.3`

`05.3 - Enable Operations Native SSO` must:

- create/update the `PlatformInit Operations` Authentik group
- create/update the `PlatformInit Zabbix` SAML provider and application
- create/update the `PlatformInit OpenObserve` OAuth2/OIDC provider and application
- create/update `operations/openobserve-sso` for OpenObserve Enterprise
- create/update `operations/zabbix-saml-certs` with the Authentik IdP certificate
- configure Zabbix SAML through the Zabbix API
- leave public Traefik ingresses under Argo CD ownership

## Why forward-auth was removed

The previous proxy-provider model only verified the browser at Traefik. It did not create a native Zabbix/OpenObserve session, so clicking the app in Authentik did not log the user into the target application.

## Zabbix break-glass

The local Zabbix admin account remains available as break-glass. `ZABBIX_ADMIN_USER` and `ZABBIX_ADMIN_PASSWORD` may be provided as GitHub secrets for SAML automation; otherwise the workflow tries `Admin` / `zabbix`. The Authentik `akadmin` user is reconciled as a Zabbix SAML bootstrap admin so the Authentik application tile can open a usable Zabbix session.

## Zabbix 7.x API contract

Zabbix 7.x no longer accepts legacy IdP detail fields such as `saml_idp_entityid`, `saml_sso_url`, `saml_slo_url`, and `saml_sp_entityid` in `authentication.update`. The CH05.3 workflow must:

1. create or update the single SAML user directory through `userdirectory.create` / `userdirectory.update`;
2. enable SAML globally through `authentication.update` with only supported global flags;
3. keep the Authentik IdP certificate mounted into the Zabbix frontend container;
4. keep `akadmin` present as a local Zabbix user matching the Authentik username.

This avoids the failure pattern:

```text
Invalid parameter "/": unexpected parameter "saml_idp_entityid"
```

## Authentik signing certificate handling

`05.3` uses a dedicated or existing Authentik certificate-keypair as the SAML signing key for Zabbix. The workflow first tries to read an existing readable public certificate through the Authentik crypto API. If no readable PEM is available, it generates a dedicated self-signed keypair named `PlatformInit Zabbix SAML Signing Certificate` and stores the resulting public certificate in `operations/zabbix-saml-certs` as `idp.crt`.

This avoids Zabbix/SimpleSAML runtime failures such as:

```text
Unable to extract public key
```

## Runtime restart ordering

`05.3` configures the Zabbix API before requesting any `zabbix-web` restart. Restarting first can invalidate the service port-forward target and produce `network namespace is closed` / `lost connection to pod`. Any restart requested by `05.3` is intentionally non-blocking; `05.2`/`05.4` own readiness validation.
