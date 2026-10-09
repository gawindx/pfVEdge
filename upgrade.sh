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
# CONFIGURATION MIGRATION
# Temporary v0.5 compatibility
# Remove in v0.6
# ==========================================

CONFIG_DIR="$PROJECT_DIR/config"
OLD_CONFIG="$CONFIG_DIR/bridges.env"
NEW_CONFIG="$CONFIG_DIR/config.json"

migrate_configuration()
{
    if [[ -f "$NEW_CONFIG" ]]; then
        logger "[INFO] JSON configuration already exists"
        return 0
    fi

    if [[ ! -f "$OLD_CONFIG" ]]; then
        logger "[ERROR] No configuration found"
        logger "[ERROR] Expected either:"
        logger "        $NEW_CONFIG"
        logger "    or  $OLD_CONFIG"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        logger "[ERROR] jq is required to migrate the configuration"
        logger "[INFO] Fedora: dnf install jq"
        return 1
    fi

    logger "[INFO] Migrating legacy configuration"
    logger "       $OLD_CONFIG"
    logger "    -> $NEW_CONFIG"

    local backup_dir
    local log_level
    local net_init
    local nm_auto_migrate
    local nm_force_factory
    local fwd_allow_ssh
    local fwd_gw_offset
    local tap_prefix
    local bridges_networks

    # The legacy configuration is a trusted local shell configuration.
    # shellcheck disable=SC1090
    source "$OLD_CONFIG"

    backup_dir="${BACKUP_DIR:-/var/lib/pfVEdge}"
    log_level="${LOG_LEVEL:-INFO}"
    net_init="${NET_INIT:-false}"
    nm_force_factory="${NM_FORCE_FACTORY_BACKUP:-false}"
    fwd_allow_ssh="${FWD_ALLOW_SSH_HOST:-false}"
    fwd_gw_offset="${FWD_GW_OFFSET:-1}"
    tap_prefix="${TAP_PREFIX:-tap}"
    bridges_networks="${BRIDGES_NETWORKS:-}"

    local tmp_file
    tmp_file="$(mktemp)"

    if ! {
        printf '{\n'
        printf '  "backup_dir": %s,\n' "$(jq -Rn --arg v "$backup_dir" '$v')"
        printf '  "log_level": %s,\n' "$(jq -Rn --arg v "$log_level" '$v')"
        printf '  "network": {\n'
        printf '    "initialize": %s,\n' "$net_init"
        printf '    "network_manager": {\n'
        printf '      "force_factory_backup": %s\n' "$nm_force_factory"
        printf '    },\n'
        printf '    "firewalld": {\n'
        printf '      "allow_ssh_host": %s\n' "$fwd_allow_ssh"
        printf '    },\n'
        printf '    "bridges": {\n'
    } > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    local first=true
    local line
    local bridge
    local iface_type
    local ifaces
    local ipv4
    local role
    local ipv4_addr
    local gateway

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r bridge iface_type ifaces ipv4 role <<< "$line"

        bridge="$(echo "$bridge" | xargs)"
        iface_type="$(echo "$iface_type" | xargs)"
        ifaces="$(echo "$ifaces" | xargs)"
        ipv4="$(echo "$ipv4" | xargs)"
        role="$(echo "$role" | xargs)"

        [[ -z "$bridge" ]] && continue
        bridge="br-$bridge"
        if [[ -z "$role" ]]; then
            role="wan"
        else
            # Remove the legacy VLAN prefix from the role field.
            role="${role##*:}"
            [[ -n "$role" ]] || role="wan"
        fi
        ipv4_addr=""
        gateway=""
        if [[ -n "$ipv4" ]]; then
            if [[ "$ipv4" == "dhcp" ]]; then
                ipv4_addr="dhcp"
            else
                IFS=',' read -r ipv4_addr gateway <<< "$ipv4"
                ipv4_addr="$(echo "$ipv4_addr" | xargs)"
                gateway="$(echo "$gateway" | xargs)"
            fi
        fi
        if [[ "$first" == "false" ]]; then
            printf ',\n' >> "$tmp_file"
        fi
        first=false
        printf '      %s: {\n' \
            "$(jq -Rn --arg v "$bridge" '$v')" >> "$tmp_file"
        printf '        "iface": %s,\n' \
            "$(jq -Rn --arg v "$ifaces" '$v')" >> "$tmp_file"
        if [[ -z "$iface_type" ]]; then
            iface_type="eth"
        fi
        printf '        "iface_type": %s,\n' \
            "$(jq -Rn --arg v "$iface_type" '$v')" >> "$tmp_file"
        if [[ -n "$ipv4_addr" ]]; then
            printf '        "ipv4": %s,\n' \
                "$(jq -Rn --arg v "$ipv4_addr" '$v')" >> "$tmp_file"
        else
            printf '        "ipv4": null,\n' >> "$tmp_file"
        fi
        if [[ -n "$gateway" ]]; then
            printf '        "gateway": %s,\n' \
                "$(jq -Rn --arg v "$gateway" '$v')" >> "$tmp_file"
        fi
        printf '        "role": %s\n' \
            "$(jq -Rn --arg v "$role" '$v')" >> "$tmp_file"
        printf '      }' >> "$tmp_file"
    done <<< "$bridges_networks"

    {
        printf '\n'
        printf '    },\n'
        printf '    "gateway_offset": %s,\n' "$fwd_gw_offset"
        printf '    "tap_prefix": %s\n' \
            "$(jq -Rn --arg v "$tap_prefix" '$v')"
        printf '  }\n'
        printf '}\n'
    } >> "$tmp_file"

    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        logger "[ERROR] Generated configuration is invalid"
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$NEW_CONFIG"
    logger "[INFO] Configuration migration completed"
}

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

for command in podman systemctl jq find sha256sum sort cut; do
    if ! command -v "$command" >/dev/null 2>&1; then
        logger "[ERROR] Missing dependency: $command"
        exit 1
    fi
done

logger "[INFO] Starting upgrade"

migrate_configuration

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

logger "[INFO] Restarting pfVEdge stack"

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
