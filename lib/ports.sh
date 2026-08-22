#!/usr/bin/env bash

# ============================================================
# Utils
# ============================================================

get_active_connection_for_iface() {
    nmcli -t -f NAME,DEVICE connection show --active | grep ":$1$" | cut -d: -f1 || true
}

warn_if_risky_interface() {
    if ip addr show "$1" | grep -q "inet "; then
        log_warn "[Attach Ports] Interface '$1' has an IP → attaching may disrupt connectivity"
    fi
}

# ============================================================
# Manage Migration
# ============================================================

handle_nm_migration() {
    local iface="$1"
    local bridge="$2"
    local existing_conn

    existing_conn=$(get_active_connection_for_iface "$iface")
    if [[ -z "$existing_conn" ]]; then
        log_debug "[Attach Ports] Active Connection for '$iface' is '$existing_conn'"
        return
    fi
    if [[ "$NM_AUTO_MIGRATE_IFACE" != "true" ]]; then
        log_error "[Attach Ports] Interface '$iface' is already managed by NetworkManager profile:"
        log_error "[Attach Ports]  \"$existing_conn\""
        log_error "[Attach Ports] "
        log_error "[Attach Ports] Automatic migration is available."
        log_error "[Attach Ports] Set NM_AUTO_MIGRATE_IFACE=true"
        exit "$E_INTERFACE"
    fi
    log_info "[Attach Ports] Migrating '$iface' to bridge '$bridge'"
    log_debug "[Attach Ports] iface down '$existing_conn' for migration"
    run nmcli connection down "$existing_conn"
    log_debug "[Attach Ports] Backup '$existing_conn' before migration"
    run nmcli connection show "$existing_conn" > "/var/tmp/${existing_conn}.bak"
    log_debug "[Attach Ports] Deleting '$existing_conn'"
    run nmcli connection delete "$existing_conn"
}

# ============================================================
# Create Podman Network
# ============================================================

# DMZ / service networks are created in "bridge" mode, directly on top
# of the host bridge that already carries pfSense's TAP for that segment
# (e.g. br-net-dmz). Containers attached to this network get their own
# MAC/IP straight on that L2 segment, exactly as if they were plugged
# into a physical switch port behind pfSense.
#
# Practical consequence: the gateway IP (network+1, see calc_network_info)
# must be configured INSIDE pfSense as that interface's own address —
# it is no longer owned by any interface on the Fedora host.
#
# Trade-off to be aware of: with bridge, the Fedora host itself cannot
# talk directly to containers on this network (bridge's well-known
# host<->child limitation). That's consistent with this project's model
# (all traffic to/from these containers should go through pfSense), but
# it does mean host-side monitoring/healthchecks can't reach them
# directly — they'd need to go through pfSense too, or use a separate
# management network.
create_podman_iface() {
    local bridge="$1"
    local iface="$2"
    local ipv4="$3"
    declare -A netinfo
    local subnet gateway

    log_debug "[Attach Ports] Create podman bridge network '$bridge' (parent=$bridge)"
    calc_network_info "$ipv4" netinfo
    log_debug "[Attach Ports] Create network with subnet '${netinfo[network]}/${netinfo[cidr]}' and gateway '${netinfo[gateway]}'"
    [[  -z "${netinfo[network]}" ]] || {
        subnet="--subnet ${netinfo[network]}/${netinfo[cidr]}"
    }
    [[  -z "${netinfo[gateway]}" ]] || {
        gateway="--gateway ${netinfo[gateway]}"
        log_warn "[Attach Ports] Gateway '${netinfo[gateway]}' must be configured on pfSense's own '$bridge' interface, not on the host"
    }
    log_debug "[Attach Ports] Create podman bridge network '$iface' attached to '$bridge' with subnet '$subnet' and gateway '$gateway'"
    run podman network exists "${bridge}" && return
    run podman network create ${subnet} ${gateway} \
        --driver bridge \
        --ipam-driver host-local \
        --disable-dns \
        --opt mode=unmanaged \
        --opt com.docker.network.bridge.name=${bridge} \
        "${bridge}"
}

# ============================================================
# Attach iface to bridge
# ============================================================

attach_interface() {
    local bridge="$1"
    local iface="$2"
    local iface_type="$3"
    local conn_name="${bridge}-${iface}"

    iface=$(trim "$iface")
    log_debug "[Attach Ports] Attach '$iface' to '$bridge'"
    run nmcli -g NAME connection show | grep -Fxq "$conn_name" && return
    [[ "$iface_type" != "podman" ]] && warn_if_risky_interface "$iface"
    handle_nm_migration "$iface" "$bridge"
    log_info "[Attach Ports] Attaching '$iface' → '$bridge'"
    log_debug "[Attach Ports] Attach '$iface' to '$bridge' as '$conn_name'"
    run nmcli connection add type bridge-slave ifname "$iface" master "$bridge" con-name "$conn_name"
    [[ "$iface_type" == "podman" ]] && return
    log_debug "[Attach Ports] Connection up '$conn_name'" 
    run nmcli connection up "$conn_name"
}

# ============================================================
# MAnage Bridge
# ============================================================

attach_bridge_ports() {
    local bridge iface iface_type ipv4

    log_info "[Attach Ports] Manage Bridges"
    for bridge in "${BRIDGE_NAMES[@]}"; do
        log_debug "[Attach Ports] Manage '$bridge'"
        iface_type="${BRIDGE_IFACE_TYPE[$bridge]}"
        ipv4="${BRIDGE_IPV4[$bridge]}"
        IFS=',' read -ra ifaces <<< "${BRIDGE_IFACES[$bridge]}"
        for iface in "${ifaces[@]}"; do
            log_debug "[Attach Ports] Attach '$iface' to '$bridge' (type='$iface_type')"
            if [[ "$iface_type" == "podman" ]]; then 
                log_debug "[Attach Ports] Create podman bridge network (no bridge-slave needed)"
                create_podman_iface "$bridge" "$iface" "$ipv4"
                continue
            fi
            [[ -z "$iface" ]] && continue
            attach_interface "$bridge" "$iface" "$iface_type"
         done
    done
}