#!/bin/bash
# Dual-SSD IOMMU contention on bigserver as a function of fio INSTANCES per
# drive, for the IOMMU mode the host is currently booted in. The SSD
# counterpart of dualnic_flow_sweep.sh.
#
#   ./dualssd_sweep.sh                          # 1,2,4,8 instances/SSD, 4k, 3 runs, both baselines + co-run
#   ./dualssd_sweep.sh -o skx-strict            # same, results named ~/skx-strict.*
#   ./dualssd_sweep.sh "1 2 4 8" "4k 1m" 3      # add 1 MiB reads
#   ./dualssd_sweep.sh "4 8" 4k 3 both          # co-run only
#
# Arguments: instances per SSD, block sizes, repeats, modes (default
# "ssd0only ssd1only both"). -o NAME anywhere names the result files. Extra
# runner options go in DUALSSD_ARGS, e.g. DUALSSD_ARGS="--iodepth 64".
#
# The baselines are on by default, unlike the NIC sweep: the two drives are
# different models (9100 PRO, 990 EVO Plus), so the co-run can only be judged
# against each drive's own single-drive numbers.
#
# 4k is the default block size because each 4 KB read is one IOMMU map, one
# unmap and, in strict mode, one IOTLB invalidation: ~256x as many of each per
# byte as 1 MiB reads, which map 256 pages per I/O.
#
# Before the sweep, one single run of SSD0 alone at the lowest instance count
# checks the datapath; the sweep stops there if it moves no I/O.
#
# Run it once per IOMMU setting: boot with the IOMMU on, run; reboot with it
# off, run again. The mode is read from sysfs (utils/iommu-mode.sh) and put in
# every experiment name, so the two sweeps never overwrite each other's reports.
#
# Results, in $HOME (override with RESULTS_DIR=...):
#   <name>.jsonl   one JSON line per configuration
#   <name>.txt     the summary table printed at the end
# Without -o, <name> is dualssd-sweep-<iommu>-<N> with N the first unused
# number. With -o, an existing <name>.jsonl is appended to, which resumes a
# sweep. Compare on and off side by side afterwards with:
#   python3 scripts/dualssd-results.py summary ~/dualssd-sweep-*.jsonl
set -u
cd "$(dirname "$0")/.."
. ../utils/setup-server.sh
. ../utils/ssd-lib.sh

NAME=""
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out) NAME="$2"; shift 2 ;;
        *)        POS+=( "$1" ); shift ;;
    esac
done
INSTANCES="${POS[0]:-1 2 4 8}"
BSIZES="${POS[1]:-4k}"
RUNS="${POS[2]:-3}"
MODES="${POS[3]:-ssd0only ssd1only both}"
EXTRA=( ${DUALSSD_ARGS:-} )

declare -p SSD_SERIALS >/dev/null 2>&1 || {
    echo "SSD_SERIALS is not set in utils/setup-server.sh; see setup-server.sh.bigserver.example" >&2
    exit 1; }
IOMMU=$(for s in "${SSD_SERIALS[@]}"; do
            ssd_resolve "$s" && bash ../utils/iommu-mode.sh "$SSD_BDF"
        done | sort -u | paste -sd+)
[ -n "$IOMMU" ] || exit 1

DIR="${RESULTS_DIR:-$HOME}"
if [ -z "$NAME" ]; then
    n=1
    while [ -e "$DIR/dualssd-sweep-$IOMMU-$n.jsonl" ] \
          || [ -e "$DIR/dualssd-sweep-$IOMMU-$n.txt" ]; do n=$((n + 1)); done
    NAME="dualssd-sweep-$IOMMU-$n"
fi
JSONL="$DIR/$NAME.jsonl"
TXT="$DIR/$NAME.txt"

echo "######## dual-SSD sweep: ${INSTANCES} instances/SSD, bs ${BSIZES}, ${RUNS} run(s)"
echo "######## modes: ${MODES}"
[ ${#EXTRA[@]} -gt 0 ] && echo "######## runner args: ${EXTRA[*]}"
echo "######## IOMMU: ${IOMMU}   kernel $(uname -r)"
echo "######## cmdline: $(cat /proc/cmdline)"
echo "######## results: $JSONL"
echo "########          $TXT"

# Written on success AND on abort, so a failure an hour in still leaves the
# finished configurations summarised.
summarize() {
    [ -s "$JSONL" ] || { echo "######## no results recorded"; return; }
    {
        echo "dual-SSD sweep  $(date '+%F %T')  host $(hostname)"
        echo "IOMMU $IOMMU  kernel $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "instances/SSD: $INSTANCES   bs: $BSIZES   runs: $RUNS   modes: $MODES"
        [ ${#EXTRA[@]} -gt 0 ] && echo "runner args: ${EXTRA[*]}"
        echo
        python3 ../scripts/dualssd-results.py summary "$JSONL"
    } | tee "$TXT"
}

run() {   # <exp> <runner args...>
    bash ./run-dualssd-experiment.sh -E "$@" ${EXTRA[@]+"${EXTRA[@]}"} --results "$JSONL"
}

# Datapath check: one short SSD0-alone run at the lowest instance count. The
# runner already aborts when fio fails to start; this also catches a drive
# that is "running" but moving nothing.
low=$(printf '%s\n' $INSTANCES | sort -n | head -1)
b0="${BSIZES%% *}"
e="dssd-$IOMMU-$b0-j$low-datapath"
echo
echo "######## datapath check: SSD0 alone, $low instance(s), bs $b0, 1 run"
if ! run "$e" --ssds 1 --ssd-index 0 -J "$low" --bs "$b0" --runs 1; then
    echo "######## ABORTING: datapath check failed" >&2
    exit 1
fi
got=$(awk '/^IOPS:/{print $2}' "../utils/reports/$e-RUN-0-ssd0/fio.rpt" 2>/dev/null)
case "${got:-}" in ''|*[!0-9.]*) got=0 ;; esac
if ! awk -v t="$got" 'BEGIN{exit !(t > 1000)}'; then
    echo "######## ABORTING: datapath check moved $got IOPS on SSD0." >&2
    echo "######## See utils/reports/$e-RUN-0-ssd0/ and utils/logs/$e-RUN-0/" >&2
    exit 1
fi
echo "######## datapath OK: $got IOPS on SSD0"

for b in $BSIZES; do
    for j in $INSTANCES; do
        for mode in $MODES; do
            case "$mode" in
                ssd0only) args="--ssds 1 --ssd-index 0" ;;
                ssd1only) args="--ssds 1 --ssd-index 1" ;;
                both)     args="--ssds 2" ;;
                *) echo "unknown mode '$mode' (ssd0only|ssd1only|both)" >&2; exit 2 ;;
            esac
            echo
            echo "######## IOMMU $IOMMU  bs $b  $j instance(s)/SSD  $mode"
            if ! run "dssd-$IOMMU-$b-j$j-$mode" $args -J "$j" --bs "$b" --runs "$RUNS"; then
                echo "######## ABORTING at bs $b / j$j / $mode" >&2
                summarize
                exit 1
            fi
        done
    done
done

echo
echo "=============================================================="
echo "  DUAL-SSD SWEEP SUMMARY"
echo "=============================================================="
summarize
