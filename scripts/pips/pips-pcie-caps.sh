#!/bin/bash
# The PCIe settings along the PIPS path, read-only (experiment E6, HANDOFF §8
# "0x0A07 paper campaign"): the root port above the switch, the switch's
# ports and every device behind it. Per function: link, max payload in use
# and supported, max read request, relaxed ordering, no-snoop, extended and
# 10-bit tags, ID-based ordering (request, completion), the completion
# timeout ranges it supports and the one set, timeout disable, ACS on the
# switch's ports, and its IOMMU group, mode and driver.
#
#   bash scripts/pips/pips-pcie-caps.sh [-o DIR]
#
# Into DIR (default ~/pips-pcie-caps-<host>-<time>):
#   caps.txt         the table (also printed), caps.tsv the same as TSV
#   lspci-<bdf>.txt  lspci -vvv of each function (sudo: the capabilities)
#   host.txt         kernel, command line, IOMMU groups of the functions
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pips-lib.sh"
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "pips-pcie-caps: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-$HOME/pips-pcie-caps-$(hostname)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" || exit 1
SUDO="sudo -n"; $SUDO true 2>/dev/null || { SUDO=""; echo "pips-pcie-caps: no sudo: lspci shows no capabilities" >&2; }
echo "pips-pcie-caps $(date +%T): finding the PIPS path"
USP=$(pips_find_usp) || exit 1
FUNCS=()
p=$(dirname "$(readlink -f "/sys/bus/pci/devices/$USP")")
while [ -e "$p/vendor" ]; do FUNCS=("$(basename "$p")" ${FUNCS[@]+"${FUNCS[@]}"}); p=$(dirname "$p"); done
FUNCS+=("$USP" $(pips_below "$USP"))
echo "pips-pcie-caps $(date +%T): ${#FUNCS[@]} functions: ${FUNCS[*]}"

{
    echo "== $(hostname) $(date '+%F %T') kernel $(uname -r)"
    echo "== cmdline"; cat /proc/cmdline
    echo "== IOMMU groups"
    for b in "${FUNCS[@]}"; do
        g=/sys/bus/pci/devices/$b/iommu_group
        if [ -e "$g" ]; then
            gn=$(basename "$(readlink -f "$g")")
            echo "$b group $gn type $(cat "/sys/kernel/iommu_groups/$gn/type" 2>/dev/null) members $(ls "/sys/kernel/iommu_groups/$gn/devices" | xargs)"
        else
            echo "$b no group"
        fi
    done
} > "$OUT/host.txt" 2>&1

caps_line() {   # lspci -vvv of one function -> the fields, tab-separated
    awk '
    function flag(s, name,   r) { if (match(s, name "[+-]")) return substr(s, RSTART + length(name), 1); return "." }
    /^[[:space:]]*(DevCap|DevCtl|DevSta|LnkCap|LnkCtl|LnkSta|DevCap2|DevCtl2|DevSta2|LnkCap2|LnkCtl2|LnkSta2|ACSCap|ACSCtl|SltCap|SltCtl|SltSta|RootCap|RootCtl|RootSta):/ {
        k = $1; sub(/:$/, "", k); cur = k }
    /^[[:space:]]*Capabilities:/ { cur = "" }
    { blk[cur] = blk[cur] " " $0 }
    END {
        s = blk["LnkSta"]; sp = "-"; w = "-"
        if (match(s, /Speed [0-9.]+GT\/s/)) sp = substr(s, RSTART + 6, RLENGTH - 10)
        if (match(s, /Width x[0-9]+/)) w = substr(s, RSTART + 7, RLENGTH - 7)
        s = blk["DevCap"]; mpscap = "-"
        if (match(s, /MaxPayload [0-9]+ bytes/)) mpscap = substr(s, RSTART + 11, RLENGTH - 17)
        s = blk["DevCtl"]; mps = "-"; mrrs = "-"
        if (match(s, /MaxPayload [0-9]+/)) mps = substr(s, RSTART + 11, RLENGTH - 11)
        if (match(s, /MaxReadReq [0-9]+/)) mrrs = substr(s, RSTART + 11, RLENGTH - 11)
        ro = flag(s, "RlxdOrd"); ns = flag(s, "NoSnoop"); et = flag(s, "ExtTag")
        s = blk["DevCap2"]; ctor = "-"
        if (match(s, /Completion Timeout: [^,]*/)) { ctor = substr(s, RSTART + 20, RLENGTH - 20); gsub(/ /, "_", ctor) }
        ctdsup = flag(s, "TimeoutDis")
        s = blk["DevCtl2"]; cto = "-"
        if (match(s, /Completion Timeout: [^,]*/)) { cto = substr(s, RSTART + 20, RLENGTH - 20); gsub(/ /, "_", cto) }
        ctd = flag(s, "TimeoutDis"); idor = flag(s, "IDOReq"); idoc = flag(s, "IDOCompl"); t10 = flag(s, "10BitTagReq")
        s = blk["ACSCtl"]; acs = (s == "") ? "-" : flag(s, "SrcValid") flag(s, "ReqRedir") flag(s, "CmpltRedir") flag(s, "UpstreamFwd")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sp, w, mps, mpscap, mrrs, ro, ns, et, t10, idor, idoc, ctor, ctdsup, cto, ctd, acs }'
}
HDR="bdf\tname\tdriver\tgroup\tmode\tGT/s\twidth\tMPS\tMPScap\tMRRS\tRO\tNoSnoop\tExtTag\t10bitTag\tIDOreq\tIDOcpl\tCTO_ranges\tCTOdis_sup\tCTO_set\tCTOdis\tACS(SV,RR,CR,UF)"
printf "$HDR\n" > "$OUT/caps.tsv"
for b in "${FUNCS[@]}"; do
    timeout 20 $SUDO lspci -vvv -s "$b" > "$OUT/lspci-$b.txt" 2>&1
    name=$(lspci -s "$b" 2>/dev/null | cut -d' ' -f2- | cut -c1-40 | tr '\t' ' ')
    d=/sys/bus/pci/devices/$b
    drv=$( [ -e "$d/driver" ] && basename "$(readlink -f "$d/driver")" || echo -)
    if [ -e "$d/iommu_group" ]; then
        gn=$(basename "$(readlink -f "$d/iommu_group")"); md=$(bash "$HERE/../../utils/iommu-mode.sh" "$b" 2>/dev/null)
    else gn=-; md=off; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$b" "$name" "$drv" "$gn" "${md:-?}" "$(caps_line < "$OUT/lspci-$b.txt")" >> "$OUT/caps.tsv"
done
column -t -s $'\t' "$OUT/caps.tsv" > "$OUT/caps.txt" 2>/dev/null || cp "$OUT/caps.tsv" "$OUT/caps.txt"
cat "$OUT/caps.txt"
echo
echo "flags: + set, - clear, . not reported. CTO ranges A-D: A 50us-10ms, B 10ms-250ms, C 250ms-4s, D 4s-64s"
echo "pips-pcie-caps $(date +%T): written to $OUT"
