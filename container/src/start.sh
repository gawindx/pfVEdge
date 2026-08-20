#!/usr/bin/env bash
set -Eeuo pipefail

log()   { echo "[pfVEdge][INFO] $*"; }
warn()  { echo "[pfVEdge][WARN] $*" >&2; }
error() { echo "[pfVEdge][ERROR] $*" >&2; }

ENV_FILE="/tmp/qemu-tap-pfSense.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error "Missing TAP env file inside container"
    exit 1
fi
source "$ENV_FILE"

# ==========================================
# Configurable interface order
# ==========================================

IFACE_ORDER="${TAP_IFACES:-}"
if [[ -z "$IFACE_ORDER" ]]; then
    log "No TAP_IFACES provided → skipping"
    return 0
fi

# ==========================================
# Network device model
# ==========================================
#
# Default kept to e1000 for compatibility
#
# Examples:
#
# QEMU_NET_MODEL=e1000
# QEMU_NET_MODEL=virtio-net-pci
#

NET_MODEL="${QEMU_NET_MODEL:-e1000}"
case "$NET_MODEL" in
    e1000)
        ;;
    virtio-net-pci)
        ;;
    *)
        error "Unsupported network model: $NET_MODEL"
        error "Supported models: e1000, virtio-net-pci"
        log "Using default: e1000"
        NET_MODEL="e1000"
        ;;
esac
log "Using QEMU network model: $NET_MODEL"

# ==========================================
# Optional virtio tuning
# ==========================================
#
# Disabled by default.
# Can be enabled later if required.
#
NET_MODEL_OPTIONS=""
if [[ "$NET_MODEL" == "virtio-net-pci" ]]; then
    if [[ "${QEMU_VIRTIO_NET_MQ:-false}" == "true" ]]; then
        NET_MODEL_OPTIONS=",mq=on,vectors=6"
        log "Virtio multiqueue enabled"
    fi
fi

# ==========================================
# MAC generator (stable)
# ==========================================
mac_from_name() {
    local name="$1"
    local hex
    hex=$(echo -n "$name" | md5sum | cut -c1-8)
    printf "52:54:%s:%s:%s:%s\n" \
        "${hex:0:2}" \
        "${hex:2:2}" \
        "${hex:4:2}" \
        "${hex:6:2}"
}

# ==========================================
# Build args
# ==========================================
QEMU_NET_ARGS=""
slot=1
for tap in $IFACE_ORDER
do
    mac=$(mac_from_name "$tap")
    log "Mapping $tap → $tap → MAC $mac → slot $slot"
    #
    # Root port required for q35
    #
    QEMU_NET_ARGS+=" -device pcie-root-port,id=rp${slot},chassis=${slot},port=${slot}"
    #
    # TAP backend
    #
    QEMU_NET_ARGS+=" -netdev tap,id=${tap},ifname=${tap},script=no,downscript=no"
    #
    # NIC model
    #
    QEMU_NET_ARGS+=" -device ${NET_MODEL}${NET_MODEL_OPTIONS},netdev=${tap},mac=${mac},bus=rp${slot}"
    slot=$((slot + 1))
done

# ==========================================
# Inject safely
# ==========================================
ARGUMENTS="${ARGUMENTS:-}"
if [[ "$ARGUMENTS" != *"-netdev tap"* ]]; then
    ARGUMENTS="${ARGUMENTS} ${QEMU_NET_ARGS}"
else
    warn "TAP already injected → skipping"
fi

# ==========================================
# QMP socket
# ==========================================
if [[ "$ARGUMENTS" != *"-qmp unix:"* ]]; then
    ARGUMENTS="${ARGUMENTS} -qmp unix:/run/shm/qmp.sock,server,wait=off"
else
    warn "QMP already configured → skipping"
fi
export ARGUMENTS

log "Network mapping complete ✅"

# ==========================================
# Watchdog
# ==========================================
if [[ -x "/healthcheck/watchdog.sh" ]]; then
    log "Starting watchdog"
    /healthcheck/watchdog.sh &
else
    warn "Watchdog not found or not executable"
fi

return 0