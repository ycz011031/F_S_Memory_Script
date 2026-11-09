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
# one PCIe switch on a single root port, so they share an IIO stack AND a
# Part. pcm-iio IOMMU events are per-stack (ch_mask=0x0, vname=Total) and
# IB/OB bandwidth is per-Part, so every hardware counter is a sum over both
# NICs. Per-NIC data comes from iperf3. See setup-server.sh.
#
# NICs behind the PIPS switch: every result records the switch's FPGA design
# ID (pips_design_id, e.g. 0x0a04) and batcher setting (pips_batch, e.g.
# d8t22c1 = depth 8, time 22, drain depth cap on), read through BAR0 before
# the runs; each run's logs/<name>-RUN-server-<j>/pips-cfg.txt holds the
# `pips cfg` readout it ran with.
#
# --pips-log 1: also record the switch's TLP log in every run, as
# run-dualssd-experiment.sh does: the region is zeroed before the NICs are
# set up, the recording starts once the senders run, before the measurement
# window, and runs until the region fills (cut after 5 s); after the window it
# is dumped from FPGA DDR through BAR0, decoded and gzipped. Per run:
#   logs/<name>-RUN-server-<j>/pips-log-id<XXXX>.bin.gz   the recording, named
#                               with the design ID (it picks the record format)
#   logs/<name>-RUN-server-<j>/pips-log-summary.txt/.json, pips-log-*.txt
#   reports/<name>-RUN-server-<j>/pips-log.rpt   status: FULL, CUT, +DROPS,
#                               NO_TRAILER, BAD or FAILED; design_id, log_format
# A log problem does not fail the run. PIPS_LOG_GZIP=0 keeps the .bin.
#
# --flows-nic1 N: NIC 1 runs N flows (both -S and -C) instead of -S/-C, for an
# uneven co-run; the results record flows_per_nic as "<nic0>x<nic1>".
# --client-hw-rate RATE (e.g. 50g): the client's NIC paces each active port to
# RATE in hardware (mlx5 per-queue tx_maxrate, RATE / flows on every TX queue),
# so frames leave evenly spaced; iperf3 itself runs uncapped (-b is ignored).
# Put back to 0 (no limit) when the run ends. A port that refuses it stops the run.
# Every run also records, over the measurement window, TCP retransmits on the
# client (nstat: reports/<name>-RUN-server-<j>/retx-client.rpt) and the deltas of both
# ends' pause, discard and buffer counters (ethtool -S: nicstats-nic<i>.rpt).
# --iommu-ops 1: also count IOMMU map/unmap calls and VT-d invalidation
# descriptors beside the pcm-iio window, with this host's rx packets of the
# same seconds (perf tracepoints, utils/iommu-ops.sh: iommu-ops.txt/.rpt,
# iommu_ops_* in the results). Counting costs CPU per map: for counting runs.
#
# --gen alias: the in-house generator instead of iperf3 (scripts/pips/alias/,
# README.md there). This host posts one-sided RDMA READs to an alias-rdma
# server on the client (styx), one per NIC, and its NIC writes the responses
# into a local MR registered ONCE, one 4 KiB page per scatter entry, in a
# fixed aliasing pattern: the same direction as iperf3 (the NIC behind the
# switch writes into this host's memory), without map/unmap per packet.
#   -S N                QPs per NIC (--flows-nic1 for NIC 1), one thread each NIC
#   --depth N           READs in flight per QP (default 16)
#   --rdma-bs BYTES     bytes per READ (default 4096: one page)
#   --ws N --stride N   pages first + i*stride, i < ws (default 64, 1)
#   --first N --order cyclic|shuffle|random --page-list PATH --backing-pages N
#   --ws1 N --stride1 N --first1 N --order1 O --page-list1 PATH
#                       NIC 1's own pattern (default NIC 0's); each NIC has its own MR
#   --sge-bytes B       bytes per scatter entry, each in the next pattern page
#                       (default 4096, or --rdma-bs below it): --rdma-bs 4096
#                       --sge-bytes 512 writes 512 B into each of 8 pages per READ
#   --rdma-mtu B        cap the RoCE path MTU (256-4096; default the ports')
# Line rate only (-b uncapped, no --client-hw-rate). Per NIC the generator
# writes fio's files (logs/<run>/fio-nic<i>.json, _iops.1.log); the Gb/s over
# the measurement windows goes to reports/<run>-nic<i>/iperf.bw.rpt as
# Avg_iperf_tput, so sweeps and dualnic-results.py read it as before; the
# results add gen=alias and alias_* (pattern). Strict or lazy mode: with pt or
# off the MR is not translated and there is no IOTLB to alias.
#
# PIPS_BG="K=V ..." (set by pips-campaign.sh nic --bg; design 0x0A08): the
# switch's background read engine runs through every run, as in
# run-dualssd-experiment.sh: `pips bg run PIPS_BG stopwin=1` starts once the
# load runs (before the warm-up) and is stopped after the measurement window.
# Per run: logs/<run>/bg-run.txt, bg-hist.txt, reports/<run>/bg.rpt; results
# bg_spec, bg_label (PIPS_BG_LABEL), bg_rate_mrd_s, bg_lat_ns, bg_lat_max_ns,
# bg_errors (bg_spec=off without). Any engine problem (non-SC completion,
# timeout, data mismatch, leak, a NIC tag in the engine's window, no reads)
# makes the run invalid (exit 3) and writes PIPS_BG_STOPFILE (default
# ~/.pips-bg-stop); while it exists every runner with PIPS_BG refuses to start.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../utils/setup-server.sh"
# PIPS: pips_identify, pips_run_cfg, pips_record, pips_collect, pips_meta.
. "$HERE/pips/pips-lib.sh"

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
results_file=""        # JSONL to append to; default ~/<exp>-<N>.jsonl, first unused N
pips_log=0             # 1: record the PIPS switch's TLP log in every run
flows1=""              # NIC 1's flow count when it differs from NIC 0's (--flows-nic1)
hw_rate=""             # client-side hardware pacing per port (--client-hw-rate), e.g. 50g
iommu_ops=0            # 1: count IOMMU map/unmap and VT-d invalidations (utils/iommu-ops.sh)
gen=iperf              # iperf, or alias: scripts/pips/alias/alias-rdma (RDMA READ)
a_ws=64; a_stride=1; a_first=0; a_order=cyclic; a_list=""; a_backing=0; a_depth=16; a_bs=4096
a_ws1=""; a_stride1=""; a_first1=""; a_order1=""; a_list1=""; a_sge=0; a_mtu=0   # NIC 1's own pattern (empty: NIC 0's)
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
        --runs)          num_runs="$2"; shift 2 ;;
        --uncapped)      bandwidth="uncapped"; shift ;;
        --results)       results_file="$2"; shift 2 ;;
        --pips-log)      pips_log="$2"; shift 2 ;;
        --flows-nic1)    flows1="$2"; shift 2 ;;
        --client-hw-rate) hw_rate="$2"; shift 2 ;;
        --iommu-ops)     iommu_ops="$2"; shift 2 ;;
        --gen)           gen="$2"; shift 2 ;;
        --ws)            a_ws="$2"; shift 2 ;;
        --stride)        a_stride="$2"; shift 2 ;;
        --first)         a_first="$2"; shift 2 ;;
        --order)         a_order="$2"; shift 2 ;;
        --page-list)     a_list="$2"; shift 2 ;;
        --backing-pages) a_backing="$2"; shift 2 ;;
        --depth)         a_depth="$2"; shift 2 ;;
        --rdma-bs)       a_bs="$2"; shift 2 ;;
        --ws1)           a_ws1="$2"; shift 2 ;;
        --stride1)       a_stride1="$2"; shift 2 ;;
        --first1)        a_first1="$2"; shift 2 ;;
        --order1)        a_order1="$2"; shift 2 ;;
        --page-list1)    a_list1="$2"; shift 2 ;;
        --sge-bytes)     a_sge="$2"; shift 2 ;;
        --rdma-mtu)      a_mtu="$2"; shift 2 ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
case "$pips_log" in 0|1) ;; *) echo "ERROR: --pips-log must be 0 or 1" >&2; exit 2 ;; esac
case "$iommu_ops" in 0|1) ;; *) echo "ERROR: --iommu-ops must be 0 or 1" >&2; exit 2 ;; esac
case "$flows1" in ''|[1-9]|[1-9][0-9]) ;; *) echo "ERROR: --flows-nic1 takes 1-99" >&2; exit 2 ;; esac
case "$hw_rate" in ''|[1-9]*[gG]) ;; *) echo "ERROR: --client-hw-rate takes e.g. 50g" >&2; exit 2 ;; esac
case "$gen" in iperf|alias) ;; *) echo "ERROR: --gen must be iperf or alias" >&2; exit 2 ;; esac
case "$a_order" in cyclic|shuffle|random) ;; *) echo "ERROR: --order cyclic, shuffle or random" >&2; exit 2 ;; esac
for v in "$a_ws" "$a_stride" "$a_first" "$a_backing" "$a_depth" "$a_bs" "$a_sge" "$a_mtu"; do
    case "$v" in ''|*[!0-9]*) echo "ERROR: --ws/--stride/--first/--backing-pages/--depth/--rdma-bs/--sge-bytes/--rdma-mtu take integers" >&2; exit 2 ;; esac
done
for v in "$a_ws1" "$a_stride1" "$a_first1"; do
    case "$v" in *[!0-9]*) echo "ERROR: --ws1/--stride1/--first1 take integers" >&2; exit 2 ;; esac
done
case "$a_order1" in ''|cyclic|shuffle|random) ;; *) echo "ERROR: --order1 cyclic, shuffle or random" >&2; exit 2 ;; esac
case "$a_mtu" in 0|256|512|1024|2048|4096) ;; *) echo "ERROR: --rdma-mtu 256, 512, 1024, 2048 or 4096" >&2; exit 2 ;; esac
[ -z "$a_list1" ] || [ -f "$a_list1" ] || { echo "ERROR: --page-list1 $a_list1: no such file" >&2; exit 2; }
# alias-rdma's pattern options for NIC <i>: NIC 1 takes its own where given.
nic_pattern() {
    local i=$1 ws=$a_ws st=$a_stride fi=$a_first or=$a_order li=$a_list
    if [ "$i" = 1 ]; then
        ws=${a_ws1:-$ws}; st=${a_stride1:-$st}; fi=${a_first1:-$fi}; or=${a_order1:-$or}; li=${a_list1:-$li}
    fi
    echo "--ws $ws --stride $st --first $fi --order $or --seed $(( i + 1 ))$( [ -n "$li" ] && echo " --page-list $li")"
    [ "$a_sge" -gt 0 ] && echo "--sge-bytes $a_sge"
    [ "$a_mtu" -gt 0 ] && echo "--mtu $a_mtu"
}
if [ "$gen" = alias ]; then
    [ -z "$hw_rate" ] || { echo "ERROR: --gen alias runs at line rate: no --client-hw-rate" >&2; exit 2; }
    case "$bandwidth" in 0|uncapped|unlimited|none|line|linerate) ;;
        *) echo "ERROR: --gen alias runs at line rate: pass -b uncapped (got $bandwidth)" >&2; exit 2 ;; esac
    [ -z "$a_list" ] || [ -f "$a_list" ] || { echo "ERROR: --page-list $a_list: no such file" >&2; exit 2; }
fi
ALIAS_DIR="$HERE/pips/alias"
ALIAS_PORT_OFF=700     # alias-rdma servers listen on BASE_PORTS[i] + this
# Flows of NIC i: -S, or --flows-nic1 for NIC 1.
nflows() { if [ "$1" = 1 ] && [ -n "$flows1" ]; then echo "$flows1"; else echo "$num_servers"; fi; }

# iperf3 -b is PER FLOW. To cap a NIC at an aggregate rate its flows have to
# divide that rate between them, otherwise "-b 40g" with 8 flows asks for
# 320 Gbps and the cap does nothing at all.
per_flow_bw() {   # <aggregate, e.g. 40g> <flow count> -> bits/sec per flow
    local v="$1" n="$2" mult num
    # 0 is iperf3's "no limit". Accept the words too so --bandwidth uncapped
    # and --uncapped behave identically.
    case "$v" in
        0|uncapped|unlimited|none|line|linerate) echo 0; return ;;
    esac
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

    # Sync first, so the checks below see the client's updated copy.
    # The remote copy must be new enough to understand --no_kill, or the second
    # NIC's client group will wipe the first (and to have alias/ for --gen alias).
    if [ "${sync_client:-0}" = "1" ]; then
        echo "   syncing client repo..."
        rsh "cd '$REPO' && git fetch origin && git checkout $CLIENT_BRANCH && git pull --ff-only" \
            || { echo "ERROR: client repo sync failed." >&2; exit 1; }
    fi

    if [ "$gen" = alias ]; then
        # Build on both hosts as the user (the runs use sudo); the binaries live
        # in build/<host>/ of each host's copy of the repo.
        ALIAS_RDMA=$(bash "$ALIAS_DIR/alias-run.sh" --build alias-rdma 2>&1 | tail -1)
        [ -x "$ALIAS_RDMA" ] || { echo "ERROR: alias-rdma does not build here: $ALIAS_RDMA" >&2; exit 1; }
        R_ALIAS_RDMA=$(rsh_try "bash '$ALIAS_DIR/alias-run.sh' --build alias-rdma" 2>&1 | tail -1)
        rsh_try "test -x '$R_ALIAS_RDMA'" || {
            echo "ERROR: alias-rdma does not build on the client: $R_ALIAS_RDMA" >&2
            echo "  (is $ALIAS_DIR in its copy of the repo? --sync-client; libibverbs-dev?)" >&2; exit 1; }
        echo "   alias-rdma: $ALIAS_RDMA here, $R_ALIAS_RDMA on the client"
    else
    rsh_try "command -v iperf3 >/dev/null" || {
        echo "ERROR: iperf3 not installed on the client." >&2; exit 1; }
    echo "   remote iperf3: OK"
    fi

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

    # The PIPS switch's build and setting, when a NIC is behind it; its TLP
    # log needs it to answer (--pips-log 1).
    pips_identify NIC ${NIC_BDFS[@]+"${NIC_BDFS[@]}"}
    if [ -n "${PIPS_BG:-}" ]; then
        if [ -e "$BG_STOPFILE" ]; then
            PROBLEMS+=("PIPS_BG is set, but the read engine was stopped for good: $BG_STOPFILE says
      $(head -3 "$BG_STOPFILE" 2>/dev/null)")
        elif ! sudo -n "$PIPS" bg info 2>&1 | grep -q 'bg_id=0x'; then
            PROBLEMS+=("PIPS_BG is set, but the switch has no background read engine (pips bg info: design 0x0A08)")
        else
            echo "   read engine (PIPS_BG): ${PIPS_BG_LABEL:+$PIPS_BG_LABEL: }$PIPS_BG"
        fi
    fi

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

# Their PCI functions, to tell whether they are behind the PIPS switch.
NIC_BDFS=()
for i in "${ACTIVE[@]}"; do
    b=$(basename "$(readlink -f "/sys/class/net/${SERVER_INTFS[$i]}/device" 2>/dev/null)" 2>/dev/null)
    [ -n "$b" ] && NIC_BDFS+=( "$b" )
done

# CPU utilisation is recorded over EVERY active NIC's cores. Recording only the
# first NIC's meant a 2-NIC run reported half of its receive-side work.
active_cores=""
for i in "${ACTIVE[@]}"; do active_cores="${active_cores:+$active_cores,}${SERVER_CORES[$i]}"; done

# What the kernel actually did, from sysfs, not what the cmdline asked for.
# Stored with every result so an IOMMU-on and an IOMMU-off run cannot be
# confused. Both NICs share one DMAR unit, so a mismatch ("lazy+strict") means
# something unexpected happened at boot.
iommu_mode=$(for i in "${ACTIVE[@]}"; do
                 bash "$HERE/../utils/iommu-mode.sh" "${SERVER_INTFS[$i]}"
             done | sort -u | paste -sd+)

# pkill by process NAME, not -f. With -f the pattern "iperf3" also matches the
# "sudo pkill -9 -f iperf3" command line itself, so pkill kills its own sudo
# wrapper -- that is where the stream of "Killed" messages came from, and it
# can stop the kill part-way through.
# The alias generators by their binary path at the start of the command line.
ALIAS_MATCH='^(/[^ ]*/)?alias-rdm[a] --role'
alias_count() { local n; n=$(pgrep -c -f "$ALIAS_MATCH client" 2>/dev/null); echo "${n:-0}"; }

# ------------------------------------------------------------ the read engine (PIPS_BG)
# As run-dualssd-experiment.sh's: started once the load runs, stopped after the window.
BG_STOPFILE=${PIPS_BG_STOPFILE:-$HOME/.pips-bg-stop}
BG_PID=""
# 11-09: the start is given 30 s and up to 3 tries. Campaign c11082355 lost
# both halves to a 5 s wait: pips reached "started" at ~5 s (behind the BAR0
# lock or a slow sudo) and was then stopped as "did not start".
# Is the engine's sudo still running? Not kill -0: BG_PID is sudo's, and on icx
# (11-09, c11091247) kill -0 from the user gets EPERM on it, so every start
# looked dead on the first 0.1 s check, before pips said "started" (3 tries
# in 4 s, empty logs; the cleanup's SIGINT then stopped the engine at 0.0 s).
# This shell's job table needs no permission: a job that ended is not listed.
bg_alive() { jobs -rp | grep -qx "$1"; }
bg_begin() {   # <log dir>: start the engine for this run; 1 if it did not start
    [ -n "${PIPS_BG:-}" ] || return 0
    local try t0 dt
    for try in 1 2 3; do
        rm -f "$1/bg-run.txt"
        echo "\$ pips bg run $PIPS_BG secs=$(( 4 * dur + 600 )) beat=10 stopwin=1   (try $try, $(date '+%T'))" >> "$1/bg-cmd.txt"
        t0=$(date +%s%3N)
        sudo -n "$PIPS" bg run $PIPS_BG secs=$(( 4 * dur + 600 )) beat=10 stopwin=1 > "$1/bg-run.txt" 2>&1 9>&- &
        BG_PID=$!
        for _ in $(seq 300); do
            if grep -q '^# bg run: started' "$1/bg-run.txt" 2>/dev/null; then
                dt=$(( $(date +%s%3N) - t0 ))
                echo "   read engine on: ${PIPS_BG_LABEL:-$PIPS_BG} (started in $dt ms$( [ "$try" -gt 1 ] && echo ", try $try"))"
                echo "bg_start_ms: $dt try $try" >> "$1/bg-cmd.txt"
                return 0
            fi
            bg_alive "$BG_PID" || break
            sleep 0.1
        done
        echo "WARNING: the read engine did not start (try $try, $(( ($(date +%s%3N) - t0) / 1000 )) s): $(tail -3 "$1/bg-run.txt" 2>/dev/null | tr '\n' ' ')" >&2
        cp "$1/bg-run.txt" "$1/bg-run-try$try.txt" 2>/dev/null
        bg_end "$1" "" >/dev/null 2>&1
        # An engine error (not a slow start) is not retried.
        grep -qE '^pips: bg start refused|^pips: .*config error' "$1/bg-run.txt" 2>/dev/null && break
        sleep 2
    done
    echo "ERROR: the read engine did not start: $(tail -3 "$1/bg-run.txt" 2>/dev/null | tr '\n' ' ')" >&2
    return 1
}
bg_end() {   # <log dir> <report dir or "">: stop it, keep its counters; 1 if the engine had a problem
    [ -n "$BG_PID" ] || return 0
    local rc k v errs=0 why="" f="$1/bg-run.txt"
    sudo -n pkill -INT -f "^$PIPS bg run " >/dev/null 2>&1
    for _ in $(seq 150); do bg_alive "$BG_PID" || break; sleep 0.1; done
    if bg_alive "$BG_PID"; then
        echo "WARNING: pips bg run did not end 15 s after SIGINT: killing it, then pips bg stop" >&2
        sudo -n pkill -KILL -f "^$PIPS bg run " >/dev/null 2>&1
    fi
    wait "$BG_PID" 2>/dev/null; rc=$?
    BG_PID=""
    sudo -n "$PIPS" bg stop 3000 >> "$1/bg-cmd.txt" 2>&1
    [ -n "$2" ] || return 0
    sudo -n "$PIPS" bg hist > "$1/bg-hist.txt" 2>&1
    bgv() { awk -v k="$1=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) v = substr($i, length(k) + 1) } END { print (v == "" ? 0 : v) }' "$f" 2>/dev/null; }
    {
        echo "bg_spec: ${PIPS_BG}"
        echo "bg_label: ${PIPS_BG_LABEL:-}"
        echo "bg_rc: $rc"
        for k in bg_run_s run_s issued issue_rate_mrd_s lat_mean_ns lat_min_ns lat_max_ns cpl_sc cpl_ur cpl_ca cpl_other \
                 cpl_poisoned cpl_malformed cpl_unexpected timeouts data_mismatch leak_cpl win_hits stall_arb stall_tags \
                 stall_fc tfc_nph_min hol_engine hol_device out_max; do
            echo "bg_${k#bg_}: $(bgv "$k")"
        done
    } > "$2/bg.rpt"
    for k in cpl_ur cpl_ca cpl_other cpl_poisoned cpl_malformed cpl_unexpected timeouts data_mismatch leak_cpl; do
        v=$(bgv "$k"); case "$v" in ''|*[!0-9]*) v=0 ;; esac
        [ "$v" -gt 0 ] && { errs=$((errs + v)); why="$why $k=$v"; }
    done
    case "$rc" in 0) ;; 6) why="$why a NIC used a tag in the engine's window (WIN_HITS)" ;; 5) why="$why LEAK or CLASH" ;;
                  *) why="$why pips bg run exit $rc" ;; esac
    [ "$(bgv issued)" = 0 ] && why="$why no reads issued"
    echo "   read engine: $(bgv issued) reads, $(awk -v r="$(bgv issue_rate_mrd_s)" 'BEGIN { printf "%.2f", r / 1e6 }') M/s," \
         "latency mean $(bgv lat_mean_ns) ns, max $(bgv lat_max_ns) ns, errors $errs, exit $rc"
    if [ -n "$why" ]; then
        echo "ERROR: the read engine had a problem in $RUN:$why. The engine is stopped for good ($BG_STOPFILE)." >&2
        printf '%s %s:%s\n(run logs %s)\n' "$(date '+%F %T')" "$RUN" "$why" "$1" >> "$BG_STOPFILE"
        return 1
    fi
    return 0
}
bg_go() {   # the engine on before the warm-up; the run stops if it does not start
    bg_begin "$L" && return 0
    printf '%s %s: the engine did not start\n(run logs %s)\n' "$(date '+%F %T')" "$RUN" "$L" >> "$BG_STOPFILE"
    exit 3
}

cleanup() {
    [ -n "$BG_PID" ] && bg_end "${L:-/tmp}" ""
    pips_bp_stop 2>/dev/null
    sudo pkill -9 iperf3 >/dev/null 2>&1 || true
    rsh_try "sudo pkill -9 iperf3; screen -wipe" >/dev/null 2>&1 || true
    if [ "$gen" = alias ]; then
        sudo pkill -INT -f "$ALIAS_MATCH" >/dev/null 2>&1 || true
        rsh_try "sudo pkill -INT -f '$ALIAS_MATCH'; screen -wipe" >/dev/null 2>&1 || true
    fi
    sudo bash -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null || true
    if [ -n "$hw_rate" ]; then
        local i
        for i in "${ACTIVE[@]}"; do hw_rate_set "${CLIENT_INTFS[$i]}" 0 >/dev/null 2>&1; done
    fi
    return 0
}

# Hardware pacing on the client (--client-hw-rate): hw_rate_set <client port>
# <Mbps per queue, 0 = off> on every TX queue of that port. Prints what the port
# reads back; fails if it refuses (the driver or firmware lacks tx_maxrate).
hw_rate_set() {
    local c="$1" per="$2"
    rsh_try "sudo bash -c 'n=0; for q in /sys/class/net/$c/queues/tx-*/tx_maxrate; do
                 echo $per > \$q || exit 1; n=\$((n + 1)); done
                 echo \"     $c: \$n TX queues, tx-0 reads \$(cat /sys/class/net/$c/queues/tx-0/tx_maxrate) Mbps\"'" ||
        { echo "ERROR: $c on the client refused tx_maxrate=$per" >&2; return 1; }
}
# <aggregate, e.g. 50g> <flows> -> Mbps per TX queue (each flow gets its own queue)
hw_per_queue() { awk -v r="${1%[gG]}" -v n="$2" 'BEGIN { printf "%d", (r * 1000 + n - 1) / n }'; }

# Counters over the measurement window. ethtool -S of the server port (here)
# and the client port (styx) before and after; the deltas of the pause,
# discard, buffer and error counters go to reports/<run>/nicstats-nic<i>.rpt
# as srv_<name> / cli_<name>. TCP retransmits on the client from nstat (all
# its flows, both ports): reports/<run>/retx-client.rpt. (retx.rpt beside it is
# record-host-metrics.sh's, written as root: this host's own retransmits.)
NICSTAT_RE='pause|discard|out_of_buffer|buffer_passed|_err|crc|drop'
nicstats_snap() {   # <tag before|after>
    local i
    for i in "${ACTIVE[@]}"; do
        ethtool -S "${SERVER_INTFS[$i]}" > "$L/ethtool-srv-nic$i-$1.txt" 2>/dev/null
        rsh_try "ethtool -S ${CLIENT_INTFS[$i]}" > "$L/ethtool-cli-nic$i-$1.txt" 2>/dev/null
    done
    if [ "$1" = before ]; then
        rsh_try "nstat -n" >/dev/null 2>&1
    else
        rsh_try "nstat -z TcpOutSegs TcpRetransSegs" > "$L/nstat-client.txt" 2>/dev/null
    fi
}
nicstats_report() {
    local i r="$setup_dir/reports/$RUN"
    for i in "${ACTIVE[@]}"; do
        for side in srv cli; do
            awk -v re="$NICSTAT_RE" -v side="$side" '
                { gsub(/^[ \t]+/, ""); split($0, kv, /:[ \t]*/); k = kv[1]; v = kv[2] + 0 }
                k !~ re { next }
                FNR == NR { b[k] = v; next }
                { d = v - b[k]; if (d != 0) printf "%s_%s: %d\n", side, k, d }
            ' "$L/ethtool-$side-nic$i-before.txt" "$L/ethtool-$side-nic$i-after.txt" 2>/dev/null
        done > "$r/nicstats-nic$i.rpt"
    done
    # nstat after nstat -n: the increments since the window opened (-z: zeros too)
    awk '$1 == "TcpOutSegs" { o = $2 } $1 == "TcpRetransSegs" { x = $2 }
         END { if (o == "") exit; printf "Out_segs: %d\nRetx_segs: %d\nRetx_percent: %.4f\n", o, x, o ? 100 * x / o : 0 }' \
        "$L/nstat-client.txt" > "$r/retx-client.rpt" 2>/dev/null
}

# One experiment at a time. Every run kills iperf3 on BOTH hosts before it
# starts and again when it exits, so a second copy -- a forgotten tmux or nohup
# sweep -- zeroes the first one's traffic and its own, and both report ~0 Gbps.
# The lock is taken BEFORE the cleanup trap is armed: otherwise the refused
# copy's exit would still kill the running copy's iperf3.
exec 9>>/tmp/dualnic-experiment.lock
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    echo "ERROR: another dual-NIC experiment is already running on $(hostname):" >&2
    pgrep -af 'dualnic_(flow|load|pips)_swee[p]|dualnic_ex[p]|run-dualnic-experimen[t]' \
        | grep -v "^$$ " | sed 's/^/    /' >&2
    echo "  Wait for it to finish, or stop it first:" >&2
    echo "    pkill -f 'dualnic_flow_swee[p]'; pkill -f 'run-dualnic-experimen[t]'" >&2
    exit 1
fi

# INT/TERM must EXIT, not just clean up: a handler that returns lets the script
# carry on, so Ctrl-C or pkill killed the traffic and the run then continued,
# measuring nothing. Exiting fires the EXIT trap, which does the cleanup.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=============================================================="
echo "  experiment : $exp"
echo "  NICs       : $nics  (indices: ${ACTIVE[*]})"
[ -n "$hw_rate" ] && bandwidth=uncapped           # the client's NIC paces, not iperf3
echo "  per NIC    : $num_servers flows${flows1:+ (NIC 1: $flows1)}, $( [ "$(per_flow_bw "$bandwidth" "$num_clients")" = 0 ] && echo "UNCAPPED (line rate)" || echo "$bandwidth aggregate ($(per_flow_bw "$bandwidth" "$num_clients") bps/flow)" ), cca=$cca${hw_rate:+, client NIC paced to $hw_rate per port in hardware}"
echo "  mtu $mtu  ring $ring_buffer  sockbuf ${buf}MB  dur ${dur}s"
[ "$gen" = alias ] && echo "  generator  : alias-rdma READs, -S = QPs per NIC, depth $a_depth, bs $a_bs; pattern $( [ -n "$a_list" ] && echo "page list $a_list" || echo "ws $a_ws stride $a_stride first $a_first") order $a_order"
[ "$gen" = alias ] && echo "  scatter    : $( [ "$a_sge" -gt 0 ] && echo "$a_sge B per entry, one page each" || echo "default (one page per entry)"); RoCE MTU $( [ "$a_mtu" -gt 0 ] && echo "capped at $a_mtu" || echo "the ports'")"
[ "$gen" = alias ] && [ -n "$a_ws1$a_stride1$a_first1$a_order1$a_list1" ] &&
    echo "  NIC 1      : $(nic_pattern 1 | head -1)"
echo "  IOMMU      : $iommu_mode   (kernel $(uname -r))"
echo "=============================================================="

preflight

for ((j = 0; j < num_runs; j++)); do
    RUN="$exp-RUN-server-$j"
    L="$setup_dir/logs/$RUN"
    rm -rf "$setup_dir/reports/$RUN" "$L"
    mkdir -p "$setup_dir/reports/$RUN" "$L"

    cleanup; sleep 2
    # The PIPS build and setting this run ran with; its log region zeroed.
    pips_run_cfg

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

    # Data-plane IPs are set by ifconfig inside setup-envir.sh and do not
    # survive a reboot; they were just re-applied above. Preflight only tests
    # the MANAGEMENT link, so verify each test link here. Without this, a
    # freshly rebooted host fails later at iperf3 connect with a much more
    # obscure symptom.
    for i in "${ACTIVE[@]}"; do
        if ! ping -c 2 -W 3 -I "${SERVER_INTFS[$i]}" "${CLIENT_NIC_IPS[$i]}" >/dev/null 2>&1; then
            echo >&2
            echo "ERROR: no data-plane connectivity for NIC $i." >&2
            echo "  ${SERVER_INTFS[$i]} (${SERVER_NIC_IPS[$i]}) cannot reach ${CLIENT_NIC_IPS[$i]}" >&2
            echo "  Check both ends carry their address:" >&2
            echo "    ip -br addr show ${SERVER_INTFS[$i]}" >&2
            echo "    ssh $CLIENT_USERNAME@$CLIENT_SSH_IP ip -br addr show ${CLIENT_INTFS[$i]}" >&2
            echo "  After a reboot these are unset until setup-envir.sh restores" >&2
            echo "  them; if it ran and the link is still down, check cabling." >&2
            exit 1
        fi
    done
    echo "   data-plane links: OK"

    if [ "$gen" = alias ]; then
    # ------------------------------------------------- alias: servers, clients
    rsh "sudo pkill -INT -f '$ALIAS_MATCH' >/dev/null 2>&1; screen -wipe >/dev/null 2>&1; true"
    for i in "${ACTIVE[@]}"; do
        rsh "screen -dmS alias_srv_nic$i bash -c \"sudo $R_ALIAS_RDMA --role server --netdev ${CLIENT_INTFS[$i]} \
             --port $(( BASE_PORTS[i] + ALIAS_PORT_OFF )) --heartbeat 30 > /tmp/alias-srv-nic$i.log 2>&1\""
    done
    sleep 2
    a_secs=$(( 2 * dur + 30 + dur + 120 ))      # a backstop: stopped with SIGINT after the window
    for i in "${ACTIVE[@]}"; do
        rm -f "$L/alias-ready-nic$i"
        sudo "$ALIAS_RDMA" --role client --netdev "${SERVER_INTFS[$i]}" --server-ip "${CLIENT_NIC_IPS[$i]}" \
            --port $(( BASE_PORTS[i] + ALIAS_PORT_OFF )) --qps "$(nflows "$i")" --depth "$a_depth" --bs "$a_bs" \
            $(nic_pattern "$i") $( [ "$a_backing" -gt 0 ] && echo "--backing-pages $a_backing") \
            --warm 10 --seconds "$a_secs" --heartbeat 10 --cpu "${SERVER_CORES[$i]%%,*}" \
            --name "alias_nic$i" --out "$L/fio-nic$i" --ready-file "$L/alias-ready-nic$i" \
            > "$L/alias-rdma-nic$i.log" 2>&1 9>&- &
    done
    for _ in $(seq 450); do      # 90 s: a large MR (n2walk: 8 GiB of IOVA) takes a while to register
        n=0; for i in "${ACTIVE[@]}"; do [ -e "$L/alias-ready-nic$i" ] && n=$((n + 1)); done
        [ "$n" -eq "${#ACTIVE[@]}" ] && break
        sleep 0.2
    done
    for i in "${ACTIVE[@]}"; do
        if [ ! -e "$L/alias-ready-nic$i" ]; then
            echo "ERROR: alias-rdma for NIC $i did not start. Its output, and the server's:" >&2
            tail -12 "$L/alias-rdma-nic$i.log" | sed 's/^/    /' >&2
            rsh_try "tail -5 /tmp/alias-srv-nic$i.log" 2>/dev/null | sed 's/^/    server: /' >&2
            exit 1
        fi
        grep -E 'pattern|MR |connected' "$L/alias-rdma-nic$i.log" | sed "s/^/   NIC $i: /"
    done
    bg_go
    echo "warming up..."; sleep 12
    running=$(alias_count)
    echo "   alias-rdma clients running: $running/${#ACTIVE[@]}"
    if [ "$running" -lt "${#ACTIVE[@]}" ]; then
        echo "ERROR: an alias-rdma client stopped during the warm-up:" >&2
        tail -5 "$L"/alias-rdma-nic*.log | sed 's/^/    /' >&2
        exit 1
    fi
    else
    # ------------------------------------------------------------ receivers
    # Every invocation gets --no_kill and the stale-process sweep happens ONCE,
    # here. The invocations are backgrounded, so loop order is not execution
    # order: letting any of them run the pkill meant whichever started first
    # had its iperf3 group wiped by the other.
    sudo pkill -9 iperf3 >/dev/null 2>&1 || true
    sleep 1
    for i in "${ACTIVE[@]}"; do
        ( cd "$exp_dir" && sudo bash run-netapp-tput.sh -m server \
              -S "$(nflows "$i")" -o "$RUN-nic$i" -p "${BASE_PORTS[$i]}" \
              -c "${SERVER_CORES[$i]}" --no_kill ) 9>&- &   # don't hold the lock
    done
    sleep 5

    # Confirm the receivers actually bound before driving traffic at them.
    want=0; ranges=""
    for i in "${ACTIVE[@]}"; do
        want=$(( want + $(nflows "$i") )); ranges="$ranges ${BASE_PORTS[$i]}:$(nflows "$i")"
    done
    got=$(ss -ltn 2>/dev/null | awk -v r="$ranges" '
        BEGIN { n = split(r, rr, " "); for (k = 1; k <= n; k++) { split(rr[k], b, ":"); lo[k] = b[1]; cnt[k] = b[2] } }
        { split($4,a,":"); p=a[length(a)]+0
          for (k = 1; k <= n; k++) if (p >= lo[k] && p < lo[k] + cnt[k]) c++ }
        END{ print c+0 }')
    echo "   receivers listening: $got/$want"
    [ "$got" -eq 0 ] && { echo "ERROR: no iperf3 receivers bound." >&2; exit 1; }

    echo "turning on IOVA logging via ftrace"
    sudo bash -c 'echo > /sys/kernel/debug/tracing/trace' 2>/dev/null
    sudo bash -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null

    # -------------------------------------------------------------- senders
    # Same rule as the receivers: sweep once, then --no_kill for every group.
    rsh "sudo pkill -9 iperf3 >/dev/null 2>&1; screen -wipe >/dev/null 2>&1; true"
    sleep 1
    if [ -n "$hw_rate" ]; then
        for i in "${ACTIVE[@]}"; do
            per=$(hw_per_queue "$hw_rate" "$(nflows "$i")")
            echo "   client hardware pacing: ${CLIENT_INTFS[$i]} $hw_rate = $per Mbps per TX queue"
            hw_rate_set "${CLIENT_INTFS[$i]}" "$per" || exit 1
        done
    fi
    for i in "${ACTIVE[@]}"; do
        nf=$(nflows "$i")
        flow_bw=$(per_flow_bw "$bandwidth" "$nf")
        rsh "screen -dmS client_nic$i bash -c \"cd $exp_dir && \
             sudo bash run-netapp-tput.sh -m client -a ${SERVER_NIC_IPS[$i]} \
             -C $nf -S $nf -o $exp-RUN-client-$j-nic$i \
             -p ${BASE_PORTS[$i]} -l ${CLIENT_CORES[$i]} -c ${CLIENT_CORES[$i]} \
             -b $flow_bw --cca $cca --no_kill\""
    done

    bg_go
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
    fi   # gen

    # The TLP log, in steady state and before the window: BAR0 accesses
    # briefly hold up the switch's host-to-device requests.
    [ "$pips_log" = 1 ] && pips_record

    # -------------------------------------------------------------- measure
    # One pcm-iio collection: the counters are a stack-level sum regardless of
    # how many NICs are active, which is exactly the contention signal.
    echo "recording host metrics for ${dur}s (aggregate over active NICs)..."
    nicstats_snap before
    ( cd "$setup_dir" && sudo bash record-host-metrics.sh -f 0 --iio 0 -t 1 \
        --intf "${SERVER_INTFS[${ACTIVE[0]}]}" -o "$RUN" --type 0 \
        --cpu-util 1 --pcie 1 --membw 1 --bw 0 --dur "$dur" \
        --iommu-ops "$iommu_ops" --cores "$active_cores" )
    nicstats_snap after
    nicstats_report
    echo "   window counters: $(cat "$setup_dir/reports/$RUN/retx-client.rpt" 2>/dev/null | xargs);" \
         "pause/discard deltas: $(cat "$setup_dir/reports/$RUN"/nicstats-nic*.rpt 2>/dev/null | grep -c .) nonzero"
    if ! bg_end "$L" "$setup_dir/reports/$RUN"; then
        echo "ERROR: run $j of '$exp' is not valid (the read engine, above); stopping. Its logs: $L/" >&2
        exit 3
    fi

    # The window is over: dump and decode the TLP log while iperf3 finishes.
    t_pips=$SECONDS
    [ "$pips_log" = 1 ] && pips_collect

    if [ "$gen" = alias ]; then
        # Stop the clients (they write their JSON on SIGINT; the servers exit
        # when their client closes), then Gb/s over exactly the windows.
        alive=$(alias_count)
        sudo pkill -INT -f "$ALIAS_MATCH client" >/dev/null 2>&1
        for _ in $(seq 30); do [ "$(alias_count)" -eq 0 ] && break; sleep 0.5; done
        [ "$alive" -lt "${#ACTIVE[@]}" ] && echo "WARNING: only $alive of ${#ACTIVE[@]} alias-rdma clients ran to the end of the window" >&2
        for i in "${ACTIVE[@]}"; do
            r="$setup_dir/reports/$RUN-nic$i"; mkdir -p "$r"
            python3 "$HERE/dualssd-results.py" fio-sum --out "$r/fio.rpt" \
                --windows "$L/windows.txt" "$L/fio-nic$i.json" ||
                echo "WARNING: NIC $i: alias-rdma did not cover the measurement window (above)" >&2
            g=$(awk '/^read_Gbps:/ { print $2 }' "$r/fio.rpt" 2>/dev/null)
            echo "Avg_iperf_tput: ${g:-0}" > "$r/iperf.bw.rpt"
            echo "   NIC $i: ${g:-0} Gb/s over the window ($(awk '/^IOPS:/ { printf "%.0f kIOPS", $2 / 1e3 }' "$r/fio.rpt" 2>/dev/null)," \
                 "covered: $(awk '/^window_covered:/ { print ($2 == 1 ? "yes" : "NO") }' "$r/fio.rpt" 2>/dev/null))"
        done
    else
    # iperf3 server stats are written by run-netapp-tput.sh after its own
    # 80s wait; give those background jobs time to land their .rpt files.
    echo "waiting for iperf3 stats to be written..."
    left=$(( 75 - (SECONDS - t_pips) ))
    [ "$left" -gt 0 ] && sleep "$left"

    for i in "${ACTIVE[@]}"; do
        rcp_back "$setup_dir/reports/$exp-RUN-client-$j-nic$i/retx.rpt" \
                 "$setup_dir/reports/$RUN/retx-nic$i.rpt" 2>/dev/null
    done
    fi

    cleanup
done

# ------------------------------------------------------------------ report
echo
echo "=============================================================="
echo "  RESULT: $exp"
echo "=============================================================="
[ "$num_runs" -gt 1 ] && echo "  (mean +/- stddev over $num_runs runs)"

# mean_sd <file-with-one-number-per-line> -> "mean sd"
mean_sd() {
    awk '{ x[n++]=$1; s+=$1 }
         END { if (!n) { print "0 0"; exit }
               m=s/n; for (i=0;i<n;i++) v+=(x[i]-m)^2
               printf "%.3f %.3f", m, (n>1 ? sqrt(v/(n-1)) : 0) }'
}

total=0
for i in "${ACTIVE[@]}"; do
    vals=$(for ((j = 0; j < num_runs; j++)); do
        g=$(awk '{print $NF}' \
            "$setup_dir/reports/$exp-RUN-server-$j-nic$i/iperf.bw.rpt" 2>/dev/null)
        case "${g:-}" in ''|*[!0-9.]*) g=0 ;; esac
        echo "$g"
    done)
    read -r m sd <<< "$(printf '%s\n' "$vals" | mean_sd)"
    if [ "$num_runs" -gt 1 ]; then
        printf '  NIC %s (%-14s) : %s +/- %s Gbps\n' "$i" "${SERVER_INTFS[$i]}" "$m" "$sd"
    else
        printf '  NIC %s (%-14s) : %s Gbps\n' "$i" "${SERVER_INTFS[$i]}" "$m"
    fi
    total=$(awk -v a="$total" -v b="$m" 'BEGIN{printf "%.3f", a+b}')
done
printf '  %-22s : %s Gbps\n' "AGGREGATE" "$total"
pips_report

# Average each counter across runs so multi-run output stays comparable.
if [ "$num_runs" -gt 1 ]; then
    P="$setup_dir/reports/$exp-RUN-server-mean.rpt"
    : > "$P"
    for key in PCIe_wr_tput PCIe_rd_tput IOTLB_lookups IOTLB_misses \
               IOTLB_hits_derived CTXT_cache_hits PWC_512G_hits PWC_1G_hits \
               PWC_2M_hits PWC_4K_hits IOMMU_mem_access; do
        v=$(for ((j = 0; j < num_runs; j++)); do
                awk -v k="^$key:" '$0 ~ k {print $NF}' \
                    "$setup_dir/reports/$exp-RUN-server-$j/pcie.rpt" 2>/dev/null
            done | mean_sd)
        set -- $v
        printf '%s: %s   (sd %s)\n' "$key" "$1" "$2" >> "$P"
    done
else
    P="$setup_dir/reports/$exp-RUN-server-0/pcie.rpt"
fi
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
    # The comparison metric. Raw miss counts scale with bytes moved, so they
    # cannot be compared between runs that carried different amounts of
    # traffic -- which is exactly the uncapped 1-NIC vs 2-NIC case. Misses per
    # Gbps of actual PCIe write traffic is the number to compare.
    ms=$(awk '/^IOTLB_misses:/{print $2}' "$P" 2>/dev/null)
    case "${ms:-}" in ''|*[!0-9.]*) ms=0 ;; esac
    if awk -v w="$wr" 'BEGIN{exit !(w > 0)}'; then
        echo
        printf '  IOTLB misses per Gbps : %s   <-- compare THIS across runs\n' \
            "$(awk -v m="$ms" -v p="$wr" 'BEGIN{printf "%.1f", m/p}')"
    fi

    if awk -v w="$wr" 'BEGIN{exit !(w > 100)}'; then
        echo
        if [ "$(per_flow_bw "$bandwidth" "$num_clients")" = "0" ]; then
            # Uncapped was asked for, so saturation is the intended condition,
            # not a mistake. Say what it does to the reading instead.
            echo "  NOTE: uncapped run. PCIe write ${wr} Gbps is $(awk -v w="$wr" \
                'BEGIN{printf "%.0f", 100*w/126}')% of the ~126 Gbps shared uplink,"
            echo "  so the link is a binding constraint here. Absolute throughput"
            echo "  and raw miss counts between 1-NIC and 2-NIC runs are therefore"
            echo "  not comparable -- use the misses-per-Gbps line above, which"
            echo "  normalises out the difference in bytes moved."
        else
            echo "  WARNING: PCIe write ${wr} Gbps is close to the ~126 Gbps shared"
            echo "  uplink despite a cap being set, so the cap is not binding."
            echo "  Lower --bandwidth, or pass --uncapped if that is intended."
        fi
    fi
fi
echo
echo "  reports: $setup_dir/reports/$exp-RUN-server-0*/"

# Machine-readable copy: config, IOMMU mode, every run, and mean/sd, as one
# JSON line. The .rpt files above remain the source of truth. Unnamed dumps
# get a fresh number rather than appending to a previous run's file.
if [ -z "$results_file" ]; then
    k=1; while [ -e "$HOME/$exp-$k.jsonl" ]; do k=$((k + 1)); done
    results_file="$HOME/$exp-$k.jsonl"
fi
flow_bw=$(per_flow_bw "$bandwidth" "$num_clients")
fl_meta="$num_servers"
[ "$nics" -eq 2 ] && [ -n "$flows1" ] && [ "$flows1" != "$num_servers" ] && fl_meta="${num_servers}x$flows1"
pips_meta       # the PIPS build, setting and log status, when the NICs are behind it
# The read engine's spec and its mean rate, latency and errors over the runs.
bgr() { awk -v k="^$2:" '$0 ~ k { print $2; exit }' "$1" 2>/dev/null; }
if [ -n "${PIPS_BG:-}" ]; then
    bgmean() { for ((j = 0; j < num_runs; j++)); do bgr "$setup_dir/reports/$exp-RUN-server-$j/bg.rpt" "$1"; done | mean_sd | cut -d' ' -f1; }
    BGMETA=( --meta "bg_spec=$PIPS_BG" --meta "bg_label=${PIPS_BG_LABEL:-}" --meta "bg_rate_mrd_s=$(bgmean bg_issue_rate_mrd_s)"
             --meta "bg_lat_ns=$(bgmean bg_lat_mean_ns)" --meta "bg_lat_max_ns=$(bgmean bg_lat_max_ns)"
             --meta "bg_errors=$(for ((j = 0; j < num_runs; j++)); do f=$setup_dir/reports/$exp-RUN-server-$j/bg.rpt
                 for k in bg_cpl_ur bg_cpl_ca bg_timeouts bg_data_mismatch bg_cpl_malformed; do bgr "$f" "$k"; done
                 done | awk '{ s += $1 } END { print s + 0 }')" )
else
    BGMETA=( --meta bg_spec=off --meta bg_label=off )
fi
python3 "$HERE/dualnic-results.py" dump \
    --reports "$setup_dir/reports" --exp "$exp" --runs "$num_runs" \
    --nics "$(IFS=,; echo "${ACTIVE[*]}")" --out "$results_file" \
    --meta mode="$( [ "$nics" -eq 2 ] && echo both || echo "nic${nic_index}only" )" \
    --meta iommu="$iommu_mode" \
    --meta flows_per_nic="$fl_meta" \
    --meta flows_nic0="$(nflows 0)" --meta flows_nic1="$(nflows 1)" \
    --meta bandwidth_per_nic="$( [ -n "$hw_rate" ] && echo "hw$hw_rate" || { [ "$flow_bw" = 0 ] && echo uncapped || echo "$bandwidth"; } )" \
    --meta client_hw_rate="${hw_rate:-none}" \
    --meta per_flow_bps="$flow_bw" \
    --meta mtu="$mtu" --meta ring_buffer="$ring_buffer" --meta sockbuf_mb="$buf" \
    --meta gen="$gen" \
    $( [ "$gen" = alias ] && printf -- '--meta %s ' alias_ws="$a_ws" alias_stride="$a_stride" alias_first="$a_first" \
        alias_order="$a_order" alias_backing="$a_backing" alias_depth="$a_depth" alias_bs="$a_bs" alias_list="${a_list:-none}" \
        alias_sge_bytes="$a_sge" alias_rdma_mtu="$a_mtu" alias_ws1="${a_ws1:-$a_ws}" alias_stride1="${a_stride1:-$a_stride}" \
        alias_first1="${a_first1:-$a_first}" alias_order1="${a_order1:-$a_order}" alias_list1="${a_list1:-${a_list:-none}}") \
    --meta dur_s="$dur" --meta cca="$cca" --meta cpu_util_cores="$active_cores" \
    ${PIPS_META[@]+"${PIPS_META[@]}"} "${BGMETA[@]}" \
    || echo "WARNING: could not write $results_file; the .rpt files are intact." >&2
