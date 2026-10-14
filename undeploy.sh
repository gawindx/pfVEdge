#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICES_DIR="$PROJECT_DIR/services"
TARGET_ROOT="/"
IMAGE_PREFIX="pfVEdge"

# ==========================================
# CHECK ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run as root"
    exit 1
fi

echo "[INFO] Undeploying from $PROJECT_DIR"

# ==========================================
# LOAD RESTORE FUNCTIONS
# ==========================================

LOG_LEVEL="INFO"

BACKUP_DIR="/var/lib/pfVEdge"
if command -v jq >/dev/null 2>&1 &&
   [[ -f "${PROJECT_DIR}/config/config.json" ]]; then
    BACKUP_DIR="$(jq -r '.backup_dir // "/var/lib/pfVEdge"' \
        "${PROJECT_DIR}/config/config.json" 2>/dev/null)" ||
        BACKUP_DIR="/var/lib/pfVEdge"
fi

NM_BACKUP_DIR="${BACKUP_DIR}/nmcli-factory"
NM_CONNECTION_DIR="/etc/NetworkManager/system-connections"

FWD_FACTORY_BACKUP_DIR="${BACKUP_DIR}/firewalld-factory"
FWD_CFG_DIR="/etc/firewalld"

source "${PROJECT_DIR}/lib/logging.sh"
source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/networkmanager.sh"
source "${PROJECT_DIR}/lib/firewalld.sh"

# ==========================================
# STOP + DISABLE ALL UNITS (DYNAMIC)
# ==========================================

echo "[INFO] Stopping and disabling services"

find "$SERVICES_DIR/etc/systemd/system" -type f \( -name "*.service" -o -name "*.timer" \) | while read -r src; do
    unit="$(basename "$src")"

    echo "→ stop $unit"
    systemctl stop "$unit" 2>/dev/null || true

    echo "→ disable $unit"
    systemctl disable "$unit" 2>/dev/null || true
done

# ==========================================
# REMOVE FILES (DECLARATIVE MATCH)
# ==========================================

echo "[INFO] Removing installed files"

find "$SERVICES_DIR/etc" -type f | while read -r file; do
    relative="${file#$SERVICES_DIR}"
    target="$TARGET_ROOT/$relative"

    if [[ -f "$target" ]]; then
        echo "→ remove $target"
        rm -f "$target"
    else
        echo "→ skip (not found): $target"
    fi
done

# ==========================================
# RESTORE FACTORY CONFIGURATION
# ==========================================

RESTORE_FAILED=false

echo "[INFO] Restoring NetworkManager factory configuration"
if ! nm_restore_backup_factory; then
    echo "[ERROR] NetworkManager factory restoration failed" >&2
    RESTORE_FAILED=true
fi

echo "[INFO] Restoring firewalld factory configuration"
if ! fwd_restore_backup_factory; then
    echo "[ERROR] firewalld factory restoration failed" >&2
    RESTORE_FAILED=true
fi

# ==========================================
# RELOAD SYSTEMD
# ==========================================

echo "[INFO] Reloading systemd"

systemctl daemon-reload

# ==========================================
# CLEAN TAP INTERFACES
# ==========================================

echo "[INFO] Cleaning TAP interfaces"

ip link | grep -o 'tap-[^:]+' | while read -r tap; do
    ip link del "$tap" 2>/dev/null || true
done

# ==========================================
# CLEAN STATE FILES
# ==========================================

rm -f /run/pfVEdge-restarts 2>/dev/null || true

# ==========================================
# REMOVE IMAGES (OPTIONAL BUT CLEAN)
# ==========================================

echo "[INFO] Removing container images"

podman images --format "{{.Repository}}:{{.Tag}}" \
| grep "^$IMAGE_PREFIX:" \
| xargs -r podman rmi || true

# ==========================================
# DONE
# ==========================================

if [[ "$RESTORE_FAILED" == "true" ]]; then
    echo "[ERROR] Undeploy completed with restoration errors" >&2
    exit 1
fi

echo ""
echo "===================================="
echo "✅ Undeploy complete"
echo "===================================="