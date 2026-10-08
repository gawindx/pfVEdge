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
    [[ -f "${NM_BACKUP_FACTORY}/empty.conf" ]] && return 0

    local profile

    for profile in "${NM_BACKUP_FACTORY}"/*.nmconnection; do
        [[ -f "$profile" ]] && return 0
    done

    return 1
}

# -------------------------------------------------------------------
# Private factory backup 
# -------------------------------------------------------------------

_nm_backup_factory()
{
    log_info "[NetworkManager] Creating factory backup"
    mkdir -p "$NM_BACKUP_FACTORY" || {
        log_error "[NetworkManager] Unable to create factory backup directory: $NM_BACKUP_FACTORY"
        return 1
    }
    rm -f "${NM_BACKUP_FACTORY}"/* || {
        log_error "[NetworkManager] Unable to clean factory backup directory"
        return 1
    }
    local profiles=(
        "${NM_CONNECTION_DIR}"/*.nmconnection
    )
    if [[ ! -e "${profiles[0]}" ]]; then
        log_info "[NetworkManager] No NetworkManager connection profile found"
        log_info "[NetworkManager] Creating empty factory backup marker"
        touch "${NM_BACKUP_FACTORY}/empty.conf" || {
            log_error "[NetworkManager] Unable to create empty factory backup marker"
            return 1
        }
        log_info "[NetworkManager] empty factory backup marker created successfully"
    else
        log_info "[NetworkManager] Saving NetworkManager connection profiles"
        cp -- "${profiles[@]}" "$NM_BACKUP_FACTORY/" || {
            log_error "[NetworkManager] Unable to copy NetworkManager connection profiles"
            return 1
        }
        log_info "[NetworkManager] Factory backup created successfully"
    fi
    selinux_rcon "$NM_BACKUP_FACTORY/"
    return 0
}

# -------------------------------------------------------------------
# Public backups
# -------------------------------------------------------------------

nm_backup_factory()
{
    if _nm_factory_exists; then
        log_info "[NetworkManager] Factory backup already exists: $NM_BACKUP_FACTORY"
        log_info "[NetworkManager] Existing factory backup will be preserved"
        return 0
    fi
    log_info "[NetworkManager] No factory backup found"
    log_info "[NetworkManager] Creating initial NetworkManager factory backup"
    if ! _nm_backup_factory; then
        log_error "[NetworkManager] Failed to create factory backup"
        return 1
    fi
    log_info "[NetworkManager] Initial NetworkManager factory backup is ready"
    return 0
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
    log_info "[NetworkManager] Starting factory configuration restore"
    if ! _nm_factory_exists; then
        log_error "[NetworkManager] Factory backup does not exist: $NM_BACKUP_FACTORY"
        return 1
    fi
    log_info "[NetworkManager] Factory backup found: $NM_BACKUP_FACTORY"
    if [[ -f "${NM_BACKUP_FACTORY}/empty.conf" ]]; then
        log_info "[NetworkManager] Factory backup contains no NetworkManager connection profiles"
        log_info "[NetworkManager] Stopping NetworkManager"
        if ! systemctl stop NetworkManager; then
            log_error "[NetworkManager] Failed to stop NetworkManager"
            return 1
        fi
        log_info "[NetworkManager] Removing current NetworkManager connection profiles"
        if ! find "$NM_CONNECTION_DIR" -maxdepth 1 -type f -name '*.nmconnection' -delete; then
            log_error "[NetworkManager] Failed to remove current NetworkManager connection profiles"
            systemctl start NetworkManager || true
            return 1
        fi
    else
        log_info "[NetworkManager] Factory backup contains NetworkManager connection profiles"

        log_info "[NetworkManager] Stopping NetworkManager"
        if ! systemctl stop NetworkManager; then
            log_error "[NetworkManager] Failed to stop NetworkManager"
            return 1
        fi

        log_info "[NetworkManager] Removing current NetworkManager connection profiles"

        if ! find "$NM_CONNECTION_DIR" -maxdepth 1 -type f -name '*.nmconnection' -delete; then
            log_error "[NetworkManager] Failed to remove current NetworkManager connection profiles"
            systemctl start NetworkManager || true
            return 1
        fi

        log_info "[NetworkManager] Restoring factory connection profiles"

        if ! cp -- "${NM_BACKUP_FACTORY}"/*.nmconnection "$NM_CONNECTION_DIR/"; then
            log_error "[NetworkManager] Failed to restore factory connection profiles"
            systemctl start NetworkManager || true
            return 1
        fi
        log_info "[NetworkManager] Restoring NetworkManager connection permissions"
        if ! chmod 600 "${NM_CONNECTION_DIR}"/*.nmconnection; then
            log_error "[NetworkManager] Failed to set NetworkManager connection permissions"
            systemctl start NetworkManager || true
            return 1
        fi
    fi
    log_info "[NetworkManager] Restoring SELinux context"
    selinux_rcon "$NM_CONNECTION_DIR/"
    log_info "[NetworkManager] Starting NetworkManager"
    if ! systemctl start NetworkManager; then
        log_error "[NetworkManager] Failed to start NetworkManager"
        return 1
    fi
    if ! nm_wait_ready 30; then
        log_error "[NetworkManager] NetworkManager did not become ready after factory restore"
        return 1
    fi
    log_info "[NetworkManager] Reloading NetworkManager connections"
    if ! nmcli connection reload; then
        log_error "[NetworkManager] Failed to reload NetworkManager connections"
        return 1
    fi
    log_info "[NetworkManager] Factory configuration restored successfully"
    return 0
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

# -------------------------------------------------------------------
# Create checkpoint for secure rollback
# -------------------------------------------------------------------

nm_checkpoint_create()
{
    local checkpoint

    log_info "[NetworkManager] Creating global checkpoint"
    log_info "[NetworkManager] Checkpoint rollback timeout: ${NM_CHECKPOINT_TIMEOUT}s"
    checkpoint="$(
        busctl call \
            org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager \
            org.freedesktop.NetworkManager \
            CheckpointCreate \
            aouu \
            0 \
            "$NM_CHECKPOINT_TIMEOUT" \
            6
    )" || {
        log_error "[NetworkManager] Failed to create NetworkManager checkpoint"
        return 1
    }
    NM_CHECKPOINT="${checkpoint##* }"
    if [[ -z "$NM_CHECKPOINT" ]]; then
        log_error "[NetworkManager] NetworkManager returned an empty checkpoint path"
        return 1
    fi
    log_info "[NetworkManager] Global checkpoint created: $NM_CHECKPOINT"
    return 0
}

# -------------------------------------------------------------------
# Rollback checkpoint
# -------------------------------------------------------------------

nm_checkpoint_rollback()
{
    local result

    if [[ -z "$NM_CHECKPOINT" ]]; then
        log_error "[NetworkManager] No NetworkManager checkpoint is active"
        return 1
    fi
    log_info "[NetworkManager] Rolling back NetworkManager checkpoint: $NM_CHECKPOINT"
    if ! result="$(
        busctl call \
            org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager \
            org.freedesktop.NetworkManager \
            CheckpointRollback \
            o \
            "$NM_CHECKPOINT"
    )"; then
        log_error "[NetworkManager] Failed to rollback NetworkManager checkpoint"
        return 1
    fi
    log_info "[NetworkManager] NetworkManager checkpoint rollback completed"
    log_debug "[NetworkManager] Checkpoint rollback result: $result"
    NM_CHECKPOINT=""
    return 0
}

# -------------------------------------------------------------------
# Destroy checkpoint
# -------------------------------------------------------------------

nm_checkpoint_destroy()
{
    if [[ -z "$NM_CHECKPOINT" ]]; then
        log_debug "[NetworkManager] No NetworkManager checkpoint to destroy"
        return 0
    fi
    log_info "[NetworkManager] Destroying NetworkManager checkpoint: $NM_CHECKPOINT"
    if ! busctl call \
        org.freedesktop.NetworkManager \
        /org/freedesktop/NetworkManager \
        org.freedesktop.NetworkManager \
        CheckpointDestroy \
        o \
        "$NM_CHECKPOINT" > /dev/null; then
        log_error "[NetworkManager] Failed to destroy NetworkManager checkpoint"
        return 1
    fi
    NM_CHECKPOINT=""
    log_info "[NetworkManager] NetworkManager checkpoint destroyed"
    return 0
}