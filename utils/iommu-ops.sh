#!/bin/bash
# IOMMU map and unmap calls and VT-d queued-invalidation descriptors over one
# window, system-wide, with the I/O the devices under test did in the same
# seconds, so per-I/O ratios need nothing else (experiment E7, HANDOFF §8
# "0x0A07 paper campaign"). perf stat counts the kernel tracepoints
# iommu:map, iommu:unmap and intel_iommu:qi_submit (one per descriptor the
# driver queues: IOTLB, device-TLB and wait descriptors); neither Skylake-SP
# nor Ice Lake has a hardware VT-d invalidation counter (Sapphire Rapids'
# IOMMU PMU), so this is the count. Run as root.
#
#   sudo bash utils/iommu-ops.sh --dur 10 -o /tmp/ops.txt -r /tmp/ops.rpt
#
# record-host-metrics.sh --iommu-ops 1 runs it beside the pcm-iio window
# (the runners' --iommu-ops 1). Counting a tracepoint costs CPU on every
# map and unmap, so runs that carry it are for these counts only.
#
# Devices from setup-server.sh: the drives by serial (SSD_SERIALS, bigserver)
# or the interfaces (SERVER_INTFS, icx), whichever it sets.
#   -o FILE   perf's output, then the device counters before and after
#   -r FILE   the report, "key: value" (dualssd/dualnic-results.py read it):
#     iommu_ops_window_s       seconds counted
#     iommu_ops_map/_unmap/_qi counts; -1 = that tracepoint is missing
#     iommu_ops_ios            drive reads completed, or NIC rx packets
#     iommu_ops_bytes          bytes read, or NIC rx bytes
#     iommu_ops_tx_packets     NIC only
#     iommu_ops_{map,unmap,qi}_per_io, iommu_ops_unmap_per_4k (per 4 KiB
#     moved), iommu_ops_qi_per_unmap
# Exit 1 when perf is missing (Ubuntu: apt install linux-tools-$(uname -r)).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DUR=20 OUT="" RPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dur) DUR="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        -r) RPT="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "iommu-ops: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-/dev/stdout}
. "$HERE/setup-server.sh"
. "$HERE/ssd-lib.sh"

if ! perf --version >/dev/null 2>&1; then
    echo "iommu-ops: perf does not run here (Ubuntu: apt install linux-tools-$(uname -r))" >&2
    [ -n "$RPT" ] && echo "iommu_ops_window_s: 0" > "$RPT"
    exit 1
fi
EV_DIR=""
for d in /sys/kernel/tracing/events /sys/kernel/debug/tracing/events; do
    [ -d "$d/iommu" ] && { EV_DIR=$d; break; }
done
EVENTS=()
for e in iommu:map iommu:unmap intel_iommu:qi_submit; do
    [ -n "$EV_DIR" ] && [ -d "$EV_DIR/${e%%:*}/${e#*:}" ] && EVENTS+=("$e")
done

# Counters of the devices under test: "<ios> <bytes> <tx_packets>"
DEVS=()
if declare -p SSD_SERIALS >/dev/null 2>&1; then
    for s in "${SSD_SERIALS[@]}"; do ssd_resolve "$s" 2>/dev/null && DEVS+=("blk:$(basename "$SSD_DEV")"); done
elif declare -p SERVER_INTFS >/dev/null 2>&1; then
    for i in "${SERVER_INTFS[@]}"; do DEVS+=("net:$i"); done
fi
dev_counts() {
    local d n ios=0 bytes=0 tx=0 st
    for d in ${DEVS[@]+"${DEVS[@]}"}; do
        n=${d#*:}
        case "$d" in
            blk:*) read -r -a st < "/sys/block/$n/stat" 2>/dev/null || continue
                   ios=$(( ios + st[0] )); bytes=$(( bytes + st[2] * 512 )) ;;
            net:*) ios=$(( ios + $(cat "/sys/class/net/$n/statistics/rx_packets" 2>/dev/null || echo 0) ))
                   bytes=$(( bytes + $(cat "/sys/class/net/$n/statistics/rx_bytes" 2>/dev/null || echo 0) ))
                   tx=$(( tx + $(cat "/sys/class/net/$n/statistics/tx_packets" 2>/dev/null || echo 0) )) ;;
        esac
    done
    echo "$ios $bytes $tx"
}

TMP=$(mktemp)
read -r i0 b0 t0 <<< "$(dev_counts)"
s0=$(date +%s.%N)
if [ ${#EVENTS[@]} -gt 0 ]; then
    perf stat -a -x, -o "$TMP" $(printf -- '-e %s ' "${EVENTS[@]}") -- sleep "$DUR" 2>/dev/null
else
    sleep "$DUR"
fi
s1=$(date +%s.%N)
read -r i1 b1 t1 <<< "$(dev_counts)"
count_of() {   # <event> -> count, -1 when not counted
    local c
    c=$(awk -F, -v e="$1" '$3 == e { print $1; exit }' "$TMP")
    case "$c" in ''|*[!0-9]*) echo -1 ;; *) echo "$c" ;; esac
}
MAP=$(count_of iommu:map); UNMAP=$(count_of iommu:unmap); QI=$(count_of intel_iommu:qi_submit)
{
    echo "== iommu-ops $(date '+%F %T') kernel $(uname -r) window ${DUR}s"
    echo "events: ${EVENTS[*]:-none} (tracefs ${EV_DIR:-not found})"
    echo "devices: ${DEVS[*]:-none}"
    echo "== perf stat"; cat "$TMP"
    echo "== device counters before / after (ios bytes tx_packets)"
    echo "$i0 $b0 $t0"; echo "$i1 $b1 $t1"
} > "$OUT"
rm -f "$TMP"
[ -n "$RPT" ] && awk -v w="$(awk -v a="$s0" -v b="$s1" 'BEGIN { printf "%.3f", b - a }')" \
        -v map="$MAP" -v unmap="$UNMAP" -v qi="$QI" -v ios=$(( i1 - i0 )) -v bytes=$(( b1 - b0 )) \
        -v tx=$(( t1 - t0 )) -v net="$(case "${DEVS[0]:-}" in net:*) echo 1 ;; *) echo 0 ;; esac)" 'BEGIN {
    printf "iommu_ops_window_s: %s\n", w
    printf "iommu_ops_map: %d\niommu_ops_unmap: %d\niommu_ops_qi: %d\n", map, unmap, qi
    printf "iommu_ops_ios: %d\niommu_ops_bytes: %d\n", ios, bytes
    if (net) printf "iommu_ops_tx_packets: %d\n", tx
    if (ios > 0) {
        if (map >= 0) printf "iommu_ops_map_per_io: %.4f\n", map / ios
        if (unmap >= 0) printf "iommu_ops_unmap_per_io: %.4f\n", unmap / ios
        if (qi >= 0) printf "iommu_ops_qi_per_io: %.4f\n", qi / ios
    }
    if (bytes > 0 && unmap >= 0) printf "iommu_ops_unmap_per_4k: %.4f\n", unmap / (bytes / 4096)
    if (unmap > 0 && qi >= 0) printf "iommu_ops_qi_per_unmap: %.4f\n", qi / unmap
}' > "$RPT"
echo "iommu-ops: ${DUR}s, map $MAP, unmap $UNMAP, qi_submit $QI, device ios $(( i1 - i0 ))"
exit 0
