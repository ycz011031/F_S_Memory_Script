#!/bin/bash
# Drive 1 or 2 NVMe SSDs with concurrent fio readers on bigserver (Skylake-SP),
# and report per-drive IOPS alongside the shared IOMMU counters. The SSD
# counterpart of run-dualnic-experiment.sh; fio runs locally, so no client.
#
#   ./run-dualssd-experiment.sh -E base-ssd0 --ssds 1 -J 4
#   ./run-dualssd-experiment.sh -E base-ssd1 --ssds 1 --ssd-index 1 -J 4
#   ./run-dualssd-experiment.sh -E dual      --ssds 2 -J 4 --runs 3
#   ./run-dualssd-experiment.sh -E dual2     --ssds 2 -J 4 --tmux   # in tmux instead
#   ./run-dualssd-experiment.sh -E asym      --ssds 2 -J 4,32       # 4 on drive 0, 32 on drive 1
#
# Runs in this terminal unless --tmux is given; --tmux starts it in a new tmux
# session (survives a dropped ssh; asks for the sudo password there).
#
# -J is fio instances PER DRIVE, the analogue of iperf3 flows per NIC; -J n0,n1
# gives the two drives of a co-run different counts. Each instance is its own
# fio process with one job, pinned round-robin over the drive's cores
# (SSD_CORES), so each submits on its own NVMe queue. When the counts differ,
# both drives' cores together are split in proportion to them instead, so
# every core runs about as many instances. I/O is O_DIRECT: the
# NVMe driver maps every buffer through the IOMMU on submit and unmaps it on
# completion, so in strict mode every completed I/O is an IOTLB invalidation.
#
# READ-ONLY: fio always runs with --readonly, and only read/randread are
# accepted. The drives hold data, and this host is shared.
#
# Never overwrites: if output for -E <name> already exists the run is refused.
# Everything lands under utils/logs/ and utils/reports/ (-E may contain a
# slash, e.g. <sweep>/<config>, to group runs in a folder):
#   logs/<name>.console.log     this script's full console output
#   logs/<name>-RUN-<j>/        pcie.csv (pcm-iio, every stack, every second),
#                               pcm-iio.out, membw.log (pcm-memory), pcm.txt
#                               (binary, row, core), the opCode file used,
#                               cpu_util.log, windows.txt (window start/end),
#                               fio-ssd<i>-<k>.json/.err and _iops.1.log
#                               (per-second IOPS, proves fio covered the window)
#   reports/<name>-RUN-<j>/     pcie.rpt, membw.rpt, cpu_util.rpt
#   reports/<name>-RUN-<j>-ssd<i>/fio.rpt
#
# Drives behind the PIPS switch: every result records the switch's FPGA
# design ID (pips_design_id, e.g. 0x0a04) and batcher setting (pips_batch,
# e.g. d8t22 = depth 8, time 22; m1 = batch_mrd on; c1 = drain depth cap on),
# read through BAR0 before the runs, and each run's logs/<name>-RUN-<j>/
# pips-cfg.txt holds the `pips cfg` readout it ran with. Results of different
# builds or settings never mix (dualssd-results.py groups by both).
#
# --pips-log 1: also record the switch's TLP log in every run. The log region
# is zeroed before fio starts. The recording starts after the warm-up, before
# the measurement windows, and runs until the region fills (milliseconds under
# load; cut after 5 s). After fio stops it is dumped from FPGA DDR through
# BAR0, decoded and gzipped. No BAR0 access overlaps a measurement window.
# Per run:
#   logs/<name>-RUN-<j>/pips-log-id<XXXX>.bin.gz   the recording, as the DMA
#                               wrote it, named with the design ID, which picks
#                               its record format (pips-log.bin.gz on a build
#                               without one)
#   logs/<name>-RUN-<j>/pips-log-summary.txt/.json, pips-cfg.txt, pips-log-*.txt
#   reports/<name>-RUN-<j>/pips-log.rpt       status: FULL, FULL+DROPS, CUT,
#                               CUT+DROPS, NO_TRAILER, BAD or FAILED (no log);
#                               design_id and log_format lines
# A log problem does not fail the run; it shows in the status. PIPS_LOG_GZIP=0
# keeps pips-log.bin uncompressed.
#
# --iommu-ops 1: also count IOMMU map/unmap calls and VT-d invalidation
# descriptors beside the pcm-iio window (perf tracepoints, utils/iommu-ops.sh:
# logs/<name>-RUN-<j>/iommu-ops.txt, reports/<name>-RUN-<j>/iommu-ops.rpt,
# iommu_ops_* in the results). Counting costs CPU per map: for counting runs.
#
# --gen alias: the in-house generator instead of fio (scripts/pips/alias/,
# README.md there). The drives are bound to vfio-pci for the runner's runs
# (alias-vfio.sh; put back on nvme when it exits, and at its next start if a
# run died) and alias-nvme reads them with polled queues: -J queues per drive,
# --iodepth reads in flight per queue, --bs per read, every 4 KiB landing on
# the next page of a fixed aliasing pattern mapped ONCE at a fixed IOVA, so
# the misses come from the pattern, not from map/unmap:
#   --ws N --stride N   pages first + i*stride, i < ws (default 64, 1)
#   --first N --order cyclic|shuffle|random --page-list PATH --backing-pages N
#   --lba rand|seq      where on the namespace (default rand)
#   --ws1 N --stride1 N --first1 N --order1 O --page-list1 PATH
#                       drive 1's own pattern (default drive 0's), its own region
#   --cursor queue|shared  one cursor per queue (default; their phases drift) or
#                       one per drive (strict pattern order)
# Read-only as fio: the generator builds no command but Identify, queue
# setup and Read. Its per-queue output is fio's (fio-ssd<i>-<k>.json and
# _iops.1.log), so fio-sum and the results are the same; the results add
# gen=alias and alias_* (pattern).
# ALIAS_HOLD=<dir> (set by pips-campaign.sh ssd --alias): a running
# alias-nvme --hold has the drives for the whole campaign; each run sends it a
# load command (<dir>/cmd) and ends the load with <dir>/stop, and the runner
# never binds, resolves block devices, or restores (releasing the drives
# froze bigserver, HANDOFF §8). The holder's queues, qd and bs are fixed
# (<dir>/config): -J, --iodepth and --bs must match. The IOMMU must be on (VFIO needs a group;
# pt is fine and translates: VFIO's domain is its own).
#
# PIPS_BG="K=V ..." (set by pips-campaign.sh --bg; design 0x0A08): the
# switch's background read engine runs through every run: `pips bg run
# PIPS_BG stopwin=1` starts once the load is up (before the warm-up) and is
# stopped after the measurement windows. Per run: logs/<run>/bg-run.txt (its
# counters), bg-hist.txt (latency histogram), reports/<run>/bg.rpt; in the
# results bg_spec, bg_label (PIPS_BG_LABEL), bg_rate_mrd_s, bg_lat_ns,
# bg_errors (means over the runs). Any engine problem (a completion other than
# SC, a timeout, a data mismatch, a leak, a device tag in the engine's tag
# window, no reads at all) makes the run invalid (exit 3) and writes
# PIPS_BG_STOPFILE (default ~/.pips-bg-stop) with the reason; while that file
# exists every runner with PIPS_BG refuses to start (the campaign then stops
# using the engine).
#
# Exit status 3: this configuration could not be measured (fio instances died,
# stalled or missed the window, or pcm-iio logged nothing with the IOMMU on;
# with it off or pt such a run is kept); sweeps log it and go on.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
. "$HERE/../utils/setup-server.sh"
. "$HERE/../utils/ssd-lib.sh"

# --tmux: start over inside a tmux session, with the same arguments minus it.
PASS=(); IN_TMUX=0
for a in "$@"; do if [ "$a" = --tmux ]; then IN_TMUX=1; else PASS+=( "$a" ); fi; done
set -- ${PASS[@]+"${PASS[@]}"}

exp="dualssd-test"
ssds=2                 # how many drives to drive
ssd_index=0            # which drive when --ssds 1
jobs=4                 # fio instances PER DRIVE
bs=4k
iodepth=32
rw=randread
ioengine=libaio
dur=20                 # each measurement window (CPU, then PCIe)
warm=10                # fio ramp_time; excluded from fio's stats
membw=1                # pcm-memory; adds 30 s + dur per run, --membw 0 skips it
num_runs=1
results_file=""        # JSONL to append to; default ~/<exp>-<N>.jsonl, first unused N
pips_log=0             # 1: record the PIPS switch's TLP log in every run
iommu_ops=0            # 1: count IOMMU map/unmap and VT-d invalidations (utils/iommu-ops.sh)
gen=fio                # fio, or alias: scripts/pips/alias/alias-nvme through VFIO
a_ws=64; a_stride=1; a_first=0; a_order=cyclic; a_list=""; a_backing=0; a_lba=rand
a_ws1=""; a_stride1=""; a_first1=""; a_order1=""; a_list1=""; a_cursor=queue   # drive 1's own pattern (empty: drive 0's)

while [ $# -gt 0 ]; do
    case "$1" in
        -E|--exp)       exp="$2"; shift 2 ;;
        --ssds)         ssds="$2"; shift 2 ;;
        --ssd-index)    ssd_index="$2"; shift 2 ;;
        -J|--jobs)      jobs="$2"; shift 2 ;;
        --bs)           bs="$2"; shift 2 ;;
        --iodepth)      iodepth="$2"; shift 2 ;;
        --rw)           rw="$2"; shift 2 ;;
        --ioengine)     ioengine="$2"; shift 2 ;;
        -d|--dur)       dur="$2"; shift 2 ;;
        --warm)         warm="$2"; shift 2 ;;
        --membw)        membw="$2"; shift 2 ;;
        --runs)         num_runs="$2"; shift 2 ;;
        --results)      results_file="$2"; shift 2 ;;
        --pips-log)     pips_log="$2"; shift 2 ;;
        --iommu-ops)    iommu_ops="$2"; shift 2 ;;
        --gen)          gen="$2"; shift 2 ;;
        --ws)           a_ws="$2"; shift 2 ;;
        --stride)       a_stride="$2"; shift 2 ;;
        --first)        a_first="$2"; shift 2 ;;
        --order)        a_order="$2"; shift 2 ;;
        --page-list)    a_list="$2"; shift 2 ;;
        --backing-pages) a_backing="$2"; shift 2 ;;
        --lba)          a_lba="$2"; shift 2 ;;
        --ws1)          a_ws1="$2"; shift 2 ;;
        --stride1)      a_stride1="$2"; shift 2 ;;
        --first1)       a_first1="$2"; shift 2 ;;
        --order1)       a_order1="$2"; shift 2 ;;
        --page-list1)   a_list1="$2"; shift 2 ;;
        --cursor)       a_cursor="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,85p' "$SELF"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

case "$rw" in
    read|randread) ;;
    *) echo "ERROR: --rw $rw refused. Only read/randread: these drives hold data." >&2; exit 2 ;;
esac
case "$ssds" in 1|2) ;; *) echo "ERROR: --ssds must be 1 or 2" >&2; exit 2 ;; esac
case "$pips_log" in 0|1) ;; *) echo "ERROR: --pips-log must be 0 or 1" >&2; exit 2 ;; esac
case "$iommu_ops" in 0|1) ;; *) echo "ERROR: --iommu-ops must be 0 or 1" >&2; exit 2 ;; esac
case "$ssd_index" in 0|1) ;; *) echo "ERROR: --ssd-index must be 0 or 1" >&2; exit 2 ;; esac
case "$gen" in fio|alias) ;; *) echo "ERROR: --gen must be fio or alias" >&2; exit 2 ;; esac
case "$a_order" in cyclic|shuffle|random) ;; *) echo "ERROR: --order cyclic, shuffle or random" >&2; exit 2 ;; esac
case "$a_lba" in rand|seq) ;; *) echo "ERROR: --lba rand or seq" >&2; exit 2 ;; esac
for v in "$a_ws" "$a_stride" "$a_first" "$a_backing"; do
    case "$v" in ''|*[!0-9]*) echo "ERROR: --ws/--stride/--first/--backing-pages take integers" >&2; exit 2 ;; esac
done
for v in "$a_ws1" "$a_stride1" "$a_first1"; do
    case "$v" in *[!0-9]*) echo "ERROR: --ws1/--stride1/--first1 take integers" >&2; exit 2 ;; esac
done
case "$a_order1" in ''|cyclic|shuffle|random) ;; *) echo "ERROR: --order1 cyclic, shuffle or random" >&2; exit 2 ;; esac
case "$a_cursor" in queue|shared) ;; *) echo "ERROR: --cursor queue or shared" >&2; exit 2 ;; esac
[ -z "$a_list" ] || [ -f "$a_list" ] || { echo "ERROR: --page-list $a_list: no such file" >&2; exit 2; }
[ -z "$a_list1" ] || [ -f "$a_list1" ] || { echo "ERROR: --page-list1 $a_list1: no such file" >&2; exit 2; }
# The holder's load extras (KEY=VALUE) and alias-nvme's options for drive 1's pattern and the cursor.
hold_extra() {
    local e="cursor=$a_cursor"
    [ "$a_first" != 0 ] && e+=" first=$a_first"
    [ -n "$a_list" ] && e+=" list=$(readlink -f "$a_list")"
    [ -n "$a_ws1" ] && e+=" ws1=$a_ws1"
    [ -n "$a_stride1" ] && e+=" stride1=$a_stride1"
    [ -n "$a_first1" ] && e+=" first1=$a_first1"
    [ -n "$a_order1" ] && e+=" order1=$a_order1"
    [ -n "$a_list1" ] && e+=" list1=$(readlink -f "$a_list1")"
    echo "$e"
}
nvme_extra() {
    echo "--cursor $a_cursor"
    [ -n "$a_ws1" ] && echo "--ws1 $a_ws1"
    [ -n "$a_stride1" ] && echo "--stride1 $a_stride1"
    [ -n "$a_first1" ] && echo "--first1 $a_first1"
    [ -n "$a_order1" ] && echo "--order1 $a_order1"
    [ -n "$a_list1" ] && echo "--page-list1 $a_list1"
}
# JOBS[i]: instances on drive i. -J n0,n1 sets them separately (co-run only).
IFS=',' read -r -a JOBS <<< "$jobs"
case "${#JOBS[@]}" in
    1) JOBS=( "${JOBS[0]}" "${JOBS[0]}" ) ;;
    2) [ "$ssds" -eq 2 ] || { echo "ERROR: -J n0,n1 needs --ssds 2" >&2; exit 2; } ;;
    *) echo "ERROR: -J takes n, or n0,n1 for a co-run" >&2; exit 2 ;;
esac
for v in "${JOBS[@]}"; do
    case "$v" in ''|*[!0-9]*|0) echo "ERROR: -J must be a positive integer, or two separated by a comma" >&2; exit 2 ;; esac
done
[ "$IN_TMUX" = 1 ] && relaunch_in_tmux "$SELF" ${PASS[@]+"${PASS[@]}"}

for v in SSD_SERIALS SSD_CORES; do
    if ! declare -p "$v" >/dev/null 2>&1; then
        echo "ERROR: $v is not set in utils/setup-server.sh." >&2
        echo "  On bigserver start from the template:" >&2
        echo "    cp utils/setup-server.sh.bigserver.example utils/setup-server.sh" >&2
        exit 1
    fi
done

REPO="${REPO_DIR:-$DEP_DIR/${REPO_NAME:-Fast-and-Safe-IO-Memory-Protection}}"
setup_dir="$REPO/utils"
PCM_BIN="${PCM_BIN:-${PCM_DIR:-}/build/bin}"
CPU_FAM=$(awk -F: '/^cpu family/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
CPU_MODEL=$(awk -F: '/^model[[:space:]]*:/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)

# Which drive indices participate in this run.
if [ "$ssds" -eq 1 ]; then ACTIVE=( "$ssd_index" ); else ACTIVE=( 0 1 ); fi

ALIAS_DIR="$HERE/pips/alias"
HOLD=""
if [ "$gen" = alias ] && [ -n "${ALIAS_HOLD:-}" ]; then
    HOLD=$ALIAS_HOLD
    grep -q '^ready' "$HOLD/state" 2>/dev/null && [ -s "$HOLD/drives" ] && [ -s "$HOLD/config" ] || {
        echo "ERROR: ALIAS_HOLD=$HOLD: no ready holder there (state: $(cat "$HOLD/state" 2>/dev/null))" >&2; exit 1; }
elif pgrep -f 'alias-nvm[e] .*--hold ' >/dev/null 2>&1; then
    echo "ERROR: an alias-nvme --hold has the drives (a campaign's holder). Run through it" >&2
    echo "       (ALIAS_HOLD=<its dir>), or end it with a reboot; never restore or kill it." >&2
    exit 1
elif [ "$gen" = alias ] && ls /run/alias-vfio/* >/dev/null 2>&1; then
    echo "-- drives left on vfio-pci by an earlier alias run: putting them back on nvme"
    sudo -n bash "$ALIAS_DIR/alias-vfio.sh" restore || echo "WARNING: alias-vfio.sh restore failed (status: bash $ALIAS_DIR/alias-vfio.sh status)" >&2
fi

DEVS=(); BDFS=()
for i in "${ACTIVE[@]}"; do
    if [ -n "$HOLD" ]; then
        read -r _ hb hs < <(awk -v i="$i" '$1 == i' "$HOLD/drives")
        [ -n "${hb:-}" ] && [ "${hs:-}" = "${SSD_SERIALS[$i]}" ] || {
            echo "ERROR: the holder has no SSD $i (${SSD_SERIALS[$i]}): $HOLD/drives" >&2; exit 1; }
        DEVS[$i]="vfio:$hb"; BDFS[$i]=$hb
        continue
    fi
    ssd_resolve "${SSD_SERIALS[$i]}" || exit 1
    DEVS[$i]=$SSD_DEV; BDFS[$i]=$SSD_BDF
done
# --gen alias binds these to vfio-pci: the active drives, and the other drive
# too when it shares their IOMMU group (no ACS on the switch's ports: VFIO
# then needs every endpoint of the group on vfio-pci, even for one drive alone).
ALIAS_BIND=()
if [ "$gen" = alias ] && [ -z "$HOLD" ]; then
    for i in "${ACTIVE[@]}"; do ALIAS_BIND+=( "${BDFS[$i]}" ); done
    for i in 0 1; do
        [[ " ${ACTIVE[*]} " == *" $i "* ]] && continue
        [ -n "${SSD_SERIALS[$i]:-}" ] || continue
        ssd_resolve "${SSD_SERIALS[$i]}" >/dev/null 2>&1 || continue
        og=$(basename "$(readlink "/sys/bus/pci/devices/$SSD_BDF/iommu_group" 2>/dev/null)" 2>/dev/null)
        for b in "${ALIAS_BIND[@]}"; do
            if [ -n "$og" ] && [ "$og" = "$(basename "$(readlink "/sys/bus/pci/devices/$b/iommu_group" 2>/dev/null)" 2>/dev/null)" ]; then
                echo "-- SSD $i ($SSD_BDF) shares IOMMU group $og with an active drive: it goes to vfio-pci too (idle)"
                ALIAS_BIND+=( "$SSD_BDF" ); break
            fi
        done
    done
fi

# CORES[i]: the cores drive i's instances run on, round-robin. Normally
# SSD_CORES[i]. A co-run with different counts splits both lists' cores in
# proportion to the counts instead, so each core runs about as many
# instances: the lighter drive keeps the head of its own list (fio off the
# interrupt CPUs), the heavier one takes its own list plus the rest. With 18
# cores, 4+32 gives 2 and 16 cores (2 instances each); 8+16 gives 6 and 12.
# SSD_SPLIT_CORES=0 (setup-server.sh) keeps each drive on its own list in an
# uneven co-run too: when the drives' queues for one CPU group interrupt the
# same CPU (bigserver from the 10-25 boot: CPUs 36-40 and 41-45 complete both
# drives on CPU 40 / 45), borrowing the other drive's cores puts both drives'
# completions, and their strict-mode invalidations, on one CPU again.
CORES=()
for i in "${ACTIVE[@]}"; do CORES[$i]=${SSD_CORES[$i]}; done
if [ "$ssds" -eq 2 ] && [ "${JOBS[0]}" != "${JOBS[1]}" ] && [ "${SSD_SPLIT_CORES:-1}" = 1 ]; then
    lo=$(( JOBS[0] < JOBS[1] ? 0 : 1 )); hi=$(( 1 - lo ))
    IFS=',' read -r -a mine <<< "${SSD_CORES[$lo]}"
    IFS=',' read -r -a other <<< "${SSD_CORES[$hi]}"
    C=$(( ${#mine[@]} + ${#other[@]} )); n=$(( JOBS[0] + JOBS[1] ))
    c=$(( (2 * C * JOBS[lo] + n) / (2 * n) ))          # its share, rounded
    [ "$c" -lt 1 ] && c=1
    [ "$c" -gt "${JOBS[$lo]}" ] && c=${JOBS[$lo]}
    [ "$c" -gt "${#mine[@]}" ] && c=${#mine[@]}
    rest=( "${other[@]}" "${mine[@]:c}" )
    CORES[$lo]=$(IFS=,; echo "${mine[*]:0:c}")
    CORES[$hi]=$(IFS=,; echo "${rest[*]}")
fi

# CPU utilisation is recorded over every active drive's cores.
active_cores=""
for i in "${ACTIVE[@]}"; do active_cores="${active_cores:+$active_cores,}${CORES[$i]}"; done
ncores=$(printf '%s' "$active_cores" | tr ',' '\n' | grep -c .)

# What the kernel actually did, from sysfs, per drive. Both drives sit behind
# dmar7, so a mismatch means something unexpected happened at boot.
iommu_mode=$(for i in "${ACTIVE[@]}"; do
                 bash "$HERE/../utils/iommu-mode.sh" "${BDFS[$i]}"
             done | sort -u | paste -sd+)
iommu_units=$(for i in "${ACTIVE[@]}"; do iommu_unit "${BDFS[$i]}"; done | sort -u | paste -sd+)
translating() {   # true unless every active drive's IOMMU is off or passthrough
    local m
    for m in $(printf '%s' "$iommu_mode" | tr '+' ' '); do
        case "$m" in off|pt) ;; *) return 0 ;; esac
    done
    return 1
}

# fio processes are found by job name. The [_] keeps the pattern from matching
# the pkill/pgrep command line itself, and the anchored fio from matching the
# sudo wrapper.
FIO_MATCH='^(/[^ ]*/)?fio .*--name=dualssd[_]'
# --gen alias: the generator, by its binary path at the start of the command
# line (sudo's own line starts with sudo). It also writes its JSON on SIGINT.
[ "$gen" = alias ] && FIO_MATCH='^(/[^ ]*/)?alias-nvm[e] --dev '
# Under a holder: "1" while its heartbeat (<dir>/alive, each second) is fresh
# and says load.
hold_loading() {
    local a; a=$(cat "$HOLD/alive" 2>/dev/null)
    [ -n "$a" ] && [ $(( $(date +%s%3N) - ${a%% *} )) -lt 10000 ] && [ "${a##* }" = load ]
}
fio_count() {
    if [ -n "$HOLD" ]; then hold_loading && echo 1 || echo 0; return; fi
    local n; n=$(pgrep -c -f "$FIO_MATCH" 2>/dev/null); echo "${n:-0}"
}
# The load's lines from the holder's log into $L/alias-nvme.out, once its
# done line is there (<dir>/done: "<n> NAME ok|FAILED").
hold_collect() {   # <name> <out>
    for _ in $(seq 60); do [ "$(awk '{ print $2 }' "$HOLD/done" 2>/dev/null)" = "$1" ] && break; sleep 1; done
    awk -v n="'$1'" 'index($0, "hold: load") && index($0, n) { on = 1 } on { print } on && index($0, n) && /(done|FAILED); idle/ { exit }' \
        "$HOLD/holder.txt" > "$2" 2>/dev/null
    grep -q "^[0-9]* $1 ok" "$HOLD/done" 2>/dev/null || echo "WARNING: the holder's load $1: $(cat "$HOLD/done" 2>/dev/null)" >&2
}
stop_fio() {    # SIGINT makes fio stop and still write its JSON
    if [ -n "$HOLD" ]; then   # the load ends, the holder keeps the drives
        hold_loading || return 0
        touch "$HOLD/stop"
        for _ in $(seq 60); do hold_loading || return 0; sleep 1; done
        echo "WARNING: the holder's load did not end 60 s after $HOLD/stop" >&2
        return 0
    fi
    sudo -n pkill -INT -f "$FIO_MATCH" >/dev/null 2>&1 || true
    # alias-nvme gives the drives back step by step after SIGINT (~30 s: NVMe
    # shutdown, settle, a reset before each close, alias-nvme.c --exit-steps). A KILL would leave
    # the close to the kernel, whose release froze bigserver on 11-05: wait
    # long, and say so loudly if it comes to that.
    local wait_s=30
    [ "$gen" = alias ] && wait_s=120
    for _ in $(seq $wait_s); do [ "$(fio_count)" -eq 0 ] && return; sleep 1; done
    [ "$gen" = alias ] && echo "WARNING: alias-nvme did not exit ${wait_s}s after SIGINT; killing it (the kernel's release of the drives may freeze the host)" >&2
    sudo -n pkill -KILL -f "$FIO_MATCH" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------ PIPS switch
# The switch's build and batcher setting with every result, and with
# --pips-log 1 its TLP log in every run: pips_identify (preflight),
# pips_run_cfg (each run), pips_record, pips_collect, pips_meta, all in
# pips-lib.sh with $PIPS, pips_tag, cfg_of, cap_of, design_of.
. "$HERE/pips/pips-lib.sh"

# Fail fast on the things that otherwise produce a full run of zeros. Collect
# every problem rather than stopping at the first.
preflight() {
    echo "-- preflight"
    echo "   running on: $(hostname) ($(id -un)), CPU family $CPU_FAM model $CPU_MODEL"
    PROBLEMS=()

    # bigserver has no NOPASSWD rule: sudo works here only while a recent
    # password entry is cached. The runner's own sudo calls keep that cache
    # alive for the whole run, so caching it once just before starting is enough.
    if sudo -n true >/dev/null 2>&1; then
        echo "   sudo: OK (no password needed right now)"
    else
        PROBLEMS+=("sudo needs a password, and this script cannot answer a prompt mid-run.
    Enter it once, in this same terminal (in tmux, the same pane), then re-run:
      sudo -v
    The runner's own sudo calls keep the cached credentials alive while it runs.")
    fi

    miss=""
    for t in $( [ "$gen" = fio ] && echo fio) python3 sar lspci; do command -v "$t" >/dev/null || miss="$miss $t"; done
    [ -n "$miss" ] && PROBLEMS+=("missing tools:$miss")
    if [ -n "$HOLD" ]; then
        read -r _ hq _ hd _ hbs < "$HOLD/config"
        bsb=$(numfmt --from=iec "${bs^^}" 2>/dev/null || echo "$bs")
        echo "   holder: $(cat "$HOLD/state") in $HOLD; queues $hq, qd $hd, bs $hbs"
        for i in "${ACTIVE[@]}"; do
            [ "${JOBS[$i]}" = "$hq" ] || PROBLEMS+=("SSD $i: -J ${JOBS[$i]}, but the holder runs $hq queues per drive")
        done
        [ "$iodepth" = "$hd" ] || PROBLEMS+=("--iodepth $iodepth, but the holder runs qd $hd")
        [ "$bsb" = "$hbs" ] || PROBLEMS+=("--bs $bs, but the holder runs bs $hbs")
        [ "${a_backing:-0}" = 0 ] && [ "$a_lba" = rand ] ||
            PROBLEMS+=("under a holder --backing-pages and --lba can't change per run")
        [ "$a_cursor" = queue ] && [ -z "$a_ws1$a_stride1$a_first1$a_order1$a_list1$a_list" ] && [ "$a_first" = 0 ] ||
            grep -q ' v2' "$HOLD/state" 2>/dev/null ||
            PROBLEMS+=("the holder predates per-drive patterns, --first/--page-list and --cursor (state without v2, 11-06): start a new campaign")
        a=$(cat "$HOLD/alive" 2>/dev/null)
        [ -n "$a" ] && [ $(( $(date +%s%3N) - ${a%% *} )) -lt 10000 ] || PROBLEMS+=("the holder's heartbeat is stale: $HOLD/alive '$a'")
    elif [ "$gen" = alias ]; then
        if ALIAS_NVME=$(bash "$ALIAS_DIR/alias-run.sh" --build alias-nvme 2>&1 | tail -1) && [ -x "$ALIAS_NVME" ]; then
            echo "   alias-nvme: $ALIAS_NVME"
        else
            PROBLEMS+=("alias-nvme does not build here: $ALIAS_NVME
    make -C $ALIAS_DIR nvme")
        fi
        modinfo vfio-pci >/dev/null 2>&1 || PROBLEMS+=("no vfio-pci module (modinfo vfio-pci)")
        for i in "${ACTIVE[@]}"; do
            [ -e "/sys/bus/pci/devices/${BDFS[$i]}/iommu_group" ] ||
                PROBLEMS+=("SSD $i (${BDFS[$i]}) has no IOMMU group: --gen alias needs the IOMMU on (VFIO; pt is fine)")
        done
    fi

    if [ -x "$PCM_BIN/pcm-iio" ]; then
        echo "   pcm-iio: $PCM_BIN/pcm-iio"
    else
        PROBLEMS+=("no pcm-iio at $PCM_BIN/pcm-iio. Set PCM_BIN in utils/setup-server.sh.")
    fi
    if [ "$membw" = 1 ] && [ ! -x "$PCM_BIN/pcm-memory" ]; then
        PROBLEMS+=("no pcm-memory at $PCM_BIN/pcm-memory. Set PCM_BIN, or pass --membw 0.")
    fi
    # pcm-iio loads opCode-<family>-<model>.txt from utils/ (the cwd it runs in).
    if [ ! -f "$setup_dir/opCode-$CPU_FAM-$CPU_MODEL.txt" ]; then
        PROBLEMS+=("utils/opCode-$CPU_FAM-$CPU_MODEL.txt is missing, so pcm-iio would fall back to
    PCM's installed event file and the CSV columns would not be the ones
    record-host-metrics.sh reads.")
    fi
    if [ "$CPU_MODEL" != 85 ]; then
        echo "   NOTE: CPU model $CPU_MODEL is not Skylake-SP (85); pcie.rpt uses that CPU's parser."
    fi
    if [ -z "${SSD_PCIE_PATTERN:-}" ]; then
        PROBLEMS+=("SSD_PCIE_PATTERN is empty in utils/setup-server.sh. Find it with:
      sudo bash $setup_dir/discover-ssd-pcie.sh")
    else
        echo "   pcm-iio row: $SSD_PCIE_PATTERN"
    fi

    # record-host-metrics.sh ends its window with 'pkill -9 pcm' and
    # 'pkill -9 -x sar', which would also kill another user's copies -- and two
    # PCM instances programming the same uncore counters corrupt each other.
    others=$(pgrep -a -x 'pcm(-[a-z]+)?' 2>/dev/null)
    if [ -n "$others" ]; then
        PROBLEMS+=("PCM is already running on this host (another user?):
$(printf '%s\n' "$others" | sed 's/^/      /')
    Its counters and ours would corrupt each other, and this run would kill it.")
    fi
    others=$(pgrep -a -x sar 2>/dev/null)
    if [ -n "$others" ]; then
        PROBLEMS+=("sar is already running on this host; this run would kill it:
$(printf '%s\n' "$others" | sed 's/^/      /')")
    fi
    others=$(ps -o user=,pid=,args= -C fio 2>/dev/null)
    if [ -n "$others" ]; then
        echo "   WARNING: other fio processes are running; they compete for CPU, and for"
        echo "            the IOMMU if they touch drives behind $iommu_units:"
        printf '%s\n' "$others" | sed 's/^/              /'
    fi

    for i in "${ACTIVE[@]}"; do
        dev=${DEVS[$i]}; bdf=${BDFS[$i]}
        model=$(cat /sys/bus/pci/devices/"$bdf"/nvme/nvme*/model 2>/dev/null | head -1 | xargs)
        echo "   SSD $i: ${SSD_SERIALS[$i]} -> $dev ($bdf, $model)"
        [ -n "$HOLD" ] && continue        # held by vfio-pci: no block device, nothing to check
        [ -b "$dev" ] || PROBLEMS+=("$dev is not a block device")
        # Busy drives: a mount or an md/LVM/dm holder means someone else's I/O
        # on the device under test, or someone else's data in use.
        busy=$(lsblk -nr -o NAME,TYPE,MOUNTPOINT "$dev" 2>/dev/null \
               | awk '$2 ~ /^(raid|lvm|crypt|md|dm)/ || $3 != ""')
        if [ -n "$busy" ]; then
            PROBLEMS+=("$dev (SSD $i) is in use -- mounted or held by md/LVM/dm:
$(printf '%s\n' "$busy" | sed 's/^/      /')")
        fi
        node=$(cat "/sys/bus/pci/devices/$bdf/numa_node" 2>/dev/null)
        for c in $(printf '%s' "${SSD_CORES[$i]}" | tr ',' ' '); do
            if [ ! -e "/sys/devices/system/cpu/cpu$c" ]; then
                PROBLEMS+=("SSD_CORES[$i] lists CPU $c, which does not exist")
            elif [ "${node:--1}" -ge 0 ] && [ ! -e "/sys/devices/system/node/node$node/cpu$c" ]; then
                echo "   WARNING: CPU $c in SSD_CORES[$i] is not on SSD $i's NUMA node $node"
            fi
        done
    done
    pips_identify drive "${BDFS[@]}"
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
    if [ "$ssds" -eq 2 ] && [ "$(printf '%s' "$iommu_units" | tr '+' '\n' | grep -c .)" -gt 1 ]; then
        echo "   NOTE: the drives are behind DIFFERENT IOMMU units ($iommu_units); a co-run"
        echo "         has no shared IOTLB to contend for."
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

# ------------------------------------------------------------ the read engine (PIPS_BG)
BG_STOPFILE=${PIPS_BG_STOPFILE:-$HOME/.pips-bg-stop}
BG_PID=""
# 11-09: the start is given 30 s and up to 3 tries. Campaign c11082355 lost
# both halves to a 5 s wait: pips reached "started" at ~5 s (behind the BAR0
# lock or a slow sudo) and was then stopped as "did not start".
bg_begin() {   # <log dir>: start the engine for this run; 1 if it did not start
    [ -n "${PIPS_BG:-}" ] || return 0
    local try t0 dt
    for try in 1 2 3; do
        rm -f "$1/bg-run.txt"
        echo "\$ pips bg run $PIPS_BG secs=$(( warm + span + 600 )) beat=10 stopwin=1   (try $try, $(date '+%T'))" >> "$1/bg-cmd.txt"
        t0=$(date +%s%3N)
        sudo -n "$PIPS" bg run $PIPS_BG secs=$(( warm + span + 600 )) beat=10 stopwin=1 > "$1/bg-run.txt" 2>&1 9>&- &
        BG_PID=$!
        for _ in $(seq 300); do
            if grep -q '^# bg run: started' "$1/bg-run.txt" 2>/dev/null; then
                dt=$(( $(date +%s%3N) - t0 ))
                echo "   read engine on: ${PIPS_BG_LABEL:-$PIPS_BG} (started in $dt ms$( [ "$try" -gt 1 ] && echo ", try $try"))"
                echo "bg_start_ms: $dt try $try" >> "$1/bg-cmd.txt"
                return 0
            fi
            kill -0 "$BG_PID" 2>/dev/null || break
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
    for _ in $(seq 150); do kill -0 "$BG_PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$BG_PID" 2>/dev/null; then
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
    case "$rc" in 0) ;; 6) why="$why a device used a tag in the engine's window (WIN_HITS)" ;; 5) why="$why LEAK or CLASH" ;;
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

aborted=0
ALIAS_BOUND=0
cleanup() {
    [ -n "$BG_PID" ] && bg_end "${L:-/tmp}" ""
    pips_bp_stop 2>/dev/null
    stop_fio
    if [ "$ALIAS_BOUND" = 1 ]; then
        sudo -n bash "$ALIAS_DIR/alias-vfio.sh" restore "${ALIAS_BIND[@]}" ||
            echo "ERROR: drives not back on nvme: sudo bash $ALIAS_DIR/alias-vfio.sh restore" >&2
    fi
    if [ "$aborted" = 1 ]; then
        # Interrupted mid-window: record-host-metrics.sh never got to stop its
        # samplers. Preflight made sure none of these belonged to anyone else.
        sudo -n pkill -9 -x pcm-iio >/dev/null 2>&1 || true
        sudo -n pkill -9 -x pcm-memory >/dev/null 2>&1 || true
        sudo -n pkill -9 -x sar >/dev/null 2>&1 || true
    fi
}

# One experiment at a time: each run stops every dualssd fio on exit, so a
# second copy -- a forgotten tmux or nohup sweep -- would end the first one's
# load. The lock is taken BEFORE the cleanup trap is armed, so a refused copy
# exits without touching the running one.
exec 9>>/tmp/dualssd-experiment.lock
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    echo "ERROR: another dual-SSD experiment is already running on $(hostname):" >&2
    pgrep -af 'dualssd_swee[p]|run-dualssd-experimen[t]' | grep -v "^$$ " | sed 's/^/    /' >&2
    echo "  Wait for it to finish, or stop it first:" >&2
    echo "    pkill -f 'dualssd_swee[p]'; pkill -f 'run-dualssd-experimen[t]'" >&2
    exit 1
fi

# Never overwrite earlier output: a name with run data is refused, not reused.
existing=$(ls -d "$setup_dir/logs/$exp-RUN-"* "$setup_dir/reports/$exp-RUN-"* 2>/dev/null)
if [ -n "$existing" ]; then
    echo "ERROR: output for experiment '$exp' already exists; refusing to overwrite:" >&2
    printf '%s\n' "$existing" | head -5 | sed 's/^/    /' >&2
    echo "  Pick a new -E name." >&2
    exit 1
fi
# From here on, everything this script prints is also saved. Appended, so a
# retry after a failed preflight (which writes no run data) keeps the first try.
console="$setup_dir/logs/$exp.console.log"
mkdir -p "$(dirname "$console")"
exec > >(tee -a "$console") 2>&1

# INT/TERM must EXIT, not just clean up, or the script carries on measuring an
# idle drive. Exiting fires the EXIT trap, which does the cleanup.
trap cleanup EXIT
trap 'aborted=1; exit 130' INT
trap 'aborted=1; exit 143' TERM

# Measurement windows are sequential in record-host-metrics.sh: CPU for dur,
# then pcm-iio for dur, then (optionally) pcm-memory for 30 s + dur. fio must
# stay loaded across all of them; the runner stops it with SIGINT afterwards,
# so its runtime is only a backstop.
span=$(( 2 * dur + (membw == 1 ? 30 + dur : 0) ))
fio_runtime=$(( warm + span + 120 ))

echo "=============================================================="
echo "  experiment : $exp   ($(date '+%F %T'))"
echo "  SSDs       : $ssds  (indices: ${ACTIVE[*]})"
for i in "${ACTIVE[@]}"; do echo "               $i: ${DEVS[$i]}  ${JOBS[$i]} instance(s) on cores ${CORES[$i]}"; done
if [ "$gen" = alias ]; then
echo "  generator  : alias-nvme (VFIO, polled), per queue: iodepth $iodepth, bs=$bs, lba $a_lba, read-only"
echo "  pattern    : $( [ -n "$a_list" ] && echo "page list $a_list" || echo "ws $a_ws stride $a_stride first $a_first") order $a_order, backing ${a_backing:-0} (0 = default), cursor $a_cursor"
[ -n "$a_ws1$a_stride1$a_first1$a_order1$a_list1" ] &&
echo "  drive 1    : $( [ -n "$a_list1" ] && echo "page list $a_list1" || echo "ws ${a_ws1:-$a_ws} stride ${a_stride1:-$a_stride} first ${a_first1:-$a_first}") order ${a_order1:-$a_order}"
else
echo "  per instance: iodepth $iodepth, $rw bs=$bs, $ioengine, O_DIRECT, read-only"
fi
echo "  windows    : ramp ${warm}s, CPU ${dur}s, PCIe ${dur}s$( [ "$membw" = 1 ] && echo ", memory $((30 + dur))s" )"
echo "  IOMMU      : $iommu_mode on $iommu_units   (kernel $(uname -r))"
echo "=============================================================="

preflight
uplink_gbps=$(shared_link_gbps $(for i in "${ACTIVE[@]}"; do echo "${BDFS[$i]}"; done))
if [ -n "$HOLD" ]; then
    echo "   drives held by the campaign's alias-nvme --hold ($(cat "$HOLD/state")): no bind, no restore"
elif [ "$gen" = alias ]; then
    # The drives leave the nvme driver for this runner's runs; cleanup puts them back.
    ALIAS_BOUND=1
    sudo -n bash "$ALIAS_DIR/alias-vfio.sh" bind "${ALIAS_BIND[@]}" || {
        echo "ERROR: could not bind the drives to vfio-pci (above)" >&2; exit 1; }
    bash "$ALIAS_DIR/alias-vfio.sh" status "${ALIAS_BIND[@]}" | sed 's/^/   /'
fi
echo "   narrowest shared PCIe link: ~${uplink_gbps} Gbps"

for ((j = 0; j < num_runs; j++)); do
    RUN="$exp-RUN-$j"
    L="$setup_dir/logs/$RUN"
    mkdir -p "$setup_dir/reports/$RUN" "$L"
    for i in "${ACTIVE[@]}"; do mkdir -p "$setup_dir/reports/$RUN-ssd$i"; done

    # What produced pcie.csv: the binary, the row parsed, and the event file
    # that defines its columns, so the raw log can be re-read on its own.
    {
        echo "date:       $(date '+%F %T')"
        echo "pcm-iio:    $PCM_BIN/pcm-iio  (pinned to CPU ${PCM_CORE:-15})"
        echo "pcm-memory: $( [ "$membw" = 1 ] && echo "$PCM_BIN/pcm-memory" || echo "not run (--membw 0)")"
        echo "event file: opCode-$CPU_FAM-$CPU_MODEL.txt (copy alongside)"
        echo "row parsed: $SSD_PCIE_PATTERN   (VT-d counters from that stack's Part0 row)"
        echo "IOMMU:      $iommu_mode on $iommu_units"
    } > "$L/pcm.txt"
    cp "$setup_dir/opCode-$CPU_FAM-$CPU_MODEL.txt" "$L/" 2>/dev/null

    stop_fio; sleep 1
    [ "$num_runs" -gt 1 ] && echo "-- run $((j + 1))/$num_runs"

    # The switch's build and setting this run ran with; the log region zeroed.
    pips_run_cfg

    # ---------------------------------------------------------------- load
    want=0; fio_pids=()
    if [ -n "$HOLD" ]; then
        # The campaign's holder runs the load: one command, ready when loaded.
        mask=0; for i in "${ACTIVE[@]}"; do mask=$(( mask | (1 << i) )); done
        rm -f "$L/alias-ready"
        echo "load $RUN $mask $a_ws $a_stride $a_order $warm $fio_runtime $L $L/alias-ready $(hold_extra)" > "$HOLD/cmd.tmp" &&
            mv "$HOLD/cmd.tmp" "$HOLD/cmd"
        for _ in $(seq 600); do [ -e "$L/alias-ready" ] && break; sleep 0.2; done
        if [ ! -e "$L/alias-ready" ]; then
            echo "ERROR: the holder did not load the drives in 120 s. Its log:" >&2
            tail -15 "$HOLD/holder.txt" | sed 's/^/    /' >&2
            stop_fio
            exit 3
        fi
        want=1
        echo "   holder: load $RUN on drives mask $mask, ws $a_ws stride $a_stride $a_order; $(hold_extra)"
    elif [ "$gen" = alias ]; then
        # One generator for every active drive: one VFIO process per group.
        aargs=(); acpus=(); aq=(); aser=()
        for i in "${ACTIVE[@]}"; do
            aargs+=( --dev "${BDFS[$i]}=$L/fio-ssd$i" ); acpus+=( "${CORES[$i]}" ); aq+=( "${JOBS[$i]}" )
            aser+=( "${SSD_SERIALS[$i]}" )
        done
        [ -n "$a_list" ] && aargs+=( --page-list "$a_list" )
        rm -f "$L/alias-ready"
        sudo "$ALIAS_NVME" "${aargs[@]}" --serial "$(IFS=,; echo "${aser[*]}")" \
            --queues "$(IFS=,; echo "${aq[*]}")" --cpus "$(IFS=/; echo "${acpus[*]}")" \
            --qd "$iodepth" --bs "$bs" --lba "$a_lba" \
            --ws "$a_ws" --stride "$a_stride" --first "$a_first" --order "$a_order" $(nvme_extra) \
            $( [ "$a_backing" -gt 0 ] && echo "--backing-pages $a_backing") \
            --warm "$warm" --seconds "$fio_runtime" --heartbeat 10 \
            --ready-file "$L/alias-ready" > "$L/alias-nvme.out" 2>&1 9>&- &
        fio_pids+=( $! ); want=1
        for _ in $(seq 300); do
            [ -e "$L/alias-ready" ] && break
            kill -0 "${fio_pids[0]}" 2>/dev/null || break
            sleep 0.2
        done
        if [ ! -e "$L/alias-ready" ]; then
            echo "ERROR: alias-nvme did not load the drives. Its output:" >&2
            tail -15 "$L/alias-nvme.out" | sed 's/^/    /' >&2
            exit 3
        fi
        grep -E '^alias-nvme: (0000|[0-9a-f]{4}:)|region|pattern' "$L/alias-nvme.out" | sed 's/^/   /'
    fi
    for i in $( [ "$gen" = fio ] && echo "${ACTIVE[@]}"); do
        IFS=',' read -r -a cores <<< "${CORES[$i]}"
        [ "${JOBS[$i]}" -gt "${#cores[@]}" ] && [ "$j" -eq 0 ] && \
            echo "   NOTE: SSD $i: ${JOBS[$i]} instances on ${#cores[@]} cores; some cores run more than one"
        for ((k = 0; k < JOBS[i]; k++)); do
            core=${cores[$((k % ${#cores[@]}))]}
            # --thread keeps one process per instance, so fio_count counts
            # instances. 9>&- so fio does not hold the experiment lock.
            # The per-second IOPS log, stamped in epoch ms, is what proves the
            # instance ran through the measurement windows and gives IOPS for
            # exactly those seconds (fio-sum --windows). fio logs nothing
            # during ramp_time.
            # Sequential (--rw read): each instance reads its own slice of the
            # drive (offset k/J, size 1/J), so the instances are J streams.
            sudo fio --name="dualssd_${i}_${k}" --filename="${DEVS[$i]}" --readonly \
                $( [ "$rw" = read ] && echo "--offset=$(( k * 100 / JOBS[i] ))% --size=$(( 100 / JOBS[i] ))%") \
                --rw="$rw" --bs="$bs" --iodepth="$iodepth" --numjobs=1 --thread \
                --direct=1 --ioengine="$ioengine" --cpus_allowed="$core" \
                --time_based --ramp_time="$warm" --runtime="$fio_runtime" \
                --randrepeat=0 --norandommap --output-format=json \
                --write_iops_log="$L/fio-ssd$i-$k" --log_avg_msec=1000 --log_unix_epoch=1 \
                --output="$L/fio-ssd$i-$k.json" > "$L/fio-ssd$i-$k.err" 2>&1 9>&- &
            fio_pids+=( $! )
            want=$((want + 1))
        done
    done

    # Start the warm-up clock once every instance is running. With 64 of them
    # (32 per drive, co-run) the last sudo + fio launch may lag the first; its
    # ramp would then end inside the window, and fio-sum rejects a late start.
    for _ in $(seq 100); do [ "$(fio_count)" -ge "$want" ] && break; sleep 0.2; done
    # PIPS_BG: the read engine from here to the end of the windows (the warm-up
    # takes the IOTLB to its loaded state with the engine already on).
    if ! bg_begin "$L"; then
        printf '%s %s: the engine did not start\n(run logs %s)\n' "$(date '+%F %T')" "$RUN" "$L" >> "$BG_STOPFILE"
        stop_fio
        exit 3
    fi
    # The window then opens 1 s after the ramp, plus 1 s per 16 instances: on
    # oversubscribed cores some instances' ramps start late (0.5-0.7 s at 64).
    echo "warming up ${warm}s..."; sleep "$warm"; sleep $((1 + want / 16))

    # An instance that died on startup leaves its drive under-loaded, and the
    # run would otherwise measure that without a word.
    got=$(fio_count)
    echo "   $( [ "$gen" = alias ] && echo "alias-nvme processes" || echo "fio instances") running: $got/$want"
    if [ "$got" -lt "$want" ]; then
        echo "ERROR: only $got of $want $gen processes are running. First errors:" >&2
        cat "$L"/fio-ssd*.err "$L"/alias-nvme.out 2>/dev/null | grep -v '^$' | grep -iE 'error|fatal|warn' | head -10 | sed 's/^/    /' >&2
        exit 3
    fi

    [ "$pips_log" = 1 ] && pips_record

    # -------------------------------------------------------------- measure
    echo "recording host metrics: CPU ${dur}s, then pcm-iio ${dur}s..."
    ( cd "$setup_dir" && sudo bash record-host-metrics.sh -f 0 --iio 0 --type 0 \
        --cpu-util 1 --retx 0 --bw 0 --pcie 1 --membw "$membw" --dur "$dur" \
        --iommu-ops "$iommu_ops" \
        --cores "$active_cores" --pattern "$SSD_PCIE_PATTERN" -o "$RUN" ) 9>&-

    bg_bad=0
    bg_end "$L" "$setup_dir/reports/$RUN" || bg_bad=1
    got=$(fio_count)
    bad_run=$bg_bad
    if [ "$got" -lt "$want" ]; then
        echo "ERROR: only $got of $want fio instances were still running at the end" >&2
        echo "       of the measurement; the drives were under-loaded for part of it." >&2
        bad_run=1
    fi
    stop_fio
    [ -n "$HOLD" ] && hold_collect "$RUN" "$L/alias-nvme.out"
    # Wait for these PIDs only. A bare `wait` also waits for the console-log
    # tee started by `exec > >(tee ...)`, which never exits while this script
    # runs: the run hangs forever after the last measurement window (and
    # under a holder there are none).
    [ ${#fio_pids[@]} -gt 0 ] && wait "${fio_pids[@]}" 2>/dev/null
    [ "$pips_log" = 1 ] && pips_collect

    # IOPS over exactly the measurement windows, and proof that every instance
    # ran through them: fio-sum exits 3 if any instance's log or its own
    # start/stop times do not cover the windows.
    if [ ! -s "$L/windows.txt" ]; then
        echo "ERROR: $L/windows.txt is missing; record-host-metrics.sh did not finish." >&2
        bad_run=1
    fi
    # No pcm-iio rows means no PCIe or IOMMU values for this run
    # (pcie_samples is written by the Skylake parser only). With the IOMMU on,
    # those counters are what the run is for, so it is not valid. With it off
    # or in passthrough they have nothing to count, and fio's IOPS and the CPU
    # cost are the comparison: the run is kept, and dualssd-results.py records
    # its PCIe values as missing rather than 0.
    n=$(awk '/^pcie_samples:/{print $2}' "$setup_dir/reports/$RUN/pcie.rpt" 2>/dev/null)
    if [ "${n:-1}" = 0 ]; then
        if translating; then
            echo "ERROR: pcm-iio logged no rows for '$SSD_PCIE_PATTERN'; see $L/pcm-iio.out" >&2
            bad_run=1
        else
            echo "WARNING: pcm-iio logged no rows for '$SSD_PCIE_PATTERN' (see $L/pcm-iio.out)." >&2
            echo "         IOMMU $iommu_mode: run kept, PCIe values recorded as missing." >&2
        fi
    fi
    for i in "${ACTIVE[@]}"; do
        F="$setup_dir/reports/$RUN-ssd$i/fio.rpt"
        if ! python3 "$HERE/dualssd-results.py" fio-sum --out "$F" \
                --windows "$L/windows.txt" "$L"/fio-ssd$i-*.json; then
            echo "ERROR: SSD $i: fio did not cover the measurement window (see above)." >&2
            bad_run=1
        fi
        printf '   SSD %s: %s kIOPS over the %s s measurement window (fio post-ramp: %s), covered: %s\n' \
            "$i" "$(awk '/^IOPS:/{printf "%.1f", $2/1e3}' "$F" 2>/dev/null)" \
            "$(awk '/^window_s:/{print $2}' "$F" 2>/dev/null)" \
            "$(awk '/^fio_IOPS_postramp:/{printf "%.1f", $2/1e3}' "$F" 2>/dev/null)" \
            "$(awk '/^window_covered:/{print ($2 == 1 ? "yes" : "NO")}' "$F" 2>/dev/null)"
    done
    if [ "$bad_run" = 1 ]; then
        echo "ERROR: run $j of '$exp' is not valid; stopping. Its logs and reports are kept:" >&2
        echo "       $L/   $setup_dir/reports/$RUN*/" >&2
        exit 3
    fi
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
rpt_val() {   # <file> <key> -> value, 0 if absent
    local v
    v=$(awk -v k="^$2:" '$0 ~ k {print $2; exit}' "$1" 2>/dev/null)
    case "${v:-}" in ''|*[!0-9.e+-]*) v=0 ;; esac
    echo "$v"
}

iops_total=0; gbps_total=0
for i in "${ACTIVE[@]}"; do
    read -r im isd <<< "$(for ((j = 0; j < num_runs; j++)); do
        rpt_val "$setup_dir/reports/$exp-RUN-$j-ssd$i/fio.rpt" IOPS; done | mean_sd)"
    read -r gm gsd <<< "$(for ((j = 0; j < num_runs; j++)); do
        rpt_val "$setup_dir/reports/$exp-RUN-$j-ssd$i/fio.rpt" read_Gbps; done | mean_sd)"
    lat=$(rpt_val "$setup_dir/reports/$exp-RUN-0-ssd$i/fio.rpt" lat_mean_us)
    if [ "$num_runs" -gt 1 ]; then
        printf '  SSD %s (%-12s) : %s +/- %s kIOPS, %s +/- %s Gbps\n' "$i" "${DEVS[$i]#/dev/}" \
            "$(awk -v x="$im" 'BEGIN{printf "%.1f", x/1e3}')" "$(awk -v x="$isd" 'BEGIN{printf "%.1f", x/1e3}')" "$gm" "$gsd"
    else
        printf '  SSD %s (%-12s) : %s kIOPS, %s Gbps, mean latency %s us\n' "$i" "${DEVS[$i]#/dev/}" \
            "$(awk -v x="$im" 'BEGIN{printf "%.1f", x/1e3}')" "$gm" "$lat"
    fi
    iops_total=$(awk -v a="$iops_total" -v b="$im" 'BEGIN{printf "%.1f", a+b}')
    gbps_total=$(awk -v a="$gbps_total" -v b="$gm" 'BEGIN{printf "%.3f", a+b}')
done
printf '  %-25s : %s kIOPS, %s Gbps\n' "AGGREGATE" \
    "$(awk -v x="$iops_total" 'BEGIN{printf "%.1f", x/1e3}')" "$gbps_total"
pips_report

# Average each counter across runs so multi-run output stays comparable. The
# key set depends on the CPU, so take it from the first run's report.
P0="$setup_dir/reports/$exp-RUN-0/pcie.rpt"
if [ "$num_runs" -gt 1 ] && [ -f "$P0" ]; then
    P="$setup_dir/reports/$exp-RUN-mean.rpt"
    : > "$P"
    for key in $(awk -F: '{print $1}' "$P0"); do
        v=$(for ((j = 0; j < num_runs; j++)); do
                rpt_val "$setup_dir/reports/$exp-RUN-$j/pcie.rpt" "$key"
            done | mean_sd)
        set -- $v
        printf '%s: %s   (sd %s)\n' "$key" "$1" "$2" >> "$P"
    done
else
    P="$P0"
fi
# A kept run without pcm-iio rows (IOMMU off or pt) has no counters to show.
if [ -f "$P" ] && grep -q '^pcie_samples:' "$P" \
        && awk '/^pcie_samples:/{exit !($2 == 0)}' "$P"; then
    echo
    echo "  pcm-iio logged no rows: no PCIe or IOMMU counters for this experiment."
elif [ -f "$P" ]; then
    echo
    echo "  shared IIO stack counters (sum over ALL active drives), per second:"
    grep -v '^cpu_model:' "$P" | sed 's/^/    /'

    wr=$(rpt_val "$P" PCIe_wr_tput)
    ms=$(rpt_val "$P" IOTLB_misses)
    if awk -v x="$iops_total" 'BEGIN{exit !(x > 0)}'; then
        echo
        printf '  IOTLB misses per I/O  : %s   <-- compare THIS across runs\n' \
            "$(awk -v m="$ms" -v n="$iops_total" 'BEGIN{printf "%.3f", m/n}')"
    fi
    # PCIe write is the drives' DMA of read data into memory; it should track
    # fio's read bandwidth plus a little protocol overhead.
    if awk -v w="$wr" 'BEGIN{exit !(w > 0)}'; then
        printf '  PCIe write / fio read : %s Gbps / %s Gbps\n' "$wr" "$gbps_total"
    fi
    if [ "${uplink_gbps:-0}" -gt 0 ] && awk -v w="$wr" -v u="$uplink_gbps" 'BEGIN{exit !(w > 0.85*u)}'; then
        echo
        echo "  NOTE: PCIe write ${wr} Gbps is $(awk -v w="$wr" -v u="$uplink_gbps" \
            'BEGIN{printf "%.0f", 100*w/u}')% of the ~${uplink_gbps} Gbps shared link, so the"
        echo "  link, not the IOMMU, is likely the binding limit for this run."
    fi
fi
echo
echo "  reports: $setup_dir/reports/$exp-RUN-*/"
echo "  raw logs (pcie.csv, pcm-iio.out, membw.log, fio JSON): $setup_dir/logs/$exp-RUN-*/"
echo "  console: $console"

# Machine-readable copy: config, IOMMU mode, every run, and mean/sd, as one
# JSON line. The .rpt files above remain the source of truth. Unnamed dumps
# get a fresh number rather than appending to a previous run's file.
if [ -z "$results_file" ]; then
    k=1; while [ -e "$HOME/${exp//\//_}-$k.jsonl" ]; do k=$((k + 1)); done
    results_file="$HOME/${exp//\//_}-$k.jsonl"
fi
# instances_per_ssd stays a number for a single drive or an even co-run, so
# old and new records group alike; an uneven co-run is "n0+n1". Per drive,
# instances_ssd<i> and cores_ssd<i> say exactly what ran where.
inst=${JOBS[${ACTIVE[0]}]}
[ "$ssds" -eq 2 ] && [ "${JOBS[0]}" != "${JOBS[1]}" ] && inst="${JOBS[0]}+${JOBS[1]}"
per_drive=()
for i in "${ACTIVE[@]}"; do
    per_drive+=( --meta "instances_ssd$i=${JOBS[$i]}" --meta "cores_ssd$i=${CORES[$i]}" )
done
# The PIPS build, setting and log status (pips_meta, pips-lib.sh).
pips_meta
per_drive+=( ${PIPS_META[@]+"${PIPS_META[@]}"} )
# The read engine's spec and its mean rate, latency and errors over the runs.
if [ -n "${PIPS_BG:-}" ]; then
    bgmean() { for ((j = 0; j < num_runs; j++)); do rpt_val "$setup_dir/reports/$exp-RUN-$j/bg.rpt" "$1"; done | mean_sd | cut -d' ' -f1; }
    per_drive+=( --meta "bg_spec=$PIPS_BG" --meta "bg_label=${PIPS_BG_LABEL:-}" --meta "bg_rate_mrd_s=$(bgmean bg_issue_rate_mrd_s)"
                 --meta "bg_lat_ns=$(bgmean bg_lat_mean_ns)" --meta "bg_lat_max_ns=$(bgmean bg_lat_max_ns)"
                 --meta "bg_errors=$(for ((j = 0; j < num_runs; j++)); do f=$setup_dir/reports/$exp-RUN-$j/bg.rpt
                     echo $(( $(rpt_val "$f" bg_cpl_ur) + $(rpt_val "$f" bg_cpl_ca) + $(rpt_val "$f" bg_timeouts) + $(rpt_val "$f" bg_data_mismatch) + $(rpt_val "$f" bg_cpl_malformed) ))
                     done | awk '{ s += $1 } END { print s + 0 }')" )
else
    per_drive+=( --meta bg_spec=off --meta bg_label=off )
fi
python3 "$HERE/dualssd-results.py" dump \
    --reports "$setup_dir/reports" --exp "$exp" --runs "$num_runs" \
    --ssds "$(IFS=,; echo "${ACTIVE[*]}")" --out "$results_file" \
    --meta mode="$( [ "$ssds" -eq 2 ] && echo both || echo "ssd${ssd_index}only" )" \
    --meta iommu="$iommu_mode" --meta iommu_units="$iommu_units" \
    --meta instances_per_ssd="$inst" "${per_drive[@]}" --meta bs="$bs" --meta iodepth="$iodepth" \
    --meta rw="$rw" --meta ioengine="$( [ "$gen" = alias ] && echo vfio-alias || echo "$ioengine")" \
    --meta gen="$gen" \
    $( [ "$gen" = alias ] && printf -- '--meta %s ' alias_ws="$a_ws" alias_stride="$a_stride" alias_first="$a_first" \
        alias_order="$a_order" alias_backing="$a_backing" alias_lba="$a_lba" alias_list="${a_list:-none}" \
        alias_cursor="$a_cursor" alias_ws1="${a_ws1:-$a_ws}" alias_stride1="${a_stride1:-$a_stride}" \
        alias_first1="${a_first1:-$a_first}" alias_order1="${a_order1:-$a_order}" alias_list1="${a_list1:-${a_list:-none}}") \
    --meta devices="$(for i in "${ACTIVE[@]}"; do printf '%s ' "${DEVS[$i]}"; done | xargs | tr ' ' ',')" \
    --meta serials="$(for i in "${ACTIVE[@]}"; do printf '%s ' "${SSD_SERIALS[$i]}"; done | xargs | tr ' ' ',')" \
    --meta dur_s="$dur" --meta warm_s="$warm" --meta cpu_util_cores="$active_cores" \
    --meta uplink_gbps="$uplink_gbps" --meta cpu_model="$CPU_MODEL" \
    --meta pcm_row="$SSD_PCIE_PATTERN" --meta membw="$membw" \
    || echo "WARNING: could not write $results_file; the .rpt files are intact." >&2
