#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Initialization
# ============================================================

source "$(cd "$(dirname "$0")" && cd .. &&  pwd)/lib/init.sh"
init "$@"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

require_root()
{
    if [[ "${EUID}" -ne 0 ]]
    then
        log_error "This script must run as root"
        exit 1
    fi
}

ensure_directories()
{
    mkdir -p \
        "${FWD_BACKUP_DIR}" \
        "${FWD_TMP_DIR}"
}

profile_exists()
{
    [[ -d "$(profile_path "$1")" ]]
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

usage()
{
    cat <<EOF
Usage:
  $0 backup
      Create a backup of current firewalld configuration
  $0 apply <profile>
      Apply firewalld profile
      Allowed:
        user
        pfSense
        recovery
  $0 reset
      reset firewalld from /usr/lib/firewalld

Examples:
  $0 backup
  $0 apply recovery
  $0 reset
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main()
{
    require_root
    ensure_directories
    case "${1:-}" in
        backup)
            save_profile
            ;;
        apply)
            [[ $# -eq 2 ]] || usage
            apply_profile "$2"
            ;;
        reset)
            reset_firewalld
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"