#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Initialization
# ============================================================

source "$(cd "$(dirname "$0")" && cd .. &&  pwd)/lib/init.sh"
init "$@"

main()
{
    log_info "Restoring user NetworkManager configuration"
    if ! nm_restore_factory; then
        log_error "Unable to restore NetworkManager configuration"
        exit 1
    fi
    if ! nm_wait_ready 30; then
        log_error "NetworkManager did not become ready"
        exit 1
    fi
    log_info "User configuration restored successfully"
}

main "$@"