# Helpers shared by pips-bringup.sh and pips-fio-log.sh. Sourced, not run.
# Safe under `set -u`.

PIPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPS_REPO=$(cd "$PIPS_DIR/../.." && pwd)
PIPS="${PIPS_TOOL:-$PIPS_DIR/pips}"     # PIPS_TOOL: use another binary (e.g. pips-sim)

die() { echo "ERROR: $*" >&2; exit 1; }

# Build the pips tool if it is missing or older than its sources.
pips_build() {
    [ -n "${PIPS_TOOL:-}" ] && return 0
    if [ ! -x "$PIPS" ] || [ "$PIPS_DIR/pips.c" -nt "$PIPS" ] || [ "$PIPS_DIR/pips_regs.h" -nt "$PIPS" ]; then
        echo "building $PIPS"
        make -s -C "$PIPS_DIR" pips || return 1
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$PIPS"
    fi
    return 0
}

# BDF of the PIPS upstream port (10ee:b048). Fails if there is none or several.
pips_find_usp() {
    local d found=()
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10ee ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = 0xb048 ] && found+=( "$(basename "$d")" )
    done
    if [ ${#found[@]} -eq 1 ]; then echo "${found[0]}"; return 0; fi
    if [ ${#found[@]} -eq 0 ]; then
        echo "ERROR: no PIPS upstream port (10ee:b048). FPGA not programmed, or not rescanned:" >&2
        echo "  echo 1 | sudo tee /sys/bus/pci/rescan;  lspci -nn -d 10ee:" >&2
    else
        echo "ERROR: several PIPS upstream ports (${found[*]}): pick one with --bdf" >&2
    fi
    return 1
}

# Every PCI function below the upstream port, in BDF order (ports before devices).
pips_below() {
    local d
    for d in /sys/bus/pci/devices/*; do
        case "$(readlink -f "$d")" in */"$1"/*) basename "$d" ;; esac
    done | sort
}

# /dev/nvmeXnY namespaces whose controller sits below the upstream port.
# Under native NVMe multipath the disk hangs off nvme-subsystem; follow a path.
pips_nvme_below() {
    local b n p m
    for b in /sys/class/block/nvme*n*; do
        [ -e "$b" ] || continue
        n=$(basename "$b")
        [[ $n =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        p=$(readlink -f "$b")
        case "$p" in
            */nvme-subsystem/*) for m in "$b/multipath/"*; do p=$(readlink -f "$m"); break; done ;;
        esac
        case "$p" in */"$1"/*) echo "/dev/$n" ;; esac
    done
}

# PCI function a block device's controller is, e.g. 0000:99:00.0 for nvme0n1.
blk_bdf() {
    local n p m
    n=$(basename "$1")
    p=$(readlink -f "/sys/class/block/$n" 2>/dev/null)
    case "$p" in
        */nvme-subsystem/*) for m in "/sys/class/block/$n/multipath/"*; do p=$(readlink -f "$m"); break; done ;;
    esac
    printf '%s' "$p" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1
}

# One line from `lspci -vv` of a function: link (and its capability), MPS/MRRS
# in use, and error bits that are set. Needs root for the capabilities.
#
# A link trains to the lower of its two ends, so it is DEGRADED only when it
# is below what both ends can do: a Gen4 switch port on a Gen3 root port, or
# an x8 port with an x4 drive, is normal. Error bits are sticky: set at any
# time since boot or since software last cleared them, not necessarily now.
lspci_brief() {
    local partner pcap=""
    partner=$(link_partner "$1")
    [ -n "$partner" ] && pcap=$(lspci -vv -s "$partner" 2>/dev/null | awk "$LSPCI_LINK_AWK"'
        /LnkCap:/ { print grab($0); exit }')
    lspci -vv -s "$1" 2>/dev/null | awk -v pcap="$pcap" "$LSPCI_LINK_AWK"'
        function num(s) { gsub(/[^0-9.]/, "", s); return s + 0 }
        /LnkCap:/ { cap = grab($0) }
        /LnkSta:/ { sta = grab($0) }
        /^[ \t]+MaxPayload [0-9]+ bytes, MaxReadReq/ { mps = $2; mrrs = $5 }
        /DevSta:|UESta:|CESta:/ { tag = $1; for (i = 2; i <= NF; i++)
            if ($i ~ /\+$/ && $i !~ /^(AuxPwr|TransPend)/) err = err " " tag $i }
        END {
            if (sta == "") printf "link ?"
            else {
                split(sta, a, " "); split(cap, c, " "); ms = num(c[1]); mw = num(c[2])
                if (pcap != "") { split(pcap, p, " ")
                    if (num(p[1]) < ms) ms = num(p[1]); if (num(p[2]) < mw) mw = num(p[2]) }
                printf "link %s", sta
                if (num(a[1]) < ms || num(a[2]) < mw)
                    printf " DEGRADED: both ends can do %gGT/s x%d", ms, mw
                else if (sta != cap)
                    printf " (this end can do %s%s)", cap, pcap != "" ? ", the other end cannot" : ""
            }
            printf "  MPS %s MRRS %s", mps == "" ? "?" : mps, mrrs == "" ? "?" : mrrs
            printf "  error bits (sticky):%s\n", err == "" ? " none" : err
        }'
}
LSPCI_LINK_AWK='
    function grab(line,   i, n, f, s, w) { n = split(line, f, /[ \t,]+/)
        for (i = 1; i < n; i++) { if (f[i] == "Speed") s = f[i+1]; if (f[i] == "Width") w = f[i+1] }
        return s " " w }'

# The function at the other end of a function's link: below a root or
# downstream port, the device on its secondary bus; above anything else, the
# port it hangs off. Empty if there is none or lspci cannot tell (not root).
link_partner() {
    local d
    case "$(lspci -vv -s "$1" 2>/dev/null | grep -oE 'Express \(v[0-9]\) [A-Za-z ]+' | head -1)" in
        *"Root Port"*|*"Downstream Port"*)
            for d in /sys/bus/pci/devices/"$1"/????:??:??.0; do
                [ -e "$d" ] && { basename "$d"; return 0; }
            done ;;
        *)
            d=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")")
            [[ $d =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] && echo "$d" ;;
    esac
    return 0
}

# Batcher setting from `pips cfg`: cfg_of <file> -> 0x..., pips_tag <cfg> ->
# d<depth>t<time>, plus m1 with batch_mrd (names results and sweeps).
cfg_of() { sed -n 's/^cfg=\(0x[0-9a-f]*\).*/\1/p' "$1"; }
pips_tag() {
    local v=$(( $1 ))
    printf 'd%dt%d%s\n' $(( v & 0xFF )) $(( (v >> 8) & 0xFF )) "$( (( (v >> 16) & 1 )) && echo m1)"
}

# Kernel log lines that report a PCIe, IOMMU or NVMe problem. Not the boot-time
# "_OSC: platform does not support [... AER ... DPC]" or "nvme ...: Shutdown
# timeout set to 10 seconds" lines.
PIPS_KERNEL_ERR_RE='AER: |DPC: |DMAR: \[DMA|DMAR:.*[Ff]ault|pciehp.*(Link Down|Card not present)|nvme.*(timeout, |controller is down|[Rr]eset(ting)? controller|I/O error|failed|Removing)'

# BAR0 of a function as the kernel holds it: prints "<start> <bytes>" (hex
# start, decimal size), start 0 when the BAR is not assigned.
bar0_of() {
    local s e
    read -r s e _ < "/sys/bus/pci/devices/$1/resource" 2>/dev/null || return 1
    [ $((e)) -gt 0 ] || return 1
    printf '%s %d\n' "$s" $(( e - s + 1 ))
}

# Make utils/logs/<name>/ (or $PIPS_LOGS/<name>/) for this run and print its
# path. With "unique", a taken name gets -2, -3, ...; otherwise it is refused.
pips_outdir() {
    local name="$1" mode="${2:-}" owner="${SUDO_USER:-$(id -un)}" logs out base k=1
    logs="${PIPS_LOGS:-$PIPS_REPO/utils/logs}"
    if [ ! -d "$logs" ]; then
        mkdir -p "$logs" && chown "$owner": "$logs"
    fi
    out="$logs/$name"
    if [ -e "$out" ]; then
        [ "$mode" = unique ] || { echo "ERROR: $out already exists; pick another name" >&2; return 1; }
        base="$out"; while [ -e "$out" ]; do k=$((k + 1)); out="$base-$k"; done
    fi
    mkdir -p "$out" && echo "$out"
}

# One PIPS run at a time: they share the log DMA, log_enable and WIN_BASE.
# Opened read-only, created only if missing: with fs.protected_regular even
# root may not O_CREAT-open another user's file in /tmp.
pips_lock() {
    local f=/tmp/pips-run.lock
    [ -e "$f" ] || { : > "$f" && chmod 666 "$f"; } 2>/dev/null
    exec 8< "$f" || return 1
    flock -n 8 && return 0
    echo "ERROR: another PIPS script is running (/tmp/pips-run.lock):" >&2
    pgrep -af 'pips-(bringu[p]|fio-lo[g])' >&2
    return 1
}
