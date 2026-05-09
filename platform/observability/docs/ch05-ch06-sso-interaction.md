# CH05 / CH06 Grafana SSO Interaction

## Ownership boundary

CH05 owns the base observability stack and the `observability-vmstack` Helm release, including Grafana.

CH06 owns identity and Authentik. CH06.1 owns the Grafana SSO overlay because it needs Authentik-side state and Grafana-side Helm values.

## Why CH05 needs an SSO-aware reconcile path

Grafana is installed by CH05. If CH06.1 later enables Generic OAuth, a later CH05 upgrade can unintentionally remove the OAuth configuration if the release is reset to only the base CH05 values.

The CH05 orchestrator therefore preserves existing Helm values in `reconcile` mode by using `--reuse-values`. This keeps post-CH05 overlays such as Grafana SSO stable during routine CH05 reconciliation.

## Operational rule

- Run CH05 `baseline` for clean observability installation or intentional reset.
- Run CH06 and CH06.1 after CH05 baseline when SSO is required.
- Run CH05 `reconcile` for routine CH05 repairs after SSO is already enabled.
- If CH05 `baseline` is rerun after SSO, rerun `06.1 - Enable Grafana SSO`.
