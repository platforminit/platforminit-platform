# CH05 Security & Audit Monitoring

Security & Audit Monitoring is part of the CH05 operational observability layer.

It is not intended to be a full SIEM. Its purpose is to expose operational security signals that matter for PlatformInit day-to-day operation.

## Primary goals

- show access elevation events;
- show whether temporary grants expired;
- show sudo and SSH anomalies;
- show UFW and AIDE/FIM baseline status;
- show identity and RBAC failures;
- show whether security telemetry itself is missing.

## Primary audit source

```text
/srv/platforminit/audit/security.log
```

The preferred format is JSON Lines.

## Audit event example

```json
{
  "timestamp": "2026-05-13T10:00:00Z",
  "event_type": "access_elevation_granted",
  "severity": "info",
  "project": "development",
  "environment": "dev",
  "host": "platforminit-dev-01",
  "actor": "github-actions",
  "workflow": "A1 - Access Elevation",
  "repository": "platforminit/platforminit-platform",
  "branch": "dev",
  "target_user": "devops",
  "grant_scope": "/tmp/platforminit-run/ch06-remote.sh",
  "duration_minutes": 15,
  "result": "success"
}
```

## Event families

| Family | Events |
|---|---|
| access elevation | requested, granted, denied, expired, failed |
| sudo | allowed, denied, unexpected command |
| SSH | failed login, root login attempt, root login success |
| firewall | UFW disabled, unexpected rule drift |
| file integrity | AIDE/FIM drift, missing baseline |
| identity | Authentik login/provider/callback failures |
| RBAC | Argo CD or Grafana access denied |
| telemetry | security log missing, collector down |

## Security dashboard panels

| Panel | Purpose |
|---|---|
| Security Status | OK/WARNING/CRITICAL/UNKNOWN summary |
| Active Security Alerts | security warning/critical/unknown counts |
| Recent Access Elevations | latest elevation events |
| Active / Recently Expired Grants | grant lifecycle visibility |
| Failed Elevation Attempts | failed or denied elevation activity |
| Sudo Activity | allowed and denied sudo events |
| SSH Auth Events | failed login and root login activity |
| UFW / Firewall State | enabled/disabled/drift status |
| AIDE / FIM Status | file integrity status |
| Identity Failures | Authentik/provider/callback failures |
| RBAC Failures | Argo CD/Grafana permission failures |

## Security alert examples

| Alert | Severity |
|---|---|
| root SSH login success | critical |
| repeated root SSH login attempts | critical |
| UFW disabled | critical |
| AIDE critical drift | critical |
| temporary sudo grant not expired | critical |
| repeated sudo denied events | warning |
| access elevation failed | warning |
| access elevation outside expected workflow | critical |
| security log source missing | unknown |
