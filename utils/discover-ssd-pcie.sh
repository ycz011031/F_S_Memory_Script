#!/bin/bash
# Find the pcm-iio row for the SSDs under test, and check that this host's PCM
# loads opCode-6-<model>.txt and reports live VT-d counters. The SSD
# counterpart of discover-pcie-topology.sh. Read-only: fio runs --readonly.
#
#   sudo bash utils/discover-ssd-pcie.sh                  # drives in SSD_SERIALS
#   sudo bash utils/discover-ssd-pcie.sh <serial>...      # or name them
#
# Loads each drive alone for ~14 s of 4k random reads while pcm-iio samples,
# so the row carrying its traffic identifies it. Prints the SSD_PCIE_PATTERN
# line for setup-server.sh.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/setup-server.sh" ] && . "$HERE/setup-server.sh"
. "$HERE/ssd-lib.sh"

SERIALS=( "$@" )
[ ${#SERIALS[@]} -eq 0 ] && SERIALS=( ${SSD_SERIALS[@]+"${SSD_SERIALS[@]}"} )
if [ ${#SERIALS[@]} -eq 0 ]; then
    echo "usage: sudo bash $0 [serial...]   (default: SSD_SERIALS from setup-server.sh)" >&2
    exit 2
fi

echo "=============================================================="
echo "== 1. Drives, PCIe path and IOMMU unit"
echo "=============================================================="
DEVS=(); BDFS=(); UNITS=()
for s in "${SERIALS[@]}"; do
    ssd_resolve "$s" || continue
    d="/sys/bus/pci/devices/$SSD_BDF"
    unit=$(iommu_unit "$SSD_BDF")
    model=$(cat "$d"/nvme/nvme*/model 2>/dev/null | head -1 | xargs)
    DEVS+=( "$SSD_DEV" ); BDFS+=( "$SSD_BDF" ); UNITS+=( "$unit" )
    echo
    echo "  $s  $SSD_DEV  $SSD_BDF  NUMA $(cat "$d/numa_node")  $model"
    echo "    IOMMU unit $unit, mode $(bash "$HERE/iommu-mode.sh" "$SSD_BDF")"
    for b in $(pci_chain "$SSD_BDF"); do
        l=$(bdf_link "$b")
        printf '    %-14s %-12s ~%s Gbps\n' "$b" "${l:-(no LnkSta)}" "$(link_gbps $l)"
    done
done
[ ${#DEVS[@]} -gt 0 ] || exit 1

if [ ${#BDFS[@]} -ge 2 ]; then
    echo
    if [ "${UNITS[0]}" = none ]; then
        echo "  IOMMU off: no units to compare. Re-run booted with it on to check"
        echo "  the drives share one."
    elif [ "$(printf '%s\n' "${UNITS[@]}" | sort -u | wc -l)" -eq 1 ]; then
        echo "  Shared IOMMU unit (${UNITS[0]}): the drives contend for one IOTLB"
        echo "  and one invalidation queue -- the precondition for the experiment."
    else
        echo "  DIFFERENT IOMMU units (${UNITS[*]}): nothing is shared between the"
        echo "  drives, so a co-run cannot show IOMMU contention between them."
    fi
    echo "  Narrowest shared PCIe hop: ~$(shared_link_gbps "${BDFS[@]}") Gbps" \
         "(both drives' DMA together cannot exceed it)"
fi

if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "== 2. pcm-iio  [SKIPPED - needs root].  Re-run with sudo."
    exit 0
fi

PCM_IIO="${PCM_BIN:-${PCM_DIR:-/nonexistent}/build/bin}/pcm-iio"
[ -x "$PCM_IIO" ] || PCM_IIO=$(command -v pcm-iio 2>/dev/null)
if [ -z "$PCM_IIO" ]; then
    echo; echo "== 2. pcm-iio  [SKIPPED - not found; set PCM_BIN in setup-server.sh]"
    exit 1
fi
command -v fio >/dev/null || { echo "fio not installed" >&2; exit 1; }

# pcm-iio reads its event file from the CURRENT directory (see opCode-6-85.txt).
cd "$HERE" || exit 1
fam=$(awk -F: '/^cpu family/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
mod=$(awk -F: '/^model[[:space:]]*:/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
echo
echo "=============================================================="
echo "== 2. pcm-iio rows carrying each drive's traffic"
echo "=============================================================="
echo "  pcm-iio    : $PCM_IIO"
echo "  CPU        : family $fam model $mod"
if [ -f "opCode-$fam-$mod.txt" ]; then
    echo "  event file : $HERE/opCode-$fam-$mod.txt"
else
    echo "  event file : opCode-$fam-$mod.txt MISSING from $HERE -- pcm-iio will"
    echo "               fall back to PCM's installed file; columns are not pinned."
fi

modprobe msr 2>/dev/null
TMP=$(mktemp -d /tmp/ssd-pcie.XXXXXX)
trap 'pkill -INT -f "^(/[^ ]*/)?fio .*--name=ssd-discove[r]" 2>/dev/null; rm -rf "$TMP"' EXIT

PATTERNS=()
for idx in "${!DEVS[@]}"; do
    dev=${DEVS[$idx]}; bdf=${BDFS[$idx]}; n=$(basename "$dev")
    node=$(cat "/sys/bus/pci/devices/$bdf/numa_node")
    pin=()
    [ "$node" -ge 0 ] 2>/dev/null && pin=( --cpus_allowed="$(cat /sys/devices/system/node/node$node/cpulist)" )

    echo
    echo "-- $n ($bdf), alone: 4k random reads, 4 jobs x iodepth 32, read-only"
    fio --name=ssd-discover --filename="$dev" --readonly --rw=randread --bs=4k \
        --iodepth=32 --numjobs=4 --thread --direct=1 --ioengine=libaio \
        --time_based --runtime=14 ${pin[@]+"${pin[@]}"} --group_reporting \
        --output-format=json --output="$TMP/fio-$n.json" >"$TMP/fio-$n.err" 2>&1 &
    fpid=$!
    sleep 3
    timeout -s INT 8 "$PCM_IIO" 1 -csv="$TMP/iio-$n.csv" </dev/null >"$TMP/pcm-$n.out" 2>&1
    wait "$fpid"

    python3 "$HERE/../scripts/dualssd-results.py" fio-sum --out "$TMP/fio-$n.rpt" \
        "$TMP/fio-$n.json" >/dev/null 2>&1
    iops=$(awk '/^IOPS:/{printf "%.0f", $2}' "$TMP/fio-$n.rpt" 2>/dev/null)
    gbps=$(awk '/^read_Gbps:/{printf "%.1f", $2}' "$TMP/fio-$n.rpt" 2>/dev/null)
    echo "   fio: ${iops:-?} IOPS, ${gbps:-?} Gbps"
    [ -n "$iops" ] || sed 's/^/     /' "$TMP/fio-$n.err" | head -5

    csv="$TMP/iio-$n.csv"
    if [ ! -s "$csv" ]; then
        echo "   pcm-iio wrote no CSV. Its output:"
        sed 's/^/     /' "$TMP/pcm-$n.out" | head -20
        continue
    fi
    if grep -qiE 'not recognized|cannot|error' "$TMP/pcm-$n.out"; then
        echo "   pcm-iio complained (an event file this PCM version cannot parse?):"
        grep -iE 'not recognized|cannot|error' "$TMP/pcm-$n.out" | head -5 | sed 's/^/     /'
    fi

    # IB write = the drive DMA-writing read data into memory.
    wcol=$(csv_col "$csv" "IB write" 6)
    echo "   rows by mean IB write (top 3):"
    top=$(awk -F ',' -v c="$wcol" '$1 != "Date" && $3 ~ /^Socket/ {
              k = $3 "," $4 "," $5; s[k] += $c; m[k]++ }
          END { for (k in s) if (s[k] > 0) printf "%.0f\t%s\n", s[k]/m[k], k }' "$csv" \
          | sort -rn | head -3)
    if [ -z "$top" ]; then
        echo "     (none -- every row read zero IB write)"
        continue
    fi
    printf '%s\n' "$top" | awk -F '\t' '{ printf "     %7.2f Gbps  %s\n", $1*8/1e9, $2 }'

    best=$(printf '%s\n' "$top" | head -1 | cut -f2)
    part=$(printf '%s' "${best##*,}" | awk '{print $1}')
    pat="${best%,*},$part"
    PATTERNS+=( "$pat" )

    # VT-d events are per stack and land on its Part0 row. Without a header
    # row, fall back to their positions in opCode-6-85.txt.
    vtd="${best%,*},Part0"
    hdr=$(grep -m1 '^Date,' "$csv")
    echo "   VT-d counters, mean per second, row '$vtd':"
    for ev in "IOTLB Hit:10" "IOTLB Miss:11" "VT-d CTXT Miss:12" "VT-d L1 Miss:13" \
              "VT-d L2 Miss:14" "VT-d L3 Miss:15" "VT-d Mem Read:16"; do
        name=${ev%:*}
        if [ -n "$hdr" ]; then c=$(csv_col "$csv" "$name" 0); else c=${ev##*:}; fi
        if [ "$c" -eq 0 ]; then
            printf '     %-15s (no such column)\n' "$name"
            continue
        fi
        v=$(grep -F "$vtd" "$csv" | awk -F ',' -v c="$c" '{ s += $c; m++ }
                END { if (m) printf "%.0f", s/m; else print "?" }')
        printf '     %-15s %s\n' "$name" "$v"
    done
done

echo
echo "--- pcm-iio banner ---"
head -5 "$TMP/pcm-$n.out" | sed 's/^/  /'
echo "--- CSV header ---"
grep -m1 '^Date,' "$TMP/iio-$n.csv" 2>/dev/null | sed 's/^/  /' \
    || echo "  (no 'Date,...' header row; columns fall back to opCode-6-85.txt order)"

echo
echo "=============================================================="
if [ ${#PATTERNS[@]} -eq 0 ]; then
    echo "  No row carried traffic. Check the fio and pcm-iio output above."
    exit 1
fi
if [ "$(printf '%s\n' "${PATTERNS[@]}" | sort -u | wc -l)" -eq 1 ]; then
    echo "  All drives on one row. Put this in utils/setup-server.sh:"
    echo
    echo "    SSD_PCIE_PATTERN=\"${PATTERNS[0]}\""
else
    echo "  The drives are on DIFFERENT rows:"
    printf '    %s\n' "${PATTERNS[@]}"
    echo "  run-dualssd-experiment.sh reads PCIe bandwidth from one row, so it"
    echo "  would count only one drive's traffic. Per-drive rows need a runner change."
fi
echo
echo "  If the IOMMU is on and the VT-d counters above read 0, the event file did"
echo "  not load or the row is wrong; do not run a sweep until they are live."
