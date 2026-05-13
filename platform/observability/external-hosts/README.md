# External Host Onboarding

This directory reserves the CH05.3 contract for future hosts such as the planned n8n host.

The target onboarding model is:

```text
Zabbix agent -> operational state
Vector agent -> logs
OpenObserve -> RCA search
```

No standing sudo should be required for runtime agents.
