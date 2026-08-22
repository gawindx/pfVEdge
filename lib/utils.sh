#!/usr/bin/env bash

run() {
    local output rc

    output=$("$@" 2>&1)
    rc=$?
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        log_debug "[RUN] $*"
        [[ -n "$output" ]] && log_debug "$output"
    elif (( rc != 0 )); then
        log_error "Command failed ($rc): $*"
        [[ -n "$output" ]] && log_error "$output"
    fi
    return $rc
}

trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

selinux_rcon()
{
    local fwd_dir="$1"

    if [[ -d "${fwd_dir}" ]] && \
    command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "${fwd_dir}" || true
    fi
}

# ==========================================
# Sysctl hardening (safe minimal)
# ==========================================

apply_sysctl() {

    log_debug "[Utils] Applying sysctl hardening"
    run sysctl -w net.ipv4.ip_forward=0 || true
    run sysctl -w net.bridge.bridge-nf-call-iptables=0 || true
    run sysctl -w net.bridge.bridge-nf-call-ip6tables=0 || true
    run sysctl -w net.bridge.bridge-nf-call-arptables=0 || true
    run sysctl -w net.ipv4.conf.all.rp_filter=0 || true
    run sysctl -w net.ipv4.conf.default.rp_filter=0 || true
    run sysctl -w net.ipv4.conf.all.proxy_arp=0 || true
    run sysctl -w net.ipv4.conf.default.proxy_arp=0 || true
    run sysctl -w net.ipv4.conf.all.send_redirects=0 || true
    run sysctl -w net.ipv4.conf.default.send_redirects=0 || true
    run sysctl -w net.ipv4.conf.all.accept_redirects=0 || true
    run sysctl -w net.ipv4.conf.default.accept_redirects=0 || true
    run sysctl -w net.ipv4.conf.all.secure_redirects=0 || true
    run sysctl -w net.ipv4.conf.default.secure_redirects=0 || true
}

# ==========================================
# MTU management
# ==========================================

set_mtu() {
    for bridge in "${BRIDGE_NAMES[@]}"; do
        log_debug "[Utils] Setting MTU 1500 on $bridge"
        run nmcli connection modify "$bridge" 802-3-ethernet.mtu $V_MTU || true
    done
}

# ==========================================
# Firewall management
# ==========================================

get_ssh_port()
{
    local port
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')
    echo "${port:-22}"
}

profile_path()
{
    echo "${FWD_BACKUP_DIR}/$1"
}

check_firewalld()
{
 if ! command -v firewall-cmd &>/dev/null; then
        return 1
    fi
    return 0
}

ip_to_int() {
  local IFS="."
  read -r a b c d <<< "$1"
  echo "$(( (a<<24) + (b<<16) + (c<<8) + d ))"
}

int_to_ip() {
  local ip="$1"
  echo "$(( (ip>>24)&255 )).$(( (ip>>16)&255 )).$(( (ip>>8)&255 )).$(( ip&255 ))"
}

calc_network_info() {
  local input="$1"
  declare -n result=$2  # référence

  local ip=${input%/*}
  local cidr=${input#*/}

  local ip_int=$(ip_to_int "$ip")
  local mask=$(( 0xFFFFFFFF << (32-cidr) & 0xFFFFFFFF ))

  local net=$(( ip_int & mask ))

  result[cidr]=$cidr
  result[network]=$(int_to_ip "$net")

  if [ "$cidr" -le 30 ]; then
    result[gateway]=$(int_to_ip $(( net + 1 )))
  else
    result[gateway]=""
  fi
}