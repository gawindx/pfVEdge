#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

SERVICES_DIR="$PROJECT_DIR/services"
CONTAINER_DIR="$PROJECT_DIR/container"

IMAGE_PREFIX="qemu-pfsense"
CURRENT_TAG="${IMAGE_PREFIX}:current"

# ==========================================
# CHECK ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run as root"
    exit 1
fi
echo "[INFO] Deploying from $PROJECT_DIR"

# ==========================================
# DEPENDENCIES
# ==========================================

for bin in podman systemctl ip; do
    if ! command -v "$bin" &>/dev/null; then
        echo "[ERROR] Missing dependency: $bin"
        exit 1
    fi
done

# ==========================================
# INITIAL IMAGE BUILD
# ==========================================

echo "[INFO] Checking container image"
if ! podman image exists "$CURRENT_TAG"; then
    echo "[INFO] No image found"
    echo "[INFO] Building initial image"
    podman build \
        -t "$CURRENT_TAG" \
        "$CONTAINER_DIR"
else
    echo "[INFO] Existing image found"
    echo "[INFO] Skipping build"
fi

# ==========================================
# INSTALL SYSTEMD / QUADLET
# ==========================================

echo "[INFO] Installing services"
cp -r "$SERVICES_DIR/etc/"* /etc/

# ==========================================
# PATCH PROJECT PATH
# ==========================================

echo "[INFO] Updating project paths"
grep -rl "__PROJECT_DIR__" \
    /etc/systemd/system \
    /etc/containers/systemd \
    2>/dev/null \
| while read -r file
do
    sed -i \
        "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
        "$file"
done

# ==========================================
# PERMISSIONS
# ==========================================

chmod +x "$PROJECT_DIR/scripts/"*.sh || true

# ==========================================
# SYSTEMD
# ==========================================

systemctl daemon-reload

# ==========================================
# ENABLE UNITS
# ==========================================

echo "[INFO] Enabling units"
find "$SERVICES_DIR/etc/systemd/system" \
    -type f \
    \( ! -name "qemu-pfsense-recovery.service" \
    -name "*.service" -o -name "*.timer" \
    -o -name "*.target" \)\
| while read -r src
do
    unit="$(basename "$src")"
    echo " -> $unit"
    systemctl enable "$unit"
done

echo
echo "===================================="
echo " Deployment completed"
echo "===================================="
echo

podman images | grep "$IMAGE_PREFIX" || true
#TODO ajouter information pour remplir fichier conf
echo
echo "Start:"
echo " systemctl start qemu-pfsense.target"