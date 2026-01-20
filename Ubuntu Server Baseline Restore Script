#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/ubuntu-baseline-RESTORE}"
PURGE_SNAPD="${PURGE_SNAPD:-false}"
DISABLE_CLOUD_INIT="${DISABLE_CLOUD_INIT:-auto}"

LOG="$BACKUP_DIR/restore.log"
umask 077
exec > >(tee -a "$LOG") 2>&1

echo "[*] Restaurando desde $BACKUP_DIR"

if [ ! -f /etc/os-release ]; then
  echo "Sistema no soportado"
  exit 1
fi
. /etc/os-release
echo "OS: $PRETTY_NAME"

apt-get update

if [ -f "$BACKUP_DIR/debconf.selections.txt" ]; then
  apt-get install -y debconf-utils
  debconf-set-selections < "$BACKUP_DIR/debconf.selections.txt"
fi

if [ -f "$BACKUP_DIR/apt.manual.txt" ]; then
  xargs -a "$BACKUP_DIR/apt.manual.txt" -r apt-get install -y
fi

if [ -f "$BACKUP_DIR/dpkg.selections.txt" ]; then
  dpkg --set-selections < "$BACKUP_DIR/dpkg.selections.txt"
  apt-get -y dselect-upgrade
fi

if [ -d "$BACKUP_DIR/configs/netplan" ]; then
  mkdir -p /etc/netplan
  cp -a "$BACKUP_DIR/configs/netplan/"*.yaml /etc/netplan/ 2>/dev/null || true
  netplan apply || true
fi

if [ -d "$BACKUP_DIR/configs/ufw" ]; then
  systemctl stop ufw || true
  rsync -a "$BACKUP_DIR/configs/ufw/" /etc/ufw/
  systemctl start ufw || true
  ufw reload || true
  ufw enable || true
fi

if [ -f "$BACKUP_DIR/configs/samba/smb.conf" ]; then
  apt-get install -y samba tdb-tools
  systemctl stop smbd nmbd winbind || true
  install -D -m 0644 "$BACKUP_DIR/configs/samba/smb.conf" /etc/samba/smb.conf
  if compgen -G "$BACKUP_DIR/samba-tdb/*.tdb" > /dev/null; then
    tdbbackup -v -r "$BACKUP_DIR/samba-tdb/"*.tdb -s /var/lib/samba/ || true
    tdbbackup -v -r "$BACKUP_DIR/samba-tdb/"*.tdb -s /var/lib/samba/private/ || true
  fi
  systemctl start smbd nmbd winbind || true
  systemctl enable smbd nmbd winbind || true
fi

[ -f "$BACKUP_DIR/configs/mdadm.conf" ] && install -D -m 0644 "$BACKUP_DIR/configs/mdadm.conf" /etc/mdadm/mdadm.conf || true
[ -f "$BACKUP_DIR/configs/fstab" ] && install -D -m 0644 "$BACKUP_DIR/configs/fstab" /etc/fstab || true
if [ -d "$BACKUP_DIR/configs/ssh" ]; then
  rsync -a "$BACKUP_DIR/configs/ssh/" /etc/ssh/
  systemctl restart ssh || true
fi

MARKERS="$BACKUP_DIR/restore.vars"
if [ -f "$MARKERS" ]; then
  . "$MARKERS"
  if [ "${HAS_AVAHI:-0}" = "1" ]; then
    apt-get install -y avahi-daemon
    [ -d "$BACKUP_DIR/configs/avahi" ] && rsync -a "$BACKUP_DIR/configs/avahi/" /etc/avahi/
    systemctl enable --now avahi-daemon || true
  fi
  if [ "${HAS_WSDD:-0}" = "1" ]; then
    apt-get install -y wsdd
    systemctl enable --now wsdd || true
  fi
fi

if [ "$DISABLE_CLOUD_INIT" = "true" ] || { [ "$DISABLE_CLOUD_INIT" = "auto" ] && [ -f "$BACKUP_DIR/restore.vars" ] && grep -q CLOUD_INIT_DISABLED=1 "$BACKUP_DIR/restore.vars"; }; then
  mkdir -p /etc/cloud
  touch /etc/cloud/cloud-init.disabled
fi

if [ "$PURGE_SNAPD" = "true" ] && command -v snap >/dev/null 2>&1; then
  if [ -f "$BACKUP_DIR/snap.list.txt" ]; then
    awk 'NR>1 {print $1}' "$BACKUP_DIR/snap.list.txt" | xargs -r -n1 snap remove --purge || true
  fi
  apt-get purge -y snapd || true
  rm -rf /var/cache/snapd /snap ~/snap 2>/dev/null || true
fi

apt-get -y autoremove --purge || true
apt-get -y clean || true

echo "[*] Restore completado"
