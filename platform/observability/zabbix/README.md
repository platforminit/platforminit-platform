# Zabbix Monitoring

Zabbix is the primary PlatformInit operational monitoring UI.

## Public access

`05.4 - Enable Operations Native SSO` creates `https://zabbix.<PLATFORM_BASE_DOMAIN>` and configures native SAML login through Authentik.

```text
ACS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?acs
SLS URL: https://zabbix.<PLATFORM_BASE_DOMAIN>/index_sso.php?sls
SP entity ID: https://zabbix.<PLATFORM_BASE_DOMAIN>
Username attribute: email
```

The local Zabbix admin remains the break-glass account.
