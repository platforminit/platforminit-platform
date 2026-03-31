#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Must run as root"
  exit 1
fi

mkdir -p /srv/platforminit/observability
chown devops:devops /srv/platforminit/observability

echo "CH05 observability baseline deploy placeholder"
