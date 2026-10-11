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
lspci_brief() {
    lspci -vv -s "$1" 2>/dev/null | awk '
        function grab(line,   i, n, f) { n = split(line, f, /[ \t,]+/)
            s = ""; w = ""; for (i = 1; i < n; i++) { if (f[i] == "Speed") s = f[i+1]; if (f[i] == "Width") w = f[i+1] }
            return s " " w }
        /LnkCap:/ { cap = grab($0) }
        /LnkSta:/ { sta = grab($0); if ($0 ~ /downgraded/) dg = 1 }
        /^[ \t]+MaxPayload [0-9]+ bytes, MaxReadReq/ { mps = $2; mrrs = $5 }
        /DevSta:|UESta:|CESta:/ { tag = $1; for (i = 2; i <= NF; i++)
            if ($i ~ /\+$/ && $i !~ /^(AuxPwr|TransPend)/) err = err " " tag $i }
        END {
            if (sta != "") printf "link %s (cap %s)%s", sta, cap, (dg || (sta != cap && cap != "")) ? " DOWNGRADED" : ""
            else printf "link ?"
            printf "  MPS %s MRRS %s", mps == "" ? "?" : mps, mrrs == "" ? "?" : mrrs
            printf "  errors:%s\n", err == "" ? " none" : err
        }'
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
