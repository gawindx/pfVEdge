#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_DIR="$PROJECT_DIR/container"
IMAGE_PREFIX="qemu-pfsense"
CURRENT_TAG="${IMAGE_PREFIX}:current"
BACKUP_FILE="/run/qemu-pfsense.previous"

# ==========================================
# ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run as root"
    exit 1
fi

echo "[INFO] Starting upgrade"

# ==========================================
# BUILD HASH
# ==========================================

echo "[INFO] Computing build hash"

IMAGE_HASH=$(
    find "$CONTAINER_DIR" \
        -type f \
        -not -path "*/.git/*" \
        -exec sha256sum {} \; \
    | sort \
    | sha256sum \
    | cut -c1-8
)

BUILD_TAG="${IMAGE_PREFIX}:build-${IMAGE_HASH}"

echo "[INFO] Build tag:"
echo "       $BUILD_TAG"

# ==========================================
# SAVE CURRENT IMAGE
# ==========================================

echo "[INFO] Saving current image"

if podman image exists "$CURRENT_TAG"
then
    PREVIOUS_TAG=$(
        podman image inspect "$CURRENT_TAG" \
        --format '{{index .RepoTags 0}}'
    )
    echo "$PREVIOUS_TAG" > "$BACKUP_FILE"
else
    echo "" > "$BACKUP_FILE"
fi

# ==========================================
# BUILD IF REQUIRED
# ==========================================

if podman image exists "$BUILD_TAG"
then
    echo "[INFO] Existing build found"
    echo "[INFO] No rebuild required"
else
    echo "[INFO] Building new image"
    podman build \
        -t "$BUILD_TAG" \
        "$CONTAINER_DIR"
fi

# ==========================================
# SWITCH CURRENT
# ==========================================

echo "[INFO] Updating current image"

podman tag \
    "$BUILD_TAG" \
    "$CURRENT_TAG"

# ==========================================
# DEPLOY INFRA
# ==========================================

"$PROJECT_DIR/deploy.sh"

# ==========================================
# RESTART STACK
# ==========================================

echo "[INFO] Restarting pfSense stack"

systemctl stop qemu-pfsense.target || true
systemctl start qemu-pfsense.target

# ==========================================
# VALIDATION
# ==========================================

echo "[INFO] Validating"

./scripts/validate-full-stack.sh --mode full --timeout 180 --quiet
rc=$?

if (( rc >= 2 )); then
    # ==========================================
    # ROLLBACK
    # ==========================================

    echo
    echo "[ERROR] Validation failed"
    echo "[INFO] Rolling back"

    if [[ -s "$BACKUP_FILE" ]]
    then
        PREVIOUS_TAG=$(cat "$BACKUP_FILE")
        podman tag \
            "$PREVIOUS_TAG" \
            "$CURRENT_TAG"
        systemctl restart qemu-pfsense.target
        echo "[INFO] Rollback completed"
    else
        echo "[ERROR] No rollback image available"
    fi
    exit 1
elif (( rc == 1 )); then
    echo "[WARN] Upgrade Finished with warnings - Check log"
else
    echo "[INFO]] Upgrade Ok"
fi

echo
echo "================================"
echo " Upgrade successful"
echo "================================"
echo "[INFO] Cleaning old builds"

podman images \
    --format "{{.Repository}}:{{.Tag}}" \
| grep "^${IMAGE_PREFIX}:build-" \
| sort -r \
| tail -n +4 \
| xargs -r podman rmi || true
exit 0