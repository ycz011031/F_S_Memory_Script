#!/bin/bash
# Drive 1 or 2 NICs receiving concurrently on icx, and report per-NIC
# throughput alongside the shared IOMMU counters.
#
#   ./run-dualnic-experiment.sh -E base-nic0 --nics 1
#   ./run-dualnic-experiment.sh -E base-nic1 --nics 1 --nic-index 1
#   ./run-dualnic-experiment.sh -E dual      --nics 2
#
# The SAME code path produces the single-NIC baselines and the dual run, so the
# comparison is not confounded by a different harness.
#
# WHY per-NIC IOMMU numbers are not reported: on this box both NICs sit behind
# PCIe switch 0000:97:00.0 on the single root port 0000:96:02.0, so they share
# an IIO stack AND a Part. pcm-iio IOMMU events are per-stack (ch_mask=0x0,
# vname=Total) and IB/OB bandwidth is per-Part, so every hardware counter is a
# sum over both NICs. Per-NIC data comes from iperf3. See setup-server.sh.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../utils/setup-server.sh"

exp="dualnic-test"
nics=2                 # how many NICs to drive
nic_index=0            # which NIC when --nics 1
num_servers=8          # iperf3 processes PER NIC
num_clients=8
dur=20
mtu="${MTU:-4000}"
ring_buffer="${RING_BUFFER:-1024}"
buf="${SOCK_BUF_MB:-1}"
bandwidth="${DUALNIC_BANDWIDTH:-40g}"
cca="${CCA:-dctcp}"
num_runs=1
sync_client=0
CLIENT_BRANCH="$(git -C "$HERE/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo icx-dualnic)"

while [ $# -gt 0 ]; do
    case "$1" in
        -E|--exp)        exp="$2"; shift 2 ;;
        --nics)          nics="$2"; shift 2 ;;
        --nic-index)     nic_index="$2"; shift 2 ;;
        -S|--num_servers) num_servers="$2"; shift 2 ;;
        -C|--num_clients) num_clients="$2"; shift 2 ;;
        -M|--MTU)        mtu="$2"; shift 2 ;;
        --ring_buffer)   ring_buffer="$2"; shift 2 ;;
        --buf)           buf="$2"; shift 2 ;;
        -b|--bandwidth)  bandwidth="$2"; shift 2 ;;
        --cca)           cca="$2"; shift 2 ;;
        --sync-client)   sync_client=1; shift ;;
        -d|--dur)        dur="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

# iperf3 -b is PER FLOW. To cap a NIC at an aggregate rate its flows have to
# divide that rate between them, otherwise "-b 40g" with 8 flows asks for
# 320 Gbps and the cap does nothing at all.
per_flow_bw() {   # <aggregate, e.g. 40g> <flow count> -> bits/sec per flow
    local v="$1" n="$2" mult num
    case "$v" in
        *[gG]) mult=1000000000; num="${v%[gG]}" ;;
        *[mM]) mult=1000000;    num="${v%[mM]}" ;;
        *[kK]) mult=1000;       num="${v%[kK]}" ;;
        *)     mult=1;          num="$v" ;;
    esac
    awk -v x="$num" -v m="$mult" -v n="$n" 'BEGIN{ printf "%d", (x*m)/n }'
}

REPO="${REPO_DIR:-$DEP_DIR/${REPO_NAME:-Fast-and-Safe-IO-Memory-Protection}}"
setup_dir="$REPO/utils"
exp_dir="$REPO/utils/tcp"

# ssh keys when CLIENT_PWD is empty, sshpass otherwise.
# rsh_try is best-effort (cleanup); rsh aborts the run on failure, because a
# silent ssh failure means no traffic is generated at all and every number
# comes back zero, which is worse than stopping.
rsh_try() {
    if [ -n "${CLIENT_PWD:-}" ]; then
        sshpass -p "$CLIENT_PWD" ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    fi
}
rsh() {
    if ! rsh_try "$@"; then
        echo "ERROR: ssh to $CLIENT_USERNAME@$CLIENT_SSH_IP failed." >&2
        echo "       command: $*" >&2
        exit 1
    fi
}

# Fail fast on the things that otherwise produce a full run of zeros.
preflight() {
    echo "-- preflight"
    echo "   running on: $(hostname) ($(id -un))"

    # This must run on the SERVER/receiver. Running it on the client makes the
    # runner ssh to the machine it is already on, so both "sides" are the same
    # host and nothing is measured. Detect that before anything else.
    for ip in $(hostname -I 2>/dev/null); do
        if [ "$ip" = "$CLIENT_SSH_IP" ] || [ "$ip" = "${CLIENT_NIC_IPS[0]:-}" ] \
           || [ "$ip" = "${CLIENT_NIC_IPS[1]:-}" ]; then
            echo >&2
            echo "ERROR: this is the CLIENT machine ($(hostname), $ip)." >&2
            echo "  Run the experiment on the SERVER/receiver instead -- it" >&2
            echo "  drives the client over ssh. Per setup-server.sh that is:" >&2
            echo "    ssh $SERVER_USERNAME@$SERVER_SSH_IP" >&2
            echo "    cd $REPO && ./scripts/sosp24-experiments/dualnic_exp.sh 40g 8" >&2
            exit 1
        fi
    done
    if [ -z "${CLIENT_PWD:-}" ]; then
        echo "   auth: ssh keys (CLIENT_PWD empty)"
    else
        echo "   auth: sshpass"
        command -v sshpass >/dev/null 2>&1 || {
            echo "ERROR: CLIENT_PWD is set but sshpass is not installed." >&2; exit 1; }
    fi

    if ! rsh_try true 2>/dev/null; then
        echo >&2
        echo "ERROR: cannot reach $CLIENT_USERNAME@$CLIENT_SSH_IP non-interactively." >&2
        echo >&2
        if [ -z "${CLIENT_PWD:-}" ]; then
            echo "  CLIENT_PWD is empty, so key auth was attempted and failed." >&2
            echo "  Either install a key:" >&2
            echo "    ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # if needed" >&2
            echo "    ssh-copy-id $CLIENT_USERNAME@$CLIENT_SSH_IP" >&2
            echo "  or set CLIENT_PWD in utils/setup-server.sh to use sshpass." >&2
        else
            echo "  sshpass with CLIENT_PWD failed. Check the password and host." >&2
        fi
        exit 1
    fi
    echo "   ssh: OK"

    rsh_try "test -d '$exp_dir'" || {
        echo >&2
        echo "ERROR: $exp_dir does not exist on the client." >&2
        echo "  The runner builds remote commands with the LOCAL path, so the" >&2
        echo "  repo must sit at the same absolute path on both machines." >&2
        echo "  On $CLIENT_SSH_IP:" >&2
        echo "    git clone <your fork> $REPO && cd $REPO && git checkout icx-dualnic" >&2
        exit 1
    }
    echo "   remote repo: OK ($REPO)"

    rsh_try "command -v iperf3 >/dev/null" || {
        echo "ERROR: iperf3 not installed on the client." >&2; exit 1; }
    echo "   remote iperf3: OK"

    # setup-server.sh is git-ignored, so it never arrives via git clone. The
    # client's setup-envir.sh sources it for DEP_DIR, which it needs to find
    # network_setup.py. Without it the client NIC is never configured.
    rsh_try "test -f '$setup_dir/setup-server.sh'" || {
        echo >&2
        echo "ERROR: $setup_dir/setup-server.sh is missing on the client." >&2
        echo "  It is git-ignored, so git clone does not bring it. Copy yours:" >&2
        echo "    scp $setup_dir/setup-server.sh \\" >&2
        echo "        $CLIENT_USERNAME@$CLIENT_SSH_IP:$setup_dir/" >&2
        echo "  (note this file holds credentials; keep it off shared storage)" >&2
        exit 1
    }
    echo "   remote setup-server.sh: OK"

    # The remote copy must be new enough to understand --no_kill, or the second
    # NIC's client group will wipe the first.
    if [ "${sync_client:-0}" = "1" ]; then
        echo "   syncing client repo..."
        rsh "cd '$REPO' && git fetch origin && git checkout $CLIENT_BRANCH && git pull --ff-only" \
            || { echo "ERROR: client repo sync failed." >&2; exit 1; }
    fi

    rsh_try "grep -q -- '--no_kill' '$exp_dir/run-netapp-tput.sh'" || {
        echo >&2
        echo "ERROR: the client's run-netapp-tput.sh has no --no_kill support." >&2
        echo "  Its copy of the repo is stale." >&2
        echo >&2
        echo "  Fix it from HERE, as a single non-interactive command -- do not" >&2
        echo "  open an interactive ssh and paste follow-up lines, because the" >&2
        echo "  ssh session consumes them as stdin and they run on THIS host:" >&2
        echo >&2
        echo "    ssh $CLIENT_USERNAME@$CLIENT_SSH_IP \\" >&2
        echo "      'cd $REPO && git fetch origin && git checkout $CLIENT_BRANCH && git pull'" >&2
        echo >&2
        echo "  Or re-run this script with --sync-client to do it automatically." >&2
        exit 1
    }
    echo "   remote script version: OK"

    # setup-envir.sh runs as root over ssh, where there is no TTY to answer a
    # sudo prompt. This is the single most common silent failure.
    # The remaining checks are all "install/configure something" problems that
    # get fixed in one sitting. Exiting on the first one turns a single fix
    # session into one round trip per missing item, so collect them all.
    PROBLEMS=()

    # setup-envir.sh runs as root over ssh, where there is no TTY to answer a
    # sudo prompt. Both hosts need this: the client for NIC setup, this host
    # for everything the runner does locally.
    if sudo -n true >/dev/null 2>&1; then
        echo "   local passwordless sudo: OK"
    else
        PROBLEMS+=("passwordless sudo missing on THIS host ($(hostname))
    Run here, answering the password prompt once:
      echo \"\$USER ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/fands
      sudo chmod 0440 /etc/sudoers.d/fands && sudo visudo -c")
    fi

    if rsh_try "sudo -n true" >/dev/null 2>&1; then
        echo "   remote passwordless sudo: OK"
    else
        PROBLEMS+=("passwordless sudo missing on the CLIENT ($CLIENT_SSH_IP)
    The runner invokes sudo over ssh, where there is no TTY to answer a
    prompt, so NIC setup fails. ssh -t forces a TTY for this one command:
      ssh -t $CLIENT_USERNAME@$CLIENT_SSH_IP \\
        'echo \"$CLIENT_USERNAME ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/fands \\
         && sudo chmod 0440 /etc/sudoers.d/fands && sudo visudo -c'")
    fi

    # What setup-envir.sh reaches for on the client.
    miss=""
    rsh_try "command -v ifconfig >/dev/null" || miss="$miss net-tools(ifconfig)"
    rsh_try "command -v python   >/dev/null" || miss="$miss python-is-python3(python)"
    if [ -n "$miss" ]; then
        PROBLEMS+=("client is missing packages:$miss
    ssh $CLIENT_USERNAME@$CLIENT_SSH_IP 'sudo apt-get install -y net-tools python-is-python3'")
    fi
    # network_setup.py applies TSO/GRO/aRFS and the ring-buffer size, so a
    # missing copy does not just warn -- it silently changes the experiment.
    # setup-envir.sh runs on BOTH hosts, so check both. DEP_DIR points at
    # $HOME here; the lab's shared copy may live elsewhere, in which case a
    # symlink is preferable to a second clone.
    NSREPO="Understanding-network-stack-overheads-SIGCOMM-2021"
    NSPATH="$DEP_DIR/$NSREPO/network_setup.py"
    CLONE_URL="https://github.com/Terabit-Ethernet/$NSREPO"

    for side in local remote; do
        if [ "$side" = local ]; then
            test -f "$NSPATH" && { echo "   local network_setup.py: OK"; continue; }
            host="THIS host ($(hostname))"; prefix=""
        else
            rsh_try "test -f '$NSPATH'" && { echo "   remote network_setup.py: OK"; continue; }
            host="the CLIENT ($CLIENT_SSH_IP)"
            prefix="ssh $CLIENT_USERNAME@$CLIENT_SSH_IP "
        fi
        PROBLEMS+=("network_setup.py missing on $host
    Expected at: $NSPATH
    setup-envir.sh uses it for TSO/GRO/aRFS and the ring buffer, so without
    it --ring_buffer $ring_buffer is silently not applied.
    Clone it:
      ${prefix}git clone $CLONE_URL $DEP_DIR/$NSREPO
    Or, if the lab already has a copy (DEP_DIR used to be /fast-lab-share/...):
      ${prefix}ln -s /path/to/existing/$NSREPO $DEP_DIR/$NSREPO")
    done
    [ -z "$miss" ] && echo "   remote setup-envir deps: OK"

    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        echo >&2
        echo "=== preflight found ${#PROBLEMS[@]} problem(s); fix all, then re-run ===" >&2
        n=1
        for p in "${PROBLEMS[@]}"; do
            echo >&2
            echo "[$n] $p" >&2
            n=$((n + 1))
        done
        echo >&2
        exit 1
    fi
}
rcp_back() {   # rcp_back <remote-path> <local-path>
    if [ -n "${CLIENT_PWD:-}" ]; then
        sshpass -p "$CLIENT_PWD" scp "$CLIENT_USERNAME@$CLIENT_SSH_IP:$1" "$2"
    else
        scp -o BatchMode=yes "$CLIENT_USERNAME@$CLIENT_SSH_IP:$1" "$2"
    fi
}

# Which NIC indices participate in this run.
if [ "$nics" -eq 1 ]; then ACTIVE=( "$nic_index" ); else ACTIVE=( 0 1 ); fi

# pkill by process NAME, not -f. With -f the pattern "iperf3" also matches the
# "sudo pkill -9 -f iperf3" command line itself, so pkill kills its own sudo
# wrapper -- that is where the stream of "Killed" messages came from, and it
# can stop the kill part-way through.
cleanup() {
    sudo pkill -9 iperf3 >/dev/null 2>&1 || true
    rsh_try "sudo pkill -9 iperf3; screen -wipe" >/dev/null 2>&1 || true
    sudo bash -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=============================================================="
echo "  experiment : $exp"
echo "  NICs       : $nics  (indices: ${ACTIVE[*]})"
echo "  per NIC    : $num_servers flows, $bandwidth aggregate ($(per_flow_bw "$bandwidth" "$num_clients") bps/flow), cca=$cca"
echo "  mtu $mtu  ring $ring_buffer  sockbuf ${buf}MB  dur ${dur}s"
echo "=============================================================="

preflight

for ((j = 0; j < num_runs; j++)); do
    RUN="$exp-RUN-server-$j"
    rm -rf "$setup_dir/reports/$RUN" "$setup_dir/logs/$RUN"
    mkdir -p "$setup_dir/reports/$RUN" "$setup_dir/logs/$RUN"

    cleanup; sleep 2

    # ---------------------------------------------------------- configure NICs
    for i in "${ACTIVE[@]}"; do
        s_intf="${SERVER_INTFS[$i]}";  s_ip="${SERVER_NIC_IPS[$i]}"
        c_intf="${CLIENT_INTFS[$i]}";  c_ip="${CLIENT_NIC_IPS[$i]}"
        echo "-- NIC $i: $c_intf($c_ip) -> $s_intf($s_ip)"

        # Capture rather than discard. Sending this to /dev/null meant a failing
        # setup-envir.sh -- and rsh's own error message -- vanished, leaving an
        # abort with no visible cause.
        log_s=$(mktemp); log_c=$(mktemp)
        if ! ( cd "$setup_dir" && sudo bash setup-envir.sh -i "$s_intf" -a "$s_ip" \
                   -m "$mtu" --ring_buffer "$ring_buffer" --buf "$buf" ) >"$log_s" 2>&1; then
            echo "WARNING: server-side setup-envir.sh for $s_intf returned non-zero:" >&2
            tail -15 "$log_s" | sed 's/^/    /' >&2
        fi
        if ! rsh_try "cd $setup_dir && sudo bash setup-envir.sh -i $c_intf -a $c_ip \
                      -m $mtu --ring_buffer $ring_buffer --buf $buf" >"$log_c" 2>&1; then
            echo >&2
            echo "ERROR: client-side setup-envir.sh for $c_intf failed. Output:" >&2
            tail -20 "$log_c" | sed 's/^/    /' >&2
            echo >&2
            echo "  Common causes on the client:" >&2
            echo "    - sudo needs a password (there is no TTY over ssh)" >&2
            echo "    - ifconfig missing        -> sudo apt-get install -y net-tools" >&2
            echo "    - 'python' missing        -> sudo apt-get install -y python-is-python3" >&2
            echo "    - network_setup.py missing under $DEP_DIR" >&2
            rm -f "$log_s" "$log_c"
            exit 1
        fi
        rm -f "$log_s" "$log_c"
    done
    sleep 5

    # ------------------------------------------------------------ receivers
    # Every invocation gets --no_kill and the stale-process sweep happens ONCE,
    # here. The invocations are backgrounded, so loop order is not execution
    # order: letting any of them run the pkill meant whichever started first
    # had its iperf3 group wiped by the other.
    sudo pkill -9 iperf3 >/dev/null 2>&1 || true
    sleep 1
    for i in "${ACTIVE[@]}"; do
        ( cd "$exp_dir" && sudo bash run-netapp-tput.sh -m server \
              -S "$num_servers" -o "$RUN-nic$i" -p "${BASE_PORTS[$i]}" \
              -c "${SERVER_CORES[$i]}" --no_kill ) &
    done
    sleep 5

    # Confirm the receivers actually bound before driving traffic at them.
    want=$(( num_servers * ${#ACTIVE[@]} ))
    got=$(ss -ltn 2>/dev/null | awk -v n="$num_servers" '
        { split($4,a,":"); p=a[length(a)]+0
          if ((p>=3000 && p<3000+n) || (p>=4000 && p<4000+n)) c++ }
        END{ print c+0 }')
    echo "   receivers listening: $got/$want"
    [ "$got" -eq 0 ] && { echo "ERROR: no iperf3 receivers bound." >&2; exit 1; }

    echo "turning on IOVA logging via ftrace"
    sudo bash -c 'echo > /sys/kernel/debug/tracing/trace' 2>/dev/null
    sudo bash -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null

    # -------------------------------------------------------------- senders
    flow_bw=$(per_flow_bw "$bandwidth" "$num_clients")
    # Same rule as the receivers: sweep once, then --no_kill for every group.
    rsh "sudo pkill -9 iperf3 >/dev/null 2>&1; screen -wipe >/dev/null 2>&1; true"
    sleep 1
    for i in "${ACTIVE[@]}"; do
        rsh "screen -dmS client_nic$i bash -c \"cd $exp_dir && \
             sudo bash run-netapp-tput.sh -m client -a ${SERVER_NIC_IPS[$i]} \
             -C $num_clients -S $num_servers -o $exp-RUN-client-$j-nic$i \
             -p ${BASE_PORTS[$i]} -l ${CLIENT_CORES[$i]} -c ${CLIENT_CORES[$i]} \
             -b $flow_bw --cca $cca --no_kill\""
    done

    echo "warming up..."; sleep 12

    # A screen session that died on startup leaves nothing running, and the run
    # would otherwise proceed to measure an idle link for 20s.
    running=$(rsh_try "pgrep -c -x iperf3" 2>/dev/null || echo 0)
    echo "   senders running on client: ${running:-0}"
    if [ "${running:-0}" -eq 0 ]; then
        echo "ERROR: no iperf3 senders started on $CLIENT_SSH_IP." >&2
        echo "  Check by hand:  ssh $CLIENT_USERNAME@$CLIENT_SSH_IP" >&2
        echo "                  cd $exp_dir && sudo bash run-netapp-tput.sh -m client \\" >&2
        echo "                    -a ${SERVER_NIC_IPS[${ACTIVE[0]}]} -C 1 -S 1 -o probe \\" >&2
        echo "                    -p ${BASE_PORTS[${ACTIVE[0]}]} -c 0 -b 1g --no_kill" >&2
        exit 1
    fi

    # -------------------------------------------------------------- measure
    # One pcm-iio collection: the counters are a stack-level sum regardless of
    # how many NICs are active, which is exactly the contention signal.
    echo "recording host metrics for ${dur}s (aggregate over active NICs)..."
    ( cd "$setup_dir" && sudo bash record-host-metrics.sh -f 0 --iio 0 -t 1 \
        --intf "${SERVER_INTFS[${ACTIVE[0]}]}" -o "$RUN" --type 0 \
        --cpu-util 1 --pcie 1 --membw 1 --bw 0 --dur "$dur" \
        --cores "${SERVER_CORES[${ACTIVE[0]}]}" )

    # iperf3 server stats are written by run-netapp-tput.sh after its own
    # 80s wait; give those background jobs time to land their .rpt files.
    echo "waiting for iperf3 stats to be written..."
    sleep 75

    for i in "${ACTIVE[@]}"; do
        rcp_back "$setup_dir/reports/$exp-RUN-client-$j-nic$i/retx.rpt" \
                 "$setup_dir/reports/$RUN/retx-nic$i.rpt" 2>/dev/null
    done

    cleanup
done

# ------------------------------------------------------------------ report
echo
echo "=============================================================="
echo "  RESULT: $exp"
echo "=============================================================="
total=0
for i in "${ACTIVE[@]}"; do
    f="$setup_dir/reports/$exp-RUN-server-0-nic$i/iperf.bw.rpt"
    g=$(awk '{print $NF}' "$f" 2>/dev/null)
    case "${g:-}" in ''|*[!0-9.]*) g=0 ;; esac
    printf '  NIC %s (%-14s) : %s Gbps\n' "$i" "${SERVER_INTFS[$i]}" "$g"
    total=$(awk -v a="$total" -v b="$g" 'BEGIN{printf "%.3f", a+b}')
done
printf '  %-22s : %s Gbps\n' "AGGREGATE" "$total"

P="$setup_dir/reports/$exp-RUN-server-0/pcie.rpt"
if [ -f "$P" ]; then
    echo
    if [ "${PCIE_COUNTERS_SHARED:-1}" = "1" ]; then
        echo "  shared IIO stack counters (sum over ALL active NICs):"
    else
        # Only reachable if someone points the NICs at separate root ports.
        # This runner still collects pcm-iio once, so the numbers would be a
        # sum across whatever the single PCIE_PATTERN matched -- say so rather
        # than implying a per-NIC breakdown that was never collected.
        echo "  PCIE_COUNTERS_SHARED=0, but this runner collects pcm-iio once"
        echo "  against a single PCIE_PATTERN. Per-NIC counters would need one"
        echo "  pattern and one report per NIC. Numbers below are still a sum:"
    fi
    grep -E '^(PCIe_wr_tput|PCIe_rd_tput|IOTLB_lookups|IOTLB_misses|IOTLB_hits_derived|CTXT_cache_hits|PWC_512G_hits|PWC_1G_hits|PWC_2M_hits|PWC_4K_hits|IOMMU_mem_access):' \
        "$P" | sed 's/^/    /'

    # PCIe is the control variable: the shared uplink is x8 @ 16GT/s, ~126 Gbps.
    wr=$(awk '/^PCIe_wr_tput:/{print $NF}' "$P" 2>/dev/null)
    case "${wr:-}" in ''|*[!0-9.]*) wr=0 ;; esac
    if awk -v w="$wr" 'BEGIN{exit !(w > 100)}'; then
        echo
        echo "  WARNING: PCIe write tput ${wr} Gbps is close to the ~126 Gbps"
        echo "  shared uplink. This run is link-bound, so the IOMMU counters"
        echo "  are not interpretable as contention. Lower --bandwidth."
    fi
fi
echo
echo "  reports: $setup_dir/reports/$exp-RUN-server-0*/"
