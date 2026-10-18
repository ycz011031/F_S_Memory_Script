#!/bin/bash
# Dual-NIC contention as a function of FLOW COUNT, for the IOMMU mode the host
# is currently booted in.
#
#   ./dualnic_flow_sweep.sh                            # co-run, 5,10,15,30 flows/NIC, uncapped, 3 runs
#   ./dualnic_flow_sweep.sh -o iommu-on                # same, results named ~/iommu-on.*
#   ./dualnic_flow_sweep.sh "5 10 15 30" "30 uncapped" 3
#   ./dualnic_flow_sweep.sh "5 10 15 30" uncapped 3 "nic0only nic1only both"   # add 1-NIC baselines
#
# Arguments: flows per NIC, rates in Gbps per NIC (default "uncapped", i.e.
# line rate), repeats, modes (default "both", the co-run).
# -o NAME anywhere names the result files. -p PREFIX names the experiments
# (run folders in utils/logs and utils/reports) <PREFIX>-<rate>-f<flows>-<mode>
# instead of dnflows-<iommu>-...; dualnic_pips_sweep.sh gives each batcher
# setting its own. Extra runner options go in DUALNIC_ARGS, e.g.
# DUALNIC_ARGS="--pips-log 1" (run-dualnic-experiment.sh -h).
#
# Before the sweep, one single run of NIC0 alone at the lowest flow count checks
# the datapath; the sweep stops there if it carries no traffic. --no-datapath
# skips it (dualnic_pips_sweep.sh --datapath-once: after its first setting).
#
# Uncapped, the two NICs together hit the ~126 Gbps shared uplink, so 'both'
# rows are link-bound and read as throughput loss that is not the IOMMU's.
# Misses per Gbps normalises out the bytes moved; pass a rate such as 30 to
# hold bytes constant instead.
#
# Run it once per IOMMU setting: boot with the IOMMU on, run; reboot with it
# off, run again. The mode is read from sysfs (utils/iommu-mode.sh) and put in
# every experiment name, so the two sweeps never overwrite each other's reports.
#
# Results, in $HOME (override with RESULTS_DIR=...):
#   <name>.jsonl   one JSON line per configuration
#   <name>.txt     the summary table printed at the end
# Without -o, <name> is dualnic-flowsweep-<iommu>-<N> with N the first unused
# number, so repeat sweeps never append to or overwrite an earlier one. With
# -o, an existing <name>.jsonl is appended to, which resumes a sweep.
# Compare on and off side by side afterwards with:
#   python3 scripts/dualnic-results.py summary ~/dualnic-flowsweep-*.jsonl
set -u
cd "$(dirname "$0")/.."
. ../utils/setup-server.sh

NAME=""
PREFIX=""
DATAPATH=1
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out) NAME="$2"; shift 2 ;;
        -p|--exp-prefix) PREFIX="$2"; shift 2 ;;
        --no-datapath) DATAPATH=0; shift ;;
        *)        POS+=( "$1" ); shift ;;
    esac
done
FLOWS="${POS[0]:-5 10 15 30}"
RATES="${POS[1]:-uncapped}"
RUNS="${POS[2]:-3}"
MODES="${POS[3]:-both}"
EXTRA=( ${DUALNIC_ARGS:-} )

IOMMU=$(for i in 0 1; do bash ../utils/iommu-mode.sh "${SERVER_INTFS[$i]}"; done \
        | sort -u | paste -sd+)
PREFIX="${PREFIX:-dnflows-$IOMMU}"
DIR="${RESULTS_DIR:-$HOME}"
if [ -z "$NAME" ]; then
    n=1
    while [ -e "$DIR/dualnic-flowsweep-$IOMMU-$n.jsonl" ] \
          || [ -e "$DIR/dualnic-flowsweep-$IOMMU-$n.txt" ]; do n=$((n + 1)); done
    NAME="dualnic-flowsweep-$IOMMU-$n"
fi
JSONL="$DIR/$NAME.jsonl"
TXT="$DIR/$NAME.txt"

echo "######## dual-NIC flow sweep: ${FLOWS} flows/NIC, rate/NIC ${RATES}, ${RUNS} run(s)"
echo "######## modes: ${MODES}"
[ ${#EXTRA[@]} -gt 0 ] && echo "######## runner args: ${EXTRA[*]}"
echo "######## experiments: $PREFIX-<rate>-f<flows>-<mode>"
echo "######## IOMMU: ${IOMMU}   kernel $(uname -r)"
echo "######## cmdline: $(cat /proc/cmdline)"
echo "######## results: $JSONL"
echo "########          $TXT"

# Written on success AND on abort, so a failure two hours in still leaves the
# finished configurations summarised.
summarize() {
    [ -s "$JSONL" ] || { echo "######## no results recorded"; return; }
    {
        echo "dual-NIC flow sweep  $(date '+%F %T')  host $(hostname)"
        echo "IOMMU $IOMMU  kernel $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "flows/NIC: $FLOWS   rates: $RATES   runs: $RUNS   modes: $MODES"
        [ ${#EXTRA[@]} -gt 0 ] && echo "runner args: ${EXTRA[*]}"
        echo
        python3 ../scripts/dualnic-results.py summary "$JSONL"
    } | tee "$TXT"
}

rate_args() {   # <rate> -> sets bwarg (for the runner) and tag (for names)
    case "$1" in
        uncapped|unlimited|0) bwarg="uncapped"; tag="uncapped" ;;
        *)                    bwarg="${1}g";    tag="${1}g" ;;
    esac
}

# Datapath check: one short NIC0-alone run at the lowest flow count. The runner
# already aborts when it cannot ping or start iperf3; this also catches a path
# that connects but carries nothing, which would otherwise surface at the end
# as a summary full of zeros.
low=$(printf '%s\n' $FLOWS | sort -n | head -1)
rate_args "${RATES%% *}"
e="$PREFIX-$tag-f$low-datapath"
echo
if [ "$DATAPATH" = 0 ]; then
    echo "######## datapath check skipped (--no-datapath)"
else
    echo "######## datapath check: NIC0 alone, $low flows/NIC, $tag, 1 run"
    if ! ./run-dualnic-experiment.sh -E "$e" --nics 1 --nic-index 0 \
            -S "$low" -C "$low" -b "$bwarg" --runs 1 --results "$JSONL" ${EXTRA[@]+"${EXTRA[@]}"}; then
        echo "######## ABORTING: datapath check failed" >&2
        exit 1
    fi
    got=$(awk '{print $NF}' "../utils/reports/$e-RUN-server-0-nic0/iperf.bw.rpt" 2>/dev/null)
    case "${got:-}" in ''|*[!0-9.]*) got=0 ;; esac
    if ! awk -v t="$got" 'BEGIN{exit !(t > 1)}'; then
        echo "######## ABORTING: datapath check carried $got Gbps on NIC0." >&2
        echo "######## See utils/reports/$e-RUN-server-0-nic0/ and utils/logs/$e-*" >&2
        exit 1
    fi
    echo "######## datapath OK: $got Gbps on NIC0"
fi

for r in $RATES; do
    rate_args "$r"
    for f in $FLOWS; do
        for mode in $MODES; do
            case "$mode" in
                nic0only) args="--nics 1 --nic-index 0" ;;
                nic1only) args="--nics 1 --nic-index 1" ;;
                both)     args="--nics 2" ;;
                *) echo "unknown mode '$mode' (nic0only|nic1only|both)" >&2; exit 2 ;;
            esac
            echo
            echo "######## IOMMU $IOMMU  $tag/NIC  $f flows/NIC  $mode"
            if ! ./run-dualnic-experiment.sh -E "$PREFIX-$tag-f$f-$mode" $args \
                    -S "$f" -C "$f" -b "$bwarg" --runs "$RUNS" --results "$JSONL" \
                    ${EXTRA[@]+"${EXTRA[@]}"}; then
                echo "######## ABORTING at $tag/f$f/$mode" >&2
                summarize
                exit 1
            fi
        done
    done
done

echo
echo "=============================================================="
echo "  FLOW SWEEP SUMMARY"
echo "=============================================================="
summarize
