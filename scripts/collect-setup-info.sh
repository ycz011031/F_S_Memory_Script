#!/bin/bash
# Read-only survey of a machine, used to adapt the F&S experiment scripts to a
# local testbed. Makes no changes. Run on BOTH machines and keep the output.
#
#   bash collect-setup-info.sh                 # auto-detect the fastest NIC
#   bash collect-setup-info.sh ens2f1np1       # or name the data-plane interface
#
# Some sections need root for full output; it degrades gracefully without it.

INTF="$1"

hr() { echo; echo "=============================================================="; echo "== $1"; echo "=============================================================="; }
have() { command -v "$1" >/dev/null 2>&1; }
try() { if have "$1"; then "$@" 2>&1; else echo "[not installed: $1]"; fi; }

hr "IDENTITY"
echo "hostname : $(hostname)"
echo "user     : $(whoami)"
echo "home     : $HOME"
echo "date     : $(date -Is)"
echo "distro   : $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)"
echo "kernel   : $(uname -r)"
echo "cmdline  : $(cat /proc/cmdline 2>/dev/null)"

hr "CPU / TOPOLOGY"
# family+model decide which utils/opCode-<model>.txt Intel PCM will load.
echo "--- vendor/family/model (model number selects the PCM opCode file) ---"
awk -F: '/^vendor_id|^cpu family|^model[^ ]*[[:space:]]*:|^model name/ {gsub(/^ /,"",$2); print $1": "$2}' /proc/cpuinfo 2>/dev/null | sort -u
echo
echo "--- lscpu summary ---"
try lscpu | grep -Ei 'model name|^CPU\(s\)|Thread|Core\(s\)|Socket|NUMA node[0-9]|^NUMA node\(s\)|MHz'
echo
echo "--- full CPU->NUMA map (CPU,Core,Socket,Node) ---"
try lscpu -p=CPU,CORE,SOCKET,NODE | grep -v '^#'

hr "NETWORK INTERFACES"
if [ -z "$INTF" ]; then
    # pick the fastest link that is UP and has a driver
    best=""; bestspeed=0
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        [ "$n" = "lo" ] && continue
        [ -e "$d/device" ] || continue
        s=$(cat "$d/speed" 2>/dev/null)
        case "$s" in ''|*[!0-9]*) s=0 ;; esac
        if [ "$s" -gt "$bestspeed" ]; then bestspeed=$s; best=$n; fi
    done
    INTF="$best"
    echo "[auto-detected fastest interface: ${INTF:-none found} (${bestspeed} Mb/s)]"
    echo "[re-run with an explicit name if this is wrong]"
fi
echo
echo "--- all physical interfaces ---"
for d in /sys/class/net/*; do
    n=$(basename "$d"); [ "$n" = "lo" ] && continue; [ -e "$d/device" ] || continue
    printf '%-14s state=%-6s speed=%-8s mac=%s numa=%s\n' \
        "$n" "$(cat "$d/operstate" 2>/dev/null)" "$(cat "$d/speed" 2>/dev/null)" \
        "$(cat "$d/address" 2>/dev/null)" "$(cat "$d/device/numa_node" 2>/dev/null)"
done

if [ -n "$INTF" ]; then
    echo
    echo "--- DETAIL for $INTF ---"
    echo "NUMA node of NIC : $(cat /sys/class/net/$INTF/device/numa_node 2>/dev/null)"
    echo "PCI address      : $(basename "$(readlink -f /sys/class/net/$INTF/device 2>/dev/null)" 2>/dev/null)"
    echo "IP addresses     :"; try ip -br addr show "$INTF"
    echo "MTU              : $(cat /sys/class/net/$INTF/mtu 2>/dev/null)"
    echo
    echo "--- driver (ethtool -i) ---"; try ethtool -i "$INTF"
    echo
    echo "--- link speed (ethtool) ---"; try ethtool "$INTF" | grep -Ei 'Speed|Duplex|Link detected'
    echo
    echo "--- RING BUFFER limits (ethtool -g) -- Fig 3 sweeps RX 256..2048 ---"
    try ethtool -g "$INTF"
    echo
    echo "--- offloads (ethtool -k) ---"; try ethtool -k "$INTF" | grep -Ei 'tcp-segmentation|generic-receive|ntuple|receive-hashing'
    echo
    echo "--- channels (ethtool -l) ---"; try ethtool -l "$INTF"
fi
echo
echo "--- PCIe: network controllers ---"
try lspci -nn | grep -Ei 'ethernet|network|infiniband'
echo
echo "--- PCIe link width/speed for the NIC ---"
if [ -n "$INTF" ]; then
    pci=$(basename "$(readlink -f /sys/class/net/$INTF/device 2>/dev/null)" 2>/dev/null)
    [ -n "$pci" ] && try lspci -vv -s "$pci" | grep -Ei 'LnkCap:|LnkSta:|NUMA'
fi

hr "IOMMU"
echo "--- kernel cmdline IOMMU flags ---"
cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -Ei 'iommu|dmar' || echo "[no iommu/dmar flags on cmdline]"
echo
echo "--- IOMMU groups present? ---"
if [ -d /sys/kernel/iommu_groups ]; then
    echo "iommu_groups count: $(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"
else
    echo "[/sys/kernel/iommu_groups absent -> IOMMU off or not compiled]"
fi
echo
echo "--- dmesg (needs root) ---"
if [ "$(id -u)" -eq 0 ]; then
    dmesg 2>/dev/null | grep -iE 'dmar|iommu' | head -25
else
    echo "[re-run as root for dmesg IOMMU lines]"
fi

hr "TCP STACK"
echo "available congestion control : $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
echo "current  congestion control  : $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
echo "dctcp module                 : $(modinfo tcp_dctcp >/dev/null 2>&1 && echo available || echo MISSING)"
echo "tcp_ecn                      : $(cat /proc/sys/net/ipv4/tcp_ecn 2>/dev/null)"

hr "REQUIRED TOOLING"
for t in iperf3 netperf netserver sar sshpass screen ethtool python3 gcc make lua wrmsr modprobe taskset nice getopt ifconfig; do
    if have "$t"; then printf '  %-10s OK   %s\n' "$t" "$(command -v $t)"; else printf '  %-10s MISSING\n' "$t"; fi
done
echo
echo "--- netperf patched for tail latency? (expects MIN_LATENCY + netserver.log) ---"
if have netperf; then netperf -V 2>&1 | head -2; else echo "[netperf not installed]"; fi

hr "EXPECTED HELPER REPOS / BINARIES"
# Paths the scripts hardcode relative to \$home.
for p in "$HOME/pcm/build/bin/pcm-iio" "$HOME/pcm/build/bin/pcm-memory" \
         "$HOME/mlc/Linux/mlc" \
         "$HOME/ddio-bench/change-ddio-on" "$HOME/ddio-bench/change-ddio-off" \
         "$HOME/terabit-network-stack-profiling/network_setup.py" \
         "$HOME/Understanding-network-stack-overheads-SIGCOMM-2021/network_setup.py" \
         "$HOME/hostCC/src" \
         "$HOME/FlameGraph/flamegraph.pl" \
         "$HOME/restart.sh"; do
    if [ -e "$p" ]; then printf '  FOUND    %s\n' "$p"; else printf '  missing  %s\n' "$p"; fi
done
echo
echo "--- where is this repo checked out? ---"
echo "  script dir: $(cd "$(dirname "$0")" && pwd)"
echo "  repo root : $(cd "$(dirname "$0")/.." && pwd)"

hr "SUDO / SSH READINESS"
# The driver runs client-side commands via: ssh -> screen -dmS -> sudo bash -c
# That path has no TTY, so sudo must be NOPASSWD on the CLIENT.
echo "passwordless sudo: $(sudo -n true 2>/dev/null && echo YES || echo 'NO  <-- required on the client machine')"
echo "sshd running     : $(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo unknown)"
echo "authorized_keys  : $([ -f "$HOME/.ssh/authorized_keys" ] && wc -l < "$HOME/.ssh/authorized_keys" || echo 0) key(s)"

hr "DONE"
echo "Save this output and paste it into LOCAL-SETUP.md (Part A)."
