#!/usr/bin/env bash
set -euo pipefail

INIT_NETWORK=false

# ============================================================
# Initialization
# ============================================================

source "$(pwd)/lib/init.sh"
init "$@"

# ============================================================
# Remove ready file if exists
# ============================================================

rm -f /run/pfVEdge/network.ready

# ============================================================
# Context
# ============================================================

log_info "[Network] Starting qemu network preparation"
log_debug "BRIDGES_NETWORKS=$BRIDGES_NETWORKS"

# ============================================================
# Transaction backup
# ============================================================

log_info "[Network] Checking factory backup"
nm_backup_factory
log_info "[Network] Creating transaction backup"
nm_backup_transaction

# ============================================================
# NetworkManager preparation
# ============================================================

if [[ "${NET_INIT}" == "true" || ! -e "${NET_STATE_FILE}" ]]; then
    log_debug "[NETWORK] NET_INT set to true or ${NET_STATE_FILE} doesn't exists"
    log_debug "[NETWORK] Network will be fully initialised"
    [[ -e "${NET_STATE_FILE}" ]] && rm -f ${NET_STATE_FILE}
    INIT_NETWORK=true
fi

if [[ "${INIT_NETWORK}" == "true" ]]; then
    log_info "[Network] Reset NetworkManager"
    nm_reset
fi

# ============================================================
# Bridges
# ============================================================

log_info "[Network] Creating bridges"
create_or_validate_bridges
log_info "[Network] Attaching bridge ports"
attach_bridge_ports
log_info "[Network] Applying MTU"
set_mtu
log_info "[Network] Applying sysctl"
apply_sysctl
log_info "[Network] Verify if User's config exists"
[[ ! -d "$(profile_path recovery)" ]] && \
    log_info "[Network] User's config missing, create it!"
save_profile
log_info "[Network] Configuring Firewalld for pfSense"
configure_firewall pfSense

# ============================================================
# Validate bridges
# ============================================================

if ! validate_bridges
then
    log_error "[Network] Bridge validation failed"
    nm_restore_transaction
    exit 1
fi

# ============================================================
# TAP creation
# ============================================================

log_info "[Network] Creating TAP interfaces"
if ! create_taps
then
    log_error "[Network] TAP creation failed"
    nm_restore_transaction
    exit 1
fi

if ! validate_taps
then
    log_error "[Network] TAP validation failed"
    cleanup_taps
    nm_restore_transaction
    exit 1
fi

# ============================================================
# Commit
# ============================================================

log_info "[Network] Saving stable configuration"
nm_backup_stable

# ============================================================
# Export QEMU environment
# ============================================================

write_qemu_network_env "$QEMU_NETWORK_ENV"
log_info "[Network] Network preparation completed ✅"

# ============================================================
# Create Ready File for QEMU Environment
# ============================================================

touch /run/pfVEdge/network.ready
touch "${NET_STATE_FILE}"