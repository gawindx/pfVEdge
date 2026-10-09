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
    log_info "[Parser] Loading configuration: $config_file"
    {
        IFS= read -r -d '' BACKUP_DIR
        IFS= read -r -d '' LOG_LEVEL
        IFS= read -r -d '' NET_INIT
        IFS= read -r -d '' NM_FORCE_FACTORY_BACKUP
        IFS= read -r -d '' FWD_ALLOW_SSH_HOST
        IFS= read -r -d '' FWD_GW_OFFSET
        IFS= read -r -d '' TAP_PREFIX
    } < <(
        jq -j '
            [
                (.backup_dir // "/var/lib/pfVEdge"),
                (.log_level // "info"),
                (.network.initialize // false),
                (.network.network_manager.force_factory_backup // false),
                (.network.firewalld.allow_ssh_host // false),
                (.network.gateway_offset // 1),
                (.network.tap_prefix // "tap")
            ]
            | map(tostring + "\u0000")
            | add
        ' "$config_file"
    )
    parse_json_bridges "$config_file"
}

# ============================================================
# Parse JSON bridges
# ============================================================

parse_json_bridges()
{
    local config_file="$1"
    declare -gA BRIDGE_IFACE_TYPE
    declare -gA BRIDGE_IFACES
    declare -gA BRIDGE_IPV4
    declare -gA BRIDGE_IP_GW
    declare -gA BRIDGE_DNS
    declare -gA BRIDGE_FWROLE
    declare -ga BRIDGE_NAMES

    BRIDGE_NAMES=()
    while
        IFS= read -r -d '' bridge &&
        IFS= read -r -d '' iface &&
        IFS= read -r -d '' iface_type &&
        IFS= read -r -d '' ipv4 &&
        IFS= read -r -d '' gateway &&
        IFS= read -r -d '' dns &&
        IFS= read -r -d '' role
    do
        validate_bridge_name "$bridge"
        if [[ -n "${BRIDGE_IFACE_TYPE[$bridge]:-}" ]]; then
            log_error "[Parser] Duplicate bridge: $bridge"
            exit "$E_VALIDATION"
        fi
        # Interface type
        if [[ -z "$iface_type" ]]; then
            log_error "[Parser] Bridge '$bridge' has no interface type"
            exit "$E_VALIDATION"
        fi
        validate_iface_type "$iface_type"
        # Interface
        if [[ -z "$iface" ]]; then
            log_error "[Parser] Bridge '$bridge' has no interface"
            exit "$E_VALIDATION"
        fi
        validate_interfaces "$iface"
        # IPv4
        if [[ -n "$ipv4" ]]; then
            validate_ipv4 "$ipv4" "$iface_type" "$bridge"
        elif [[ "$iface_type" == "podman" ]]; then
            log_error "[Parser] Podman bridge '$bridge' must have a static IPv4"
            exit "$E_VALIDATION"
        fi
        # Gateway
        if [[ -n "$gateway" ]]; then
            validate_ipv4gw "$gateway"
        elif [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ||
              "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_debug \
                "[Parser] No gateway specified for bridge '$bridge', calculating..."
            gateway=$(calc_gateway "$ipv4")
        fi
        # DNS
        if [[ -n "$dns" ]]; then
            validate_ipv4gw "$dns"
        else
            log_debug \
                "[Parser] No DNS specified for bridge '$bridge', using gateway as DNS"
            dns="$gateway"
        fi
        # Firewall role
        if [[ -z "$role" ]]; then
            log_error "[Parser] Bridge '$bridge' has no firewall role"
            exit "$E_VALIDATION"
        fi
        validate_fw_role "$role"
        BRIDGE_NAMES+=("$bridge")
        BRIDGE_IFACE_TYPE["$bridge"]="$iface_type"
        BRIDGE_IFACES["$bridge"]="$iface"
        BRIDGE_IPV4["$bridge"]="$ipv4"
        BRIDGE_IP_GW["$bridge"]="$gateway"
        BRIDGE_DNS["$bridge"]="$dns"
        BRIDGE_FWROLE["$bridge"]="$role"
        log_debug \
            "[Parser] Parsed $bridge -> iface=$iface type=$iface_type " \
            "ip=$ipv4 gateway=$gateway dns=$dns role=$role"
    done < <(
        jq -j '
            .network.bridges // {}
            | to_entries[]
            | [
                .key,
                (.value.iface // ""),
                (.value.iface_type // ""),
                (.value.ipv4 // ""),
                (.value.gateway // ""),
                (.value.dns // ""),
                (.value.role // "")
            ]
            | map(tostring + "\u0000")
            | add
        ' "$config_file"
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

    validate_boolean "$NET_INIT" "network.initialize" || return 1

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