#!/bin/bash
# Minimal traffic run: N iperf3 flows Broadwell -> Ice Lake, aggregate result.
# Run this on the ICE LAKE (the receiver). It drives the sender over ssh.
#
#   bash run-traffic.sh                 # use config.sh as-is
#   bash run-traffic.sh 20              # override NUM_FLOWS for this run
#
# No PCM, no MLC, no IOMMU logging, no ddio-bench. Just packets.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/_common.sh"
load_config "$HERE"

FAILED=0
[ $# -ge 1 ] && NUM_FLOWS="$1"

RESULTS="$REPO_DIR/$OUT_DIR"
mkdir -p "$RESULTS"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$RESULTS/run-$STAMP.log"

cleanup() {
    pkill -9 -f 'iperf3 -s' >/dev/null 2>&1
    rsh "pkill -9 -f 'iperf3 -c'" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------- pinning
S_CORES="${SERVER_CORES:-}"
[ -z "$S_CORES" ] && S_CORES=$(pick_cores "$SERVER_INTF" "$NUM_FLOWS")
IFS=',' read -ra S_CORE_LIST <<< "$S_CORES"

step "Run $STAMP"
info "$NUM_FLOWS flows x ${DURATION}s   $CLIENT_IP -> $SERVER_IP   cca=$CCA"
info "server cores $S_CORES   results -> $LOG"

# -------------------------------------------------------------------- tuning
apply_tuning_local() {
    sudo ip link set "$SERVER_INTF" mtu "$MTU" 2>/dev/null || warn "local MTU set failed"
    [ -n "${RING_BUFFER:-}" ] && { sudo ethtool -G "$SERVER_INTF" rx "$RING_BUFFER" 2>/dev/null || warn "local ring set failed"; }
    local b=$((SOCK_BUF_MB * 1000000))
    sudo sysctl -qw net.ipv4.tcp_moderate_rcvbuf=0 2>/dev/null
    sudo sysctl -qw "net.ipv4.tcp_rmem=$((b*2)) $((b*2)) $((b*2))" 2>/dev/null
    sudo sysctl -qw "net.ipv4.tcp_wmem=$b $b $b" 2>/dev/null
}
apply_tuning_remote() {
    rsh "sudo ip link set $CLIENT_INTF mtu $MTU; \
         { [ -n '${RING_BUFFER:-}' ] && sudo ethtool -G $CLIENT_INTF rx ${RING_BUFFER:-0}; } ; \
         sudo sysctl -qw net.ipv4.tcp_moderate_rcvbuf=0; \
         sudo sysctl -qw 'net.ipv4.tcp_wmem=$((SOCK_BUF_MB*1000000)) $((SOCK_BUF_MB*1000000)) $((SOCK_BUF_MB*1000000))'" \
        >/dev/null 2>&1 || warn "remote tuning failed (passwordless sudo?)"
}

if [ "$APPLY_NET_TUNING" = "1" ]; then
    step "Applying network tuning (MTU=$MTU ring=${RING_BUFFER:-default} buf=${SOCK_BUF_MB}MB)"
    apply_tuning_local; apply_tuning_remote
    ok "tuning applied"
else
    info "APPLY_NET_TUNING=0 -- system left untouched"
fi

# ------------------------------------------------------------------- servers
step "Starting $NUM_FLOWS iperf3 receivers"
cleanup; sleep 1
for ((i = 0; i < NUM_FLOWS; i++)); do
    core=${S_CORE_LIST[$((i % ${#S_CORE_LIST[@]}))]}
    port=$((BASE_PORT + i))
    taskset -c "$core" iperf3 -s -p "$port" --one-off >/dev/null 2>&1 &
done
sleep 2

listening=$(ss -ltn 2>/dev/null | awk -v b="$BASE_PORT" -v n="$NUM_FLOWS" \
    '{split($4,a,":"); p=a[length(a)]+0; if (p>=b && p<b+n) c++} END{print c+0}')
if [ "$listening" -eq "$NUM_FLOWS" ]; then
    ok "$listening/$NUM_FLOWS receivers listening on ports $BASE_PORT-$((BASE_PORT+NUM_FLOWS-1))"
else
    warn "only $listening/$NUM_FLOWS receivers came up"
fi

# --------------------------------------------------------------------- CPU
SAR_PID=""
if command -v sar >/dev/null 2>&1; then
    sar -P "$S_CORES" 1 "$DURATION" > "$RESULTS/cpu-$STAMP.log" 2>/dev/null &
    SAR_PID=$!
fi

# -------------------------------------------------------------------- senders
step "Driving traffic for ${DURATION}s"
OUT=$(rsh "bash '$REPO_DIR/scripts/local/_remote-client.sh' \
    '$SERVER_IP' '$NUM_FLOWS' '$BASE_PORT' '$DURATION' \
    '$CCA' '$BANDWIDTH' '${CLIENT_CORES:-auto}' '$CLIENT_INTF'" 2>&1)
rc=$?
[ -n "$SAR_PID" ] && wait "$SAR_PID" 2>/dev/null

printf '%s\n' "$OUT" > "$LOG"

if [ $rc -ne 0 ]; then
    printf '\n%sremote sender failed (rc=%d)%s\n' "$c_red" "$rc" "$c_off"
    printf '%s\n' "$OUT" | sed 's/^/  /'
    exit 1
fi

# -------------------------------------------------------------------- report
gbps=$(printf '%s\n' "$OUT" | awk '/^TOTAL_GBPS/{print $2}')
flows_ok=$(printf '%s\n' "$OUT" | awk '/^FLOWS_OK/{print $2}')
retx=$(printf '%s\n' "$OUT" | awk '/^RETRANSMITS/{print $2}')
ccores=$(printf '%s\n' "$OUT" | awk '/^CLIENT_CORES/{print $2}')
speed=$(cat "/sys/class/net/$SERVER_INTF/speed" 2>/dev/null)

step "Result"
printf '  aggregate throughput : %s%s Gbps%s\n' "$c_grn" "${gbps:-0}" "$c_off"
printf '  flows completed      : %s/%s\n' "${flows_ok:-0}" "$NUM_FLOWS"
printf '  retransmits          : %s\n' "${retx:-?}"
printf '  client cores used    : %s\n' "${ccores:-?}"

if [ -n "${speed:-}" ] && [ "${speed:-0}" -gt 0 ] && [ -n "${gbps:-}" ]; then
    pct=$(python3 -c "print(f'{100*$gbps/($speed/1000.0):.1f}')" 2>/dev/null)
    printf '  link utilisation     : %s%% of %s Gb/s\n' "${pct:-?}" "$((speed/1000))"
    # The Broadwell sender is the likely ceiling; say so rather than letting a
    # slow sender masquerade as "the IOMMU is free".
    if [ -n "${pct:-}" ] && python3 -c "import sys; sys.exit(0 if $pct < 70 else 1)" 2>/dev/null; then
        printf '\n  %sNOTE%s sender is not filling the link. Before drawing any\n' "$c_yel" "$c_off"
        printf '       IOMMU conclusions, raise NUM_FLOWS and widen CLIENT_CORES\n'
        printf '       until this plateaus -- otherwise you are measuring the Broadwell.\n'
    fi
fi

if command -v sar >/dev/null 2>&1 && [ -f "$RESULTS/cpu-$STAMP.log" ]; then
    idle=$(awk '/Average/ && $2 ~ /^[0-9]+$/ {s+=$NF; n++} END{if(n) printf "%.1f", 100-s/n}' \
        "$RESULTS/cpu-$STAMP.log" 2>/dev/null)
    [ -n "${idle:-}" ] && printf '  receiver CPU (busy)  : %s%%\n' "$idle"
fi

printf '\n  full log: %s\n\n' "$LOG"
