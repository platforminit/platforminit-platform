#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[CH02-RESET][$(date -u +%FT%TZ)] $*"; }
[[ $EUID -eq 0 ]] || { echo 'Run as root (sudo).' >&2; exit 1; }
log "Stopping and uninstalling existing k3s state if present..."
/usr/local/bin/k3s-uninstall.sh || true
/usr/local/bin/k3s-killall.sh || true
systemctl stop k3s || true
systemctl disable k3s || true
log "Removing stale CH02 and k3s state..."
rm -rf /etc/rancher/k3s \
       /var/lib/rancher/k3s \
       /var/lib/kubelet \
       /var/lib/cni \
       /etc/cni/net.d \
       /run/k3s \
       /srv/k3s \
       /srv/ch02
log "Recreating clean /srv/k3s ..."
install -d -m 0755 /srv/k3s
log "Clean-slate reset complete."
