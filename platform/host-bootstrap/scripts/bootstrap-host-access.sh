#!/usr/bin/env bash
set -euo pipefail
AUTOMATION_SSH_PUBLIC_KEY="${AUTOMATION_SSH_PUBLIC_KEY:-}"
if [[ -z "$AUTOMATION_SSH_PUBLIC_KEY" ]]; then
  echo "Missing AUTOMATION_SSH_PUBLIC_KEY" >&2
  exit 1
fi
BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
LEGACY_AUDIT_DIR="/var/lib/platforminit/audit"
init_audit_dirs(){
  mkdir -p "$BOOTSTRAP_AUDIT_DIR"
  mkdir -p "$(dirname "$LEGACY_AUDIT_DIR")"
  if [[ "$BOOTSTRAP_AUDIT_DIR" != "$LEGACY_AUDIT_DIR" ]]; then
    rm -rf "$LEGACY_AUDIT_DIR"
    ln -sfn "$BOOTSTRAP_AUDIT_DIR" "$LEGACY_AUDIT_DIR"
  fi
}
log(){ echo "[BOOTSTRAP][$(date -u +%FT%TZ)] $*"; }
audit(){ printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s"}
' "$(date -u +%FT%TZ)" "$1" "${2:-ok}" "${3:-}" >> "$BOOTSTRAP_AUDIT_DIR/security.log"; }
create_user(){ local u="$1"; id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"; }
install_key(){ local u="$1"; local h; h="$(getent passwd "$u" | cut -d: -f6)"; install -d -m 700 -o "$u" -g "$u" "$h/.ssh"; printf '%s
' "$AUTOMATION_SSH_PUBLIC_KEY" > "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"; chown -R "$u:$u" "$h/.ssh"; }
load_host_context(){
  if [[ -f /etc/platforminit/host-context.env ]]; then
    # shellcheck disable=SC1091
    source /etc/platforminit/host-context.env
  fi
  PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
  PLATFORMINIT_SRV_PATH="${PLATFORMINIT_SRV_PATH:-/srv}"
  PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
  PLATFORMINIT_DB_PATH="${PLATFORMINIT_DB_PATH:-/srv/db}"
  PLATFORMINIT_OBSERVABILITY_PATH="${PLATFORMINIT_OBSERVABILITY_PATH:-/srv/observability}"
}
mount_volume_by_id(){
  local role="$1" volume_id="$2" mount_path="$3" device="/dev/disk/by-id/scsi-0HC_Volume_${volume_id}" uuid
  if mountpoint -q "$mount_path"; then log "${mount_path} already mounted"; return 0; fi
  if [[ ! -e "$device" ]]; then log "Volume device missing for ${role}: ${device}"; audit "volume_mount_probe" "warn" "role=${role} device_missing=${device}"; return 0; fi
  if ! blkid "$device" >/dev/null 2>&1; then mkfs.ext4 -F "$device"; fi
  uuid="$(blkid -s UUID -o value "$device")"
  mkdir -p "$mount_path"
  grep -qE "^[^#].+[[:space:]]+${mount_path//\//\/}[[:space:]]+" /etc/fstab || echo "UUID=${uuid} ${mount_path} ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "$mount_path"
  audit "volume_mount_ready" "ok" "role=${role} device=${device} mount=${mount_path}"
}
ensure_srv_mount(){
  load_host_context
  if [[ -s /etc/platforminit/volume-layout.tsv ]]; then
    while IFS=$'\t' read -r role volume_id _name mount_path; do
      [[ -n "${role:-}" && -n "${volume_id:-}" && -n "${mount_path:-}" ]] || continue
      mount_volume_by_id "$role" "$volume_id" "$mount_path"
    done < /etc/platforminit/volume-layout.tsv
    init_audit_dirs
    return 0
  fi

  if mountpoint -q /srv; then log "/srv already mounted"; return 0; fi
  local root_source root_parent candidate uuid
  root_source="$(findmnt -n -o SOURCE / || true)"
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  candidate="$(lsblk -pnro NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" {print $1}' | grep -v "/dev/${root_parent}$" | head -n1 || true)"
  if [[ -z "$candidate" ]]; then log "No extra block device detected for /srv mount"; audit "srv_mount_probe" "warn" "no extra block device detected"; return 0; fi
  if ! blkid "$candidate" >/dev/null 2>&1; then mkfs.ext4 -F "$candidate"; fi
  uuid="$(blkid -s UUID -o value "$candidate")"
  mkdir -p /srv
  grep -qE '^[^#].+[[:space:]]+/srv[[:space:]]+' /etc/fstab || echo "UUID=${uuid} /srv ext4 defaults,nofail 0 2" >> /etc/fstab
  mount /srv
  init_audit_dirs
  audit "srv_mount_ready" "ok" "device=${candidate}"
}
install_helpers(){ install -d -m 755 /usr/local/lib/platforminit /usr/local/sbin "$BOOTSTRAP_AUDIT_DIR"; install -m 644 /tmp/platforminit-lib-policy.sh /usr/local/lib/platforminit/lib-policy.sh; install -m 755 /tmp/platforminit-grant-temporary-sudo.sh /usr/local/sbin/platforminit-grant-sudo; install -m 755 /tmp/platforminit-sync-host-access.sh /usr/local/sbin/platforminit-sync-host-access; }
install_broker_policy(){ cat > /etc/sudoers.d/itadmin-platforminit <<'EOFSUDO'
itadmin ALL=(root) NOPASSWD: /usr/local/sbin/platforminit-grant-sudo *
itadmin ALL=(root) NOPASSWD: /usr/local/sbin/platforminit-sync-host-access *
EOFSUDO
chmod 440 /etc/sudoers.d/itadmin-platforminit
visudo -cf /etc/sudoers.d/itadmin-platforminit >/dev/null; }
remove_standing_sudo(){ rm -f /etc/sudoers.d/devops /etc/sudoers.d/itadmin /etc/sudoers.d/devops-temp /etc/sudoers.d/devops-temporary /etc/sudoers.d/devops-elevation /etc/sudoers.d/itadmin-temporary || true; }
harden_ssh(){ install -d -m 755 /etc/ssh/sshd_config.d; cat > /etc/ssh/sshd_config.d/99-platforminit-hardening.conf <<'EOFSSH'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOFSSH
sshd -t
systemctl restart ssh || systemctl restart sshd; }
write_audit_marker(){ cat > "$BOOTSTRAP_AUDIT_DIR/bootstrap-host-access.json" <<EOFJSON
{
  "timestamp": "$(date -u +%FT%TZ)",
  "event": "host_bootstrap_completed",
  "users": ["devops", "itadmin"]
}
EOFJSON
audit "host_bootstrap_completed" "ok" "users=devops,itadmin"; }
main(){ init_audit_dirs; ensure_srv_mount; init_audit_dirs; create_user devops; create_user itadmin; install_key devops; install_key itadmin; usermod -aG sudo devops; usermod -aG sudo itadmin; install_helpers; install_broker_policy; remove_standing_sudo; harden_ssh; write_audit_marker; }
main "$@"
