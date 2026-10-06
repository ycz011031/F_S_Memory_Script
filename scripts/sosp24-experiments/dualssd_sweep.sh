#!/bin/bash
# Dual-SSD IOMMU contention on bigserver as a function of fio INSTANCES per
# drive, for the IOMMU mode the host is currently booted in. The SSD
# counterpart of dualnic_flow_sweep.sh.
#
#   ./dualssd_sweep.sh                          # co-run, 1,2,4,8 instances/SSD, 4k, 3 runs
#   ./dualssd_sweep.sh --single                 # also each drive alone (baselines)
#   ./dualssd_sweep.sh --single-ssd 0           # also drive 0 alone, not drive 1
#   ./dualssd_sweep.sh -o skx-strict            # name the sweep (must be new)
#   ./dualssd_sweep.sh "1 2 4 8" "4k 1m" 3      # add 1 MiB reads
#   ./dualssd_sweep.sh --single --tmux          # in a tmux session instead
#
# Arguments: instances per SSD, block sizes, repeats. Options: --single adds
# the single-drive runs (ssd0only, ssd1only) at every point; without them the
# summary's CONTENTION column stays empty. --single-ssd N runs only drive N
# alone (half the single-drive time; fills KEPT% for that drive, not
# CONTENTION). -o NAME names the sweep. --tmux
# runs it in a new tmux session (survives a dropped ssh; asks for the sudo
# password there) instead of this terminal, which is the default. Extra
# runner options go in DUALSSD_ARGS, e.g. DUALSSD_ARGS="--iodepth 64".
#
# Progress: each configuration prints "[k/N]" with the time so far and an
# estimate of the time left.
#
# 4k is the default block size because each 4 KB read is one IOMMU map, one
# unmap and, in strict mode, one IOTLB invalidation: ~256x as many of each per
# byte as 1 MiB reads, which map 256 pages per I/O.
#
# Before the sweep, one short run of both drives at the lowest instance count
# checks the datapath; the sweep stops there if either drive moves no I/O.
#
# Run it once per IOMMU setting: boot with the IOMMU on, run; reboot with it
# off, run again. The mode is read from sysfs and put in the sweep's name.
#
# Nothing is ever overwritten. Each sweep gets a new name, <name>: the -o NAME
# given (refused if already used), or <prefix>-<iommu>-<N> with prefix
# dualssd-sweep ($SWEEP_PREFIX overrides) and N the first number not used by
# any earlier sweep. It writes:
#   ~/<name>.jsonl                one JSON line per configuration
#   ~/<name>.txt                  the summary table printed at the end (and,
#                                 for several block sizes AND instance counts,
#                                 block size x instances grids)
#   utils/logs/<name>/sweep.log   everything printed, start to finish
#   utils/logs/<name>/            every run's raw logs: pcm-iio CSV and
#                                 output, pcm-memory, fio JSON, CPU
#   utils/reports/<name>/         every run's parsed reports
# Compare on and off side by side afterwards with:
#   python3 scripts/dualssd-results.py summary ~/dualssd-sweep-*.jsonl
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
. "$(dirname "$SELF")/../../utils/ssd-lib.sh"

# --tmux: start over inside a tmux session, with the same arguments minus it.
PASS=(); IN_TMUX=0
for a in "$@"; do if [ "$a" = --tmux ]; then IN_TMUX=1; else PASS+=( "$a" ); fi; done
set -- ${PASS[@]+"${PASS[@]}"}

NAME=""
SINGLE=0
SINGLE_SSD=""
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)  NAME="$2"; shift 2 ;;
        --single)  SINGLE=1; shift ;;
        --single-ssd)
            case "$2" in 0|1) SINGLE_SSD="$2" ;;
                *) echo "--single-ssd takes 0 or 1, not '$2'" >&2; exit 2 ;; esac
            SINGLE=1; shift 2 ;;
        -h|--help) sed -n '2,48p' "$SELF"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)         POS+=( "$1" ); shift ;;
    esac
done
[ "$IN_TMUX" = 1 ] && relaunch_in_tmux "$SELF" ${PASS[@]+"${PASS[@]}"}

cd "$(dirname "$SELF")/.."
. ../utils/setup-server.sh
INSTANCES="${POS[0]:-1 2 4 8}"
BSIZES="${POS[1]:-4k}"
RUNS="${POS[2]:-3}"
if [ -n "$SINGLE_SSD" ]; then MODES="ssd${SINGLE_SSD}only both"
elif [ "$SINGLE" = 1 ]; then MODES="ssd0only ssd1only both"
else MODES="both"; fi
EXTRA=( ${DUALSSD_ARGS:-} )

declare -p SSD_SERIALS >/dev/null 2>&1 || {
    echo "SSD_SERIALS is not set in utils/setup-server.sh; see setup-server.sh.bigserver.example" >&2
    exit 1; }
IOMMU=$(for s in "${SSD_SERIALS[@]}"; do
            ssd_resolve "$s" && bash ../utils/iommu-mode.sh "$SSD_BDF"
        done | sort -u | paste -sd+)
[ -n "$IOMMU" ] || exit 1

DIR="${RESULTS_DIR:-$HOME}"
PREFIX="${SWEEP_PREFIX:-dualssd-sweep}"
UTILS="$(cd ../utils && pwd)"
used() {   # <name> -> true if any output of that name exists
    [ -e "$DIR/$1.jsonl" ] || [ -e "$DIR/$1.txt" ] \
        || [ -e "$UTILS/logs/$1" ] || [ -e "$UTILS/reports/$1" ]
}
if [ -z "$NAME" ]; then
    n=1
    while used "$PREFIX-$IOMMU-$n"; do n=$((n + 1)); done
    NAME="$PREFIX-$IOMMU-$n"
elif used "$NAME"; then
    echo "ERROR: a sweep named '$NAME' already has output; refusing to overwrite it." >&2
    echo "  Pick another -o NAME, or leave -o out for a fresh numbered name." >&2
    exit 1
fi
JSONL="$DIR/$NAME.jsonl"
TXT="$DIR/$NAME.txt"
LOGDIR="$UTILS/logs/$NAME"
mkdir -p "$LOGDIR"
# Everything below is also saved to the sweep's log.
exec > >(tee -a "$LOGDIR/sweep.log") 2>&1

echo "######## dual-SSD sweep $NAME: ${INSTANCES} instances/SSD, bs ${BSIZES}, ${RUNS} run(s)"
echo "######## modes: ${MODES}$( [ "$SINGLE" = 0 ] && echo "   (--single adds the single-drive runs)" )"
[ ${#EXTRA[@]} -gt 0 ] && echo "######## runner args: ${EXTRA[*]}"
echo "######## IOMMU: ${IOMMU}   kernel $(uname -r)"
echo "######## cmdline: $(cat /proc/cmdline)"
echo "######## results: $JSONL"
echo "########          $TXT"
echo "######## logs:    $LOGDIR/   (sweep.log = this output)"
echo "######## reports: $UTILS/reports/$NAME/"

# Written on success AND on abort, so a failure an hour in still leaves the
# finished configurations summarised.
summarize() {
    [ -s "$JSONL" ] || { echo "######## no results recorded"; return; }
    {
        echo "dual-SSD sweep $NAME  $(date '+%F %T')  host $(hostname)"
        echo "IOMMU $IOMMU  kernel $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "instances/SSD: $INSTANCES   bs: $BSIZES   runs: $RUNS   modes: $MODES"
        [ ${#EXTRA[@]} -gt 0 ] && echo "runner args: ${EXTRA[*]}"
        echo
        python3 ../scripts/dualssd-results.py summary "$JSONL"
        # A cross sweep also reads as block size x instances tables.
        if [ "$(echo $BSIZES | wc -w)" -gt 1 ] && [ "$(echo $INSTANCES | wc -w)" -gt 1 ]; then
            echo
            python3 ../scripts/dualssd-results.py grid "$JSONL"
        fi
    } | tee "$TXT"
}

run() {   # <config name> <results file> <runner args...>
    local cfg="$1" out="$2"; shift 2
    bash ./run-dualssd-experiment.sh -E "$NAME/$cfg" "$@" \
        ${EXTRA[@]+"${EXTRA[@]}"} --results "$out"
}

# Datapath check: one short run of both drives at the lowest instance count,
# kept out of the summary. The runner already aborts when fio fails to start;
# this also catches a drive that is "running" but moving nothing.
low=$(printf '%s\n' $INSTANCES | sort -n | head -1)
b0="${BSIZES%% *}"
e="datapath-$b0-j$low"
echo
echo "######## datapath check: both drives, $low instance(s) each, bs $b0, 1 run"
if ! run "$e" "$LOGDIR/datapath.jsonl" --ssds 2 -J "$low" --bs "$b0" --runs 1; then
    echo "######## ABORTING: datapath check failed" >&2
    exit 1
fi
for i in 0 1; do
    got=$(awk '/^IOPS:/{print $2}' "$UTILS/reports/$NAME/$e-RUN-0-ssd$i/fio.rpt" 2>/dev/null)
    case "${got:-}" in ''|*[!0-9.]*) got=0 ;; esac
    if ! awk -v t="$got" 'BEGIN{exit !(t > 1000)}'; then
        echo "######## ABORTING: datapath check moved $got IOPS on SSD$i." >&2
        echo "######## See $UTILS/reports/$NAME/$e-RUN-0-ssd$i/ and $LOGDIR/$e-RUN-0/" >&2
        exit 1
    fi
    echo "######## datapath OK: $got IOPS on SSD$i"
done

total=$(( $(echo $BSIZES | wc -w) * $(echo $INSTANCES | wc -w) * $(echo $MODES | wc -w) ))
k=0; t0=$SECONDS
for b in $BSIZES; do
    for j in $INSTANCES; do
        for mode in $MODES; do
            case "$mode" in
                ssd0only) args="--ssds 1 --ssd-index 0" ;;
                ssd1only) args="--ssds 1 --ssd-index 1" ;;
                both)     args="--ssds 2" ;;
            esac
            # Progress, with time left from the average so far.
            k=$((k + 1)); took=$((SECONDS - t0)); left=""
            [ "$k" -gt 1 ] && left=", ~$(( took / (k - 1) * (total - k + 1) / 60 )) min left"
            echo
            echo "######## [$k/$total] IOMMU $IOMMU  bs $b  $j instance(s)/SSD  $mode" \
                 "  ($(date +%H:%M), $((took / 60)) min in$left)"
            if ! run "$b-j$j-$mode" "$JSONL" $args -J "$j" --bs "$b" --runs "$RUNS"; then
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
echo
echo "  everything for this sweep:"
echo "    $JSONL"
echo "    $TXT"
echo "    $LOGDIR/sweep.log"
echo "    $LOGDIR/<config>-RUN-<j>/    raw pcm-iio / pcm-memory / fio / CPU logs"
echo "    $UTILS/reports/$NAME/"
