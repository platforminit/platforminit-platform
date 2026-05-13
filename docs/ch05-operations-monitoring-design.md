# CH05 Operations Monitoring Design (v2)

## Goal
Answer two questions fast:
1. What is broken?
2. Why is it broken?

## Stack
- Zabbix: alerting + host/service monitoring
- Vector: log collection
- OpenObserve: searchable RCA logs
- Authentik: SSO for Zabbix/OpenObserve

## Why previous stack was removed
- High storage growth
- Too many moving parts
- Poor 2AM operator UX
- Excessive dashboard fragmentation

## Workflow order
- 05 Deploy Zabbix Monitoring
- 05.1 Deploy Vector Logging
- 05.2 Deploy OpenObserve
- 05.3 Onboard External Host
- 05.4 Enable Operations SSO

## Default operator flow
Zabbix alert -> OpenObserve search -> fix issue
