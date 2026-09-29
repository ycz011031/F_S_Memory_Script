#!/bin/bash
# Dual-NIC contention as a function of OFFERED LOAD.
#
#   ./dualnic_load_sweep.sh                # 15,30,45,60 Gbps per NIC
#   ./dualnic_load_sweep.sh "20 40 60" 8 3 # rates, flows, repeats
#
# WHY A SWEEP RATHER THAN ONE CAPPED POINT
#
# The two NICs share a ~126 Gbps x8 uplink (0000:96:02.0 via switch
# 0000:97:00.0). Run both uncapped and the link saturates before the IOMMU
# does: measured 110.5 Gbps PCIe write at 88% of the uplink, with throughput
# 46% below the sum of the single-NIC baselines. That degradation is the link,
# not the IOMMU, and the two cannot be separated at that point.
#
# But capping at one low rate has the opposite problem: it may sit below the
# regime where IOMMU pressure matters at all, making a small effect look like
# the whole story.
#
# Sweeping load settles it. If misses-per-byte contention is flat in offered
# load, it is a fixed property of sharing an IIO stack. If it grows with load,
# it is genuine queueing pressure in the IOMMU. And the point where PCIe_wr
# approaches ~126 Gbps marks where the link takes over -- everything at or
# beyond that is uninterpretable, and the sweep shows you exactly where it is.
set -u
cd "$(dirname "$0")/.."

RATES="${1:-15 30 45 60 uncapped}"   # Gbps per NIC; "uncapped" = line rate
FLOWS="${2:-8}"
RUNS="${3:-1}"

echo "######## dual-NIC load sweep: ${RATES} Gbps/NIC, ${FLOWS} flows, ${RUNS} run(s)"
echo "######## shared uplink is ~126 Gbps; watch where PCIe_wr approaches it"

for r in $RATES; do
    for mode in nic0only nic1only both; do
        case "$mode" in
            nic0only) args="--nics 1 --nic-index 0" ;;
            nic1only) args="--nics 1 --nic-index 1" ;;
            both)     args="--nics 2" ;;
        esac
        # "uncapped" is a valid rate: it means no -b limit, i.e. line rate.
        case "$r" in
            uncapped|unlimited|0) bwarg="uncapped"; tag="uncapped" ;;
            *)                    bwarg="${r}g";    tag="${r}g" ;;
        esac
        echo
        echo "######## $tag/NIC  $mode"
        if ! ./run-dualnic-experiment.sh -E "dnload-$tag-$mode" $args \
                -S "$FLOWS" -C "$FLOWS" -b "$bwarg" --runs "$RUNS"; then
            echo "######## ABORTING at $tag/$mode" >&2
            exit 1
        fi
    done
done

echo
echo "=============================================================="
echo "  LOAD SWEEP SUMMARY"
echo "=============================================================="
printf '  %-8s %-10s %-12s %-14s %-16s %s\n' \
    RATE MODE TPUT PCIe_wr IOTLB_miss MISS_PER_GBPS
for r in $RATES; do
    for mode in nic0only nic1only both; do
        case "$r" in uncapped|unlimited|0) tag="uncapped" ;; *) tag="${r}g" ;; esac; e="dnload-$tag-$mode"
        P="../utils/reports/$e-RUN-server-0/pcie.rpt"
        [ -f "../utils/reports/$e-RUN-server-mean.rpt" ] && \
            P="../utils/reports/$e-RUN-server-mean.rpt"
        tput=0
        for d in ../utils/reports/$e-RUN-server-*-nic*/iperf.bw.rpt; do
            [ -f "$d" ] || continue
            g=$(awk '{print $NF}' "$d" 2>/dev/null)
            case "${g:-}" in ''|*[!0-9.]*) g=0 ;; esac
            tput=$(awk -v a="$tput" -v b="$g" 'BEGIN{printf "%.3f", a+b}')
        done
        # with repeats the per-NIC dirs are summed across runs; divide back out
        tput=$(awk -v t="$tput" -v n="$RUNS" 'BEGIN{printf "%.3f", t/n}')
        miss=$(awk '/^IOTLB_misses:/{print $2}' "$P" 2>/dev/null)
        pcie=$(awk '/^PCIe_wr_tput:/{print $2}' "$P" 2>/dev/null)
        case "${miss:-}" in ''|*[!0-9.]*) miss=0 ;; esac
        case "${pcie:-}" in ''|*[!0-9.]*) pcie=0 ;; esac
        mpg=$(awk -v m="$miss" -v p="$pcie" 'BEGIN{ printf "%.1f", (p>0 ? m/p : 0) }')
        flag=""
        awk -v p="$pcie" 'BEGIN{exit !(p > 100)}' && flag="  <-- LINK BOUND"
        printf '  %-8s %-10s %-12s %-14s %-16s %s%s\n' \
            "$tag" "$mode" "$tput" "$pcie" "$miss" "$mpg" "$flag"
    done
done
echo
echo "  Read MISS_PER_GBPS across the three modes at each rate."
echo "  contention = both / mean(nic0only, nic1only) - 1"
echo "  Flat across rates  -> fixed cost of sharing an IIO stack."
echo "  Rising with rate   -> real IOMMU queueing pressure."
echo "  Ignore any row marked LINK BOUND; there the uplink, not the IOMMU,"
echo "  is the constraint and the comparison does not hold."
