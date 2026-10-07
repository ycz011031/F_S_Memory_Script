#!/bin/bash
# Dual-SSD block size x instances cross sweep on bigserver: every block size
# at every instance count per drive, for the IOMMU mode the host is booted
# in. Same runner, reports and summary as dualssd_sweep.sh, plus block size x
# instances grids at the end (total kIOPS, per-drive split, GB/s, CPU us per
# I/O, misses per 4 KiB, and the single drive's numbers).
#
#   ./dualssd_cross_sweep.sh                     # both drives; 4k 8k 16k 64k 1m x 1 2 4 8 16 32; 1 run
#   ./dualssd_cross_sweep.sh --single            # also drive 0 (9100 PRO, nvme0) alone
#   ./dualssd_cross_sweep.sh --single-ssd 1      # drive 1 (990 EVO Plus, nvme1) alone instead
#   ./dualssd_cross_sweep.sh "4k 8k" "8 12 16 24 32" 3
#   ./dualssd_cross_sweep.sh --single --tmux     # in a tmux session instead
#
# Arguments: block sizes (default "4k 8k 16k 64k 1m"), instances per drive
# (default "1 2 4 8 16 32"; from 10 up, cores run several each, since
# SSD_CORES has 9 per drive), repeats (default 1: the grid is large; 3 gives
# error bars at 3x the time). Options:
#   --single          also run ONE drive alone at every point, drive 0. Unlike
#                     dualssd_sweep.sh --single (each drive alone), this
#                     halves the single-drive time. It fills the KEPT% column
#                     and grid (that drive's co-run IOPS as % of alone), not
#                     CONTENTION, which needs both drives' single runs.
#   --single-ssd N    the drive to run alone, 0 or 1; implies --single.
#                     Drive 1, the 990 EVO Plus, is the one whose host memory
#                     buffer adds PCIe traffic fio does not see (HANDOFF §7).
#   -o NAME           name the sweep (must be new)
#   --tmux            run it in a new tmux session instead of this terminal
# Runner options go in DUALSSD_ARGS, e.g. DUALSSD_ARGS="--membw 0" skips
# pcm-memory and saves ~50 s per run.
#
# Time: ~1 min per run with --membw 0, ~2 min with pcm-memory. The default
# grid is 30 points: ~30 min (~1 h with pcm-memory); --single doubles it.
# Every point prints "[k/N]" with the time so far and an estimate of the rest.
#
# 8k is in the default list because it is where strict mode's 4k ceiling
# (~650K IOPS, ~2.7 GB/s) and the Gen3 x8 uplink (~6.4-7 GB/s) should meet:
# at 8k the same per-I/O ceiling is ~5.3 GB/s, still under the link.
#
# At 32 instances x iodepth 32 each drive has 1024 reads in flight, 1 GiB at
# 1m. On a switch design that starves drive 0 at 1m, its reads waited ~1 s at
# 4 instances, so expect several seconds at 32 (the NVMe timeout is 30 s).
# Check dmesg for nvme timeouts after the first such sweep.
#
# Results are named dualssd-xsweep-<iommu>-<N> (or -o NAME); everything else
# as dualssd_sweep.sh, including that nothing is ever overwritten.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

OPTS=(); POS=(); SINGLE_SSD=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)      OPTS+=( "$1" "$2" ); shift 2 ;;
        --tmux)        OPTS+=( "$1" ); shift ;;
        --single)      SINGLE_SSD="${SINGLE_SSD:-0}"; shift ;;
        --single-ssd)  SINGLE_SSD="$2"; shift 2 ;;
        -h|--help)     sed -n '2,45p' "$SELF"; exit 0 ;;
        -*)            echo "unknown option: $1" >&2; exit 2 ;;
        *)             POS+=( "$1" ); shift ;;
    esac
done
[ -n "$SINGLE_SSD" ] && OPTS+=( --single-ssd "$SINGLE_SSD" )
BSIZES="${POS[0]:-4k 8k 16k 64k 1m}"
INSTANCES="${POS[1]:-1 2 4 8 16 32}"
RUNS="${POS[2]:-1}"

export SWEEP_PREFIX="${SWEEP_PREFIX:-dualssd-xsweep}"
exec bash "$(dirname "$SELF")/dualssd_sweep.sh" ${OPTS[@]+"${OPTS[@]}"} \
    "$INSTANCES" "$BSIZES" "$RUNS"
