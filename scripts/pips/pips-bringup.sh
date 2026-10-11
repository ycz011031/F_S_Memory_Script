#!/bin/bash
# PIPS host bring-up: enumeration and links, BAR0 registers and BRAM, the AXI
# window to the batcher/logger config register (regfile), the log DMA and
# DDR, the window's error path, and an empty log recording (DMA -> DDR ->
# host). Nothing behind the switch is written to.
#
#   sudo bash scripts/pips/pips-bringup.sh [options]
#
#   --bdf BDF       PIPS upstream port (default: the only 10ee:b048 device)
#   --soak N        also N random BRAM write/read pairs (done criterion: 1000000)
#   --ddr-addr A    DDR page for the window write/read test (default 0x10000000,
#                   outside the log region)
#   --enable-mem    turn on Memory Space Enable on the upstream port if it is off
#   -o NAME         folder under utils/logs/ (default pips-bringup-<date>-<time>)
#
# Run after programming the FPGA and a rescan. hwtest stops at its first
# failing step; the script still collects the readouts, then exits 1.
# Everything is kept in utils/logs/<NAME>/:
#   bringup.log            this output
#   lspci-tree.txt         lspci -tvnn
#   lspci-<BDF>.txt        lspci -vvv of the root port and every PIPS function
#   dmesg.txt              kernel log; dmesg-pips.txt: lines naming a PIPS function
#                          or reporting an error; dmesg-errors.txt: the errors only
#   info.txt cfg.txt dma.txt   pips readouts before the tests
#   hwtest.txt             pips hwtest
#   log-smoke.bin/.txt     the empty recording hwtest made, and its decode
#   soak.txt               with --soak
#   info-after.txt         pips info at the end (counters, CQ_SPLIT)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pips-lib.sh"

BDF=""; SOAK=0; DDR_ADDR=""; ENABLE_MEM=0; NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bdf) BDF="$2"; shift 2 ;;
        --soak) SOAK="$2"; shift 2 ;;
        --ddr-addr) DDR_ADDR="$2"; shift 2 ;;
        --enable-mem) ENABLE_MEM=1; shift ;;
        -o) NAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (-h for help)" >&2; exit 2 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || echo "WARNING: not root: BAR0 access, lspci capabilities and dmesg need sudo"

pips_lock || exit 1
pips_build || die "cannot build $PIPS"
if [ -n "$NAME" ]; then OUT=$(pips_outdir "$NAME") || exit 1
else OUT=$(pips_outdir "pips-bringup-$(date +%Y%m%d-%H%M%S)" unique) || exit 1; fi
OWNER="${SUDO_USER:-$(id -un)}"
trap 'chown -R "$OWNER": "$OUT" 2>/dev/null' EXIT
exec > >(tee "$OUT/bringup.log") 2>&1
echo "saving to $OUT/"

declare -A RESULT
section() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }

# ---------------------------------------------------------------------------
section "1. Enumeration"
if [ -z "$BDF" ]; then
    BDF=$(pips_find_usp) || { lspci -nn -d 10ee: 2>/dev/null | sed 's/^/  /'; exit 1; }
fi
case "$BDF" in ????:??:??.?) ;; *) BDF="0000:$BDF" ;; esac
D=/sys/bus/pci/devices/$BDF
[ -e "$D" ] || die "$BDF: no such PCI function"
echo "  upstream port $BDF: $(lspci -nn -s "$BDF" 2>/dev/null | cut -d' ' -f2-)"
lspci -vv -s "$BDF" 2>/dev/null | grep -E 'Region 0|Control:|Bus: primary' | sed 's/^[[:space:]]*/    /'

cmd=$(setpci -s "$BDF" COMMAND 2>/dev/null)
if [ -n "$cmd" ] && [ $((0x$cmd & 2)) -eq 0 ]; then
    if [ "$ENABLE_MEM" = 1 ]; then
        echo "  Memory Space Enable is off: turning it on (setpci COMMAND=0x02:0x02)"
        setpci -s "$BDF" COMMAND=0x02:0x02
    else
        echo "  Memory Space Enable is off (Mem-): BAR0 cannot be reached. Re-run with --enable-mem"
        RESULT[enum]=FAIL
    fi
fi
BAR_OK=0
read -r bar_start bar_size < <(bar0_of "$BDF")
if [ -n "${bar_size:-}" ] && [ "$bar_size" -eq 32768 ] && [ $((bar_start)) -ne 0 ]; then
    BAR_OK=1
    echo "  BAR0 $bar_start, 32 KB"
elif [ -z "${bar_size:-}" ]; then
    echo "  BAR0 does not exist: this bitstream has no BAR0 on the upstream port"
    RESULT[enum]=FAIL
elif [ "$bar_size" -ne 32768 ]; then
    echo "  BAR0 is $bar_size bytes. PIPS with the host register block (BAR0 map v2) has"
    echo "  32 KB, so this bitstream predates it (FPGA repo af165d6) or was built with another"
    echo "  upstream-port BAR size. Program a build of the current pips.tcl, then rescan."
    echo "  BAR0 is left alone: in builds without the PIO, BAR0 accesses are forwarded to"
    echo "  the device on downstream port one (PIO_KNOWLEDGE_MAP D6)."
    RESULT[enum]=FAIL
elif [ $((bar_start)) -eq 0 ]; then
    echo "  BAR0 is not assigned an address (Region 0 <unassigned>): boot with pci=realloc"
    RESULT[enum]=FAIL
fi

echo
echo "  path from the root port (link as trained, and its capability):"
for b in $(readlink -f "$D" | tr '/' '\n' | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$'); do
    printf '    %-14s %s\n' "$b" "$(lspci_brief "$b")"
    lspci -vvv -s "$b" > "$OUT/lspci-$b.txt" 2>&1
done

echo
echo "  below the upstream port:"
dsps=0
for b in $(pips_below "$BDF"); do
    ven=$(cat "/sys/bus/pci/devices/$b/vendor"); dev=$(cat "/sys/bus/pci/devices/$b/device")
    drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" 2>/dev/null)
    case "$ven:$dev" in
        0x10ee:0xb148) role="downstream port zero (log port in1)"; dsps=$((dsps + 1)) ;;
        0x10ee:0xb348) role="downstream port one  (log port in0)"; dsps=$((dsps + 1)) ;;
        *) role="$(lspci -s "$b" 2>/dev/null | cut -d' ' -f2- | cut -c1-60)" ;;
    esac
    printf '    %-14s %s:%s %s  driver %s\n' "$b" "${ven#0x}" "${dev#0x}" "$role" "${drv:-none}"
    printf '    %-14s %s\n' "" "$(lspci_brief "$b")"
    case "$ven" in 0x10ee) ;; *)
        grp=none
        [ -e "/sys/bus/pci/devices/$b/iommu_group" ] &&
            grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$b/iommu_group")")
        printf '    %-14s IOMMU group %s, unit %s, mode %s, NUMA %s\n' "" "$grp" \
            "$(l=/sys/bus/pci/devices/$b/iommu; [ -e "$l" ] && basename "$(readlink -f "$l")" || echo none)" \
            "$(bash "$PIPS_REPO/utils/iommu-mode.sh" "$b" 2>/dev/null)" \
            "$(cat "/sys/bus/pci/devices/$b/numa_node" 2>/dev/null)" ;;
    esac
    lspci -vvv -s "$b" > "$OUT/lspci-$b.txt" 2>&1
done
[ "$dsps" -eq 2 ] || { echo "  expected 2 downstream ports (10ee:b148, 10ee:b348), found $dsps"; RESULT[enum]=FAIL; }
nvmes=$(pips_nvme_below "$BDF" | xargs)
echo "  NVMe namespaces behind PIPS: ${nvmes:-none}"
lspci -tvnn > "$OUT/lspci-tree.txt" 2>&1
mps=$(for f in "$OUT"/lspci-*:*.txt; do awk '/^[ \t]+MaxPayload [0-9]+ bytes, MaxReadReq/{print $2; exit}' "$f"; done | sort -u | xargs)
case "$mps" in
    *" "*) echo "  MaxPayload differs along the PIPS tree: $mps bytes (one value expected)"; RESULT[enum]=FAIL ;;
    "")    echo "  MaxPayload: not readable (needs root)" ;;
    *)     echo "  MaxPayload $mps bytes on every function" ;;
esac
RESULT[enum]=${RESULT[enum]:-ok}

# ---------------------------------------------------------------------------
section "2. Kernel log"
if dmesg > "$OUT/dmesg.txt" 2>/dev/null; then
    pat="$(for b in $BDF $(pips_below "$BDF"); do printf '%s|' "$b"; done)$PIPS_KERNEL_ERR_RE"
    grep -E "$pat" "$OUT/dmesg.txt" > "$OUT/dmesg-pips.txt"
    grep -E "$PIPS_KERNEL_ERR_RE" "$OUT/dmesg.txt" > "$OUT/dmesg-errors.txt"
    echo "  $(wc -l < "$OUT/dmesg-pips.txt") lines name a PIPS function or report an error (dmesg-pips.txt); the last 10:"
    tail -10 "$OUT/dmesg-pips.txt" | sed 's/^/    /'
    if [ -s "$OUT/dmesg-errors.txt" ]; then
        echo "  $(wc -l < "$OUT/dmesg-errors.txt") PCIe/IOMMU/NVMe error lines since boot (dmesg-errors.txt); the last 5:"
        tail -5 "$OUT/dmesg-errors.txt" | sed 's/^/    /'
    else
        echo "  no AER, DPC, DMAR fault or NVMe error lines since boot"
    fi
else
    echo "  dmesg not readable (needs root)"
fi

# ---------------------------------------------------------------------------
section "3. Registers before the tests"
P() { "$PIPS" -s "$BDF" "$@"; }
if [ "$BAR_OK" = 0 ]; then
    echo "  skipped: BAR0 is not the 32 KB PIPS register BAR (section 1)"
    RESULT[regs]=skipped
elif P info > "$OUT/info.txt" 2>&1; then
    sed 's/^/  /' "$OUT/info.txt"
    P cfg > "$OUT/cfg.txt" 2>&1; sed 's/^/  /' "$OUT/cfg.txt"
    P dma > "$OUT/dma.txt" 2>&1; sed 's/^/  /' "$OUT/dma.txt"
    RESULT[regs]=ok
else
    sed 's/^/  /' "$OUT/info.txt"
    RESULT[regs]=FAIL
fi

# ---------------------------------------------------------------------------
section "4. hwtest"
if [ "${RESULT[regs]}" = ok ]; then
    P hwtest ${DDR_ADDR:+--ddr-addr "$DDR_ADDR"} > "$OUT/hwtest.txt" 2>&1
    rc=$?
    sed 's/^/  /' "$OUT/hwtest.txt"
    [ $rc -eq 0 ] && RESULT[hwtest]=ok || RESULT[hwtest]=FAIL
else
    echo "  skipped: no BAR0 registers"
    RESULT[hwtest]=skipped
fi

# ---------------------------------------------------------------------------
section "5. Log smoke test: the empty recording, from DDR"
if [ "${RESULT[hwtest]}" = ok ]; then
    if P log-dump "$OUT/log-smoke.bin" > "$OUT/log-smoke.txt" 2>&1 &&
       python3 "$HERE/pips-log-decode.py" "$OUT/log-smoke.bin" >> "$OUT/log-smoke.txt" 2>&1; then
        RESULT[log]=ok
    else
        RESULT[log]=FAIL
    fi
    sed 's/^/  /' "$OUT/log-smoke.txt"
else
    echo "  skipped: hwtest did not pass"
    RESULT[log]=skipped
fi

# ---------------------------------------------------------------------------
if [ "$SOAK" -gt 0 ] 2>/dev/null; then
    section "6. Soak: $SOAK BRAM write/read pairs"
    if [ "${RESULT[hwtest]}" = ok ]; then
        P soak "$SOAK" 2>&1 | tee "$OUT/soak.txt" | sed 's/^/  /'
        [ "${PIPESTATUS[0]}" -eq 0 ] && RESULT[soak]=ok || RESULT[soak]=FAIL
    else
        echo "  skipped: hwtest did not pass"; RESULT[soak]=skipped
    fi
fi

# ---------------------------------------------------------------------------
if [ "${RESULT[regs]}" = ok ]; then
    section "Registers after"
    P info > "$OUT/info-after.txt" 2>&1
    grep -E '^(CQ_SPLIT|MWR_COUNT|MRD_COUNT|PIO_STATUS|WIN_STATUS)' "$OUT/info-after.txt" | sed 's/^/  /'
fi

section "Summary"
fail=0
for k in enum regs hwtest log soak; do
    [ -n "${RESULT[$k]:-}" ] || continue
    printf '  %-8s %s\n' "$k" "${RESULT[$k]}"
    [ "${RESULT[$k]}" = FAIL ] && fail=1
done
echo "  logs: $OUT/"
[ "$fail" -eq 0 ] && echo "  next: sudo bash scripts/pips/pips-fio-log.sh"
exit $fail
