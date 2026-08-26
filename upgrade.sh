#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_DIR="$PROJECT_DIR/container"
IMAGE_PREFIX="pfvedge"
CURRENT_TAG="${IMAGE_PREFIX}:current"
BACKUP_FILE="/run/pfVEdge.previous"
LOG_FILE="$PROJECT_DIR/upgrade.log"

# ==========================================
# LOGGING
# ==========================================

> "$LOG_FILE"

logger() {
    local MESSAGE="$1"
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    local LOG_LINE="[$TIMESTAMP] $MESSAGE"

    # append to log file and display on console
    echo "$LOG_LINE" | tee -a "$LOG_FILE"
}

# ==========================================
# ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    logger "[ERROR] Run as root"
    exit 1
fi

logger "[INFO] Starting upgrade"

# ==========================================
# BUILD HASH
# ==========================================

logger "[INFO] Computing build hash"

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

logger "[INFO] Build tag:"
logger "       $BUILD_TAG"

# ==========================================
# SAVE CURRENT IMAGE
# ==========================================

logger "[INFO] Saving current image"

if podman image exists "$CURRENT_TAG"
then
    PREVIOUS_TAG=$(
        podman image inspect "$CURRENT_TAG" \
        --format '{{index .RepoTags 0}}'
    )
    logger "$PREVIOUS_TAG" > "$BACKUP_FILE"
else
    logger "" > "$BACKUP_FILE"
fi

# ==========================================
# BUILD IF REQUIRED
# ==========================================

if podman image exists "$BUILD_TAG"
then
    logger "[INFO] Existing build found"
    logger "[INFO] No rebuild required"
else
    logger "[INFO] Building new image"
    logger "$( podman build \
        -t "$BUILD_TAG" \
        "$CONTAINER_DIR" )"
fi

# ==========================================
# SWITCH CURRENT
# ==========================================

logger "[INFO] Updating current image"

logger "$( podman tag \
    "$BUILD_TAG" \
    "$CURRENT_TAG" )"

# ==========================================
# DEPLOY INFRA
# ==========================================

logger "$( ${PROJECT_DIR}/deploy.sh )"

# ==========================================
# RESTART STACK
# ==========================================

logger "[INFO] Restarting pfSense stack"

systemctl restart pfVEdge.target || true

# ==========================================
# VALIDATION
# ==========================================

logger "[INFO] Validating"

logger "$( ./scripts/validate-full-stack.sh --mode full --timeout 180 --quiet )"
rc=$?

if (( rc >= 2 )); then
    # ==========================================
    # ROLLBACK
    # ==========================================

    logger ""
    logger "[ERROR] Validation failed"
    logger "[INFO] Rolling back"

    if [[ -s "$BACKUP_FILE" ]]
    then
        PREVIOUS_TAG=$(cat "$BACKUP_FILE")
        podman tag \
            "$PREVIOUS_TAG" \
            "$CURRENT_TAG"
        systemctl restart pfVEdge.target
        logger "[INFO] Rollback completed"
    else
        logger "[ERROR] No rollback image available"
    fi
    exit 1
elif (( rc == 1 )); then
    logger "[WARN] Upgrade Finished with warnings - Check log"
else
    logger "[INFO]] Upgrade Ok"
fi

logger ""
logger "================================"
logger " Upgrade successful"
logger "================================"
logger "[INFO] Cleaning old builds"

logger "$( podman images \
    --format "{{.Repository}}:{{.Tag}}" \
| grep "^${IMAGE_PREFIX}:build-" \
| sort -r \
| tail -n +4 \
| xargs -r podman rmi || true )"
exit 0
