#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Entry : Launch Firewalld configuration
# -----------------------------------------------------------------------------

configure_firewall()
{
    local mode="${1:-pfsense}"

    if ! check_firewalld; then
        log_warn "[Firewalld] firewalld not installed → skipping"
        return
    fi
    case "$mode" in
        pfsense)
            apply_profile pfsense
            ;;
        recovery)
            apply_profile recovery
            ;;
        *)
            log_error "[Firewalld] Unknown firewall mode: ${mode}"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Utils
# -----------------------------------------------------------------------------

init_zone()
{
    local zone="$1"
    
    if zone_exists "${zone}"; then
        log_debug "[Firewall] Zone ${zone} already exists"
        firewall-cmd \
            --permanent \
            --delete-zone="${zone}"
        log_debug "[Firewall] Zone ${zone} has been deleted"
    fi
    log_debug "[Firewalld] Creating ${zone} zone"
    firewall-cmd \
        --permanent \
        --new-zone="${zone}"
}

zone_exists()
{
    local zone="$1"

    firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -Fxq "$zone"
}

# -----------------------------------------------------------------------------
# Create pfsense/recovery Zones
# -----------------------------------------------------------------------------

create_pfsense_fwall_rules()
{
    log_info "[Firewalld] Applying pfSense firewall profile"
    for br in "${BRIDGE_NAMES[@]}"; do
        local zone="$br"

        # NOTE: For "podman"-type bridges (e.g., br-net-dmz), this DROP
        # zone protects only the host itself (it has no IP address on the bridge).
        # Traffic between pfSense and macvlan containers remains pure L2
        # (bridge-nf-call-iptables=0); it never passes through this zone.
        # Actual filtering for this segment is therefore entirely delegated to pfSense.
        init_zone "${zone}"
        log_debug "[Firewalld] Assigning ${br} -> ${zone}"
        run firewall-cmd \
            --permanent \
            --zone="${zone}" \
            --add-interface="${br}"
        log_debug "[Firewalld] OK, ${br} set to${zone}" 
        # Security: Fedora must not expose services
        run firewall-cmd \
            --permanent \
            --zone="${zone}" \
            --set-target=DROP
        log_debug "[Firewalld] Default's zone ${zone} set to Drop" 
        if [ "${FWD_ALLOW_SSH_HOST}" = "true" ]; then
            # Detect SSH port
            ssh_port=$(get_ssh_port)
            log_debug "[Firewalld] ssh allowed by user on port : ${ssh_port}/tcp" 
            # SSH access
            run firewall-cmd \
                --permanent \
                --zone="$zone" \
                --add-port="$ssh_port"/tcp
        fi
    done
    log_info "[Firewalld] pfSense firewall profile applied ✅"
}

create_recovery_fwall_rules()
{
    local zone="recovery"
    local ssh_port

    init_zone "${zone}"
    log_debug "[Firewalld] Applying Drop Target for $zone"
    # Default deny
    firewall-cmd \
        --permanent \
        --zone="${zone}" \
        --set-target=DROP
    # Attach all known bridges
    for bridge in "${BRIDGE_NAMES[@]}"; do
        log_debug "[Firewalld] Recovery attach ${bridge} to $zone"
        firewall-cmd \
            --permanent \
            --zone="${zone}" \
            --add-interface="${bridge}"
    done
    # Detect SSH port
    ssh_port=$(get_ssh_port)
    log_debug "[Firewalld] ssh allowed for recovery on port : ${ssh_port}/tcp" 
    # SSH access
    run firewall-cmd \
        --permanent \
        --zone="$zone" \
        --add-port="$ssh_port"/tcp \
        --add-service=ssh
    # ICMP useful for diagnostics
    log_debug "[Firewalld] add ICMP for diagnostics" 
    run firewall-cmd \
        --permanent \
        --zone="$zone" \
        --add-service=dhcpv6-client || true
    log_info "[Firewalld] Recovery firewall generated"
}

# -----------------------------------------------------------------------------
# Save / Apply
# -----------------------------------------------------------------------------

backup_current_firewalld()
{
    local backup_dir="${FWD_TMP_DIR}/current"

    log_info "[Firewalld] Backing up current configuration"
    rm -rf "${backup_dir}"
    mkdir -p "${backup_dir}"
    cp -a "${FWD_CFG_DIR}/." "${backup_dir}/"
    log_info "[Firewalld] Temporary backup created"
}

restore_current_firewalld()
{
    local backup_dir="${FWD_TMP_DIR}/current"

    if [[ ! -d "${backup_dir}" ]]; then
        log_warn "[Firewalld] No temporary firewalld backup found"
        return 1
    fi
    log_info "[Firewalld] Restoring previous configuration"
    log_debug "[Firewalld] Restoring from ${backup_dir}"
    log_debug "[Firewalld] Restoring to ${FWD_CFG_DIR}"
    log_debug "[Firewalld] Stopping Firewalld"
    systemctl stop firewalld
    rm -rf "${FWD_CFG_DIR:?}/"*
    cp -a "${backup_dir}/." "${FWD_CFG_DIR}/"
    selinux_rcon "${FWD_CFG_DIR}" || true
    log_debug "[Firewalld] Configuration Restored"
    systemctl start firewalld
    log_debug "[Firewalld] Firewalld restarted"
    firewall-cmd --reload
    log_info "[Firewalld] Previous configuration restored"
}

# -----------------------------------------------------------------------------
# Reset firewalld configuration
# -----------------------------------------------------------------------------

reset_firewalld()
{
    log_info "[Firewalld] Resetting firewalld configuration"
    systemctl stop firewalld
    rm -rf /etc/firewalld/*
    cp -a /usr/lib/firewalld/. /etc/firewalld/
    selinux_rcon "/etc/firewalld"
    systemctl start firewalld
}

# -----------------------------------------------------------------------------
# MAnage Profiles
# -----------------------------------------------------------------------------

save_profile()
{
    local profile="user"
    local destination

    destination=$(profile_path "user")
    log_info "[Firewalld] Saving firewalld Actual configuration"
    rm -rf "${destination}"
    mkdir -p "${destination}"
    cp -a "${FWD_CFG_DIR}/." "${destination}/"
    log_info "[Firewalld] Configuration saved: ${destination}"
}

apply_profile()
{
    local profile="$1"
    local source

    log_info "[Firewalld] Applying firewalld profile: ${profile}"
    case $profile in
        user)
            source=$(profile_path "$profile")
            if [[ ! -d "${source}" ]]; then
                log_error "[Firewalld] Profile does not exist: ${profile}"
                exit 1
            fi
            mkdir -p "${FWD_TMP_DIR}"
            # Backup current running configuration
            rm -rf "${FWD_TMP_DIR}/current"
            cp -a "${FWD_CFG_DIR}" "${FWD_TMP_DIR}/current"
            systemctl stop firewalld
            rm -rf "${FWD_CFG_DIR:?}/"*
            cp -a "${source}/." "${FWD_CFG_DIR}/"
            # Restore SELinux context if available
            selinux_rcon "${FWD_CFG_DIR}"
            ;;
        pfsense)
            generate_profile pfsense
            ;;
        recovery)
            generate_profile recovery
            ;;
        *)
            ;;
    esac
    systemctl start firewalld
    firewall-cmd --reload
    log_info "Profile applied successfully"
}

# -----------------------------------------------------------------------------
# Generate profiles
# -----------------------------------------------------------------------------

generate_profile()
{
    local profile="$1"

    backup_current_firewalld
    {
        reset_firewalld
        log_info "[Firewalld] Generating ${profile} firewalld profile"
        case "$profile" in
            pfsense)
                create_pfsense_fwall_rules
                ;;
            recovery)
                log_info "[Firewalld] Generating recovery firewalld profile"
                create_recovery_fwall_rules
                ;;
        esac
        firewall-cmd --reload
    } || restore_current_firewalld
}