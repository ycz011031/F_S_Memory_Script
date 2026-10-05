#!/bin/bash
# Drive 1 or 2 NVMe SSDs with concurrent fio readers on bigserver (Skylake-SP),
# and report per-drive IOPS alongside the shared IOMMU counters. The SSD
# counterpart of run-dualnic-experiment.sh; fio runs locally, so no client.
#
#   ./run-dualssd-experiment.sh -E base-ssd0 --ssds 1 -J 4
#   ./run-dualssd-experiment.sh -E base-ssd1 --ssds 1 --ssd-index 1 -J 4
#   ./run-dualssd-experiment.sh -E dual      --ssds 2 -J 4 --runs 3
#   ./run-dualssd-experiment.sh -E dual2     --ssds 2 -J 4 --tmux   # in tmux instead
#
# Runs in this terminal unless --tmux is given; --tmux starts it in a new tmux
# session (survives a dropped ssh; asks for the sudo password there).
#
# -J is fio instances PER DRIVE, the analogue of iperf3 flows per NIC. Each is
# its own fio process with one job, pinned round-robin over the drive's cores
# (SSD_CORES), so each submits on its own NVMe queue. I/O is O_DIRECT: the
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
#                               cpu_util.log, fio-ssd<i>-<k>.json/.err
#   reports/<name>-RUN-<j>/     pcie.rpt, membw.rpt, cpu_util.rpt
#   reports/<name>-RUN-<j>-ssd<i>/fio.rpt
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
        -h|--help)
            sed -n '2,32p' "$SELF"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

case "$rw" in
    read|randread) ;;
    *) echo "ERROR: --rw $rw refused. Only read/randread: these drives hold data." >&2; exit 2 ;;
esac
case "$ssds" in 1|2) ;; *) echo "ERROR: --ssds must be 1 or 2" >&2; exit 2 ;; esac
case "$ssd_index" in 0|1) ;; *) echo "ERROR: --ssd-index must be 0 or 1" >&2; exit 2 ;; esac
case "$jobs" in ''|*[!0-9]*|0) echo "ERROR: -J must be a positive integer" >&2; exit 2 ;; esac
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

DEVS=(); BDFS=()
for i in "${ACTIVE[@]}"; do
    ssd_resolve "${SSD_SERIALS[$i]}" || exit 1
    DEVS[$i]=$SSD_DEV; BDFS[$i]=$SSD_BDF
done

# CPU utilisation is recorded over every active drive's cores.
active_cores=""
for i in "${ACTIVE[@]}"; do active_cores="${active_cores:+$active_cores,}${SSD_CORES[$i]}"; done
ncores=$(printf '%s' "$active_cores" | tr ',' '\n' | grep -c .)

# What the kernel actually did, from sysfs, per drive. Both drives sit behind
# dmar7, so a mismatch means something unexpected happened at boot.
iommu_mode=$(for i in "${ACTIVE[@]}"; do
                 bash "$HERE/../utils/iommu-mode.sh" "${BDFS[$i]}"
             done | sort -u | paste -sd+)
iommu_units=$(for i in "${ACTIVE[@]}"; do iommu_unit "${BDFS[$i]}"; done | sort -u | paste -sd+)

# fio processes are found by job name. The [_] keeps the pattern from matching
# the pkill/pgrep command line itself, and the anchored fio from matching the
# sudo wrapper.
FIO_MATCH='^(/[^ ]*/)?fio .*--name=dualssd[_]'
fio_count() { local n; n=$(pgrep -c -f "$FIO_MATCH" 2>/dev/null); echo "${n:-0}"; }
stop_fio() {    # SIGINT makes fio stop and still write its JSON
    sudo -n pkill -INT -f "$FIO_MATCH" >/dev/null 2>&1 || true
    for _ in $(seq 30); do [ "$(fio_count)" -eq 0 ] && return; sleep 1; done
    sudo -n pkill -KILL -f "$FIO_MATCH" >/dev/null 2>&1 || true
}

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
    for t in fio python3 sar lspci; do command -v "$t" >/dev/null || miss="$miss $t"; done
    [ -n "$miss" ] && PROBLEMS+=("missing tools:$miss")

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

aborted=0
cleanup() {
    stop_fio
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
for i in "${ACTIVE[@]}"; do echo "               $i: ${DEVS[$i]}  cores ${SSD_CORES[$i]}"; done
echo "  per SSD    : $jobs fio instances x iodepth $iodepth, $rw bs=$bs, $ioengine, O_DIRECT, read-only"
echo "  windows    : ramp ${warm}s, CPU ${dur}s, PCIe ${dur}s$( [ "$membw" = 1 ] && echo ", memory $((30 + dur))s" )"
echo "  IOMMU      : $iommu_mode on $iommu_units   (kernel $(uname -r))"
echo "=============================================================="

preflight
uplink_gbps=$(shared_link_gbps $(for i in "${ACTIVE[@]}"; do echo "${BDFS[$i]}"; done))
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

    # ---------------------------------------------------------------- load
    want=0
    for i in "${ACTIVE[@]}"; do
        IFS=',' read -r -a cores <<< "${SSD_CORES[$i]}"
        for ((k = 0; k < jobs; k++)); do
            core=${cores[$((k % ${#cores[@]}))]}
            # --thread keeps one process per instance, so fio_count counts
            # instances. 9>&- so fio does not hold the experiment lock.
            sudo fio --name="dualssd_${i}_${k}" --filename="${DEVS[$i]}" --readonly \
                --rw="$rw" --bs="$bs" --iodepth="$iodepth" --numjobs=1 --thread \
                --direct=1 --ioengine="$ioengine" --cpus_allowed="$core" \
                --time_based --ramp_time="$warm" --runtime="$fio_runtime" \
                --randrepeat=0 --norandommap --output-format=json \
                --output="$L/fio-ssd$i-$k.json" > "$L/fio-ssd$i-$k.err" 2>&1 9>&- &
            want=$((want + 1))
        done
    done
    [ "$jobs" -gt "${#cores[@]}" ] && [ "$j" -eq 0 ] && \
        echo "   NOTE: $jobs instances on ${#cores[@]} cores per drive; some cores run more than one"

    echo "warming up ${warm}s..."; sleep "$warm"; sleep 1

    # An instance that died on startup leaves its drive under-loaded, and the
    # run would otherwise measure that without a word.
    got=$(fio_count)
    echo "   fio instances running: $got/$want"
    if [ "$got" -lt "$want" ]; then
        echo "ERROR: only $got of $want fio instances are running. First errors:" >&2
        cat "$L"/fio-ssd*.err 2>/dev/null | grep -v '^$' | head -10 | sed 's/^/    /' >&2
        exit 1
    fi

    # -------------------------------------------------------------- measure
    echo "recording host metrics: CPU ${dur}s, then pcm-iio ${dur}s..."
    ( cd "$setup_dir" && sudo bash record-host-metrics.sh -f 0 --iio 0 --type 0 \
        --cpu-util 1 --retx 0 --bw 0 --pcie 1 --membw "$membw" --dur "$dur" \
        --cores "$active_cores" --pattern "$SSD_PCIE_PATTERN" -o "$RUN" ) 9>&-

    got=$(fio_count)
    if [ "$got" -lt "$want" ]; then
        echo "WARNING: only $got of $want fio instances were still running at the end" >&2
        echo "         of the measurement; the drives were under-loaded for part of it." >&2
    fi
    stop_fio
    wait 2>/dev/null

    for i in "${ACTIVE[@]}"; do
        python3 "$HERE/dualssd-results.py" fio-sum --out "$setup_dir/reports/$RUN-ssd$i/fio.rpt" \
            "$L"/fio-ssd$i-*.json \
            || echo "WARNING: no usable fio output for SSD $i in $L" >&2
    done
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
if [ -f "$P" ]; then
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
python3 "$HERE/dualssd-results.py" dump \
    --reports "$setup_dir/reports" --exp "$exp" --runs "$num_runs" \
    --ssds "$(IFS=,; echo "${ACTIVE[*]}")" --out "$results_file" \
    --meta mode="$( [ "$ssds" -eq 2 ] && echo both || echo "ssd${ssd_index}only" )" \
    --meta iommu="$iommu_mode" --meta iommu_units="$iommu_units" \
    --meta instances_per_ssd="$jobs" --meta bs="$bs" --meta iodepth="$iodepth" \
    --meta rw="$rw" --meta ioengine="$ioengine" \
    --meta devices="$(for i in "${ACTIVE[@]}"; do printf '%s ' "${DEVS[$i]}"; done | xargs | tr ' ' ',')" \
    --meta serials="$(for i in "${ACTIVE[@]}"; do printf '%s ' "${SSD_SERIALS[$i]}"; done | xargs | tr ' ' ',')" \
    --meta dur_s="$dur" --meta warm_s="$warm" --meta cpu_util_cores="$active_cores" \
    --meta uplink_gbps="$uplink_gbps" --meta cpu_model="$CPU_MODEL" \
    || echo "WARNING: could not write $results_file; the .rpt files are intact." >&2
