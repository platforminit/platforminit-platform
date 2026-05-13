# OpenObserve RCA Logs

OpenObserve is the searchable log backend for CH05.

Its job is to answer:

```text
Why did this break?
What exact error line explains it?
Which pod/service/host emitted it?
```

## Public access

OpenObserve is not exposed directly by the base deploy. `05.4 - Enable Operations SSO` creates `https://logs.<PLATFORM_BASE_DOMAIN>` and protects it with Authentik forward-auth.

## Retention note

Keep retention intentionally short on the development host. PlatformInit is not trying to build an enterprise log warehouse on a single CAX31 node.
