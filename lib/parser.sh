#!/usr/bin/env bash

parse_networks() {
    local input="$1"

    declare -gA BRIDGE_IFACE_TYPE
    declare -gA BRIDGE_IFACES
    declare -gA BRIDGE_IPV4
    declare -gA BRIDGE_IP_GW
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
        IFS=':' read -r bridge iface_type ifaces ipv4 fwrole <<< "$line"
        bridge="br-$bridge"
        validate_bridge_name "$bridge"
        if [[ -n "${seen[$bridge]:-}" ]]; then
            log_error "[Parser] Duplicate bridge: $bridge"
            exit "$E_VALIDATION"
        fi
        seen[$bridge]=1
        [[ -n "$iface_type" ]] && validate_iface_type "$iface_type" || {
            log_error "[Parser] Invalid bridge configuration for $bridge (empty iface_type)"
            exit "$E_VALIDATION"
        }
        if [[ -n "$ipv4" ]]; then
            IFS=',' read -ra arr <<< "$ipv4"
            clean=()
            for idx in "${!arr[@]}"; do
                val=$(trim "${arr[idx]}")
                [[ -z "$val" ]] && continue
                clean["$idx"]="$val"
            done
            ipv4="${clean[0]}"
            validate_ipv4 "$ipv4" "$iface_type"
            if [[ "${#clean[@]}" -gt 1 ]]; then
                ipv4gw="${clean[1]}"
                validate_ipv4gw "$ipv4gw"
            else
                ipv4gw=""
            fi
        else
            if [[ "$iface_type" == "podman" ]]; then
                log_error "[Parser] Podman bridge '$bridge' must have a static IP (not empty)"
                exit "$E_VALIDATION"
            fi
        fi
        if [[ -n "$ifaces" ]]; then
            validate_interfaces "$ifaces"
        else 
            log_error "[Parser] Invalid bridge configuration for $bridge (no interfaces specified)"
            exit "$E_VALIDATION"
        fi
        if [[ -z "$fwrole" ]]; then
            fwrole="wan"
        else
            validate_fw_role "$fwrole"
        fi

        BRIDGE_NAMES+=("$(trim "$bridge")")
        BRIDGE_IFACE_TYPE["$bridge"]=$(trim "$iface_type")
        BRIDGE_IFACES["$bridge"]=$(trim "$ifaces")
        BRIDGE_IPV4["$bridge"]=$(trim "$ipv4")
        BRIDGE_IP_GW["$bridge"]=$(trim "$ipv4gw")
        BRIDGE_FWROLE["$bridge"]=$(trim "$fwrole")
        log_debug "[Parser] Parsed $bridge → ifaces=$ifaces type=$iface_type ip=$ipv4 firewall_role=$fwrole"
    done <<< "$input"
}