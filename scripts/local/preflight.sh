#!/bin/bash
# Validate the local testbed before running traffic. Read-only: changes nothing.
# Run this on the ICE LAKE (the receiver).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/_common.sh"
load_config "$HERE"

FAILED=0

step "Resolved configuration"
info "repo        : $REPO_DIR"
info "server (me) : $SSH_USER-local  $SERVER_IP on $SERVER_INTF"
info "client (ssh): $SSH_USER@$SSH_HOST  ->  $CLIENT_IP on $CLIENT_INTF"
info "workload    : $NUM_FLOWS flows, ${DURATION}s, cca=$CCA, bw=$BANDWIDTH"
info "tuning      : APPLY_NET_TUNING=$APPLY_NET_TUNING"

# --------------------------------------------------------------------- local
step "Local machine (receiver / Ice Lake)"

for t in iperf3 ssh python3 taskset; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t present"
    else bad "$t MISSING  ->  sudo apt-get install -y ${t/taskset/util-linux}"; fi
done

if [ -e "/sys/class/net/$SERVER_INTF" ]; then
    ok "interface $SERVER_INTF exists"
    state=$(cat "/sys/class/net/$SERVER_INTF/operstate" 2>/dev/null)
    if [ "$state" = "up" ]; then ok "$SERVER_INTF is up"
    else bad "$SERVER_INTF state=$state  ->  sudo ip link set $SERVER_INTF up"; fi

    if ip -br addr show "$SERVER_INTF" 2>/dev/null | grep -qw "$SERVER_IP/[0-9]*"; then
        ok "$SERVER_IP is configured on $SERVER_INTF"
    else
        bad "$SERVER_IP not on $SERVER_INTF (have: $(ip -br addr show "$SERVER_INTF" 2>/dev/null | awk '{$1="";$2="";print}' | xargs))"
    fi

    speed=$(cat "/sys/class/net/$SERVER_INTF/speed" 2>/dev/null)
    numa=$(cat "/sys/class/net/$SERVER_INTF/device/numa_node" 2>/dev/null)
    info "link speed ${speed:-?} Mb/s, NIC on NUMA node ${numa:-?}"
else
    bad "interface $SERVER_INTF does not exist  ->  check 'ip -br addr'"
fi

[ -d "$REPO_DIR/scripts/local" ] && ok "repo layout looks right" \
    || bad "repo layout unexpected at $REPO_DIR"

# ---------------------------------------------------------------- data plane
step "Data-plane connectivity"
if ping -c 2 -W 3 -I "$SERVER_INTF" "$CLIENT_IP" >/dev/null 2>&1; then
    rtt=$(ping -c 3 -W 3 -I "$SERVER_INTF" "$CLIENT_IP" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    ok "$CLIENT_IP reachable over $SERVER_INTF (avg rtt ${rtt:-?} ms)"
else
    bad "cannot ping $CLIENT_IP out of $SERVER_INTF -- no traffic will flow"
    info "check cabling, link state on both ends, and that both IPs share a subnet"
fi

# -------------------------------------------------------------------- remote
step "Remote machine (sender / Broadwell) over SSH"
if rsh true 2>/dev/null; then
    ok "ssh $SSH_USER@$SSH_HOST works without a password"

    rhost=$(rsh hostname 2>/dev/null)
    info "remote hostname: ${rhost:-?}"

    if rsh "test -d '$REPO_DIR/scripts/local'" 2>/dev/null; then
        ok "repo present at the same path: $REPO_DIR"
    else
        bad "repo NOT at $REPO_DIR on the remote"
        info "the remote command is built here and run there, so the path must match"
        info "fix:  ssh $SSH_USER@$SSH_HOST 'git clone <your fork> $REPO_DIR'"
    fi

    if rsh "command -v iperf3 >/dev/null"; then ok "remote iperf3 present"
    else bad "remote iperf3 MISSING  ->  ssh $SSH_USER@$SSH_HOST 'sudo apt-get install -y iperf3'"; fi

    if rsh "command -v python3 >/dev/null"; then ok "remote python3 present"
    else bad "remote python3 MISSING"; fi

    if rsh "test -e /sys/class/net/$CLIENT_INTF"; then
        ok "remote interface $CLIENT_INTF exists"
        if rsh "ip -br addr show $CLIENT_INTF | grep -qw '$CLIENT_IP/[0-9]*'"; then
            ok "$CLIENT_IP is configured on remote $CLIENT_INTF"
        else
            bad "$CLIENT_IP not on remote $CLIENT_INTF"
        fi
    else
        bad "remote interface $CLIENT_INTF does not exist"
    fi

    # Congestion control matters on the SENDER, which is the remote.
    avail=$(rsh "cat /proc/sys/net/ipv4/tcp_available_congestion_control" 2>/dev/null)
    if printf '%s' "$avail" | tr ' ' '\n' | grep -qx "$CCA"; then
        ok "cca '$CCA' available on the sender"
    else
        bad "cca '$CCA' NOT available on the sender (have: $avail)"
        [ "$CCA" = "dctcp" ] && info "fix:  ssh $SSH_USER@$SSH_HOST 'sudo modprobe tcp_dctcp'"
    fi

    if [ "$APPLY_NET_TUNING" = "1" ]; then
        if rsh "sudo -n true" 2>/dev/null; then ok "passwordless sudo on the remote"
        else bad "remote sudo needs a password; APPLY_NET_TUNING=1 will hang"
             info "fix:  ssh $SSH_USER@$SSH_HOST 'echo \"\$USER ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/fands'"; fi
    else
        info "APPLY_NET_TUNING=0, so remote sudo is not needed"
    fi
else
    bad "cannot ssh to $SSH_USER@$SSH_HOST without a password"
    info "fix:  ssh-keygen -t ed25519   &&   ssh-copy-id $SSH_USER@$SSH_HOST"
    info "(BatchMode is on, so a password prompt counts as a failure by design)"
fi

# --------------------------------------------------------------------- cores
step "CPU pinning"
s_cores="${SERVER_CORES:-}"; [ -z "$s_cores" ] && s_cores=$(pick_cores "$SERVER_INTF" "$NUM_FLOWS")
info "server cores: $s_cores $( [ -z "${SERVER_CORES:-}" ] && echo '(auto: NUMA-local to NIC)' )"
s_max=$(max_core_id "$s_cores"); s_n=$(nproc 2>/dev/null || echo 0)
if [ "$s_max" -lt "$s_n" ]; then ok "server cores fit (max $s_max < $s_n CPUs)"
else bad "server core $s_max does not exist (only $s_n CPUs) -- taskset will fail"; fi

if [ -n "${CLIENT_CORES:-}" ]; then
    c_cores="$CLIENT_CORES"
    c_n=$(rsh nproc 2>/dev/null || echo 0)
    c_max=$(max_core_id "$c_cores")
    info "client cores: $c_cores (explicit)"
    if [ "${c_n:-0}" -gt 0 ] && [ "$c_max" -lt "$c_n" ]; then
        ok "client cores fit (max $c_max < $c_n CPUs)"
    elif [ "${c_n:-0}" -gt 0 ]; then
        bad "client core $c_max does not exist (only $c_n CPUs) -- taskset will fail"
    fi
else
    info "client cores: auto-detected on the remote at run time"
fi

# ------------------------------------------------------------------- verdict
step "Verdict"
if [ "$FAILED" -eq 0 ]; then
    printf '  %sReady.%s  Run:  bash %s/scripts/local/run-traffic.sh\n\n' "$c_grn" "$c_off" "$REPO_DIR"
    exit 0
else
    printf '  %s%d check(s) failed.%s Fix those first -- run-traffic.sh will not work.\n\n' \
        "$c_red" "$FAILED" "$c_off"
    exit 1
fi
