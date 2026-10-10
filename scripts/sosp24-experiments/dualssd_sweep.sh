#!/bin/bash
# Dual-SSD IOMMU contention on bigserver as a function of fio INSTANCES per
# drive, for the IOMMU mode the host is currently booted in. The SSD
# counterpart of dualnic_flow_sweep.sh.
#
#   ./dualssd_sweep.sh                          # co-run, 1,2,4,8,16,32 instances/SSD, 4k, 3 runs
#   ./dualssd_sweep.sh --single                 # also each drive alone (baselines)
#   ./dualssd_sweep.sh --single-ssd 0           # also drive 0 alone, not drive 1
#   ./dualssd_sweep.sh --single --asy           # also uneven co-runs, 2/4/8 vs 16/32
#   ./dualssd_sweep.sh -o skx-strict            # name the sweep (must be new)
#   ./dualssd_sweep.sh "1 2 4 8" "4k 1m" 3      # up to 8 instances, 4k and 1 MiB reads
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
# Uneven co-runs: --asy adds, at every block size, co-runs where one drive
# runs LOW instances and the other HIGH, for each LOW in --asy-low (default
# "2 4 8") and HIGH in --asy-high (default "16 32"), both ways round (drive 0
# LOW, then drive 1 LOW), so a difference between the drives or their slots
# shows up as such instead of passing for an effect. --no-swap runs only
# drive 0 LOW. The runner splits the 18 cores in proportion to the counts.
# The summary adds a table of these; KEPT% needs each drive alone at its own
# count (--single).
#
# Progress: each configuration prints "[k/N]" with the time so far and an
# estimate of the time left.
#
# 4k is the default block size because each 4 KB read is one IOMMU map, one
# unmap and, in strict mode, one IOTLB invalidation: ~256x as many of each per
# byte as 1 MiB reads, which map 256 pages per I/O.
#
# Instances default to 1-32 per drive. SSD_CORES has 9 cores per drive, so
# from 10 instances up cores run several each (3-4 at 32).
#
# Once started, the sweep runs every point; only you stop it (Ctrl-C, or the
# pkill in HANDOFF §7). A point that fails for any reason -- including the
# datapath check, one short run of both drives at the lowest instance count
# -- is logged with the runner's first error in utils/logs/<name>/failed.txt
# and at the top of the summary, and the sweep moves on.
#
# Run it once per IOMMU setting: boot with the IOMMU on, run; reboot with it
# off, run again. The mode is read from sysfs and put in the sweep's name.
#
# Nothing is ever overwritten. Each sweep gets a new name, <name>: the -o NAME
# given (refused if ~/<name>.jsonl or .txt exists), or <prefix>-<iommu>-<N>
# with prefix dualssd-sweep ($SWEEP_PREFIX overrides) and N the first number
# with no ~/<name>.jsonl or .txt, so clearing those out of ~ restarts N at 1.
# Logs or reports still in utils/ under that name are moved aside to
# <name>.old-<date>-<time>, not deleted. It writes:
#   ~/<name>.jsonl                one JSON line per configuration
#   ~/<name>.txt                  the summary table printed at the end (and,
#                                 for several block sizes AND instance counts,
#                                 block size x instances grids)
#   utils/logs/<name>/sweep.log   everything printed, start to finish
#   utils/logs/<name>/failed.txt  each failed point, its exit status and error
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
ASY=0
ASY_LOW="2 4 8"
ASY_HIGH="16 32"
SWAP=1
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)  NAME="$2"; shift 2 ;;
        --single)  SINGLE=1; shift ;;
        --single-ssd)
            case "$2" in 0|1) SINGLE_SSD="$2" ;;
                *) echo "--single-ssd takes 0 or 1, not '$2'" >&2; exit 2 ;; esac
            SINGLE=1; shift 2 ;;
        --asy)       ASY=1; shift ;;
        --asy-low)   ASY=1; ASY_LOW="$2"; shift 2 ;;
        --asy-high)  ASY=1; ASY_HIGH="$2"; shift 2 ;;
        --no-swap)   SWAP=0; shift ;;
        -h|--help) sed -n '2,67p' "$SELF"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)         POS+=( "$1" ); shift ;;
    esac
done
for v in $ASY_LOW $ASY_HIGH; do
    case "$v" in ''|*[!0-9]*|0) echo "--asy-low/--asy-high take positive integers, not '$v'" >&2; exit 2 ;; esac
done
[ "$IN_TMUX" = 1 ] && relaunch_in_tmux "$SELF" ${PASS[@]+"${PASS[@]}"}

cd "$(dirname "$SELF")/.."
. ../utils/setup-server.sh
INSTANCES="${POS[0]:-1 2 4 8 16 32}"
BSIZES="${POS[1]:-4k}"
RUNS="${POS[2]:-3}"
if [ -n "$SINGLE_SSD" ]; then MODES="ssd${SINGLE_SSD}only both"
elif [ "$SINGLE" = 1 ]; then MODES="ssd0only ssd1only both"
else MODES="both"; fi
EXTRA=( ${DUALSSD_ARGS:-} )

# Uneven co-runs, "<drive 0 instances> <drive 1 instances>" each.
ASY_PAIRS=()
if [ "$ASY" = 1 ]; then
    for lo in $ASY_LOW; do
        for hi in $ASY_HIGH; do
            [ "$lo" -lt "$hi" ] || continue
            ASY_PAIRS+=( "$lo $hi" )
            [ "$SWAP" = 1 ] && ASY_PAIRS+=( "$hi $lo" )
        done
    done
fi

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
used() {   # <name> -> true if that sweep's results are in $DIR
    [ -e "$DIR/$1.jsonl" ] || [ -e "$DIR/$1.txt" ]
}
if [ -z "$NAME" ]; then
    n=1
    while used "$PREFIX-$IOMMU-$n"; do n=$((n + 1)); done
    NAME="$PREFIX-$IOMMU-$n"
elif used "$NAME"; then
    echo "ERROR: a sweep named '$NAME' already has results in $DIR; refusing to overwrite them." >&2
    echo "  Pick another -o NAME, or leave -o out for a fresh numbered name." >&2
    exit 1
fi
JSONL="$DIR/$NAME.jsonl"
TXT="$DIR/$NAME.txt"
LOGDIR="$UTILS/logs/$NAME"
# Logs and reports of an earlier sweep of this name, whose results have since
# been cleared from $DIR, are moved aside: the runner refuses to reuse them.
MOVED=()
stamp=$(date +%Y%m%d-%H%M%S)
for d in "$LOGDIR" "$UTILS/reports/$NAME"; do
    [ -e "$d" ] || continue
    mv "$d" "$d.old-$stamp" || { echo "ERROR: could not move aside $d" >&2; exit 1; }
    MOVED+=( "$d.old-$stamp" )
done
mkdir -p "$LOGDIR"
# Everything below is also saved to the sweep's log. The tee ignores Ctrl-C,
# so a sweep stopped by hand can still print and save its summary.
exec > >(trap '' INT TERM; exec tee -a "$LOGDIR/sweep.log") 2>&1

ASY_DESC="LOW $ASY_LOW / HIGH $ASY_HIGH, $( [ "$SWAP" = 1 ] && echo "both ways round" || echo "drive 0 LOW only" )"
echo "######## dual-SSD sweep $NAME: ${INSTANCES} instances/SSD, bs ${BSIZES}, ${RUNS} run(s)"
echo "######## modes: ${MODES}$( [ "$SINGLE" = 0 ] && echo "   (--single adds the single-drive runs)" )"
[ "$ASY" = 1 ] && echo "######## uneven co-runs: $ASY_DESC (${#ASY_PAIRS[@]} per block size)"
[ ${#EXTRA[@]} -gt 0 ] && echo "######## runner args: ${EXTRA[*]}"
echo "######## IOMMU: ${IOMMU}   kernel $(uname -r)"
echo "######## cmdline: $(cat /proc/cmdline)"
echo "######## results: $JSONL"
echo "########          $TXT"
echo "######## logs:    $LOGDIR/   (sweep.log = this output)"
echo "######## reports: $UTILS/reports/$NAME/"
for d in ${MOVED[@]+"${MOVED[@]}"}; do echo "######## old output of this name moved to $d/"; done

FAILED=()   # "<config>  exit <status>: <first error>", also in failed.txt

# Written at the end, or when stopped by hand, so the finished configurations
# are always summarised.
summarize() {
    {
        echo "dual-SSD sweep $NAME  $(date '+%F %T')  host $(hostname)"
        echo "IOMMU $IOMMU  kernel $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "instances/SSD: $INSTANCES   bs: $BSIZES   runs: $RUNS   modes: $MODES"
        [ "$ASY" = 1 ] && echo "uneven co-runs: $ASY_DESC"
        [ ${#EXTRA[@]} -gt 0 ] && echo "runner args: ${EXTRA[*]}"
        if [ ${#FAILED[@]} -gt 0 ]; then
            echo
            echo "FAILED, ${#FAILED[@]} point(s), not in the tables below" \
                 "(full output: utils/logs/$NAME/<config>.console.log):"
            printf '  %s\n' "${FAILED[@]}"
        fi
        echo
        if [ -s "$JSONL" ]; then
            python3 ../scripts/dualssd-results.py summary "$JSONL"
            # A cross sweep also reads as block size x instances tables.
            if [ "$(echo $BSIZES | wc -w)" -gt 1 ] && [ "$(echo $INSTANCES | wc -w)" -gt 1 ]; then
                echo
                python3 ../scripts/dualssd-results.py grid "$JSONL"
            fi
        else
            echo "no results recorded"
        fi
    } | tee "$TXT"
}

run() {   # <config name> <results file> <runner args...>
    local cfg="$1" out="$2"; shift 2
    bash ./run-dualssd-experiment.sh -E "$NAME/$cfg" "$@" \
        ${EXTRA[@]+"${EXTRA[@]}"} --results "$out"
}

# Stopping by hand is the one thing that ends the sweep early. Bash runs the
# trap once the current run has returned; the runner itself stops on the same
# Ctrl-C (exit 130) or pkill (143).
STOP=0
trap 'STOP=1' INT TERM
stop_if_asked() {   # <runner exit status>
    if [ "$STOP" = 1 ] || [ "$1" = 130 ] || [ "$1" = 143 ]; then
        echo "######## STOPPED by hand" >&2
        summarize
        exit 130
    fi
}

fail() {   # <config> <what went wrong>: log it, then the sweep goes on
    FAILED+=( "$1  $2" )
    printf '%s\t%s\n' "$1" "$2" >> "$LOGDIR/failed.txt"
    echo "######## FAILED $1: $2. Going on." >&2
}

first_error() {   # <config> -> the runner's first error line for it
    local why
    why=$(grep -m1 -E '^(ERROR|FATAL)|^\[1\] ' "$LOGDIR/$1.console.log" 2>/dev/null | sed 's/^ *//')
    echo "${why:-see sweep.log}"
}

# Datapath check: one short run of both drives at the lowest instance count,
# kept out of the summary. The runner already fails when fio fails to start;
# this also catches a drive that is "running" but moving nothing.
low=$(printf '%s\n' $INSTANCES | sort -n | head -1)
b0="${BSIZES%% *}"
e="datapath-$b0-j$low"
echo
echo "######## datapath check: both drives, $low instance(s) each, bs $b0, 1 run"
run "$e" "$LOGDIR/datapath.jsonl" --ssds 2 -J "$low" --bs "$b0" --runs 1
rc=$?
stop_if_asked "$rc"
if [ "$rc" != 0 ]; then
    fail "$e" "exit $rc: $(first_error "$e")"
else
    for i in 0 1; do
        got=$(awk '/^IOPS:/{print $2}' "$UTILS/reports/$NAME/$e-RUN-0-ssd$i/fio.rpt" 2>/dev/null)
        case "${got:-}" in ''|*[!0-9.]*) got=0 ;; esac
        if awk -v t="$got" 'BEGIN{exit !(t > 1000)}'; then
            echo "######## datapath OK: $got IOPS on SSD$i"
        else
            fail "$e" "SSD$i moved only $got IOPS; see $UTILS/reports/$NAME/$e-RUN-0-ssd$i/"
        fi
    done
fi

total=$(( $(echo $BSIZES | wc -w) * ( $(echo $INSTANCES | wc -w) * $(echo $MODES | wc -w) + ${#ASY_PAIRS[@]} ) ))
k=0; t0=$SECONDS
point() {   # <config> <label> <runner args...>: one configuration, with progress
    local cfg="$1" label="$2" rc; shift 2
    k=$((k + 1)); took=$((SECONDS - t0)); left=""
    [ "$k" -gt 1 ] && left=", ~$(( took / (k - 1) * (total - k + 1) / 60 )) min left"
    echo
    echo "######## [$k/$total] IOMMU $IOMMU  $label  ($(date +%H:%M), $((took / 60)) min in$left)"
    run "$cfg" "$JSONL" "$@" --runs "$RUNS"
    rc=$?
    stop_if_asked "$rc"
    [ "$rc" = 0 ] || fail "$cfg" "exit $rc: $(first_error "$cfg")"
}

for b in $BSIZES; do
    for j in $INSTANCES; do
        for mode in $MODES; do
            case "$mode" in
                ssd0only) args="--ssds 1 --ssd-index 0" ;;
                ssd1only) args="--ssds 1 --ssd-index 1" ;;
                both)     args="--ssds 2" ;;
            esac
            point "$b-j$j-$mode" "bs $b  $j instance(s)/SSD  $mode" $args -J "$j" --bs "$b"
        done
    done
    for p in ${ASY_PAIRS[@]+"${ASY_PAIRS[@]}"}; do
        read -r n0 n1 <<< "$p"
        point "$b-j$n0+$n1-both" "bs $b  uneven: $n0 on SSD0, $n1 on SSD1" --ssds 2 -J "$n0,$n1" --bs "$b"
    done
done

echo
echo "=============================================================="
echo "  DUAL-SSD SWEEP SUMMARY$( [ ${#FAILED[@]} -gt 0 ] && echo ", ${#FAILED[@]} point(s) FAILED" )"
echo "=============================================================="
summarize
echo
echo "  everything for this sweep:"
echo "    $JSONL"
echo "    $TXT"
echo "    $LOGDIR/sweep.log"
[ ${#FAILED[@]} -gt 0 ] && echo "    $LOGDIR/failed.txt"
echo "    $LOGDIR/<config>-RUN-<j>/    raw pcm-iio / pcm-memory / fio / CPU logs"
echo "    $UTILS/reports/$NAME/"
