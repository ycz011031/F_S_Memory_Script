#!/bin/bash
# Map NICs -> PCIe root complex -> pcm-iio stack label, so PCIE_PATTERN for each
# NIC can be set without guessing. Read-only.
#
#   sudo bash discover-pcie-topology.sh                       # all NICs with a driver
#   sudo bash discover-pcie-topology.sh enp153s0f0np0 enp154s0np0
#
# Needs root for pcm-iio. Sources setup-server.sh for PCM_DIR if present.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/setup-server.sh" ] && . "$HERE/setup-server.sh" 2>/dev/null

# Locate pcm-iio: config, then PATH, then the usual build spots.
PCM_IIO=""
for c in "${PCM_DIR:-}/build/bin/pcm-iio" "$(command -v pcm-iio 2>/dev/null)" \
         "$HOME/pcm/build/bin/pcm-iio" /usr/local/bin/pcm-iio /opt/pcm/bin/pcm-iio; do
    [ -n "$c" ] && [ -x "$c" ] && { PCM_IIO="$c"; break; }
done

INTFS=("$@")
if [ ${#INTFS[@]} -eq 0 ]; then
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        [ "$n" = "lo" ] && continue
        [ -e "$d/device" ] || continue
        INTFS+=("$n")
    done
fi

echo "=============================================================="
echo "== 1. NIC -> PCI -> root complex (from sysfs, no root needed)"
echo "=============================================================="
printf '%-16s %-14s %-5s %-8s %-13s %-8s %s\n' \
    IFACE PCI NUMA SPEED ROOT_PORT LINK SWITCHED
RPFILE=$(mktemp)
for i in "${INTFS[@]}"; do
    dev=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || continue
    pci=$(basename "$dev")
    numa=$(cat "/sys/class/net/$i/device/numa_node" 2>/dev/null)
    speed=$(cat "/sys/class/net/$i/speed" 2>/dev/null)

    # Split the sysfs chain: .../pci0000:96/0000:96:02.0/0000:97:00.0/.../0000:99:00.0
    # The FIRST bdf after the root complex is the root port -- that is what
    # determines the pcm-iio IIO stack and Part. Anything between it and the
    # NIC is a PCIe switch.
    chain=$(printf '%s' "$dev" | tr '/' '\n' | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:' )
    rport=$(printf '%s\n' "$chain" | head -1)
    hops=$(printf '%s\n' "$chain" | grep -c .)
    if [ "$hops" -gt 2 ]; then sw="yes ($((hops-2)) hop)"; else sw="no"; fi

    # LnkSta: Speed 16GT/s (ok), Width x16 (ok)  -> want speed AND width
    link=$(lspci -vv -s "$pci" 2>/dev/null \
           | awk '/LnkSta:/{for(n=1;n<=NF;n++){if($n=="Speed")s=$(n+1);if($n=="Width")w=$(n+1)};
                            gsub(/,/,"",s); gsub(/,/,"",w); print s"/"w; exit}')
    printf '%-16s %-14s %-5s %-8s %-13s %-8s %s\n' \
        "$i" "$pci" "${numa:--}" "${speed:--}" "${rport:--}" "${link:-?}" "$sw"
    [ -n "$rport" ] && echo "$rport $i" >> "$RPFILE"
done

echo
echo "  -- root-port sharing --"
# NICs behind the same ROOT PORT cannot be separated by pcm-iio at all:
# same IIO stack (kills the IOMMU counters, which are per-stack totals) AND
# same Part (kills per-NIC IB/OB bandwidth, which is per-Part).
awk '{rp=$1; nic=$2; map[rp]=(rp in map)?map[rp]" "nic:nic; cnt[rp]++}
     END{ shared=0
          for (rp in cnt) {
            if (cnt[rp] > 1) { shared=1
              printf "  SHARED  %s  <-  %s\n", rp, map[rp]
            } else printf "  alone   %s  <-  %s\n", rp, map[rp]
          }
          if (shared) {
            print ""
            print "  NICs on a SHARED root port give aggregate counters ONLY:"
            print "    - IOMMU events are per-stack  (ch_mask=0x0, vname=Total)"
            print "    - IB/OB bandwidth is per-Part, and one root port is one Part"
            print "  Use ONE PCIE_PATTERN for them and treat all pcm-iio numbers as"
            print "  the sum over both NICs. Per-NIC data must come from iperf3."
            print "  They also share that root ports bandwidth -- check LINK above."
          }
        }' "$RPFILE"
rm -f "$RPFILE"

echo
echo "=============================================================="
echo "== 2. Root port chain per NIC"
echo "=============================================================="
for i in "${INTFS[@]}"; do
    dev=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || continue
    echo "$i:"
    printf '%s' "$dev" | tr '/' '\n' | grep -E '^(pci)?[0-9a-f]{4}:' | sed 's/^/    /'
done

if [ -z "$PCM_IIO" ]; then
    echo
    echo "=============================================================="
    echo "== 3. pcm-iio  [SKIPPED - binary not found]"
    echo "=============================================================="
    echo "  Looked in: \$PCM_DIR/build/bin, \$PATH, ~/pcm/build/bin,"
    echo "             /usr/local/bin, /opt/pcm/bin"
    echo "  Re-run as:  sudo PCM_DIR=/path/to/pcm bash $0 $*"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "== 3. pcm-iio  [SKIPPED - needs root].  Re-run with sudo."
    exit 0
fi

TMP=$(mktemp -d /tmp/pcie-topo.XXXXXX)
modprobe msr 2>/dev/null

# pcm-iio loads its event definitions from opCode-<family>-<model>.txt in the
# CURRENT directory. Run from anywhere else it silently falls back to defaults
# that omit the IOMMU events, so the CSV columns shift and IOTLB/PWC data goes
# missing without an error. record-host-metrics.sh gets this right only because
# the runners cd into utils/ first; do the same here.
cd "$HERE" || { echo "cannot cd to $HERE"; exit 1; }

fam=$(awk -F: '/^cpu family/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
mod=$(awk -F: '/^model[[:space:]]*:/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)

echo
echo "=============================================================="
echo "== 3. pcm-iio CSV: the exact Socket,Stack,Part strings"
echo "=============================================================="
echo "  (these are what record-host-metrics.sh greps for as PCIE_PATTERN)"
echo "  cwd for pcm-iio : $HERE"
echo "  CPU             : family $fam model $mod"
if [ -f "opCode-$fam-$mod.txt" ]; then
    echo "  event file      : opCode-$fam-$mod.txt  [FOUND]"
elif [ -f "opCode-$mod.txt" ]; then
    echo "  event file      : opCode-$mod.txt  [found, older naming]"
else
    echo "  event file      : opCode-$fam-$mod.txt  [** MISSING **]"
    echo "                    IOMMU columns will be absent and column offsets"
    echo "                    will not match parse_pciebw. Fix before trusting."
fi
echo
"$PCM_IIO" 1 -csv="$TMP/pcie.csv" >/dev/null 2>&1 &
sleep 6; pkill -f pcm-iio >/dev/null 2>&1; sleep 1

if [ -s "$TMP/pcie.csv" ]; then
    echo "--- header (column order for parse_pciebw) ---"
    head -2 "$TMP/pcie.csv"
    echo
    echo "--- unique Socket,Stack,Part rows ---"
    cut -d, -f1-3 "$TMP/pcie.csv" | grep -i socket | sort -u | sed 's/^/    /'
    cp "$TMP/pcie.csv" ./pcie-topology.csv 2>/dev/null && \
        echo && echo "  full CSV saved to: $(pwd)/pcie-topology.csv"
else
    echo "  [pcm-iio produced no CSV -- check that msr is loaded and NMI watchdog off]"
fi

echo
echo "=============================================================="
echo "== 4. pcm-iio text: which stack each NIC hangs off"
echo "=============================================================="
"$PCM_IIO" 1 > "$TMP/pcie.txt" 2>&1 &
sleep 6; pkill -f pcm-iio >/dev/null 2>&1; sleep 1

if [ -s "$TMP/pcie.txt" ]; then
    for i in "${INTFS[@]}"; do
        pci=$(basename "$(readlink -f "/sys/class/net/$i/device" 2>/dev/null)" 2>/dev/null)
        [ -z "$pci" ] && continue
        short=${pci#0000:}                      # pcm-iio often prints bb:dd.f
        # Walk the text, remembering the most recent Socket / Stack / Part header,
        # and report them when the NIC's BDF appears.
        awk -v bdf="$short" -v full="$pci" -v iface="$i" '
            /[Ss]ocket[ ]*[0-9]/ { if (match($0,/[Ss]ocket[ ]*[0-9]+/)) sock=substr($0,RSTART,RLENGTH) }
            /IIO Stack/          { if (match($0,/IIO Stack[ ]*[0-9]+[ ]*-[ ]*[A-Za-z0-9]+/)) stack=substr($0,RSTART,RLENGTH) }
            /Part[0-9]/          { if (match($0,/Part[0-9]+/)) part=substr($0,RSTART,RLENGTH) }
            index($0,bdf) || index($0,full) {
                printf "  %-16s -> %s | %s | %s\n", iface, (sock?sock:"?"), (stack?stack:"?"), (part?part:"?")
                found=1; exit
            }
            END { if (!found) printf "  %-16s -> not found in pcm-iio text output\n", iface }
        ' "$TMP/pcie.txt"
    done
    cp "$TMP/pcie.txt" ./pcie-topology.txt 2>/dev/null && \
        echo && echo "  full text saved to: $(pwd)/pcie-topology.txt"
    echo
    echo "  Build each PCIE_PATTERN as:  \"Socket<N>,IIO Stack <M> - <PCIeK>,Part<P>\""
    echo "  Cross-check the spelling against the unique rows in section 3 --"
    echo "  the CSV form is authoritative, since that is what gets grepped."
else
    echo "  [no text output from pcm-iio]"
fi

rm -rf "$TMP"
echo
echo "Send sections 1, 3 and 4 back to set PCIE_PATTERN per NIC."
