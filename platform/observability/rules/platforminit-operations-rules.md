# PlatformInit Operations Rule System

This is the operator decision model for CH05.

## Primary rule

Every production-facing alert must answer at least three questions:

```text
what is broken?
where is it broken?
what should I check next?
```

## Severity model

| Severity | Meaning | Operator action |
|---|---|---|
| OK | healthy | no action |
| WARNING | degraded or approaching limit | inspect during working window |
| CRITICAL | user-visible or platform-critical failure | immediate action |
| UNKNOWN | monitoring cannot determine state | fix monitoring visibility first |

## Alert rules

- Do not alert on raw metrics without human-readable context.
- Do not expose PromQL/label noise to the primary operator view.
- Prefer service-state language over telemetry language.
- Every critical alert must link to a log search path or runbook.
- Storage growth alerts must include the affected mount and top suspected consumers.

## Log rules

- Logs must be searchable by host, namespace, pod, container and severity where available.
- Collector logs must be rate-limited/noise-controlled.
- Log pipelines must not create unbounded retention by default.
- `too many open files`, `CrashLoopBackOff`, `ImagePullBackOff`, `permission denied`, `certificate`, `timeout` and `connection refused` must be easy RCA searches.
