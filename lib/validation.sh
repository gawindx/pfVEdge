#!/usr/bin/env bash

# ============================================================
# Verify environment
# ============================================================

validate_environment() {
    command -v nmcli >/dev/null 2>&1 || exit "$E_NMCLI"
    command -v ip >/dev/null 2>&1 || exit "$E_RUNTIME"
    command -v firewall-cmd &>/dev/null || log_warn "[Validate] firewalld not available"
    command -v bridge &>/dev/null || log_warn "[Validate] bridge tool missing"
    log_info "[Validate] Environment OK"
}

# ============================================================
# Validate Env Bridge Name Format
# ============================================================

validate_bridge_name() {
    log_debug "[Validate] Receive '$1' as bridge name"
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || {
        log_error "[Validate] Invalid bridge name: '$1'"
        exit "$E_VALIDATION"
    }
}

# ============================================================
# Validate Env iface type
# ============================================================

validate_iface_type() {
    log_debug "[Validate] Receive '$1' as iface_type"
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || {
        log_error "[Validate] Invalid iface_type: '$1'"
        exit "$E_VALIDATION"
    }
}

# ============================================================
# Validate Env IPV4 Format
# ============================================================

validate_ipv4() {
    log_debug "[Validate] Receive '$1' as IPV4"
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || {
        [[ "$1" == "dhcp" ]] || {
            log_error "[Validate] Invalid IPv4: '$1'"
            exit "$E_VALIDATION"
        }
    }
}

# ============================================================
# Validate Env IPV4 Format
# ============================================================

validate_ipv4gw() {
    log_debug "[Validate] Receive '$1' as IPV4"
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        log_error "[Validate] Invalid IPv4 Gateway: '$1'"
        exit "$E_VALIDATION"
    }
}

# ============================================================
# Validate Env iface name
# ============================================================

validate_interfaces() {
    log_debug "[Validate] Receive '$1' as interfaces"
    IFS=',' read -ra arr <<< "$1"
    declare -A seen

    for iface in "${arr[@]}"; do
        iface=$(trim "$iface")
        if [[ -z "$iface" ]]; then
            log_error "[Validate] Invalid interface list (empty element)"
            exit "$E_VALIDATION"
        fi
        [[ "$iface" =~ ^[a-zA-Z0-9._-]+$ ]] || {
            log_error "[Validate] Invalid interface name: '$iface'"
            exit "$E_VALIDATION"
        }
        if [[ -n "${seen[$iface]:-}" ]]; then
            log_error "[Validate] Duplicate interface: '$iface'"
            exit "$E_VALIDATION"
        fi
        seen[$iface]=1
    done
}

# ============================================================
# Validate Env Vlans
# ============================================================

validate_vlans() {
    log_debug "[Validate] Receive '$1' as VLAN"
    IFS=',' read -ra arr <<< "$1"
    declare -A seen

    for v in "${arr[@]}"; do
        v=$(trim "$v")
        [[ "$v" =~ ^[0-9]+$ ]] || {
            log_error "[Validate] Invalid VLAN: '$v'"
            exit "$E_VALIDATION"
        }
        ((v >= 1 && v <= 4094)) || {
            log_error "[Validate] VLAN out of range: '$v'"
            exit "$E_VALIDATION"
        }
        if [[ -n "${seen[$v]:-}" ]]; then
            log_error "[Validate] Duplicate VLAN: '$v'"
            exit "$E_VALIDATION"
        fi
        log_debug "[Validate] VLAN '$v' Validated"
        seen[$v]=1
    done
}

# ============================================================================
# Validate all bridges
# ============================================================================

validate_bridges()
{
    local i

    log_info "[Validate] Validating bridges"
    for bridge in "${BRIDGE_NAMES[@]}"
    do
        validate_bridge "$bridge" || return 1
    done
    validate_fw_roles || return 1
    log_info "[Validate] Validation successful"
    return 0
}

# ============================================================================
# Validate one bridge
#
# Arguments:
#   $1 : bridge index
# ============================================================================

validate_bridge()
{
    local br="$1"
    local iface_type="${BRIDGE_IFACE_TYPE[$br]}"
    local ifaces="${BRIDGE_IFACES[$br]}"
    local ipv4="${BRIDGE_IPV4[$br]}"
    local vlans="${BRIDGE_VLANS[$br]}"
    local role="${BRIDGE_FWROLE[$br]}"

    # ------------------------------------------------------------------------
    # Check bridge exists
    # ------------------------------------------------------------------------

    log_debug "[Validate] Checking $br"
    if ! ip link show "$br" >/dev/null 2>&1; then
        log_error "[Validate] Missing bridge interface: $br"
        return 1
    else
        log_debug "[Validate] Bridge interface exists: $br"
    fi

    # ------------------------------------------------------------------------
    # Check bridge is UP
    # ------------------------------------------------------------------------

    if [[ "$iface_type" == "podman" ]]; then
        log_debug "[Validate] Podman bridge '$br' → skip UP check"
    else
        if [[ "$(cat "/sys/class/net/${br}/operstate")" != "up" ]]; then
            log_error "[Validate] Bridge not UP: $br"
            return 1
        fi
        log_debug "[Validate] Bridge is UP: $br" 
    fi

    # ------------------------------------------------------------------------
    # Check NetworkManager profile
    # ------------------------------------------------------------------------

    if ! nmcli -t -f NAME,TYPE connection show \
        | grep -Fxq "${br}:bridge"
    then
        log_error "[Validate] Missing NetworkManager profile: $br"
        return 1
    else
        log_debug "[Validate] NetworkManager profile exists: $br"
    fi

    # ------------------------------------------------------------------------
    # Check MTU
    # ------------------------------------------------------------------------

    local mtu

    mtu=$(cat "/sys/class/net/${br}/mtu")
    if [[ "$mtu" != "$V_MTU" ]]
    then
        log_error "[Validate] Invalid MTU on $br ($mtu != $V_MTU)"
        return 1
    else
        log_debug "[Validate] MTU is valid on $br ($mtu)"
    fi

    # ------------------------------------------------------------------------
    # Validate interface type
    # ------------------------------------------------------------------------

    case "$iface_type" in
        eth)
            validate_bridge_eth "$br" "$ifaces"
            ;;
        podman)
            validate_bridge_podman "$br"
            ;;
        *)
            log_error "[Validate] Unsupported interface type '$iface_type'"
            return 1
            ;;
    esac || return 1

    # ------------------------------------------------------------------------
    # Validate IPv4
    # ------------------------------------------------------------------------

    validate_bridge_ipv4 "$br" "$ipv4" || return 1

    # ------------------------------------------------------------------------
    # Validate VLANs
    # ------------------------------------------------------------------------

    validate_bridge_vlans "$br" "$vlans" || return 1

    # ------------------------------------------------------------------------
    # Validate firewall role
    # ------------------------------------------------------------------------

    case "$role" in
        wan|lan|dmz)
            ;;
        *)
            log_error "[Validate] Invalid firewall role '$role' on $br"
            return 1
            ;;
    esac
    log_debug "[Validate] Firewall role is valid on $br"
    return 0
}

# ============================================================================
# Validate ethernet bridge ports
# ============================================================================

validate_bridge_eth()
{
    local bridge="$1"
    local ifaces="$2"
    local iface

    IFS=',' read -ra iface_list <<< "$ifaces"
    for iface in "${iface_list[@]}"; do
        if ! ip link show "$iface" >/dev/null 2>&1; then
            log_error "[Validate] Missing interface '$iface'"
            return 1
        fi
        if ! bridge link show master "$bridge" \
            | grep -qw "$iface"
        then
            log_error "[Validate] Interface '$iface' not attached to '$bridge'"
            return 1
        fi
    done
    return 0
}

# ============================================================================
# Validate podman bridge
# ============================================================================

validate_bridge_podman()
{
    local bridge="$1"

    if ! podman network exists "$bridge" >/dev/null 2>&1; then
        log_error "[Validate] Podman bridge '$bridge' does not exist"
        return 1
    fi
    log_debug "[Validate] Podman bridge exists: $bridge"
    return 0
}

# ============================================================================
# Validate IPv4 configuration
# ============================================================================

validate_bridge_ipv4()
{
    local bridge="$1"
    local expected="$2"
    local iface_type="${BRIDGE_IFACE_TYPE[$bridge]}"

    case "$expected" in
        "")
            return 0
            ;;
        dhcp)
            if ! ip -4 addr show "$bridge" \
                | grep -q "inet "
            then
                log_error "[Validate] DHCP address missing on $bridge"
                return 1
            else
                log_debug "[Validate] DHCP address present on $bridge"
            fi
            ;;
        *)
            if ! ip -4 addr show "$bridge" \
                | grep -q "$expected"
            then
                log_error "[Validate] Verify if bridge $bridge is a podman network and is valid as $expected"
                if [[ "$iface_type" == "podman" ]]; then
                    log_warn "[Validate] Podman bridge '$bridge' may not be up without clients attached, skipping IPv4 validation"
                else
                    log_error "[Validate] Invalid IPv4 on $bridge"
                    return 1
                fi
            else
                log_debug "[Validate] IPv4 is valid on $bridge"
            fi
            ;;
    esac
    return 0
}

# ============================================================================
# Validate VLAN list
# ============================================================================

validate_bridge_vlans()
{
    local bridge="$1"
    local vlans="$2"
    local vlan

    if [[ -z "$vlans" ]]; then
        return 0
    fi
    IFS=',' read -ra vlan_list <<< "$vlans"
    for vlan in "${vlan_list[@]}"; do
        if ! [[ "$vlan" =~ ^[0-9]+$ ]]; then
            log_error "[Validate] Invalid VLAN '$vlan'"
            return 1
        else
            log_debug "[Validate] VLAN '$vlan' is valid"
        fi
    done
    return 0
}

# ============================================================================
# Validate firewall roles
# ============================================================================

validate_fw_roles()
{
    local wan=0
    local lan=0
    local role

    for role in "${BRIDGE_FWROLE[@]}"; do
        case "$role" in
            wan)
                ((wan++))
                ;;
            lan)
                ((lan++))
                ;;
            "")
                log_error "[Validate] Bridge must have a firewall role"
                return 1
                ;;
        esac
    done
    if [[ "$wan" -ne 1 ]]; then
        log_error "[Validate] Exactly one WAN bridge required"
        return 1
    fi
    if [[ "$lan" -lt 1 ]]; then
        log_error "[Validate] At least one LAN bridge required"
        return 1
    fi
    log_debug "[Validate] Firewall roles are valid (WAN=$wan, LAN=$lan)"
    return 0
}