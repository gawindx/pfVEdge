#!/usr/bin/env bash

bridge_exists() {
    nmcli -t -f NAME,TYPE connection show | grep -Fxq "$1:bridge"
}

configure_bridge_ip() {
    local bridge="$1"
    local ipv4="$2"
    local iface_type="$3"

    log_debug "[Bridges] Configure Bridge '$bridge' with address '$ipv4' and Type '$iface_type'"
    if [[ -z "$ipv4" ]]; then
        log_debug "[Bridges] Configure Bridge '$bridge' with no IP"
        run nmcli connection modify "$bridge" ipv4.method disabled ipv6.method disabled
    elif [[ "$ipv4" == "dhcp" ]]; then
        log_debug "[Bridges] Configure Bridge '$bridge' with DHCP"
        run nmcli connection modify "$bridge" ipv4.method auto ipv6.method disabled
    elif [[ "$iface_type" == "podman" ]]; then
        log_debug "[Bridges] Configure Bridge '$bridge' with no IP for podman"
        run nmcli connection modify "$bridge" ipv4.method disabled ipv6.method disabled
    else
        log_debug "[Bridges] Configure Bridge '$bridge' with manual IP '$ipv4'"
        run nmcli connection modify "$bridge" ipv4.method manual ipv4.addresses "$ipv4" ipv6.method disabled
    fi
    run nmcli connection modify "$bridge" 802-3-ethernet.mtu $V_MTU
}

ensure_bridge() {
    local bridge="$1"
    local ipv4="$2"
    local iface_type="$3"

    if ! bridge_exists "$bridge"; then
        log_debug "[Bridges] Bridge '$bridge' need to be created"
        log_info "[Bridges] Creating bridge '$1'"
        run nmcli connection add type bridge ifname "$bridge" con-name "$bridge" bridge.stp no
    fi
    configure_bridge_ip "$bridge" "$ipv4" "$iface_type"
    run nmcli connection up "$bridge"
}

create_or_validate_bridges() {
    log_debug "[Bridges] Create Bridges"
    for bridge in "${BRIDGE_NAMES[@]}"; do
        ensure_bridge "$bridge" "${BRIDGE_IPV4[$bridge]}" "${BRIDGE_IFACE_TYPE[$bridge]}"
        ip link set "$bridge" up
    done
}
