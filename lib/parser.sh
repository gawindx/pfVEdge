#!/usr/bin/env bash

# ============================================================
# Load JSON configuration
# ============================================================

load_json_config()
{
    local config_file="$1"

    if ! command -v jq >/dev/null 2>&1; then
        log_error "[Parser] jq is required to load the JSON configuration"
        exit "$E_CONFIG"
    fi

    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log_error "[Parser] Invalid JSON configuration: $config_file"
        exit "$E_CONFIG"
    fi

    log_debug "[Parser] Loading configuration: $config_file"

    FIREWALL=$(jq -r '.firewall // empty' "$config_file")
    BACKUP_DIR=$(jq -r '.backup_dir // empty' "$config_file")
    LOG_LEVEL=$(jq -r '.log_level // empty' "$config_file")

    NET_INIT=$(jq -r '.network.initialize // empty' "$config_file")

    NM_AUTO_MIGRATE_IFACE=$(
        jq -r '.network.network_manager.auto_migrate_interface // empty' \
            "$config_file"
    )

    NM_FORCE_FACTORY_BACKUP=$(
        jq -r '.network.network_manager.force_factory_backup // empty' \
            "$config_file"
    )

    FWD_ALLOW_SSH_HOST=$(
        jq -r '.network.firewalld.allow_ssh_host // empty' \
            "$config_file"
    )

    FWD_GW_OFFSET=$(
        jq -r '.network.gateway_offset // empty' \
            "$config_file"
    )

    TAP_PREFIX=$(jq -r '.network.tap_prefix // empty' "$config_file")

    parse_json_bridges "$config_file"
}

# ============================================================
# Parse JSON bridges
# ============================================================

parse_json_bridges()
{
    local config_file="$1"
    local bridge

    declare -gA BRIDGE_IFACE_TYPE
    declare -gA BRIDGE_IFACES
    declare -gA BRIDGE_IPV4
    declare -gA BRIDGE_IP_GW
    declare -gA BRIDGE_IP_DNS
    declare -gA BRIDGE_FWROLE
    declare -ga BRIDGE_NAMES

    BRIDGE_NAMES=()

    while IFS= read -r bridge; do
        [[ -z "$bridge" ]] && continue

        validate_bridge_name "$bridge"

        if [[ -n "${BRIDGE_IFACE_TYPE[$bridge]:-}" ]]; then
            log_error "[Parser] Duplicate bridge: $bridge"
            exit "$E_VALIDATION"
        fi

        local iface
        local iface_type
        local ipv4
        local gateway
        local dns
        local role

        iface=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].iface // empty' \
            "$config_file")

        iface_type=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].iface_type // empty' \
            "$config_file")

        ipv4=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].ipv4 // empty' \
            "$config_file")

        gateway=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].gateway // empty' \
            "$config_file")

        dns=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].dns // empty' \
            "$config_file")

        role=$(jq -r --arg bridge "$bridge" \
            '.network.bridges[$bridge].role // empty' \
            "$config_file")

        # --------------------------------------------------------
        # Interface type
        # --------------------------------------------------------

        if [[ -z "$iface_type" ]]; then
            log_error "[Parser] Missing iface_type for bridge '$bridge'"
            exit "$E_VALIDATION"
        fi

        validate_iface_type "$iface_type"

        # --------------------------------------------------------
        # Interface
        # --------------------------------------------------------

        if [[ -z "$iface" ]]; then
            log_error "[Parser] Missing iface for bridge '$bridge'"
            exit "$E_VALIDATION"
        fi

        validate_interfaces "$iface"

        # --------------------------------------------------------
        # IPv4
        # --------------------------------------------------------

        if [[ -n "$ipv4" ]]; then
            validate_ipv4 "$ipv4" "$iface_type"
        elif [[ "$iface_type" == "podman" ]]; then
            log_error "[Parser] Podman bridge '$bridge' must have a static IPv4"
            exit "$E_VALIDATION"
        fi

        # --------------------------------------------------------
        # Gateway
        # --------------------------------------------------------

        if [[ -n "$gateway" ]]; then
            validate_ipv4gw "$gateway"
        fi

        # --------------------------------------------------------
        # DNS
        # --------------------------------------------------------

        if [[ -n "$dns" ]]; then
            validate_ipv4gw "$dns"
        fi

        # --------------------------------------------------------
        # Firewall role
        # --------------------------------------------------------

        if [[ -z "$role" ]]; then
            log_error "[Parser] Missing role for bridge '$bridge'"
            exit "$E_VALIDATION"
        fi

        validate_fw_role "$role"

        # --------------------------------------------------------
        # Store parsed values
        # --------------------------------------------------------

        BRIDGE_NAMES+=("$bridge")
        BRIDGE_IFACE_TYPE["$bridge"]="$iface_type"
        BRIDGE_IFACES["$bridge"]="$iface"
        BRIDGE_IPV4["$bridge"]="$ipv4"
        BRIDGE_IP_GW["$bridge"]="$gateway"
        BRIDGE_IP_DNS["$bridge"]="$dns"
        BRIDGE_FWROLE["$bridge"]="$role"

        log_debug \
            "[Parser] Parsed $bridge -> iface=$iface type=$iface_type " \
            "ip=$ipv4 gateway=$gateway dns=$dns role=$role"

    done < <(
        jq -r '.network.bridges // {} | keys[]' "$config_file"
    )

    if [[ "${#BRIDGE_NAMES[@]}" -eq 0 ]]; then
        log_error "[Parser] No bridge configured"
        exit "$E_VALIDATION"
    fi
}

# ============================================================
# Validate complete configuration
# ============================================================

validate_config()
{
    log_info "[Parser] Validating configuration"

    case "$FIREWALL" in
        pfsense|opnsense)
            ;;
        *)
            log_error "[Parser] Invalid firewall: '$FIREWALL'"
            return 1
            ;;
    esac

    validate_boolean "$NET_INIT" "network.initialize" || return 1
    validate_boolean \
        "$NM_AUTO_MIGRATE_IFACE" \
        "network.network_manager.auto_migrate_interface" \
        || return 1

    validate_boolean \
        "$NM_FORCE_FACTORY_BACKUP" \
        "network.network_manager.force_factory_backup" \
        || return 1

    validate_boolean \
        "$FWD_ALLOW_SSH_HOST" \
        "network.firewalld.allow_ssh_host" \
        || return 1

    if [[ ! "$FWD_GW_OFFSET" =~ ^[0-9]+$ ]]; then
        log_error "[Parser] Invalid gateway_offset: '$FWD_GW_OFFSET'"
        return 1
    fi

    if [[ -z "$TAP_PREFIX" || ! "$TAP_PREFIX" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "[Parser] Invalid tap_prefix: '$TAP_PREFIX'"
        return 1
    fi

    validate_bridges
}

# ============================================================
# Validate boolean
# ============================================================

validate_boolean()
{
    local value="$1"
    local name="$2"

    case "$value" in
        true|false)
            ;;
        *)
            log_error "[Parser] Invalid boolean '$name': '$value'"
            return 1
            ;;
    esac
}