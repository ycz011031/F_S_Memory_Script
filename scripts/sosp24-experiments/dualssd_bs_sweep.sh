#!/bin/bash
# Dual-SSD block-size sweep on bigserver: does reading in bigger blocks change
# the ~600-700K IOPS ceiling seen at 4k? Same runner, same reports and
# summary as dualssd_sweep.sh; this fixes the instance count and sweeps the
# block size instead.
#
#   ./dualssd_bs_sweep.sh                              # both drives, 4 instances each, 4k..1m, 3 runs
#   ./dualssd_bs_sweep.sh --single                     # also each drive alone
#   ./dualssd_bs_sweep.sh "4k 8k 16k 32k 64k 128k 256k 512k 1m" 4 3
#   ./dualssd_bs_sweep.sh --tmux                       # in a tmux session instead
#
# Arguments: block sizes (default "4k 16k 64k 256k 1m"), instances per drive
# (default 4), repeats (default 3). Options as for dualssd_sweep.sh: --single,
# -o NAME, --tmux; DUALSSD_ARGS for runner options (e.g. "--membw 0" to save
# ~50 s per run).
#
# 4 instances per drive is the smallest count at which each drive uses all 4
# of its NVMe queues with fio off the interrupt CPUs (HANDOFF §7).
#
# What to read: each 4 KiB read costs one IOMMU map, one unmap and, in strict
# mode, one invalidation; a 1 MiB read costs the same for 256x the data. If
# the 4k ceiling is a per-I/O cost, GB/s rises with block size until the
# shared Gen3 x8 uplink binds (~6.4-7 GB/s, LINK BOUND in the summary). If
# GB/s stays near 3 GB/s at every size, the limit is bandwidth, not per I/O.
# MISS/4K shows whether IOTLB misses per byte change with block size.
#
# Results are named dualssd-bssweep-<iommu>-<N> (or -o NAME); everything else
# as dualssd_sweep.sh, including that nothing is ever overwritten.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

OPTS=(); POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)         OPTS+=( "$1" "$2" ); shift 2 ;;
        --single|--tmux)  OPTS+=( "$1" ); shift ;;
        -h|--help)        sed -n '2,28p' "$SELF"; exit 0 ;;
        -*)               echo "unknown option: $1" >&2; exit 2 ;;
        *)                POS+=( "$1" ); shift ;;
    esac
done
BSIZES="${POS[0]:-4k 16k 64k 256k 1m}"
INSTANCES="${POS[1]:-4}"
RUNS="${POS[2]:-3}"

export SWEEP_PREFIX="${SWEEP_PREFIX:-dualssd-bssweep}"
exec bash "$(dirname "$SELF")/dualssd_sweep.sh" ${OPTS[@]+"${OPTS[@]}"} \
    "$INSTANCES" "$BSIZES" "$RUNS"
