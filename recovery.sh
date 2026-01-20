#!/usr/bin/env bash
# ==============================================================================
# Script de Restauración de Baseline (Ubuntu)
# Descripción: Automatiza la reinstalación de paquetes y restauración de 
#              configuraciones críticas (Red, Firewall, Samba, SSH).
# ==============================================================================

set -euo pipefail

# --- Configuración ---
# Puedes sobrescribir estas variables desde el entorno
BACKUP_DIR="${BACKUP_DIR:-/opt/ubuntu-baseline-RESTORE}"
PURGE_SNAPD="${PURGE_SNAPD:-false}"               # true/false
DISABLE_CLOUD_INIT="${DISABLE_CLOUD_INIT:-auto}"  # auto/true/false

LOG="$BACKUP_DIR/restore.log"

# Asegurar que los archivos creados tengan permisos restringidos
umask 077

# Redirigir salida a log y pantalla
exec > >(tee -a "$LOG") 2>&1

echo "[*] Iniciando restauración desde: $BACKUP_DIR"

# 0) Pre-chequeos y actualización de índices
if [ ! -f /etc/os-release ]; then
  echo "[!] Error: Sistema operativo no soportado."
  exit 1
fi
. /etc/os-release
echo "[*] Sistema detectado: $PRETTY_NAME"

apt-get update

# 1) Restaurar selecciones de Debconf (Configuraciones de paquetes)
if [ -f "$BACKUP_DIR/debconf.selections.txt" ]; then
  echo "[*] Aplicando selecciones de debconf..."
  apt-get install -y debconf-utils
  debconf-set-selections < "$BACKUP_DIR/debconf.selections.txt"
fi

# 2) Reinstalar paquetes (Manuales y selecciones de dpkg)
if [ -f "$BACKUP_DIR/apt.manual.txt" ]; then
  echo "[*] Instalando paquetes marcados manualmente..."
  xargs -a "$BACKUP_DIR/apt.manual.txt" -r apt-get install -y
fi

if [ -f "$BACKUP_DIR/dpkg.selections.txt" ]; then
  echo "[*] Restaurando selecciones completas de dpkg..."
  dpkg --set-selections < "$BACKUP_DIR/dpkg.selections.txt"
  apt-get -y dselect-upgrade
fi

# 3) Restaurar configuraciones de sistema

# Netplan (Red)
if [ -d "$BACKUP_DIR/configs/netplan" ]; then
  echo "[*] Restaurando configuración de red (Netplan)..."
  mkdir -p /etc/netplan
  cp -a "$BACKUP_DIR/configs/netplan/"*.yaml /etc/netplan/ 2>/dev/null || true
  netplan apply || true
fi

# UFW (Firewall)
if [ -d "$BACKUP_DIR/configs/ufw" ]; then
  echo "[*] Restaurando reglas de UFW..."
  systemctl stop ufw || true
  rsync -a "$BACKUP_DIR/configs/ufw/" /etc/ufw/
  systemctl start ufw || true
  ufw reload || true
  ufw enable || true
fi

# Samba (Archivos compartidos y base de datos de usuarios TDB)
if [ -f "$BACKUP_DIR/configs/samba/smb.conf" ]; then
  echo "[*] Restaurando Samba y bases de datos TDB..."
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

# mdadm (RAID), fstab (Montajes) y SSH
echo "[*] Restaurando archivos de sistema (mdadm, fstab, ssh)..."
[ -f "$BACKUP_DIR/configs/mdadm.conf" ] && install -D -m 0644 "$BACKUP_DIR/configs/mdadm.conf" /etc/mdadm/mdadm.conf || true
[ -f "$BACKUP_DIR/configs/fstab" ] && install -D -m 0644 "$BACKUP_DIR/configs/fstab" /etc/fstab || true

if [ -d "$BACKUP_DIR/configs/ssh" ]; then
  rsync -a "$BACKUP_DIR/configs/ssh/" /etc/ssh/
  systemctl restart ssh || true
fi

# Descubrimiento en red (Avahi/WSDD)
MARKERS="$BACKUP_DIR/restore.vars"
if [ -f "$MARKERS" ]; then
  . "$MARKERS"
  if [ "${HAS_AVAHI:-0}" = "1" ]; then
    echo "[*] Instalando y configurando Avahi..."
    apt-get install -y avahi-daemon
    [ -d "$BACKUP_DIR/configs/avahi" ] && rsync -a "$BACKUP_DIR/configs/avahi/" /etc/avahi/
    systemctl enable --now avahi-daemon || true
  fi
  if [ "${HAS_WSDD:-0}" = "1" ]; then
    echo "[*] Instalando y configurando WSDD..."
    apt-get install -y wsdd
    systemctl enable --now wsdd || true
  fi
fi

# cloud-init (Opcional: Desactivar si se detecta marcador)
if [ "$DISABLE_CLOUD_INIT" = "true" ] || { [ "$DISABLE_CLOUD_INIT" = "auto" ] && [ -f "$MARKERS" ] && grep -q CLOUD_INIT_DISABLED=1 "$MARKERS"; }; then
  echo "[*] Desactivando cloud-init..."
  mkdir -p /etc/cloud
  touch /etc/cloud/cloud-init.disabled
fi

# 4) Limpieza de Snap (Si se solicita)
if [ "$PURGE_SNAPD" = "true" ] && command -v snap >/dev/null 2>&1; then
  echo "[*] Eliminando paquetes Snap y snapd..."
  if [ -f "$BACKUP_DIR/snap.list.txt" ]; then
    awk 'NR>1 {print $1}' "$BACKUP_DIR/snap.list.txt" | xargs -r -n1 snap remove --purge || true
  fi
  apt-get purge -y snapd || true
  rm -rf /var/cache/snapd /snap ~/snap 2>/dev/null || true
fi

# 5) Limpieza final de APT
echo "[*] Finalizando: Autoremove y limpieza de caché..."
apt-get -y autoremove --purge || true
apt-get -y clean || true

echo "[*] RESTAURACIÓN COMPLETADA."
echo "[!] Se recomienda reiniciar el sistema y verificar los servicios."