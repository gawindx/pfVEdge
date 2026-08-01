#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Initialization
# ============================================================

init()
{
    init_paths
    load_core_libraries
    parse_arguments "$@"
    load_user_config
    load_application_libraries
    set_defaults
    prepare_environment
}

# ============================================================
# Paths
# ============================================================

init_paths()
{
    BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_DIR="$(cd "$BASE_DIR/.." && pwd)"

    INPUT_FILE=""
    NET_CONF_FILE=""
    NET_CONF_FILE="$PROJECT_DIR/config/bridges.env"
}

# ============================================================
# Core libraries
# Must be loaded before argument parsing
# ============================================================

load_core_libraries()
{
    source "$PROJECT_DIR/lib/constants.sh"
    source "$PROJECT_DIR/lib/logging.sh"
}

# ============================================================
# Arguments handling
# ============================================================

parse_arguments()
{
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input)
                shift
                if [[ $# -eq 0 ]]; then
                    log_error "[Init] Missing value for -i/--input"
                    exit 1
                fi
                INPUT_FILE="$1"
                ;;
            *)
                log_warn "[Init] Unknown argument: $1"
                ;;
        esac
        shift
    done
}

# ============================================================
# Configuration loading
# ============================================================

load_user_config()
{
    if [[ -f "$NET_CONF_FILE" ]]; then
        source <(sed 's/\r$//' "$NET_CONF_FILE")
    else
        log_warn "[Init] Configuration file not found: $NET_CONF_FILE"
    fi
}

# ============================================================
# Application libraries
# ============================================================

load_application_libraries()
{
    source "$PROJECT_DIR/lib/utils.sh"
    source "$PROJECT_DIR/lib/parser.sh"
    source "$PROJECT_DIR/lib/validation.sh"
    source "$PROJECT_DIR/lib/bridges.sh"
    source "$PROJECT_DIR/lib/ports.sh"
    source "$PROJECT_DIR/lib/taps.sh"
    source "$PROJECT_DIR/lib/networkmanager.sh"
    source "$PROJECT_DIR/lib/firewalld.sh"
}

# ============================================================
# Default values
# ============================================================

set_defaults()
{
    # Common
    BACKUP_DIR=$(trim "${BACKUP_DIR:-/var/lib/qemu-pfsense}")
    LOG_LEVEL=$(trim "${LOG_LEVEL:-INFO}")
    QEMU_NETWORK_ENV="${QEMU_NETWORK_ENV:-/run/qemu-pfsense/network.env}"

    # Bridges
    BRIDGES_NETWORKS=$(trim "${BRIDGES_NETWORKS:-}")
    BRIDGES_MANAGE_FIREWALL=$(trim "${BRIDGES_MANAGE_FIREWALL:-true}")

    # NetworkManager
    NM_AUTO_MIGRATE_IFACE=$(trim "${NM_AUTO_MIGRATE_IFACE:-false}")
    NM_BACKUP_DIR="${BACKUP_DIR}/nmcli"
    NM_BACKUP_FACTORY="${NM_BACKUP_DIR}/factory"
    NM_BACKUP_STABLE="${NM_BACKUP_DIR}/stable"
    NM_BACKUP_TRANSACTION="${NM_BACKUP_DIR}/transaction"
    NM_CONNECTION_DIR="/etc/NetworkManager/system-connections"
    NM_FORCE_FACTORY_BACKUP="${NM_FORCE_FACTORY_BACKUP:-false}"
    NM_HASH_FILE="${NM_BACKUP_DIR}/current.sha256"

    # Firewalld
    FWD_ALLOW_SSH_HOST=$(trim "${FWD_ALLOW_SSH_HOST:-false}")
    FWD_BACKUP_DIR="${BACKUP_DIR}/firewalld"
    FWD_CFG_DIR="/etc/firewalld"
    FWD_TMP_DIR="/run/qemu-pfsense-firewalld"

    # Taps    
    TAP_IFACES=""
    TAP_PREFIX="${TAP_PREFIX:-tap}"
}

prepare_environment()
{
    # ============================================================
    # Validate + parse
    # ============================================================

    validate_environment
    parse_networks "$BRIDGES_NETWORKS"
    validate_bridges
    validate_taps
    log_info "[Init] Environment Validated successfuly"
}