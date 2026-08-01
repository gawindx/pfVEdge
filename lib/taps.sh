#!/usr/bin/env bash

# ============================================================
# Build TAP name
# ============================================================

bridge_to_tap()
{
    local bridge="$1"

    echo "${TAP_PREFIX}-${bridge#br-}"
}

# ============================================================
# Create TAP interfaces
# ============================================================

create_taps()
{
    local bridge
    local tap
    local taps=()

    for bridge in "${BRIDGE_NAMES[@]}"; do
        tap=$(bridge_to_tap "$bridge")
        if ip link show "$tap" >/dev/null 2>&1; then
            log_debug "[TAP] Exists: $tap"
            ip link delete "$tap" || true
            log_debug "[TAP] Removed: $tap"
        fi
        log_info "[TAP] Creating $tap -> $bridge"
        ip tuntap add dev "$tap" mode tap
        ip link set "$tap" master "$bridge"
        ip link set "$tap" up
        taps+=("$tap")
    done
    TAP_IFACES="${taps[*]}"
}

# ============================================================
# Remove TAP interfaces
# ============================================================

cleanup_taps()
{
    local bridge
    local tap

    for bridge in "${BRIDGE_NAMES[@]}"; do
        tap=$(bridge_to_tap "$bridge")
        if ip link show "$tap" >/dev/null 2>&1; then
            log_info "[TAP] Removing $tap"
            ip link delete "$tap"
            log_debug "[TAP] Removed: $tap"
        fi
    done
}

# ============================================================
# Validate TAP
# ============================================================

validate_taps()
{
    local bridge
    local tap

    for bridge in "${BRIDGE_NAMES[@]}"; do
        tap=$(bridge_to_tap "$bridge")
        if ! ip link show "$tap" >/dev/null 2>&1; then
            log_error "[TAP] Missing $tap"
            return 1
        fi
        if ! bridge link show master "$bridge" \
            | grep -qw "$tap"
        then
            log_error "[TAP] $tap not attached to $bridge"
            return 1
        fi
    done
    return 0
}

# ============================================================
# Generate QEMU environment
# ============================================================

write_qemu_network_env()
{
    local file="$1"

    mkdir -p "$(dirname "$file")"
    {
        echo "# Generated file - do not edit"
        echo
        echo "TAP_IFACES=\"$TAP_IFACES\"" > "$QEMU_NETWORK_ENV"
    } > "$file"
    chmod 600 "$file"
    log_debug "[TAP] Environment written: $file"
}