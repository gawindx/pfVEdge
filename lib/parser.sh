#!/usr/bin/env bash

parse_networks() {
    local input="$1"

    declare -gA BRIDGE_IFACE_TYPE
    declare -gA BRIDGE_IFACES
    declare -gA BRIDGE_IPV4
    declare -gA BRIDGE_VLANS
    declare -gA BRIDGE_FWROLE
    declare -ga BRIDGE_NAMES
    declare -A seen
    BRIDGE_NAMES=()

    if [[ -z "$input" ]]; then
        log_warn "[Parser] BRIDGES_NETWORKS is empty → nothing to configure"
        return
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        IFS=':' read -r bridge iface_type ifaces ipv4 vlans fwrole <<< "$line"
        bridge="br-$bridge"
        validate_bridge_name "$bridge"
        if [[ -n "${seen[$bridge]:-}" ]]; then
            log_error "[Parser] Duplicate bridge: $bridge"
            exit "$E_VALIDATION"
        fi
        seen[$bridge]=1
        [[ -n "$iface_type" ]] && validate_iface_type "$iface_type"
        [[ -n "$ipv4" ]] && validate_ipv4 "$ipv4"
        [[ -n "$ifaces" ]] && validate_interfaces "$ifaces"
        # Normalize VLAN
        if [[ -n "$vlans" ]]; then
            IFS=',' read -ra arr <<< "$vlans"
            clean=()
            for v in "${arr[@]}"; do
                v=$(trim "$v")
                [[ -z "$v" ]] && continue
                clean+=("$v")
            done
            vlans="$(IFS=','; echo "${clean[*]}")"
            validate_vlans "$vlans"
        fi
        if [[ -z "$fwrole" ]]; then
            fwrole="wan"
        fi
        BRIDGE_NAMES+=("$(trim "$bridge")")
        BRIDGE_IFACE_TYPE["$bridge"]=$(trim "$iface_type")
        BRIDGE_IFACES["$bridge"]=$(trim "$ifaces")
        BRIDGE_IPV4["$bridge"]=$(trim "$ipv4")
        BRIDGE_VLANS["$bridge"]=$(trim "$vlans")
        BRIDGE_FWROLE["$bridge"]=$(trim "$fwrole")
        log_debug "[Parser] Parsed $bridge → ifaces=$ifaces ip=$ipv4 vlans=$vlans type=$iface_type firewall_role=$fwrole"
    done <<< "$input"
}