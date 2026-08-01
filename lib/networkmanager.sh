#!/usr/bin/env bash

# -------------------------------------------------------------------
# Compute configuration hash
# -------------------------------------------------------------------

nm_compute_hash()
{
    find "$NM_CONNECTION_DIR" \
        -type f \
        -name "*.nmconnection" \
        -print0 2>/dev/null \
    | sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum \
    | awk '{print $1}'
}

# -------------------------------------------------------------------
# Detect changes
#
# return:
# 0 changed
# 1 unchanged
# -------------------------------------------------------------------

nm_has_changed()
{
    local current
    current=$(nm_compute_hash)
    [[ ! -f "$NM_HASH_FILE" ]] && return 0
    [[ "$current" != "$(cat "$NM_HASH_FILE")" ]]
}

# -------------------------------------------------------------------
# Update current hash
# -------------------------------------------------------------------

nm_update_hash()
{
    mkdir -p "$NM_BACKUP_DIR"
    nm_compute_hash > "$NM_HASH_FILE"
}

# -------------------------------------------------------------------
# Generic backup
# -------------------------------------------------------------------

_nm_backup()
{
    local destination="$1"
    if ! nm_has_changed; then
        log_info "[NM] NetworkManager configuration unchanged"
        return 0
    fi
    mkdir -p "$destination"
    cp -a "${NM_CONNECTION_DIR}/." "$destination/"
    nm_update_hash
    log_info "[NM] Backup created: $destination"
}

# -------------------------------------------------------------------
# Private check factory backup exists 
# -------------------------------------------------------------------

_nm_factory_exists()
{
    [[ -d "$NM_BACKUP_FACTORY" ]] || return 1
    #
    # Empty factory backup
    #
    [[ -f "$NM_BACKUP_FACTORY/empty.conf" ]] && return 0
    #
    # Standard backup
    #
    find "$NM_BACKUP_FACTORY" \
        -maxdepth 1 \
        -type f \
        -name "*.nmconnection" \
        | grep -q .
}

# -------------------------------------------------------------------
# Private factory backup 
# -------------------------------------------------------------------

_nm_backup_factory()
{
    local destination="$NM_BACKUP_FACTORY"

    if _nm_factory_exists; then
        if [[ "$NM_FORCE_FACTORY_BACKUP" != "true" ]]; then
            log_info "[NM] Factory backup already exists"
            return 0
        fi
        log_warn "[NM] Replacing factory backup"
        rm -rf "$destination"
    fi
    mkdir -p "$destination"
    log_debug "[NM] Backing up NetworkManager to $destination"
    log_debug "[NM] Source: $NM_CONNECTION_DIR"
    log_debug "[NM] Connection files:"

    # ----------------------------------------------------------------------
    # No NetworkManager configuration
    # ----------------------------------------------------------------------

    if ! find "$NM_CONNECTION_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.nmconnection" \
        | grep -q .
    then
        log_debug "[NM] No NetworkManager configuration found"
        touch "$destination/empty.conf"
        log_info "[NM] Factory backup created (empty configuration)"
        return 0
    fi
    find "$NM_CONNECTION_DIR" -type f -name "*.nmconnection" | while read -r file; do
        log_debug "[NM]   - $file"
    done
    cp -a "${NM_CONNECTION_DIR}/." "$destination/"
    log_info "[NM] Factory backup created"
}

# -------------------------------------------------------------------
# Public backups
# -------------------------------------------------------------------

nm_backup_factory()
{
    _nm_backup_factory
}

nm_backup_stable()
{
    _nm_backup "$NM_BACKUP_STABLE"
}

nm_backup_transaction()
{
    _nm_backup "$NM_BACKUP_TRANSACTION"
}

# -------------------------------------------------------------------
# Generic restore
# -------------------------------------------------------------------

_nm_restore()
{
    local source="$1"
    if [[ ! -d "$source" ]]; then
        log_error "[NM] Backup does not exist: $source"
        return 1
    fi
    log_warn "[NM] Restoring NetworkManager from $source"
    systemctl stop NetworkManager
    rm -f "${NM_CONNECTION_DIR}"/*
    cp -a "${source}/." "$NM_CONNECTION_DIR/"
    selinux_rcon "$NM_CONNECTION_DIR/"
    chmod 600 "${NM_CONNECTION_DIR}"/* 2>/dev/null
    nm_reload
    if nm_has_bridges; then
        nm_remove_bridges
    fi
    nm_update_hash
    log_info "[NM] Restore completed"
}

# -------------------------------------------------------------------
# Public restore
# -------------------------------------------------------------------

nm_restore_factory()
{
    if [[ -f "$NM_BACKUP_FACTORY/empty.conf" ]]; then
        log_warn "[NM] Restoring empty NetworkManager configuration"
        systemctl stop NetworkManager
        rm -f "${NM_CONNECTION_DIR}"/*
        nm_reload
        if nm_has_bridges; then
            nm_remove_bridges
        fi
        nm_update_hash
        log_info "[NM] Restore completed"
        return 0
    else
        _nm_restore "$NM_BACKUP_FACTORY"
    fi
}

nm_restore_stable()
{
    _nm_restore "$NM_BACKUP_STABLE"
}

nm_restore_transaction()
{
    _nm_restore "$NM_BACKUP_TRANSACTION"
}

# -------------------------------------------------------------------
# NetworkManager reset
# -------------------------------------------------------------------

nm_reset()
{
    log_warn "[NM] Resetting NetworkManager"
    nm_backup_transaction
    systemctl stop NetworkManager
    rm -f "${NM_CONNECTION_DIR}"/*
    rm -f /var/lib/NetworkManager/NetworkManager.state
    nm_reload
    if nm_has_bridges; then
        nm_remove_bridges
    fi
    log_info "[NM] NetworkManager reset done"
}

# -------------------------------------------------------------------
# Reload / restart
# -------------------------------------------------------------------

nm_reload()
{
    systemctl start NetworkManager
    if ! nm_wait_ready 30; then
        log_error "[NM] NetworkManager is not ready"
        return 1
    fi
    nmcli connection reload
}

nm_restart()
{
    systemctl restart NetworkManager
}

# -------------------------------------------------------------------
# Wait ready
# -------------------------------------------------------------------

nm_wait_ready()
{
    local timeout="${1:-30}"
    local i=0
    while (( i < timeout )); do
        if nmcli general status >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((i++))
    done
    return 1
}

# -------------------------------------------------------------------
# Remove bridge profiles only
# -------------------------------------------------------------------

nm_remove_bridges()
{
    local bridges
    bridges=$(nmcli -t -f NAME,TYPE connection show \
        | awk -F: '$2=="bridge"{print $1}')
    [[ -z "$bridges" ]] && return 0
    while read -r bridge; do
        if [[ " ${BRIDGE_NAMES[*]} " =~ [[:space:]]${bridge}[[:space:]] ]]; then
            log_info "[NM] Removing bridge: $bridge"
            nmcli connection delete "$bridge"
        fi
    done <<< "$bridges"
}

# -------------------------------------------------------------------
# Check bridges
# -------------------------------------------------------------------

nm_has_bridges()
{
    nmcli -t -f TYPE connection show \
        | grep -qx "bridge"
}