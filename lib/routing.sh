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
    declare -A eth_info

    if [[ -z "${BRIDGE_IPV4[$bridge]}" ]]; then
        return 1
    fi
    if [[ "${BRIDGE_IPV4[$bridge]}" == "dhcp" ]]; then
        return 1
    fi
    calc_network_info "$bridge" eth_info || {
        log_error \
            "[Routing] Unable to calculate network for bridge '$bridge'"
        return 1
    }
    result[cidr]="${eth_info[cidr]}"
    result[network]="${eth_info[network]}"
    result[gateway]="${eth_info[gateway]}"
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
        local iface_type="${BRIDGE_IFACE_TYPE[$bridge]}"
        local fwrole="${BRIDGE_FWROLE[$bridge]}"

        [[ "${iface_type}" == "podman" || "${fwrole}" == "wan" ]] || continue
        table_id=$(get_route_table_id "$bridge")
        for other_bridge in "${BRIDGE_NAMES[@]}"; do
            [[ "$bridge" == "$other_bridge" ]] && continue
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
# Append an item to a comma-separated list
# -----------------------------------------------------------------------------

append_csv()
{
    local -n list="$1"
    local value="$2"

    [[ -z "$value" ]] && return 0
    list+=("$value")
}

# -----------------------------------------------------------------------------
# Check whether a routing table belongs to pfVEdge
# -----------------------------------------------------------------------------

is_pfvedge_table()
{
    local table_id="$1"

    [[ "$table_id" =~ ^[0-9]+$ ]] || return 1
    (( table_id >= ROUTE_TABLE_BASE &&
       table_id < ROUTE_TABLE_BASE + ROUTE_TABLE_SIZE ))
}

# -----------------------------------------------------------------------------
# Remove pfVEdge routes from an existing NetworkManager profile
#
# Routes outside the pfVEdge reserved table range are preserved.
# -----------------------------------------------------------------------------

get_existing_nm_routes()
{
    local bridge="$1"
    local raw_routes
    local route
    local table_id
    local -n result="$2"
    local -a routes=()

    raw_routes=$(nmcli -g ipv4.routes connection show "$bridge" 2>/dev/null || true)
    [[ -z "$raw_routes" || "$raw_routes" == "--" ]] && return 0
    raw_routes=${raw_routes//$'\n'/,}
    IFS=',' read -ra raw_routes <<< "$raw_routes"
    for route in "${raw_routes[@]}"; do
        route=$(trim "$route")
        [[ -z "$route" ]] && continue
        if [[ "$route" =~ table=([0-9]+) ]]; then
            table_id="${BASH_REMATCH[1]}"
            if is_pfvedge_table "$table_id"; then
                continue
            fi
        fi
        routes+=("$route")
    done
    result=("${routes[@]}")
}

# -----------------------------------------------------------------------------
# Remove pfVEdge routing rules from an existing NetworkManager profile
#
# Rules outside the pfVEdge reserved priority range are preserved.
# -----------------------------------------------------------------------------

get_existing_nm_rules()
{
    local bridge="$1"
    local raw_rules
    local rule
    local priority
    local -n result="$2"
    local -a rules=()

    raw_rules=$(nmcli -g ipv4.routing-rules connection show "$bridge" 2>/dev/null || true)
    [[ -z "$raw_rules" || "$raw_rules" == "--" ]] && return 0
    raw_rules=${raw_rules//$'\n'/,}
    IFS=',' read -ra raw_rules <<< "$raw_rules"
    for rule in "${raw_rules[@]}"; do
        rule=$(trim "$rule")
        [[ -z "$rule" ]] && continue
        if [[ "$rule" =~ priority[[:space:]]+([0-9]+) ]]; then
            priority="${BASH_REMATCH[1]}"
            if (( priority >= ROUTE_RULE_PRIORITY_BASE &&
                  priority < ROUTE_RULE_PRIORITY_BASE + ROUTE_TABLE_SIZE )); then
                continue
            fi
        fi
        rules+=("$rule")
    done
    result=("${rules[@]}")
}

# -----------------------------------------------------------------------------
# Configure one LAN routing table in NetworkManager
# -----------------------------------------------------------------------------

configure_bridge_route_table()
{
    local bridge="$1"
    local table_id="$2"
    local lan_network="$3"
    local gateway="$4"

    local other_bridge
    local other_network
    local other_cidr
    local fwrole

    local -a routes=()
    local -a existing_routes=()

    log_debug \
        "[Routing] Configuring NetworkManager table $table_id for bridge '$bridge'"

    # -------------------------------------------------------------------------
    # Preserve non-pfVEdge routes already present in the profile.
    # -------------------------------------------------------------------------

    get_existing_nm_routes "$bridge" existing_routes
    for route in "${existing_routes[@]}"; do
        routes+=("$route")
    done

    # -------------------------------------------------------------------------
    # Connected local network
    #
    # This route is required so that the firewall gateway itself is reachable
    # from this routing table.
    # -------------------------------------------------------------------------

    log_debug \
        "[Routing] Table $table_id: $lan_network dev $bridge"
    routes+=(
        "$lan_network 0.0.0.0 0 table=$table_id"
    )

    # -------------------------------------------------------------------------
    # Other firewall-managed networks
    #
    # LAN and DMZ networks must always be reached through the firewall.
    # The current bridge is already directly connected, so it is skipped.
    #
    # Podman bridges have no IP configured on Fedora, but their network
    # information is still defined in the general bridge configuration.
    # They therefore need a route through the firewall from this table.
    # -------------------------------------------------------------------------

    for other_bridge in "${BRIDGE_NAMES[@]}"; do
        [[ "$other_bridge" == "$bridge" ]] && continue
        if [[ "${BRIDGE_IFACE_TYPE[$other_bridge]}" == "podman" ]]; then
            if [[ -z "${BRIDGE_IPV4[$other_bridge]:-}" ]]; then
                log_error \
                    "[Routing] Podman bridge '$other_bridge' has no IPv4 network configured"
                return 1
            fi
            if [[ "${BRIDGE_IPV4[$other_bridge]}" == "dhcp" ]]; then
                log_error \
                    "[Routing] Podman bridge '$other_bridge' cannot use DHCP for routing"
                return 1
            fi
            declare -A pod_info
            calc_network_info "$other_bridge" pod_info || {
                log_error \
                    "[Routing] Unable to calculate network for Podman bridge '$other_bridge'"
                return 1
            }
            other_network="${pod_info[network]}"
            other_cidr="${pod_info[cidr]}"
            log_debug \
                "[Routing] Table $table_id: $other_network/$other_cidr via $gateway dev $bridge"
            routes+=(
                "$other_network/$other_cidr $gateway 0 table=$table_id"
            )
            continue
        fi
        fwrole="${BRIDGE_FWROLE[$other_bridge]}"
        [[ "$fwrole" == "lan" || "$fwrole" == "dmz" ]] || continue
        if [[ -z "${BRIDGE_IPV4[$other_bridge]:-}" ]]; then
            log_debug \
                "[Routing] Skipping bridge '$other_bridge': no IPv4 network configured"
            continue
        fi
        if [[ "${BRIDGE_IPV4[$other_bridge]}" == "dhcp" ]]; then
            log_error \
                "[Routing] Bridge '$other_bridge' cannot use DHCP for policy routing"
            return 1
        fi
        declare -A other_info
        calc_network_info "$other_bridge" other_info || {
            log_error \
                "[Routing] Unable to calculate network for bridge '$other_bridge'"
            return 1
        }
        other_network="${other_info[network]}"
        other_cidr="${other_info[cidr]}"
        log_debug \
            "[Routing] Table $table_id: $other_network/$other_cidr via $gateway dev $bridge"
        routes+=(
            "$other_network/$other_cidr $gateway 0 table=$table_id"
        )
    done

    # -------------------------------------------------------------------------
    # Default route
    #
    # Traffic originating from this LAN/DMZ must never fall back to the main
    # routing table and therefore bypass pfVEdge.
    # -------------------------------------------------------------------------

    log_debug \
        "[Routing] Table $table_id: default via $gateway dev $bridge"
    routes+=(
        "0.0.0.0/0 $gateway 0 table=$table_id"
    )

    local routes_csv

    routes_csv=$(IFS=','; echo "${routes[*]}")

    log_debug \
        "[Routing] NetworkManager routes for '$bridge': $routes_csv"

    run nmcli connection modify \
        "$bridge" \
        ipv4.routes "$routes_csv"
}

# -----------------------------------------------------------------------------
# Configure one LAN policy rule in NetworkManager
# -----------------------------------------------------------------------------

configure_lan_rule()
{
    local bridge="$1"
    local table_id="$2"
    local lan_network="$3"
    local priority
    local rule
    local -a rules=()
    local -a existing_rules=()

    priority=$(get_route_rule_priority "$table_id")
    rule="priority $priority from $lan_network table $table_id"
    log_debug \
        "[Routing] Rule $priority: from $lan_network lookup table $table_id"

    # -------------------------------------------------------------------------
    # Preserve non-pfVEdge routing rules already present in the profile.
    # -------------------------------------------------------------------------

    get_existing_nm_rules "$bridge" existing_rules
    for existing_rule in "${existing_rules[@]}"; do
        rules+=("$existing_rule")
    done
    rules+=("$rule")

    local rules_csv

    rules_csv=$(IFS=','; echo "${rules[*]}")
    log_debug \
        "[Routing] NetworkManager routing rules for '$bridge': $rules_csv"
    run nmcli connection modify \
        "$bridge" \
        ipv4.routing-rules "$rules_csv"
}

# -----------------------------------------------------------------------------
# Remove legacy pfVEdge kernel routing state
#
# Clean up legacy routing rules from pre-v0.4 installations.
# Kept for backward compatibility; planned for removal in v0.5.
# -----------------------------------------------------------------------------

cleanup_legacy_routing()
{
    local bridge
    local table_id
    local priority

    log_info "[Routing] Cleaning legacy kernel routing state"
    for bridge in "${BRIDGE_NAMES[@]}"; do
        [[ "${BRIDGE_FWROLE[$bridge]}" == "wan" ]] && continue
        [[ "${BRIDGE_IFACE_TYPE[$bridge]}" == "podman" ]] && continue
        [[ -n "${BRIDGE_IPV4[$bridge]:-}" ]] || continue
        [[ "${BRIDGE_IPV4[$bridge]}" != "dhcp" ]] || continue
        table_id=$(get_route_table_id "$bridge")
        priority=$(get_route_rule_priority "$table_id")
        log_debug \
            "[Routing] Removing legacy rule $priority and table $table_id for '$bridge'"
        ip -4 rule del priority "$priority" 2>/dev/null || true
        ip -4 route flush table "$table_id" 2>/dev/null || true
    done
    return 0
}

# -----------------------------------------------------------------------------
# Prepare routing
# -----------------------------------------------------------------------------

prepare_routing()
{
    log_info "[Routing] Preparing routing configuration"
    validate_route_table_ids || return 1
    cleanup_legacy_routing || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Configure one bridge policy routing profile
# -----------------------------------------------------------------------------

configure_bridge_policy_routing()
{
    local bridge="$1"
    local table_id
    local priority
    local gateway
    local lan_network
    local lan_cidr

    declare -A lan_info

    [[ "${BRIDGE_FWROLE[$bridge]}" == "wan" ]] && return 0
    [[ "${BRIDGE_IFACE_TYPE[$bridge]}" == "podman" ]] && return 0
    if [[ -z "${BRIDGE_IPV4[$bridge]}" ]]; then
        log_error \
            "[Routing] Bridge '$bridge' has no IPv4 configuration"
        return 1
    fi
    if [[ "${BRIDGE_IPV4[$bridge]}" == "dhcp" ]]; then
        log_debug \
            "[Routing] Skipping DHCP bridge '$bridge': not eligible for policy routing"
        return 0
    fi
    get_bridge_network_info "$bridge" lan_info || {
        log_error \
            "[Routing] Unable to calculate network information for bridge '$bridge'"
        return 1
    }
    lan_network="${lan_info[network]}"
    lan_cidr="${lan_info[cidr]}"
    gateway="${lan_info[gateway]}"
    if [[ -z "$gateway" ]]; then
        log_error \
            "[Routing] Unable to calculate firewall gateway for bridge '$bridge'"
        return 1
    fi
    table_id=$(get_route_table_id "$bridge")
    priority=$(get_route_rule_priority "$table_id")
    log_info \
        "[Routing] LAN '$bridge': $lan_network/$lan_cidr -> firewall $gateway, table $table_id, rule $priority"
    configure_bridge_route_table \
        "$bridge" \
        "$table_id" \
        "$lan_network/$lan_cidr" \
        "$gateway" || return 1
    configure_lan_rule \
        "$bridge" \
        "$table_id" \
        "$lan_network/$lan_cidr" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Main routing configuration
#
# Kept as a compatibility wrapper for callers outside qemu-networks.sh.
# Runtime routing is now configured per NetworkManager connection.
# -----------------------------------------------------------------------------

configure_routing()
{
    log_info "[Routing] NetworkManager-based routing is configured per bridge"
    return 0
}