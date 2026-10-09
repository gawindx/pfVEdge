#!/usr/bin/env bash

# -------------------------------------------------------------------
# Restore factory backup
# -------------------------------------------------------------------

nm_restore_backup_factory()
{
    log_info "[NetworkManager] Starting factory configuration restore"
    if ! nm_factory_backup_exists; then
        log_error "[NetworkManager] Factory backup does not exist: $NM_BACKUP_DIR"
        return 1
    fi
    log_info "[NetworkManager] Factory backup found: $NM_BACKUP_DIR"
    if [[ -f "${NM_BACKUP_DIR}/empty.conf" ]]; then
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

        if ! cp -- "${NM_BACKUP_DIR}"/*.nmconnection "$NM_CONNECTION_DIR/"; then
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
# Create checkpoint for secure rollback
# -------------------------------------------------------------------

nm_checkpoint_create()
{
    local checkpoint

    log_info "[NetworkManager] Creating global checkpoint"
    log_info "[NetworkManager] Checkpoint rollback timeout: ${NM_CHECKPOINT_TIMEOUT}s"
    # Create a checkpoint using the D-Bus interface of NetworkManager
    # The CheckpointCreate method takes the following parameters:
    # - aouu: an array of object paths (empty in this case)
    # - 0: the checkpoint timeout in seconds
    # - 14: the checkpoint flags (14 means "include all connections and devices")
    #      DESTROY_ALL                  0x01
    #      DELETE_NEW_CONNECTIONS       0x02  *
    #      DISCONNECT_NEW_DEVICES       0x04  *
    #      ALLOW_OVERLAPPING            0x08  *
    # The method returns the object path of the created checkpoint.
    checkpoint="$(
        busctl --system call \
            org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager \
            org.freedesktop.NetworkManager \
            CheckpointCreate \
            aouu \
            0 \
            "$NM_CHECKPOINT_TIMEOUT" \
            14
    )" || {
        log_error "[NetworkManager] Failed to create NetworkManager checkpoint"
        return 1
    }
    NM_CHECKPOINT="${checkpoint#o }"
    NM_CHECKPOINT="${NM_CHECKPOINT#\"}"
    NM_CHECKPOINT="${NM_CHECKPOINT%\"}"
    if [[ -z "$NM_CHECKPOINT" ]]; then
        log_error "[NetworkManager] NetworkManager returned an empty checkpoint path"
        return 1
    fi
    log_info "[NetworkManager] Global checkpoint created: '$NM_CHECKPOINT'"
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
        busctl --system call \
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
    local checkpoints

    if [[ -z "$NM_CHECKPOINT" ]]; then
        log_debug "[NetworkManager] No NetworkManager checkpoint to destroy"
        return 0
    fi
    log_info "[NetworkManager] Checking NetworkManager checkpoint: $NM_CHECKPOINT"
    if ! checkpoints="$(
        busctl get-property \
            --system \
            org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager \
            org.freedesktop.NetworkManager \
            Checkpoints
    )"; then
        log_error "[NetworkManager] Unable to retrieve active checkpoints"
        return 1
    fi
    if [[ "$checkpoints" != *"\"$NM_CHECKPOINT\""* ]]; then
        log_warn "[NetworkManager] Checkpoint no longer exists; skipping destruction"
        NM_CHECKPOINT=""
        return 0
    fi
    log_info "[NetworkManager] Destroying NetworkManager checkpoint: $NM_CHECKPOINT"
    if ! busctl --system call \
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

# -------------------------------------------------------------------
# Verify if backup already exists
# -------------------------------------------------------------------

nm_factory_backup_exists()
{
    [[ -d "$NM_BACKUP_DIR" ]] || return 1
    [[ -f "${NM_BACKUP_DIR}/empty.conf" ]] && return 0

    local profile

    for profile in "${NM_BACKUP_DIR}"/*.nmconnection; do
        [[ -f "$profile" ]] && return 0
    done

    return 1
}

# -------------------------------------------------------------------
# Backup Factory Configuration
# -------------------------------------------------------------------

nm_backup_factory()
{
    if nm_factory_backup_exists; then
        log_info "[NetworkManager] Factory backup already exists: $NM_BACKUP_DIR"
        log_info "[NetworkManager] Existing factory backup will be preserved"
        return 0
    fi
    log_info "[NetworkManager] No factory backup found"
    log_info "[NetworkManager] Creating initial NetworkManager factory backup"
    if ! nm_create_backup_factory; then
        log_error "[NetworkManager] Failed to create factory backup"
        return 1
    fi
    log_info "[NetworkManager] Initial NetworkManager factory backup is ready"
    return 0
}

# -------------------------------------------------------------------
# Create factory backup
# -------------------------------------------------------------------

nm_create_backup_factory()
{
    log_info "[NetworkManager] Creating factory backup"
    mkdir -p "$NM_BACKUP_DIR" || {
        log_error "[NetworkManager] Unable to create factory backup directory: $NM_BACKUP_DIR"
        return 1
    }
    rm -f "${NM_BACKUP_DIR}"/* || {
        log_error "[NetworkManager] Unable to clean factory backup directory"
        return 1
    }
    local profiles=(
        "${NM_CONNECTION_DIR}"/*.nmconnection
    )
    if [[ ! -e "${profiles[0]}" ]]; then
        log_info "[NetworkManager] No NetworkManager connection profile found"
        log_info "[NetworkManager] Creating empty factory backup marker"
        touch "${NM_BACKUP_DIR}/empty.conf" || {
            log_error "[NetworkManager] Unable to create empty factory backup marker"
            return 1
        }
        log_info "[NetworkManager] empty factory backup marker created successfully"
    else
        log_info "[NetworkManager] Saving NetworkManager connection profiles"
        cp -- "${profiles[@]}" "$NM_BACKUP_DIR/" || {
            log_error "[NetworkManager] Unable to copy NetworkManager connection profiles"
            return 1
        }
        log_info "[NetworkManager] Factory backup created successfully"
    fi
    selinux_rcon "$NM_BACKUP_DIR/"
    return 0
}