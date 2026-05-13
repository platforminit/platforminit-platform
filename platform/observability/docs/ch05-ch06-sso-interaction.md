# Deprecated: CH05 / CH06 Grafana SSO Interaction

This document is retained only as a compatibility pointer. The old CH06.1 Grafana SSO lifecycle has been replaced by the CH04.5 identity foundation and CH05.x observability lifecycle.

Use instead:

- `platform/observability/docs/ch05-ch05-1-sso-interaction.md` for the current transitional Grafana SSO workflow.
- `platform/observability/workflows/README.md` for the target CH05 split where Grafana SSO becomes `05.5 - Enable Grafana SSO`.

Current rule:

```text
04.5 - Deploy Identity Foundation
04.6 - Enable Argo CD SSO
05   - Deploy Observability Stack
05.1 - Enable Grafana SSO   # transitional; target is 05.5
```
