#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Initialization
# ============================================================

init()
{
    init_paths
    load_core_libraries
    load_user_config
    parse_arguments "$@"
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
    NET_CONF_FILE="$PROJECT_DIR/config/config.json"
    STORAGE_DIR="${PROJECT_DIR}/storage"
    LOG_LEVEL="INFO"

    [[ -d "$STORAGE_DIR" ]] || mkdir -p "$STORAGE_DIR"
}

# ============================================================
# Core libraries
# Must be loaded before argument parsing
# ============================================================

load_core_libraries()
{
    source "$PROJECT_DIR/lib/constants.sh"
    source "$PROJECT_DIR/lib/logging.sh"
    source "$PROJECT_DIR/lib/utils.sh"
    source "$PROJECT_DIR/lib/validation.sh"
    source "$PROJECT_DIR/lib/parser.sh"
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

    if [[ -n "$INPUT_FILE" ]]; then
        NET_CONF_FILE="$INPUT_FILE"
    fi
}

# ============================================================
# Configuration loading
# ============================================================

load_user_config()
{
    if [[ ! -f "$NET_CONF_FILE" ]]; then
        log_error "[Init] Configuration file not found: $NET_CONF_FILE"
        exit "$E_CONFIG"
    fi

    load_json_config "$NET_CONF_FILE"
}

# ============================================================
# Application libraries
# ============================================================

load_application_libraries()
{
    source "$PROJECT_DIR/lib/bridges.sh"
    source "$PROJECT_DIR/lib/ports.sh"
    source "$PROJECT_DIR/lib/taps.sh"
    source "$PROJECT_DIR/lib/networkmanager.sh"
    source "$PROJECT_DIR/lib/firewalld.sh"
    source "$PROJECT_DIR/lib/routing.sh"
}

# ============================================================
# Default values
# ============================================================

set_defaults()
{
    # Common
    BACKUP_DIR=$(trim "${BACKUP_DIR:-/var/lib/pfVEdge}")
    LOG_LEVEL=$(trim "${LOG_LEVEL:-INFO}")
    QEMU_NETWORK_ENV="${QEMU_NETWORK_ENV:-/run/pfVEdge/network.env}"
    INIT_NETWORK="${INIT_NETWORK:-false}"
    INSTALL_MARKER="${STORAGE_DIR}/install-done"

    # Bridges
    BRIDGES_MANAGE_FIREWALL=$(trim "${BRIDGES_MANAGE_FIREWALL:-true}")

    # Network
    NET_INIT="$(trim "${NET_INIT:-false}")"
    NET_STATE_FILE="${BACKUP_DIR}/network.initialised"

    # NetworkManager
    NM_BACKUP_DIR="${BACKUP_DIR}/nmcli"
    NM_BACKUP_FACTORY="${NM_BACKUP_DIR}/factory"
    NM_BACKUP_STABLE="${NM_BACKUP_DIR}/stable"
    NM_BACKUP_TRANSACTION="${NM_BACKUP_DIR}/transaction"
    NM_CONNECTION_DIR="/etc/NetworkManager/system-connections"
    NM_FORCE_FACTORY_BACKUP="${NM_FORCE_FACTORY_BACKUP:-false}"
    NM_HASH_FILE="${NM_BACKUP_DIR}/current.sha256"
    NM_CHECKPOINT_TIMEOUT=300
    NM_CHECKPOINT=""

    # Routes
    # Routing tables reserved for pfVEdge.
    #
    # Table IDs:
    #   10000 - 10999
    #
    # Rule priorities:
    #   20000 - 20999
    #
    ROUTE_TABLE_BASE=10000
    ROUTE_TABLE_SIZE=1000
    ROUTE_RULE_PRIORITY_BASE=20000

    # Firewalld
    FWD_ALLOW_SSH_HOST=$(trim "${FWD_ALLOW_SSH_HOST:-false}")
    FWD_BACKUP_DIR="${BACKUP_DIR}/firewalld"
    FWD_CFG_DIR="/etc/firewalld"
    FWD_TMP_DIR="/run/pfVEdge-firewalld"
    FWD_GW_OFFSET="${FWD_GW_OFFSET:-1}"

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
    validate_config
    log_info "[Init] Configuration validated successfully"
}