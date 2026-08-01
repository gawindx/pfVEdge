#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICES_DIR="$PROJECT_DIR/services"
TARGET_ROOT="/"
IMAGE_PREFIX="qemu-pfsense"

# ==========================================
# CHECK ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run as root"
    exit 1
fi

echo "[INFO] Undeploying from $PROJECT_DIR"

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
# RELOAD USER PROFILE FIREWALLD
# ==========================================

"${PROJECT_DIR}"/scripts/firewalld-profile.sh apply user

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

rm -f /run/qemu-pfsense-restarts 2>/dev/null || true

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

echo ""
echo "===================================="
echo "✅ Undeploy complete"
echo "===================================="