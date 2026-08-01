#!/bin/sh
set -eu

PIDFILE="/run/shm/qemu.pid"
QMP="/run/shm/qmp.sock"

fail()
{
    echo "[qemu-healthcheck] FAILED: $1"
    exit 1
}

log()
{
    echo "[qemu-healthcheck] $1"
}

#
# PID QEMU
#
[ -f "$PIDFILE" ] \
    || fail "PID file missing"
PID=$(cat "$PIDFILE")
case "$PID" in
    ''|*[!0-9]*)
        fail "Invalid PID"
        ;;
esac
kill -0 "$PID" 2>/dev/null \
    || fail "QEMU process not running"

#
# Socket QMP
#
[ -S "$QMP" ] \
    || fail "QMP socket missing"

#
# Dialogue QMP
#
QMP_RESPONSE=$(
{
    sleep 0.2
    printf '%s\n' \
    '{"execute":"qmp_capabilities"}'
    sleep 0.2
    printf '%s\n' \
    '{"execute":"query-status"}'
} | nc -U -N "$QMP" 2>/dev/null
)

#
# Validation
#
echo "$QMP_RESPONSE" \
    | grep -q '"return"' \
    || fail "No QMP response"
echo "$QMP_RESPONSE" | grep -q '"status"[[:space:]]*:[[:space:]]*"running"' \
    || fail "VM status not running"
echo "$QMP_RESPONSE" | grep -q '"running"[[:space:]]*:[[:space:]]*true' \
    || fail "VM flag not running"
log "OK - QEMU running PID=$PID"
exit 0