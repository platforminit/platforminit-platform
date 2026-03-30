#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Uninstalling k3s..."
/usr/local/bin/k3s-uninstall.sh || true

echo "[INFO] Removing data dir..."
rm -rf /srv/k3s

echo "[DONE]"
