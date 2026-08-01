#!/bin/sh
set -eu

#
# Configuration
#
QMP="/run/shm/qmp.sock"
PIDFILE="/run/shm/qemu.pid"
WDG_CHECK_INTERVAL=${WDG_CHECK_INTERVAL:-30}
WDG_START_DELAY=${WDG_START_DELAY:-120}
WDG_MAX_FAIL=${WDG_MAX_FAIL:-3}
WDG_SHUTDOWN_TIMEOUT=${WDG_SHUTDOWN_TIMEOUT:-60}   
WDG_LOG_TAG="qemu-pfsense-watchdog"
FAIL_COUNT=0
START_TIME=$(date +%s)

#
# Logging
#
log()
{
    LEVEL="$1"
    MESSAGE="$2"
    echo "[$LEVEL] $MESSAGE"
    logger -t "$WDG_LOG_TAG" "[$LEVEL] $MESSAGE" 2>/dev/null || true
}

#
# Process QEMU vivant ?
#
qemu_alive()
{
    PID="$1"
    kill -0 "$PID" 2>/dev/null
}

#
# Validation PID
#
# Evite de tuer un mauvais processus
#
validate_qemu_pid()
{
    PID="$1"
    [ -d "/proc/$PID" ] || return 1
    if [ -r "/proc/$PID/cmdline" ]
    then
        grep -q "qemu-system" "/proc/$PID/cmdline"
        return $?
    fi
    return 1
}

#
# Commande QMP simple
#
qmp_pwrdown_command()
{
    {
        # laisser passer le banner QMP
        sleep 0.2
        printf '%s\n' \
        '{"execute":"qmp_capabilities"}'
        sleep 0.2
        printf '%s\n' \
        '{"execute":"system_powerdown"}'
    } | timeout 5 nc -N -U "$QMP" >/dev/null 2>&1
}

#
# Récupération état QMP
#
qmp_status()
{
    {
        sleep 0.2
        printf '%s\n' \
        '{"execute":"qmp_capabilities"}'
        sleep 0.2
        printf '%s\n' \
        '{"execute":"query-status"}'
    } | timeout 5 nc -N -U "$QMP" 2>/dev/null
}

#
# Vérification santé QEMU
#
check_qemu()
{
    PID="$1"

    #
    # Processus vivant
    #
    if ! qemu_alive "$PID"
    then
        log ERROR "QEMU process not running"
        return 1
    fi

    #
    # Socket QMP
    #
    if [ ! -S "$QMP" ]
    then
        log ERROR "QMP socket missing"
        return 1
    fi
    RESPONSE=$(qmp_status || true)
    if echo "$RESPONSE" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' &&
       echo "$RESPONSE" | grep -Eq '"running"[[:space:]]*:[[:space:]]*true'
    then
        return 0
    fi
    log ERROR "QMP status invalid"
    echo "$RESPONSE"
    return 1
}

#
# Arrêt propre pfSense
#
graceful_shutdown()
{
    PID="$1"
    log WARN "Requesting pfSense shutdown via ACPI"

    #
    # Etat avant arrêt
    #
    STATUS=$(qmp_status || true)
    log INFO "Current QMP state:"
    echo "$STATUS" | logger -t "$WDG_LOG_TAG"

    #
    # Envoi arrêt ACPI
    #
    if [ -S "$QMP" ]
    then
        qmp_pwrdown_command
    else
        log ERROR "QMP unavailable"
    fi

    #
    # Attente arrêt propre
    #
    ELAPSED=0
    while qemu_alive "$PID"
    do
        if [ "$ELAPSED" -ge "$WDG_SHUTDOWN_TIMEOUT" ]
        then
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED+5))
        log INFO "Waiting QEMU shutdown ($ELAPSED/$WDG_SHUTDOWN_TIMEOUT)"
    done

    #
    # Escalade
    #
    if qemu_alive "$PID"
    then
        log WARN "Graceful shutdown failed, sending SIGTERM"
        kill -TERM "$PID" 2>/dev/null || true
        sleep 10
        if qemu_alive "$PID"
        then
            log ERROR "QEMU still alive, sending SIGKILL"
            kill -KILL "$PID" 2>/dev/null || true
        fi
    else
        log INFO "QEMU stopped cleanly"
    fi
}

#
# Boucle principale
#
log INFO "Watchdog started"
while true
do
    sleep "$WDG_CHECK_INTERVAL"
    NOW=$(date +%s)

    #
    # Attente démarrage
    #
    if [ ! -f "$PIDFILE" ]
    then
        if [ $((NOW-START_TIME)) -lt "$WDG_START_DELAY" ]
        then
            log INFO "Waiting QEMU startup"
            continue
        fi

        log ERROR "QEMU failed to start"
        exit 1
    fi
    PID=$(cat "$PIDFILE")

    #
    # PID valide ?
    #
    if ! validate_qemu_pid "$PID"
    then
        log ERROR "Invalid QEMU PID"
        FAIL_COUNT=$((FAIL_COUNT+1))
    else
        log INFO "Checking QEMU health (PID=$PID)"
        #
        # Healthcheck
        #
        if check_qemu "$PID"
        then
            FAIL_COUNT=0
            continue
        else
            FAIL_COUNT=$((FAIL_COUNT+1))
        fi
    fi
    log WARN "Failed healthcheck $FAIL_COUNT/$WDG_MAX_FAIL"
    if [ "$FAIL_COUNT" -ge "$WDG_MAX_FAIL" ]
    then
        log ERROR "QEMU unhealthy, initiating recovery"
        graceful_shutdown "$PID"
        exit 1
    fi
done