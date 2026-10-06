# Helpers shared by run-dualssd-experiment.sh, dualssd_sweep.sh and
# discover-ssd-pcie.sh. Sourced, not run. Safe under `set -u`.

# ssd_resolve <serial>: set SSD_DEV (/dev/nvmeXnY) and SSD_BDF (PCI function).
#
# Drives are named by serial because /dev/nvmeN follows probe order, which can
# change across the reboots every strict/off comparison needs. On bigserver a
# stale /dev name could land on nvme2-5, which are someone's RAID members.
ssd_resolve() {
    local s="$1" c l n=0 links=()
    SSD_DEV=""; SSD_BDF=""
    for c in /sys/class/nvme/nvme*; do
        [ -e "$c/serial" ] || continue
        [ "$(xargs < "$c/serial")" = "$s" ] || continue
        SSD_BDF=$(basename "$(readlink -f "$c/device")")
        n=$((n + 1))
    done
    # nvme-<model>_<serial> is the namespace-1 disk; the _1 twin is the same disk.
    for l in /dev/disk/by-id/nvme-*_"$s"; do
        [ -e "$l" ] && links+=( "$l" )
    done
    if [ "$n" -ne 1 ] || [ "${#links[@]}" -ne 1 ]; then
        echo "ERROR: no unique NVMe drive with serial $s" \
             "($n controller(s), ${#links[@]} /dev/disk/by-id link(s))." >&2
        echo "  List drives with:  sudo nvme list" >&2
        return 1
    fi
    SSD_DEV=$(readlink -f "${links[0]}")
}

# IOMMU (DMAR) unit a PCI function is behind, e.g. dmar7; "none" when the
# IOMMU is off. Devices on the same unit share its IOTLB and invalidation queue.
iommu_unit() {
    local l="/sys/bus/pci/devices/$1/iommu"
    if [ -e "$l" ]; then basename "$(readlink -f "$l")"; else echo none; fi
}

# relaunch_in_tmux <script> [args...]: run <script> in a new tmux session
# instead of this terminal, so it survives a dropped ssh connection. Does not
# return. sudo caches the password per terminal and a tmux pane is a new one,
# so the session asks for it first, then runs the script, then keeps the
# window open on its final output.
relaunch_in_tmux() {
    local script="$1"; shift
    command -v tmux >/dev/null 2>&1 || {
        echo "ERROR: --tmux given, but tmux is not installed. Run without --tmux." >&2; exit 1; }
    local base name k=1 launcher
    base=$(basename "$script" .sh); base=${base//_/-}
    name="$base-1"
    while tmux has-session -t "=$name" 2>/dev/null; do k=$((k + 1)); name="$base-$k"; done

    launcher=$(mktemp /tmp/dualssd-tmux.XXXXXX)
    {
        echo '#!/bin/bash'
        echo 'rm -f "$0"'
        printf 'cd %q || exit 1\n' "$PWD"
        # A running tmux server does not pass this shell's environment on.
        local v
        for v in DUALSSD_ARGS RESULTS_DIR SWEEP_PREFIX; do
            [ -n "${!v+x}" ] && printf 'export %s=%q\n' "$v" "${!v}"
        done
        echo "echo \"== tmux session $name: enter your sudo password to start\""
        echo 'sudo -v || { echo "sudo failed; nothing was run."; exec bash; }'
        printf 'bash %q' "$script"; [ $# -gt 0 ] && printf ' %q' "$@"; echo
        echo 'rc=$?'
        echo "echo; echo \"[$name finished with status \$rc at \$(date '+%F %T'). This window stays open; type exit to close it.]\""
        echo 'exec bash'
    } > "$launcher"

    echo "Starting $(basename "$script") in tmux session '$name'."
    echo "  It asks for your sudo password first."
    echo "  Detach, leaving it running:  Ctrl-b, then d"
    echo "  Re-attach later:             tmux attach -t $name"
    echo "  Its log path is printed at the top of its output."
    if [ -n "${TMUX:-}" ]; then
        tmux new-session -d -s "$name" "bash $launcher" && tmux switch-client -t "=$name"
    elif [ -t 0 ] && [ -t 1 ]; then
        tmux new-session -s "$name" "bash $launcher"
    else
        tmux new-session -d -s "$name" "bash $launcher" \
            && echo "  No terminal here: attach with 'tmux attach -t $name' to enter the password."
    fi
    exit $?
}

# PCI functions from the root port down to <bdf>, one per line.
pci_chain() {
    readlink -f "/sys/bus/pci/devices/$1" | tr '/' '\n' \
        | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$'
}

# "8GT/s x16" for a bdf, from its LnkSta line. lspci needs root to show it.
bdf_link() {
    sudo -n lspci -vv -s "$1" 2>/dev/null | awk '/LnkSta:/{
        for (n = 1; n <= NF; n++) { if ($n == "Speed") s = $(n+1); if ($n == "Width") w = $(n+1) }
        gsub(/,/, "", s); gsub(/,/, "", w); print s " " w; exit }'
}

# Usable Gbps for a "<speed> <width>" pair. 8GT/s and up use 128b/130b
# encoding; 2.5 and 5 GT/s use 8b/10b.
link_gbps() {
    local s="${1:-}" w="${2:-}"
    s="${s%GT/s}"; w="${w#x}"
    case "$s$w" in ''|*[!0-9.]*) echo 0; return ;; esac
    awk -v s="$s" -v w="$w" 'BEGIN{ printf "%d", s*w*((s+0>=8)?128/130:0.8) }'
}

# Narrowest PCIe link, in Gbps, on the path shared by all the given devices:
# for one device its whole path, for several only the hops they have in
# common (on bigserver, the Gen3 root port b0:00.0 to the switch above both
# drives). Combined PCIe traffic cannot exceed it. 0 if unknown.
shared_link_gbps() {   # <bdf>...
    local common b g min=0
    common=$(pci_chain "$1" | sort)
    shift
    for b in "$@"; do
        common=$(comm -12 <(printf '%s\n' "$common") <(pci_chain "$b" | sort))
    done
    for b in $common; do
        g=$(link_gbps $(bdf_link "$b"))
        [ "$g" -gt 0 ] || continue
        if [ "$min" -eq 0 ] || [ "$g" -lt "$min" ]; then min=$g; fi
    done
    echo "$min"
}

# Column number of event <name> in a pcm-iio CSV, from its "Date,Time,..."
# header row; <fallback> when there is no header or no such column.
csv_col() {   # <csv> <name> <fallback>
    local c
    c=$(awk -F ',' -v n="$2" '$1 == "Date" {
            for (i = 1; i <= NF; i++) { f = $i; gsub(/^ +| +$/, "", f); if (f == n) { print i; exit } }
            exit }' "$1" 2>/dev/null)
    echo "${c:-$3}"
}
