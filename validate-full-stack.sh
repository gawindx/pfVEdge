#!/usr/bin/env bash
set -uo pipefail
# NOTE: no "-e" here on purpose — this script runs many independent checks
# and must keep going (and tally results) even when one of them fails.
# lib/init.sh below enables "-e" for its own init() call; we deliberately
# "set +e" right after it returns (see main()).

# =========================================================================
# pfVEdge — Full stack validator
#
# Modes:
#   network   → host network layer only (bridges, attachments, TAPs,
#               firewalld "pfSense" profile). Safe to run immediately
#               after pfVEdge-bridges.service, VM not required.
#   full      → network checks + container/VM checks, with a retry
#               window since pfSense needs real boot time (default).
#   recovery  → validates the "recovery" firewalld fallback instead of
#               the "pfSense" one (run this after a recovery trigger).
#
# Exit codes:
#   0 → everything OK (warnings tolerated)
#   1 → at least one WARN, no ERROR
#   2 → at least one ERROR
# =========================================================================

CONTAINER_NAME="pfVEdge"
MODE="full"
TIMEOUT=120
INTERVAL=5
QUIET=false
WITH_NAT_TEST=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --mode network|full|recovery   Validation scope (default: full)
  --timeout SECONDS               Max wait for VM-dependent checks (default: 120)
  --interval SECONDS              Poll interval while waiting (default: 5)
  --with-nat-test                 Spin up a throwaway container on the DMZ
                                   podman network to test NAT through pfSense
  --quiet                         Only print WARN/ERROR lines and the summary
  -h, --help                      This help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --with-nat-test) WITH_NAT_TEST=true; shift ;;
        --quiet) QUIET=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

case "$MODE" in
    network|full|recovery) ;;
    *) echo "Invalid --mode: $MODE (expected network|full|recovery)" >&2; exit 1 ;;
esac

# =========================================================================
# Report helpers
# =========================================================================

OK_COUNT=0
WARN_COUNT=0
ERR_COUNT=0

ts() { date '+%F %T'; }

ok() {
    OK_COUNT=$((OK_COUNT + 1))
    $QUIET && return 0
    printf "[%s] [OK]    %s\n" "$(ts)" "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "[%s] [WARN]  %s\n" "$(ts)" "$*" >&2
}

error() {
    ERR_COUNT=$((ERR_COUNT + 1))
    printf "[%s] [ERROR] %s\n" "$(ts)" "$*" >&2
}

info() {
    $QUIET && return 0
    printf "[%s] [INFO]  %s\n" "$(ts)" "$*"
}

section() {
    $QUIET && return 0
    echo ""
    echo "======================================"
    echo " $*"
    echo "======================================"
}

# Poll a command until it succeeds or timeout is reached.
# wait_until <timeout> <interval> -- <command...>
wait_until() {
    local timeout="$1" interval="$2"; shift 2
    [[ "$1" == "--" ]] && shift
    local waited=0
    while (( waited < timeout )); do
        if "$@" &>/dev/null; then
            return 0
        fi
        sleep "$interval"
        waited=$(( waited + interval ))
    done
    return 1
}

# =========================================================================
# Reuse the project's own config parsing / network validation
# (single source of truth: same code path as qemu-networks.sh)
# =========================================================================

load_project_state() {
    section "Loading project configuration"
    # init.sh runs with "set -e"; keep it isolated in a conditional so a
    # failure here is reported instead of killing this script outright.
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/init.sh"
    if init; then
        ok "Configuration loaded, bridges and TAPs validated (lib/init.sh)"
    else
        error "lib/init.sh validation failed — network layer is not in the expected state"
    fi
    # init.sh leaves "set -e" active; turn it back off for the rest of this
    # script, whose checks are expected to "fail" as a normal signal.
    set +e
}

# =========================================================================
# Section: declared bridges (topology-aware, not a generic br-* sweep)
# =========================================================================

check_bridges() {
    section "Host - Declared Bridges"

    local bridge state actual_ip expected_ip iface_type nm_state

    for bridge in "${BRIDGE_NAMES[@]}"; do
        if ! ip link show "$bridge" &>/dev/null; then
            error "$bridge does not exist (declared in config/bridges.env)"
            continue
        fi

        state=$(ip -br link show "$bridge" | awk '{print $2}')
        [[ "$state" == "UP" ]] && ok "$bridge is UP" || warn "$bridge is $state"

        nm_state=$(nmcli -t -f GENERAL.STATE connection show "$bridge" 2>/dev/null | cut -d: -f2)
        if [[ "$nm_state" == *activated* ]]; then
            ok "$bridge NetworkManager profile is activated"
        else
            warn "$bridge NetworkManager profile state: ${nm_state:-unknown}"
        fi

        iface_type="${BRIDGE_IFACE_TYPE[$bridge]:-}"
        expected_ip="${BRIDGE_IPV4[$bridge]:-}"
        actual_ip=$(ip -4 addr show "$bridge" | grep -oP '(?<=inet\s)\S+' || true)

        if [[ "$iface_type" == "podman" ]]; then
            # The bridge itself is intentionally IP-less: podman owns
            # addressing on its own bridge interface (see check_podman_ifaces).
            [[ -z "$actual_ip" ]] && ok "$bridge has no IP (expected, podman manages addressing)" \
                                   || warn "$bridge unexpectedly carries $actual_ip (podman-type bridge should be IP-less)"
        elif [[ -z "$expected_ip" ]]; then
            [[ -z "$actual_ip" ]] && ok "$bridge has no IP (as configured)" \
                                   || warn "$bridge carries $actual_ip but config declares no IP"
        elif [[ "$expected_ip" == "dhcp" ]]; then
            [[ -n "$actual_ip" ]] && ok "$bridge has a DHCP-leased IP ($actual_ip)" \
                                   || warn "$bridge configured for DHCP but has no IP yet"
        else
            if [[ "$actual_ip" == "$expected_ip" ]]; then
                ok "$bridge IP matches config ($expected_ip)"
            else
                warn "$bridge IP mismatch: expected $expected_ip, found ${actual_ip:-none}"
            fi
        fi
    done
}

# =========================================================================
# Section: interface attachments (real interfaces vs podman networks)
# =========================================================================

check_attachments() {
    section "Host - Bridge Attachments"

    local bridge iface_type ifaces_csv iface conn_name master

    for bridge in "${BRIDGE_NAMES[@]}"; do
        iface_type="${BRIDGE_IFACE_TYPE[$bridge]:-}"
        ifaces_csv="${BRIDGE_IFACES[$bridge]:-}"
        [[ -z "$ifaces_csv" ]] && continue

        if [[ "$iface_type" == "podman" ]]; then
            check_podman_iface "$bridge"
            continue
        fi

        IFS=',' read -ra ifaces <<< "$ifaces_csv"
        for iface in "${ifaces[@]}"; do
            iface="$(trim "$iface")"
            [[ -z "$iface" ]] && continue

            conn_name="${bridge}-${iface}"
            if nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "$conn_name"; then
                ok "$iface attached and active on $bridge ($conn_name)"
            else
                warn "$iface: NetworkManager connection '$conn_name' not active"
            fi

            master=$(bridge -j link show 2>/dev/null | grep -A2 "\"ifname\":\"$iface\"" | grep -oP '(?<="master":")[^"]+' || true)
            if [[ -z "$master" ]]; then
                # Fallback for systems without "bridge -j" JSON support
                bridge link show master "$bridge" 2>/dev/null | grep -qw "$iface" && master="$bridge"
            fi
            [[ "$master" == "$bridge" ]] && ok "$iface kernel-attached to $bridge" \
                                          || warn "$iface is not currently a slave of $bridge (found: '${master:-none}')"
        done
    done
}

# Podman-managed segments use the "macvlan" driver, parented directly
# on the bridge itself (lib/ports.sh: create_podman_iface, --opt
# parent="$bridge"). There is no separate podman-owned bridge device
# and nothing persistent to look for on the host: macvlan child
# interfaces are created per-container at runtime and disappear when
# the container stops, so their absence here is normal, not an error.
check_podman_iface() {
    local bridge="$1" driver parent

    if ! podman network exists "$bridge" 2>/dev/null; then
        error "podman network '$bridge' does not exist"
        return
    fi
    ok "podman network '$bridge' exists"

    driver=$(podman network inspect "$bridge" --format '{{.Driver}}' 2>/dev/null || true)
    [[ "$driver" == "macvlan" ]] && ok "podman network '$bridge' uses the macvlan driver" \
                                  || warn "podman network '$bridge' uses driver '${driver:-unknown}', expected macvlan"

    parent=$(podman network inspect "$bridge" --format '{{.NetworkInterface}}' 2>/dev/null || true)
    if [[ "$parent" == "$bridge" ]]; then
        ok "podman network '$bridge' is parented directly on $bridge"
    else
        warn "podman network '$bridge' parent is '${parent:-unknown}', expected '$bridge'"
    fi

    info "macvlan child interfaces are created per-container at runtime — nothing persistent to check on the host for '$bridge'"
}

# =========================================================================
# Section: TAP interfaces (declared TAPs, correctly named and attached)
# =========================================================================

check_taps() {
    section "Host - TAP Interfaces"

    local bridge tap

    for bridge in "${BRIDGE_NAMES[@]}"; do
        tap=$(bridge_to_tap "$bridge")
        if ! ip link show "$tap" &>/dev/null; then
            error "$tap is missing (expected for $bridge)"
            continue
        fi
        ok "$tap exists"

        if bridge link show master "$bridge" 2>/dev/null | grep -qw "$tap"; then
            ok "$tap attached to $bridge"
        else
            error "$tap exists but is not attached to $bridge"
        fi
    done
}

# =========================================================================
# Section: firewalld — "pfSense" profile (one zone per bridge)
# =========================================================================

check_firewalld_pfSense() {
    section "Host - Firewalld (pfSense profile)"

    if ! command -v firewall-cmd &>/dev/null; then
        warn "firewalld not installed — skipping"
        return
    fi

    local bridge zone target assigned_zone

    for bridge in "${BRIDGE_NAMES[@]}"; do
        zone="$bridge" # zones are named after the bridge itself (lib/firewalld.sh)

        if ! firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep -Fxq "$zone"; then
            error "firewalld zone '$zone' does not exist"
            continue
        fi

        assigned_zone=$(firewall-cmd --get-zone-of-interface="$bridge" 2>/dev/null || echo "")
        [[ "$assigned_zone" == "$zone" ]] && ok "$bridge is bound to zone '$zone'" \
                                           || warn "$bridge is bound to zone '${assigned_zone:-none}', expected '$zone'"

        target=$(firewall-cmd --permanent --zone="$zone" --get-target 2>/dev/null || echo "")
        [[ "$target" == "DROP" ]] && ok "zone '$zone' target is DROP" \
                                   || warn "zone '$zone' target is '${target:-unknown}', expected DROP"
    done
}

# =========================================================================
# Section: firewalld — "recovery" profile (single zone, all bridges)
# =========================================================================

check_firewalld_recovery() {
    section "Host - Firewalld (recovery profile)"

    if ! command -v firewall-cmd &>/dev/null; then
        warn "firewalld not installed — skipping"
        return
    fi

    local zone="recovery" target bridge ssh_port active_bridges

    if ! firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep -Fxq "$zone"; then
        error "firewalld zone '$zone' does not exist — recovery has not been applied"
        return
    fi
    ok "zone '$zone' exists"

    target=$(firewall-cmd --permanent --zone="$zone" --get-target 2>/dev/null || echo "")
    [[ "$target" == "DROP" ]] && ok "zone '$zone' target is DROP" \
                               || warn "zone '$zone' target is '${target:-unknown}', expected DROP"

    active_bridges=$(firewall-cmd --permanent --zone="$zone" --list-interfaces 2>/dev/null || echo "")
    for bridge in "${BRIDGE_NAMES[@]}"; do
        if grep -qw "$bridge" <<< "$active_bridges"; then
            ok "$bridge is attached to zone '$zone'"
        else
            error "$bridge is NOT attached to zone '$zone'"
        fi
    done

    ssh_port=$(get_ssh_port 2>/dev/null || echo "22")
    if firewall-cmd --permanent --zone="$zone" --list-ports 2>/dev/null | grep -qw "${ssh_port}/tcp"; then
        ok "SSH port ${ssh_port}/tcp is open in zone '$zone'"
    else
        error "SSH port ${ssh_port}/tcp is NOT open in zone '$zone' — you could lock yourself out"
    fi
}

# =========================================================================
# Section: host sysctl hardening
# =========================================================================

check_sysctl() {
    section "Host - Sysctl"

    local ipf brnf

    ipf=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "1")
    [[ "$ipf" == "0" ]] && ok "ip_forward disabled (routing job belongs to pfSense)" \
                         || error "ip_forward is ENABLED on the host"

    brnf=$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo "0")
    [[ "$brnf" == "0" ]] && ok "bridge-nf-call-iptables disabled" || warn "bridge-nf-call-iptables enabled"
}

# =========================================================================
# Section: Podman container state / health (VM-dependent, retried)
# =========================================================================

check_container() {
    section "Podman - Container"

    # wait_until can't take a pipeline directly, so the poll loop below is
    # written out explicitly instead of reusing the wait_until helper.
    local waited=0 running=false healthy=false
    while (( waited <= TIMEOUT )); do
        if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
            running=true
            break
        fi
        (( waited >= TIMEOUT )) && break
        sleep "$INTERVAL"
        waited=$(( waited + INTERVAL ))
    done

    if ! $running; then
        error "container '$CONTAINER_NAME' is not running (waited ${TIMEOUT}s)"
        return
    fi
    ok "container '$CONTAINER_NAME' is running"

    waited=0
    while (( waited <= TIMEOUT )); do
        if [[ "$(podman inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null)" == "healthy" ]]; then
            healthy=true
            break
        fi
        (( waited >= TIMEOUT )) && break
        sleep "$INTERVAL"
        waited=$(( waited + INTERVAL ))
    done

    if $healthy; then
        ok "container health status: healthy (within ${TIMEOUT}s)"
    else
        error "container health status did not reach 'healthy' within ${TIMEOUT}s (pfSense may still be booting, or is stuck)"
    fi
}

# =========================================================================
# Section: guest NIC attachment, via TAP carrier state
#
# Carrier == 1 means the TAP's peer (the virtio/e1000 NIC *inside* the
# pfSense guest) is up and has a driver attached. This is a much more
# reliable signal than "ip link inside the container" (which — since the
# container runs with Network=host — would just show the host's own
# interfaces again, proving nothing about the guest itself).
# =========================================================================

check_guest_nics() {
    section "Guest - Network Interface Attachment (TAP carrier)"

    local bridge tap carrier waited

    for bridge in "${BRIDGE_NAMES[@]}"; do
        tap=$(bridge_to_tap "$bridge")
        if [[ ! -e "/sys/class/net/$tap/carrier" ]]; then
            error "$tap: no carrier file, interface missing"
            continue
        fi

        waited=0
        carrier=""
        while (( waited <= TIMEOUT )); do
            carrier=$(cat "/sys/class/net/$tap/carrier" 2>/dev/null || echo "0")
            [[ "$carrier" == "1" ]] && break
            (( waited >= TIMEOUT )) && break
            sleep "$INTERVAL"
            waited=$(( waited + INTERVAL ))
        done

        if [[ "$carrier" == "1" ]]; then
            ok "$tap: carrier up → pfSense has attached a NIC driver to $bridge"
        else
            warn "$tap: no carrier after ${TIMEOUT}s → pfSense hasn't brought this interface up yet"
        fi
    done
}

# =========================================================================
# Section: VLAN trunk sniffing (best-effort, informational only)
# =========================================================================

check_vlan_trunk() {
    section "Connectivity - VLAN (trunk)"

    local tap
    tap=$(bridge_to_tap "br-trunk")

    if ! ip link show "$tap" &>/dev/null; then
        info "$tap not found — VLAN test skipped"
        return
    fi
    if ! command -v tcpdump &>/dev/null; then
        info "tcpdump not installed — VLAN test skipped"
        return
    fi
    if timeout 3 tcpdump -i "$tap" -nn -c 1 vlan &>/dev/null; then
        ok "VLAN-tagged traffic observed on $tap"
    else
        info "no VLAN traffic observed on $tap in the 3s window (may simply be idle)"
    fi
}

# =========================================================================
# Section: optional real NAT test through pfSense, via the DMZ
#
# Running from the host is not representative (Network=host means the
# container shares the host's own netns and default route — pinging
# "from the container" never actually crosses pfSense). Instead, spin up
# a disposable container on the "br-net-dmz" podman network: any traffic
# it sends has to go through pfSense's DMZ interface to reach the
# internet, which is a genuine end-to-end test of pfSense's routing/NAT.
# =========================================================================

check_nat_via_dmz() {
    section "Connectivity - NAT through pfSense (DMZ probe)"

    local dmz_bridge=""
    for bridge in "${BRIDGE_NAMES[@]}"; do
        [[ "${BRIDGE_FWROLE[$bridge]:-}" == "dmz" && "${BRIDGE_IFACE_TYPE[$bridge]:-}" == "podman" ]] && dmz_bridge="$bridge"
    done

    if [[ -z "$dmz_bridge" ]]; then
        info "no podman-backed DMZ bridge declared — NAT probe skipped"
        return
    fi
    if ! podman network exists "$dmz_bridge" 2>/dev/null; then
        warn "podman network '$dmz_bridge' missing — NAT probe skipped"
        return
    fi

    info "probing internet reachability via '$dmz_bridge' (disposable container)..."
    if podman run --rm --network "$dmz_bridge" docker.io/library/busybox:latest \
         sh -c 'ping -c 1 -W 3 8.8.8.8' &>/dev/null; then
        ok "NAT via pfSense works (DMZ container reached 8.8.8.8 through pfSense)"
    else
        error "NAT via pfSense FAILED (DMZ container could not reach the internet through pfSense)"
    fi
}

# =========================================================================
# Main
# =========================================================================

main() {
    load_project_state

    if [[ "$MODE" == "network" || "$MODE" == "full" ]]; then
        check_bridges
        check_attachments
        check_taps
        check_firewalld_pfSense
        check_sysctl
    fi

    if [[ "$MODE" == "recovery" ]]; then
        check_bridges
        check_taps
        check_firewalld_recovery
        check_sysctl
    fi

    if [[ "$MODE" == "full" ]]; then
        check_container
        check_guest_nics
        check_vlan_trunk
        $WITH_NAT_TEST && check_nat_via_dmz
    fi

    section "Summary"
    echo "OK: $OK_COUNT   WARN: $WARN_COUNT   ERROR: $ERR_COUNT"

    if (( ERR_COUNT > 0 )); then
        echo "Validation FAILED ❌"
        exit 2
    elif (( WARN_COUNT > 0 )); then
        echo "Validation completed with warnings ⚠️"
        exit 1
    else
        echo "Validation complete ✅"
        exit 0
    fi
}

main "$@"
