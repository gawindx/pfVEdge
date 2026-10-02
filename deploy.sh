#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIG
# ==========================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

SERVICES_DIR="$PROJECT_DIR/services"
CONTAINER_DIR="$PROJECT_DIR/container"

IMAGE_PREFIX="pfvedge"
CURRENT_TAG="${IMAGE_PREFIX}:current"

# ==========================================
# LOGGING
# ==========================================

log_info()
{
    echo "[INFO] $*"
}

log_error()
{
    echo "[ERROR] $*" >&2
}

# ==========================================
# ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    log_error "Run as root"
    exit 1
fi

log_info "Deploying from $PROJECT_DIR"

# ==========================================
# PREREQUISITES
# ==========================================

check_prerequisites()
{
    local missing=()
    local command

    local required_commands=(
        podman
        systemctl
        nmcli
        ip
        bridge
        firewall-cmd
        jq
        ss
        sshd
        sysctl
    )

    for command in "${required_commands[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            missing+=("$command")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log_info "Prerequisites OK"
        return 0
    fi

    log_error "Missing required dependencies:"

    local item
    for item in "${missing[@]}"; do
        log_error "  - $item"
    done

    echo
    log_info "On Fedora, the corresponding packages are usually:"
    log_info "  dnf install podman systemd NetworkManager iproute"
    log_info "  dnf install bridge-utils firewalld jq iproute openssh-clients"

    return 1
}

check_prerequisites

# ==========================================
# CONFIGURATION
# ==========================================

CONFIG_FILE="$PROJECT_DIR/config/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_error "Create it from config/config.json.example"
    exit 1
fi

if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    log_error "Invalid JSON configuration: $CONFIG_FILE"
    exit 1
fi

log_info "Configuration OK"

# ==========================================
# ENSURE override.env EXISTS
# ==========================================

OVERRIDE_ENV="$PROJECT_DIR/config/pfVEdge.override.env"

[[ -f "$OVERRIDE_ENV" ]] || touch "$OVERRIDE_ENV"

# ==========================================
# INITIAL IMAGE BUILD
# ==========================================

log_info "Checking container image"

if ! podman image exists "$CURRENT_TAG"; then
    log_info "No image found"
    log_info "Building initial image"

    podman build \
        -t "$CURRENT_TAG" \
        "$CONTAINER_DIR"
else
    log_info "Existing image found"
    log_info "Skipping build"
fi

# ==========================================
# INSTALL SYSTEMD / QUADLET
# ==========================================

log_info "Installing services"

cp -r "$SERVICES_DIR/etc/"* /etc/

# ==========================================
# PATCH PROJECT PATH
# ==========================================

log_info "Updating project paths"

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

log_info "Enabling units"

find "$SERVICES_DIR/etc/systemd/system" \
    -type f \
    \( ! -name "pfVEdge-recovery.service" \
    ! -name "DelayedStart@.timer" \
    -name "*.service" -o -name "*.timer" \
    -o -name "*.target" \) \
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

echo
echo "Start:"
echo " systemctl start pfVEdge.target"