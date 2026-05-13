# Operations SSO

All public CH05 WebUIs must require Authentik login.

## Model

The default model is edge authentication through Traefik + Authentik forward-auth:

```text
browser -> Traefik ingress -> Authentik forward-auth -> Zabbix/OpenObserve service
```

This keeps Zabbix and OpenObserve simple while preventing direct unauthenticated public access.

## Protected UIs

- `https://zabbix.<PLATFORM_BASE_DOMAIN>`
- `https://logs.<PLATFORM_BASE_DOMAIN>`

## Dependency

`04.5 - Deploy Identity Foundation` must be healthy before `05.4 - Enable Operations SSO` is executed.
