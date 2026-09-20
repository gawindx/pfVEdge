#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# pfVEdge - Routing
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Bridge name -> deterministic routing table ID
# -----------------------------------------------------------------------------

get_route_table_id()
{
    local bridge="$1"
    local hash
    local value

    hash=$(printf '%s' "$bridge" | sha256sum | cut -c1-8)
    value=$((16#$hash))
    echo $((ROUTE_TABLE_BASE + (value % ROUTE_TABLE_SIZE)))
}

# -----------------------------------------------------------------------------
# Routing table ID -> rule priority
# -----------------------------------------------------------------------------

get_route_rule_priority()
{
    local table_id="$1"

    echo $((ROUTE_RULE_PRIORITY_BASE +
        table_id -
        ROUTE_TABLE_BASE))
}

# -----------------------------------------------------------------------------
# Calculate network information
# -----------------------------------------------------------------------------

get_bridge_network_info()
{
    local bridge="$1"
    local -n result="$2"
    declare -A info

    if [[ -z "${BRIDGE_IPV4[$bridge]}" ]]; then
        return 1
    fi
    if [[ "${BRIDGE_IPV4[$bridge]}" == "dhcp" ]]; then
        return 1
    fi
    calc_network_info "${BRIDGE_IPV4[$bridge]}" info
    result[cidr]="${info[cidr]}"
    result[network]="${info[network]}"
    result[gateway]="${info[gateway]}"
}

# -----------------------------------------------------------------------------
# Check deterministic table ID collisions
# -----------------------------------------------------------------------------

validate_route_table_ids()
{
    local bridge
    local other_bridge
    local table_id
    local other_table_id

    for bridge in "${BRIDGE_NAMES[@]}"; do
        [[ "${BRIDGE_FWROLE[$bridge]}" == "LAN" ]] || continue
        table_id=$(get_route_table_id "$bridge")
        for other_bridge in "${BRIDGE_NAMES[@]}"; do
            [[ "$bridge" == "$other_bridge" ]] && continue
            [[ "${BRIDGE_FWROLE[$other_bridge]}" == "LAN" ]] || continue
            other_table_id=$(get_route_table_id "$other_bridge")
            if [[ "$table_id" == "$other_table_id" ]]; then
                log_error \
                    "[Routing] Routing table ID collision: bridges '$bridge' and '$other_bridge' both use table $table_id"
                return 1
            fi
        done
    done
    return 0
}

# -----------------------------------------------------------------------------
# Configure one LAN routing table
# -----------------------------------------------------------------------------

configure_lan_route_table()
{
    local bridge="$1"
    local table_id="$2"
    local lan_network="$3"
    local gateway="$4"

    local pod_bridge
    local pod_network
    local pod_cidr

    log_debug \
        "[Routing] Configuring table $table_id for LAN bridge '$bridge'"

    # -------------------------------------------------------------------------
    # Connected LAN network
    #
    # This route is required so that the firewall gateway itself is reachable
    # from this routing table.
    # -------------------------------------------------------------------------

    log_debug \
        "[Routing] Table $table_id: $lan_network dev $bridge"

    run ip -4 route replace \
        "$lan_network" \
        dev "$bridge" \
        table "$table_id"

    # -------------------------------------------------------------------------
    # Podman networks
    # -------------------------------------------------------------------------

    for br in "${BRIDGE_NAMES[@]}"; do
        case "${BRIDGE_IFACE_TYPE[$br]}" in
            podman)
                continue
                log_debug \
                    "[Routing] Table $table_id: $br is a Podman bridge, skipping"
                ;;
            *)
                local fwrole="${BRIDGE_FWROLE[$br]}"
                [[ "$fwrole" == "lan" || "$fwrole" == "dmz" ]] || continue
                log_debug \
                    "[Routing] Table $table_id: $br is a LAN or DMZ bridge. Configuring route to Podman networks"
                ;;
        esac
        if [[ -z "${BRIDGE_IPV4[$br]}" ]]; then
            log_debug \
                "[Routing] Skipping Podman bridge '$br': no IPv4 configured"
            continue
        fi
        if [[ "${BRIDGE_IPV4[$br]}" == "dhcp" ]]; then
            log_error \
                "[Routing] Podman bridge '$br' cannot use DHCP for routing"
            return 1
        fi
        declare -A pod_info
        get_bridge_network_info "$br" pod_info || {
            log_error \
                "[Routing] Unable to calculate network for Podman bridge '$br'"
            return 1
        }
        pod_network="${pod_info[network]}"
        pod_cidr="${pod_info[cidr]}"
        log_debug \
            "[Routing] Table $table_id: $pod_network/$pod_cidr via $gateway dev $bridge"
        run ip -4 route replace \
            "$pod_network/$pod_cidr" \
            via "$gateway" \
            dev "$bridge" \
            table "$table_id"
    done

    # -------------------------------------------------------------------------
    # Default route
    #
    # Traffic originating from this LAN must never fall back to the main
    # routing table and therefore bypass pfVEdge.
    # -------------------------------------------------------------------------

    log_debug \
        "[Routing] Table $table_id: default via $gateway dev $bridge"
    run ip -4 route replace \
        default \
        via "$gateway" \
        dev "$bridge" \
        table "$table_id"
}

# -----------------------------------------------------------------------------
# Configure one LAN policy rule
# -----------------------------------------------------------------------------

configure_lan_rule()
{
    local bridge="$1"
    local table_id="$2"
    local lan_network="$3"
    local priority

    priority=$(get_route_rule_priority "$table_id")
    log_debug \
        "[Routing] Rule $priority: from $lan_network lookup table $table_id"

    # ip rule does not provide the same replace operation as ip route.
    # Delete our deterministic rule first if it already exists.
    log_debug "[Routing] Verifying if rule with priority $priority already exists"
    if ip -4 rule show | grep -Eq \
        "^${priority}: .*from ${lan_network} .*lookup ${table_id}([[:space:]]|$)"; then
        run ip -4 rule del \
            priority "$priority"
    fi
    log_debug "[Routing] Adding rule with priority $priority"
    run ip -4 rule add \
        priority "$priority" \
        from "$lan_network" \
        table "$table_id"
}

# -----------------------------------------------------------------------------
# Remove stale pfVEdge LAN rules
# -----------------------------------------------------------------------------

cleanup_lan_rules()
{
    local priority

    while read -r priority; do
        [[ "$priority" =~ ^[0-9]+$ ]] || continue
        if (( priority >= ROUTE_RULE_PRIORITY_BASE &&
              priority < ROUTE_RULE_PRIORITY_BASE + ROUTE_TABLE_SIZE )); then
            log_debug \
                "[Routing] Removing pfVEdge routing rule with priority $priority"
            run ip -4 rule del priority "$priority"
        fi
    done < <(
        ip -4 rule show |
        awk -F: '
            {
                gsub(/^[[:space:]]+/, "", $1)
                print $1
            }
        '
    )
}

# -----------------------------------------------------------------------------
# Configure LAN policy routing
# -----------------------------------------------------------------------------

configure_lan_policy_routing()
{
    local bridge
    local table_id
    local priority
    local gateway
    local lan_network
    local lan_cidr
    declare -A lan_info

    log_info "[Routing] Configuring LAN policy routing"
    validate_route_table_ids || return 1

    # Remove only rules belonging to pfVEdge.
    cleanup_lan_rules
    for bridge in "${BRIDGE_NAMES[@]}"; do
        log_debug "[Routing] Processing LAN bridge '$bridge'"
        [[ "${BRIDGE_FWROLE[$bridge]}" == "LAN" ]] || continue
        log_debug "[Routing] Configuring LAN policy routing for bridge '$bridge'"
        if [[ -z "${BRIDGE_IPV4[$bridge]}" ]]; then
            log_error \
                "[Routing] LAN bridge '$bridge' has no IPv4 configuration"
            return 1
        fi
        if [[ "${BRIDGE_IPV4[$bridge]}" == "dhcp" ]]; then
            log_error \
                "[Routing] LAN bridge '$bridge' cannot use DHCP for policy routing"
            return 1
        fi
        log_debug "[Routing] '$bridge' is Eligible for LAN policy routing"
        unset lan_info
        declare -A lan_info

        get_bridge_network_info "$bridge" lan_info || {
            log_error \
                "[Routing] Unable to calculate network information for LAN bridge '$bridge'"
            return 1
        }
        lan_network="${lan_info[network]}"
        lan_cidr="${lan_info[cidr]}"
        gateway="${lan_info[gateway]}"

        log_debug "[Routing] Calculated gateway for LAN bridge '$bridge': $gateway"
        if [[ -z "$gateway" ]]; then
            log_error \
                "[Routing] Unable to calculate firewall gateway for LAN bridge '$bridge'"
            return 1
        fi
        table_id=$(get_route_table_id "$bridge")
        priority=$(get_route_rule_priority "$table_id")
        log_info \
            "[Routing] LAN '$bridge': $lan_network/$lan_cidr -> firewall $gateway, table $table_id, rule $priority"
        configure_lan_route_table \
            "$bridge" \
            "$table_id" \
            "$lan_network/$lan_cidr" \
            "$gateway" || return 1
        configure_lan_rule \
            "$bridge" \
            "$table_id" \
            "$lan_network/$lan_cidr" || return 1
    done
    return 0
}

# -----------------------------------------------------------------------------
# Main routing configuration
# -----------------------------------------------------------------------------

configure_routing()
{
    # The WAN default route is intentionally managed by NetworkManager
    # LAN policy routing is managed here.
    configure_lan_policy_routing || return 1
    log_info "[Routing] Routing configuration completed"
    return 0
}