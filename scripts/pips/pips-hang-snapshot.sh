#!/bin/bash
# What the host can still see when PIPS stops answering (the NIC sweep's stop
# of 2026-10-17: completion timeouts through the switch, then its BAR reading
# all ones). Run it on the host BEFORE reprogramming or rescanning, so the
# state is the hung one. It only reads: no rescan, no reset, no config write.
#
#   bash scripts/pips/pips-hang-snapshot.sh [-o DIR] [--since "2 hours ago"]
#
# Into DIR (default ~/pips-hang-<host>-<time>), then DIR.tar.gz:
#   devices.txt     every Xilinx (10ee) and Mellanox (15b3) function and each
#                   bridge above it up to the root port, from sysfs: BDF, IDs,
#                   link speed/width now and at most
#   lspci-<bdf>.txt lspci -vvv of each (sudo: capabilities, LnkSta, DevSta,
#                   the AER status registers)
#   aer.txt         the kernel's AER counters per function (aer_dev_*)
#   pips-cfg.txt    `pips cfg` with a 10 s timeout: reads 0xFFFFFFFF when the
#                   switch is gone, the batcher setting when it is not
#   kernel.txt      journalctl -k since --since (default 3 hours ago):
#                   AER, pcieport, mlx5, nvme and Hardware Error lines; and
#                   kernel-all.txt with everything
#   devlink.txt     devlink health of the mlx5 functions, ip -s link of the
#                   interfaces they own
#   sweep.txt       the newest PIPS sweep folders' last lines (pips-sweep.log)
# A line per step as it goes. Then, also before reprogramming, read the
# switch over JTAG (scripts/pips/pips-xsct.tcl: pips_connect, pips_cfg,
# pips_dma), which works when PCIe does not, and note the board's temperature.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT="" SINCE="3 hours ago"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "pips-hang-snapshot: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-$HOME/pips-hang-$(hostname)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" || exit 1
T0=$SECONDS
NSTEP=7
step() { echo "[$1/$NSTEP] $(date +%T) +$((SECONDS - T0))s  $2"; }
sudo -n true 2>/dev/null || echo "pips-hang-snapshot: sudo will ask for a password (lspci -vvv, pips cfg)"

step 1 "devices: Xilinx and Mellanox functions and the bridges above them"
declare -A SEEN
ORDER=()
for d in /sys/bus/pci/devices/*; do
    v=$(cat "$d/vendor" 2>/dev/null)
    case "$v" in 0x10ee|0x15b3) ;; *) continue ;; esac
    p=$(readlink -f "$d")
    while [ -n "$p" ] && [ -e "$p/vendor" ]; do         # up to the root port
        b=$(basename "$p")
        [ -n "${SEEN[$b]:-}" ] || { SEEN[$b]=1; ORDER+=("$b"); }
        p=$(dirname "$p")
    done
done
{
    printf '%-14s %-6s %-6s %-12s %-12s %-6s %-6s %s\n' bdf vendor device speed max_speed width max class
    for b in "${ORDER[@]}"; do
        d=/sys/bus/pci/devices/$b
        printf '%-14s %-6s %-6s %-12s %-12s %-6s %-6s %s\n' "$b" "$(cat $d/vendor 2>/dev/null)" "$(cat $d/device 2>/dev/null)" \
            "$(cat $d/current_link_speed 2>/dev/null | tr -d ' ')" "$(cat $d/max_link_speed 2>/dev/null | tr -d ' ')" \
            "$(cat $d/current_link_width 2>/dev/null)" "$(cat $d/max_link_width 2>/dev/null)" "$(cat $d/class 2>/dev/null)"
    done
} > "$OUT/devices.txt"
echo "    ${#ORDER[@]} functions: ${ORDER[*]}"

step 2 "lspci -vvv of each (sudo)"
for b in "${ORDER[@]}"; do
    timeout 20 sudo lspci -vvv -s "$b" > "$OUT/lspci-$b.txt" 2>&1 || echo "    lspci $b: failed or timed out"
done
grep -H -E 'LnkSta:|DevSta:|UESta:|CESta:' "$OUT"/lspci-*.txt 2>/dev/null | sed 's#.*/lspci-##; s#\.txt:#  #' | head -60

step 3 "AER counters"
for b in "${ORDER[@]}"; do
    for f in /sys/bus/pci/devices/$b/aer_dev_*; do
        [ -e "$f" ] || continue
        echo "== $b $(basename "$f")"
        awk '$2 != 0' "$f"
    done
done > "$OUT/aer.txt" 2>&1
echo "    non-zero counters: $(grep -vc '^==' "$OUT/aer.txt")"

step 4 "pips cfg (10 s timeout)"
if [ -x "$HERE/pips" ]; then
    timeout 10 sudo "$HERE/pips" cfg > "$OUT/pips-cfg.txt" 2>&1
    echo "    exit $?: $(head -2 "$OUT/pips-cfg.txt" | tr '\n' ' ')"
else
    echo "    no $HERE/pips (make -C scripts/pips)" | tee "$OUT/pips-cfg.txt"
fi

step 5 "kernel log since $SINCE"
journalctl -k --since "$SINCE" --no-pager > "$OUT/kernel-all.txt" 2>&1 || dmesg -T > "$OUT/kernel-all.txt" 2>&1
grep -E -i 'aer|pcieport|mlx5|nvme|hardware error|cmpltto|link (down|up)|surprise' "$OUT/kernel-all.txt" > "$OUT/kernel.txt"
echo "    $(wc -l < "$OUT/kernel.txt") matching lines; last: $(tail -1 "$OUT/kernel.txt" | cut -c1-120)"

step 6 "mlx5: devlink health, interfaces"
{
    command -v devlink >/dev/null && timeout 10 devlink health show 2>&1
    for b in "${ORDER[@]}"; do
        for n in /sys/bus/pci/devices/$b/net/*; do
            [ -e "$n" ] || continue
            echo "== $b $(basename "$n")"; timeout 5 ip -s link show "$(basename "$n")" 2>&1
        done
    done
} > "$OUT/devlink.txt" 2>&1
echo "    $(grep -c '^==' "$OUT/devlink.txt") interfaces"

step 7 "the newest PIPS sweep logs"
{
    for f in $(ls -dt "$REPO"/utils/logs/dual*-pips-*/pips-sweep.log 2>/dev/null | head -2); do
        echo "== $f"; tail -40 "$f"
    done
} > "$OUT/sweep.txt" 2>&1
echo "    $(grep -c '^==' "$OUT/sweep.txt") sweep log(s)"

( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) &&
    echo "pips-hang-snapshot: $OUT.tar.gz ($((SECONDS - T0)) s). Next, before reprogramming: XSCT pips_cfg / pips_dma."
