#!/bin/bash
# What sets a NIC host's bandwidth and its transmit pacing, read-only: each
# NIC's PCIe path to its root port, the NIC settings that shape when frames
# leave, the TCP settings, and the counters (pause, discards, retransmits).
# Written for styx (the sender: both test ports on one dual-port card, HANDOFF
# §8 "0x0A04 results" item 13); runs on icx too, for comparison.
#
#   bash scripts/nic-host-snapshot.sh [-o DIR] [IFACE ...]
#
# IFACE defaults to every mlx5 interface. Run it on the host itself (on styx:
# ssh there first). sudo (non-interactive) for lspci -vvv, dmidecode, mlnx_qos;
# without it those parts come out thinner. Nothing is written to a device.
#
# Prints a summary (paste it back), and saves into DIR (default
# ~/nic-snapshot-<host>-<time>), then DIR.tar.gz:
#   summary.txt        what is printed
#   host.txt           kernel, cmdline, lscpu, NUMA, memory DIMMs
#   path-<iface>.txt   each hop from the NIC function up to the root port:
#                      link capability and status, max payload, max read
#                      request, relaxed ordering, RCB; and lspci -vvv of each
#                      (lspci-<bdf>.txt), lspci -tv
#   kernel-pcie.txt    the kernel's "available PCIe bandwidth" lines (mlx5
#                      prints its own at probe), PCIe/mlx5 warnings
#   nic-<iface>.txt    ethtool -i/-a/-k/-l/-g/-c, link speed, ip -d link,
#                      mlnx_qos, tc -s qdisc, IRQs and their CPUs
#   tcp.txt            qdisc and TCP sysctls
#   counters.txt       ethtool -S (all) and nstat -az; run the script before
#                      and after a run to get the deltas
set -u

OUT=""
IFS_ARG=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "nic-host-snapshot: unknown option $1 (--help)" >&2; exit 2 ;;
        *) IFS_ARG+=("$1"); shift ;;
    esac
done
HOST=$(hostname)
OUT=${OUT:-$HOME/nic-snapshot-$HOST-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" || exit 1
T0=$SECONDS
NSTEP=7
step() { echo "[$1/$NSTEP] $(date +%T) +$((SECONDS - T0))s  $2" >&2; }
SUDO="sudo -n"
$SUDO true 2>/dev/null || { SUDO=""; echo "nic-host-snapshot: no passwordless sudo; lspci capabilities, dmidecode and mlnx_qos will be missing" >&2; }
SUM="$OUT/summary.txt"
say() { echo "$*" | tee -a "$SUM"; }

# Interfaces: the arguments, else every mlx5 netdev.
INTFS=("${IFS_ARG[@]}")
if [ ${#INTFS[@]} -eq 0 ]; then
    for d in /sys/class/net/*; do
        [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = mlx5_core ] && INTFS+=("$(basename "$d")")
    done
fi
[ ${#INTFS[@]} -gt 0 ] || { echo "nic-host-snapshot: no mlx5 interfaces found; name them" >&2; exit 1; }

# Raw Gbps of "<speed GT/s> <width>": 128b/130b from 8 GT/s, 8b/10b below.
raw_gbps() { awk -v s="$1" -v w="$2" 'BEGIN{ if (s == "" || w == "") { print "?"; exit }
    printf "%.0f", s * w * ((s >= 8) ? 128/130 : 0.8) }'; }

# One line per hop from an lspci -vvv dump: cap and status of the link,
# payload, read request, relaxed ordering, extended tags, RCB.
hop_line() {
    awk '
    /LnkCap:/ { for (i = 1; i <= NF; i++) { if ($i == "Speed") cs = $(i+1); if ($i == "Width") cw = $(i+1) } }
    /LnkSta:/ { for (i = 1; i <= NF; i++) { if ($i == "Speed") ss = $(i+1); if ($i == "Width") sw = $(i+1) } }
    /LnkCtl:/ { if (match($0, /RCB [0-9]+ bytes/)) rcb = substr($0, RSTART + 4, RLENGTH - 10) }
    /DevCap:/ { if (match($0, /MaxPayload [0-9]+ bytes/)) mpscap = substr($0, RSTART + 11, RLENGTH - 17) }
    /DevCtl:/ { ctl = 1 }
    ctl && /RlxdOrd/ { ro = ($0 ~ /RlxdOrd\+/) ? "on" : "off"; et = ($0 ~ /ExtTag\+/) ? "on" : "off" }
    ctl && /MaxReadReq/ {
        if (match($0, /MaxPayload [0-9]+/)) mps = substr($0, RSTART + 11, RLENGTH - 11)
        if (match($0, /MaxReadReq [0-9]+/)) mrrs = substr($0, RSTART + 11, RLENGTH - 11)
        ctl = 0 }
    END {
        gsub(/[,GT\/s]/, "", cs); gsub(/[,GT\/s]/, "", ss); gsub(/[,x]/, "", cw); gsub(/[,x]/, "", sw)
        printf "%s %s %s %s %s %s %s %s %s %s\n", (ss ? ss : "-"), (sw ? sw : "-"), (cs ? cs : "-"), (cw ? cw : "-"),
            (mps ? mps : "-"), (mpscap ? mpscap : "-"), (mrrs ? mrrs : "-"), (ro ? ro : "-"), (et ? et : "-"), (rcb ? rcb : "-") }'
}

say "nic-host-snapshot  $HOST  $(date '+%F %T')  kernel $(uname -r)"
say "interfaces: ${INTFS[*]}"

step 1 "host: CPU, NUMA, memory"
{
    echo "== uname";   uname -a
    echo "== cmdline"; cat /proc/cmdline
    echo "== lscpu";   lscpu
    echo "== numa";    (command -v numactl >/dev/null && numactl -H) || ls /sys/devices/system/node
    echo "== memory DIMMs (dmidecode -t 17)"
    [ -n "$SUDO" ] && $SUDO dmidecode -t 17 2>/dev/null | grep -E '^\s*(Locator|Size|Speed|Configured (Memory|Clock) Speed|Type):'
} > "$OUT/host.txt" 2>&1
CPU=$(lscpu | awk -F: '/Model name/{sub(/^ +/, "", $2); print $2; exit}')
SOCK=$(lscpu | awk -F: '/Socket\(s\)/{gsub(/ /, "", $2); print $2}')
CORES=$(lscpu | awk -F: '/Core\(s\) per socket/{gsub(/ /, "", $2); print $2}')
DIMMS=$(grep -cE '^\s*Size: [0-9]+ (GB|MB)' "$OUT/host.txt")
DSPD=$(grep -E '^\s*Configured (Memory|Clock) Speed: [0-9]' "$OUT/host.txt" | awk '{print $(NF-1)" "$NF}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
say "cpu: $CPU, $SOCK socket(s) x $CORES cores; DIMMs populated: $DIMMS (configured speed: ${DSPD:-unknown})"

step 2 "PCIe path of each interface up to its root port (lspci -vvv)"
lspci -tv > "$OUT/lspci-tree.txt" 2>&1
say ""
say "PCIe path, NIC first (status = now, cap = most; MPS/MRRS bytes; raw Gbps of status)"
say "$(printf '  %-12s %-14s %-9s %-9s %-6s %-11s %-6s %-5s %-6s %-4s %s' iface bdf status cap raw_Gbps mps/mpscap mrrs relord exttag rcb device)"
for i in "${INTFS[@]}"; do
    dev=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || { say "  $i: no device"; continue; }
    p=$dev
    : > "$OUT/path-$i.txt"
    while [ -n "$p" ] && [ -e "$p/vendor" ]; do
        b=$(basename "$p")
        [ -f "$OUT/lspci-$b.txt" ] || timeout 20 $SUDO lspci -vvv -s "$b" > "$OUT/lspci-$b.txt" 2>&1
        read -r ss sw cs cw mps mpscap mrrs ro et rcb <<< "$(hop_line < "$OUT/lspci-$b.txt")"
        name=$(lspci -s "$b" 2>/dev/null | cut -d' ' -f2- | cut -c1-60)
        line=$(printf '  %-12s %-14s %-9s %-9s %-6s %-11s %-6s %-5s %-6s %-4s %s' "$i" "$b" "${ss}/x${sw}" "${cs}/x${cw}" \
               "$(raw_gbps "$ss" "$sw")" "$mps/$mpscap" "$mrrs" "$ro" "$et" "$rcb" "$name")
        say "$line"
        echo "$line" >> "$OUT/path-$i.txt"
        p=$(dirname "$p")
    done
    pn=$(grep -m1 -E 'Part number|\[PN\]' "$OUT/lspci-$(basename "$dev").txt" 2>/dev/null | sed 's/.*: *//')
    prod=$(grep -m1 'Product Name' "$OUT/lspci-$(basename "$dev").txt" 2>/dev/null | sed 's/.*: *//')
    say "  $i: card ${prod:-?} ${pn:+(PN $pn)}; NUMA node $(cat "$dev/numa_node" 2>/dev/null), local CPUs $(cat "$dev/local_cpulist" 2>/dev/null)"
done
say "  ports sharing one PCIe function tree (same bus, other function) share its link:"
for i in "${INTFS[@]}"; do
    b=$(basename "$(readlink -f "/sys/class/net/$i/device" 2>/dev/null)")
    say "    $i -> ${b%.*}.*  ($(ls -d /sys/bus/pci/devices/${b%.*}.* 2>/dev/null | wc -l) functions on that device)"
done

step 3 "the kernel's PCIe bandwidth lines and warnings"
{
    echo "== available PCIe bandwidth (dmesg, then journal of this boot)"
    ($SUDO dmesg 2>/dev/null || dmesg 2>/dev/null) | grep -iE 'available PCIe bandwidth|limited by|PCIe link'
    (journalctl -k -b --no-pager 2>/dev/null || true) | grep -iE 'available PCIe bandwidth|limited by' | tail -20
    echo "== mlx5 / pcieport / AER lines of this boot"
    ($SUDO dmesg 2>/dev/null || dmesg 2>/dev/null) | grep -iE 'mlx5|pcieport|AER' | tail -80
} > "$OUT/kernel-pcie.txt" 2>&1
say ""
say "kernel: available PCIe bandwidth"
grep -iE 'available PCIe bandwidth' "$OUT/kernel-pcie.txt" | sed 's/^\[[^]]*\] *//' | sort -u | head -8 | sed 's/^/  /' | tee -a "$SUM"
grep -qi 'available PCIe bandwidth' "$OUT/kernel-pcie.txt" || say "  (none in dmesg or this boot's journal)"

step 4 "NIC settings: link, pause, offloads, channels, rings, coalescing, mlnx_qos, qdisc, IRQs"
say ""
say "NIC settings"
for i in "${INTFS[@]}"; do
    f="$OUT/nic-$i.txt"
    {
        echo "== ethtool -i";  ethtool -i "$i"
        echo "== ethtool";     ethtool "$i"
        echo "== ethtool -a";  ethtool -a "$i"
        echo "== ethtool -k";  ethtool -k "$i"
        echo "== ethtool -l";  ethtool -l "$i"
        echo "== ethtool -g";  ethtool -g "$i"
        echo "== ethtool -c";  ethtool -c "$i"
        echo "== ip -d link";  ip -d link show "$i"
        echo "== mlnx_qos";    command -v mlnx_qos >/dev/null && timeout 20 $SUDO mlnx_qos -i "$i"
        echo "== tc -s qdisc"; tc -s qdisc show dev "$i"
        echo "== IRQs (number, CPUs, name)"
        dev=$(basename "$(readlink -f "/sys/class/net/$i/device")")
        grep -E "$i|$dev" /proc/interrupts | while read -r irq _; do
            irq=${irq%:}
            echo "  $irq $(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null) $(grep -E "^ *$irq:" /proc/interrupts | awk '{print $NF}')"
        done
    } > "$f" 2>&1
    sect() { awk -v s="== $1" '$0 == s {on=1; next} /^== /{on=0} on' "$f"; }   # one command's output
    spd=$(sect ethtool | awk -F': ' '/Speed:/{print $2; exit}')
    fw=$(sect "ethtool -i" | awk -F': ' '/^firmware-version/{print $2; exit}')
    drv=$(sect "ethtool -i" | awk -F': ' '/^version/{print $2; exit}')
    pause=$(sect "ethtool -a" | awk -F':' 'NF == 2 {gsub(/[ \t]/, "", $2); if ($2 != "") printf "%s=%s ", $1, $2}')
    offl=$(sect "ethtool -k" | awk -F': ' '
        BEGIN { n["tcp-segmentation-offload"]="tso"; n["generic-segmentation-offload"]="gso"; n["generic-receive-offload"]="gro"
                n["large-receive-offload"]="lro"; n["rx-checksumming"]="rxcsum"; n["tx-checksumming"]="txcsum" }
        ($1 in n) { v=$2; sub(/ .*/, "", v); printf "%s=%s ", n[$1], v }')
    ch=$(sect "ethtool -l" | awk '/Current hardware settings/{c=1} c && /^Combined:/{print $2; exit}')
    rg=$(sect "ethtool -g" | awk '/Current hardware settings/{c=1} c && /^RX:/{rx=$2} c && /^TX:/{print "rx " rx " tx " $2; exit}')
    co=$(sect "ethtool -c" | awk '/^Adaptive/{gsub(/[ \t]+/, " "); printf "%s; ", $0} /^(rx-usecs|tx-usecs|rx-frames|tx-frames):/{printf "%s%s ", $1, $2}')
    mtu=$(sect "ip -d link" | awk '{for(n=1;n<=NF;n++) if($n=="mtu") {print $(n+1); exit}}')
    gso=$(sect "ip -d link" | awk '{for(n=1;n<=NF;n++) if($n=="gso_max_size") {print $(n+1); exit}}')
    # mlnx_qos: "tc: N ratelimit: R, tsa: T" then the priorities it carries
    rl=$(sect mlnx_qos | awk '
        /^tc: / { if (t != "") printf "tc%s %s [prio%s]; ", t, r, p; t=$2; r=$4; sub(/,$/, "", r); if ($5 ~ /bps/) { u=$5; sub(/,$/, "", u); r = r u }; p="" }
        /^[ \t]*priority:/ && t != "" { for (n = 2; n <= NF; n++) p = p " " $n }
        END { if (t != "") printf "tc%s %s [prio%s]", t, r, p }')
    qd=$(sect "tc -s qdisc" | awk '$1 == "qdisc" {print $2}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
    irqc=$(sect "IRQs (number, CPUs, name)" | awk '{print $2}' | sort -u | tr '\n' ' ' | cut -c1-80)
    say "  $i: $spd, mtu $mtu, gso_max_size ${gso:-?}; driver $drv fw $fw"
    say "      pause: ${pause:-?}; $offl"
    say "      channels $ch, rings $rg; coalescing: $co"
    say "      qdisc: ${qd:-?}"
    say "      mlnx_qos: ${rl:-not available}"
    say "      IRQ CPUs: ${irqc:-?}"
done

step 5 "TCP and qdisc sysctls"
{
    for k in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control \
             net.ipv4.tcp_ecn net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf \
             net.ipv4.tcp_limit_output_bytes net.ipv4.tcp_min_tso_segs net.ipv4.tcp_tso_win_divisor \
             net.ipv4.tcp_pacing_ss_ratio net.ipv4.tcp_pacing_ca_ratio net.core.wmem_max net.core.rmem_max; do
        echo "$k = $(sysctl -n "$k" 2>/dev/null)"
    done
    echo "== cpufreq governor / driver"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null
} > "$OUT/tcp.txt" 2>&1
say ""
say "TCP: $(grep -E 'default_qdisc|tcp_congestion_control =|tcp_ecn|tcp_wmem|tcp_rmem|tcp_limit_output' "$OUT/tcp.txt" | sed 's/net\.\(core\|ipv4\)\.//' | tr '\n' ';' | tr -s ' ')"
say "     governor: $(sed -n 1p /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo ?)"

step 6 "counters: ethtool -S, nstat"
{
    for i in "${INTFS[@]}"; do echo "== ethtool -S $i"; ethtool -S "$i"; done
    echo "== nstat -az"; (command -v nstat >/dev/null && nstat -az) || cat /proc/net/snmp
} > "$OUT/counters.txt" 2>&1
say ""
say "counters now (cumulative since driver load; diff two snapshots around a run)"
for i in "${INTFS[@]}"; do
    c=$(awk -v ifc="$i" '$0 == "== ethtool -S " ifc {on=1; next} /^== /{on=0}
        on && /(pause|discard|out_of_buffer|tx_packets_phy|tx_bytes_phy|rx_packets_phy|tx_queue_stopped|tx_queue_dropped|rx_buffer_passed_thres)/ && $2 != 0 {
            gsub(/:/, "", $1); printf "%s=%s ", $1, $2}' "$OUT/counters.txt")
    say "  $i: ${c:-(all zero)}"
done
say "  TCP: $(awk '/^(TcpRetransSegs|TcpExtTCPLostRetransmit|TcpOutSegs) /{printf "%s=%s ", $1, $2}' "$OUT/counters.txt")"

step 7 "pack"
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && \
    echo "saved: $OUT/ and $OUT.tar.gz ($(du -h "$OUT.tar.gz" | cut -f1))" >&2
