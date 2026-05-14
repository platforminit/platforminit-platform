# Zabbix Monitoring

Zabbix is the primary PlatformInit operational monitoring UI.

## Public access

`05.2 - Sync Operations Stack` exposes `https://zabbix.<PLATFORM_BASE_DOMAIN>` through the Argo CD-owned ingress. `05.3 - Enable Operations Native SSO` configures native SAML login through Authentik and the Zabbix API before requesting any runtime restart, avoiding port-forward loss against terminating pods. It does not wait for rollout; readiness remains owned by `05.2`/`05.4`.

```text
ACS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?acs
SLS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?sls
SP entity ID: https://zabbix.<PLATFORM_BASE_DOMAIN>
Username attribute: username
```

The local Zabbix admin remains the break-glass account.


## Break-glass access

Local login must remain available and is part of the base CH05 runtime contract. Native Authentik SSO is optional and must not be the only operator access path.
