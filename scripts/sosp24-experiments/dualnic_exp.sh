#!/bin/bash
# Dual-NIC IOMMU contention on icx.
#
# Three points, same harness, same per-NIC load:
#   1. NIC0 alone      baseline + establishes the sender ceiling for link A
#   2. NIC1 alone      baseline + sender ceiling for link B
#   3. NIC0 + NIC1     the contention case
#
# Read the result as: does aggregate throughput fall short of (1)+(2), and do
# the shared-stack IOTLB misses rise faster than the byte count? Both NICs feed
# one IIO stack, so the IOMMU counters are a sum -- that sum IS the contention
# signal. Per-NIC throughput comes from iperf3.
#
# Runs deliberately BELOW saturation. The two NICs share a ~126 Gbps x8 uplink
# and the Broadwell sender tops out near 100-130 Gbps; at 40g per NIC the
# aggregate (~80 Gbps) clears both, so what moves is IOMMU-side.
set -u
cd "$(dirname "$0")/.."

BW="${1:-40g}"
FLOWS="${2:-8}"
shift 2 2>/dev/null || shift $# 2>/dev/null || true
EXTRA=( "$@" )      # forwarded to every run, e.g. --sync-client

echo "######## dual-NIC contention sweep, ${BW} per NIC, ${FLOWS} flows per NIC"
[ ${#EXTRA[@]} -gt 0 ] && echo "######## extra args: ${EXTRA[*]}"

# A failed run yields no data, so continuing to the next one only buries the
# error under two more failures and a summary of zeros that looks like a result.
run_or_die() {
    local label="$1"; shift
    echo
    echo "######## $label"
    if ! ./run-dualnic-experiment.sh "$@" "${EXTRA[@]}"; then
        echo >&2
        echo "######## ABORTING: '$label' failed. Later runs would be" >&2
        echo "######## meaningless and the summary would show zeros." >&2
        exit 1
    fi
}

run_or_die "1/3  NIC0 alone" \
    -E "dualnic-${BW}-nic0only" --nics 1 --nic-index 0 -S "$FLOWS" -C "$FLOWS" -b "$BW"
run_or_die "2/3  NIC1 alone" \
    -E "dualnic-${BW}-nic1only" --nics 1 --nic-index 1 -S "$FLOWS" -C "$FLOWS" -b "$BW"
run_or_die "3/3  both NICs" \
    -E "dualnic-${BW}-both" --nics 2 -S "$FLOWS" -C "$FLOWS" -b "$BW"

echo
echo "=============================================================="
echo "  SUMMARY"
echo "=============================================================="
for e in "dualnic-${BW}-nic0only" "dualnic-${BW}-nic1only" "dualnic-${BW}-both"; do
    P="../utils/reports/$e-RUN-server-0/pcie.rpt"
    tput=0
    for d in ../utils/reports/$e-RUN-server-0-nic*/iperf.bw.rpt; do
        [ -f "$d" ] || continue
        g=$(awk '{print $NF}' "$d" 2>/dev/null)
        case "${g:-}" in ''|*[!0-9.]*) g=0 ;; esac
        tput=$(awk -v a="$tput" -v b="$g" 'BEGIN{printf "%.3f", a+b}')
    done
    miss=$(awk '/^IOTLB_misses:/{print $NF}' "$P" 2>/dev/null)
    pcie=$(awk '/^PCIe_wr_tput:/{print $NF}' "$P" 2>/dev/null)
    printf '  %-28s tput=%-9s IOTLB_miss=%-12s PCIe_wr=%s\n' \
        "$e" "$tput" "${miss:-n/a}" "${pcie:-n/a}"
done
echo
echo "  Compare: is 'both' tput < nic0only + nic1only?"
echo "           is 'both' IOTLB_miss > nic0only + nic1only?"
echo "  If PCIe_wr on 'both' approaches ~126 Gbps the run was link-bound and"
echo "  the IOMMU comparison does not hold -- lower the bandwidth and repeat."
