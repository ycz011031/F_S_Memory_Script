#!/bin/bash
# Move NVMe drives between the kernel's nvme driver and vfio-pci for
# alias-nvme, and back. Runtime only: no reboot, no GRUB, nothing persistent
# (driver_override is cleared on the way back).
#
#   sudo bash scripts/pips/alias/alias-vfio.sh bind 0000:65:00.0 0000:66:00.0
#   sudo bash scripts/pips/alias/alias-vfio.sh restore [BDF ...]   # no BDF: every one bind recorded
#   bash scripts/pips/alias/alias-vfio.sh status [BDF ...]
#
# bind refuses a drive whose namespaces are mounted, swapped on or held
# (md, LVM, dm): someone's data in use. It records the driver it found in
# /run/alias-vfio/<BDF> (gone at reboot, when the kernel rebinds anyway), so
# restore puts back exactly that and a crashed run can be undone later.
# restore waits until the drive's block device is back (30 s).
# The IOMMU must be on (strict, lazy or pt): VFIO needs a group. Every
# device in the drive's IOMMU group must end on vfio-pci too; status lists
# the group, and bind refuses a group with other endpoints in it.
set -u
STATE=/run/alias-vfio
die() { echo "alias-vfio: $*" >&2; exit 1; }
drv_of() { local l; l=$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null) && basename "$l" || echo none; }
grp_of() { local l; l=$(readlink "/sys/bus/pci/devices/$1/iommu_group" 2>/dev/null) && basename "$l" || echo none; }
blk_of() { ls -d /sys/bus/pci/devices/"$1"/nvme/nvme*/nvme*n* 2>/dev/null | xargs -r -n1 basename; }

status_one() {
    local b=$1 g
    g=$(grp_of "$b")
    printf '%s  driver %-9s group %-5s block %s%s\n' "$b" "$(drv_of "$b")" "$g" \
        "$(blk_of "$b" | xargs | sed 's/^$/-/')" "$( [ -e "$STATE/$b" ] && echo "  (bound by alias-vfio; was $(cat "$STATE/$b"))")"
    if [ "$g" != none ]; then
        local m
        for m in /sys/kernel/iommu_groups/"$g"/devices/*; do
            m=$(basename "$m"); [ "$m" = "$b" ] && continue
            printf '    group %s also: %s (%s, class %s)\n' "$g" "$m" "$(drv_of "$m")" "$(cat "/sys/bus/pci/devices/$m/class" 2>/dev/null)"
        done
    fi
}

busy_of() {   # what holds the drive's namespaces: mounts, swap, holders, open files
    local n f p
    for n in $(blk_of "$1"); do
        lsblk -nr -o NAME,TYPE,MOUNTPOINT "/dev/$n" 2>/dev/null | awk '$2 ~ /^(raid|lvm|crypt|md|dm)/ || $3 != ""'
        grep -qs "^/dev/$n" /proc/swaps && echo "/dev/$n swap"
        ls /sys/block/"$n"/holders 2>/dev/null | sed "s|^|/dev/$n held by |"
        # anyone's process with the namespace or a partition open (another user's fio)
        for f in /proc/[0-9]*/fd/*; do
            case "$(readlink "$f" 2>/dev/null)" in
                /dev/"$n"|/dev/"$n"p[0-9]*)
                    p=${f#/proc/}; p=${p%%/*}
                    echo "/dev/$n open by PID $p ($(ps -o user=,comm= -p "$p" 2>/dev/null | xargs))" ;;
            esac
        done | sort -u
        [ -e "/dev/ng${n#nvme}" ] && for f in /proc/[0-9]*/fd/*; do
            [ "$(readlink "$f" 2>/dev/null)" = "/dev/ng${n#nvme}" ] && echo "/dev/ng${n#nvme} open by PID $(echo "$f" | cut -d/ -f3)"
        done | sort -u
    done
}

bind_one() {
    local b=$1 d g m k
    [ -e "/sys/bus/pci/devices/$b" ] || die "$b: no such PCI device"
    d=$(drv_of "$b")
    if [ "$d" = vfio-pci ]; then echo "alias-vfio: $b already on vfio-pci"; return 0; fi
    [ "$(cat "/sys/bus/pci/devices/$b/class")" = 0x010802 ] || die "$b is not an NVMe controller (class $(cat "/sys/bus/pci/devices/$b/class"))"
    g=$(grp_of "$b")
    [ "$g" != none ] || die "$b has no IOMMU group: the IOMMU is off, and VFIO needs it (strict, lazy or pt)"
    for m in /sys/kernel/iommu_groups/"$g"/devices/*; do
        m=$(basename "$m"); [ "$m" = "$b" ] && continue
        case "$(cat "/sys/bus/pci/devices/$m/class" 2>/dev/null)" in
            0x0604*) ;;            # bridges (the switch's ports) may share it
            *) [[ " $* " == *" $m "* ]] || die "$b's IOMMU group $g also holds $m ($(drv_of "$m")): bind both, or none" ;;
        esac
    done
    k=$(busy_of "$b")
    [ -z "$k" ] || die "$b is in use, not touching it:
$k"
    modprobe vfio-pci 2>/dev/null || die "modprobe vfio-pci failed"
    mkdir -p "$STATE"
    echo "$d" > "$STATE/$b"
    echo vfio-pci > "/sys/bus/pci/devices/$b/driver_override"
    [ "$d" != none ] && echo "$b" > "/sys/bus/pci/devices/$b/driver/unbind"
    echo "$b" > /sys/bus/pci/drivers_probe 2>/dev/null
    [ "$(drv_of "$b")" = vfio-pci ] || die "$b did not bind to vfio-pci (driver $(drv_of "$b")); run restore $b"
    echo "alias-vfio: $b: $d -> vfio-pci (group $g)"
}

restore_one() {
    local b=$1 was k
    was=$(cat "$STATE/$b" 2>/dev/null || echo nvme)
    if [ "$(drv_of "$b")" != vfio-pci ] && [ ! -e "$STATE/$b" ]; then
        echo "alias-vfio: $b is on $(drv_of "$b"), nothing to restore"; return 0
    fi
    pkill -INT -f "alias-nvme .*$b" 2>/dev/null && sleep 2
    echo "" > "/sys/bus/pci/devices/$b/driver_override"
    [ "$(drv_of "$b")" = vfio-pci ] && echo "$b" > /sys/bus/pci/drivers/vfio-pci/unbind
    if [ "$was" != none ]; then
        echo "$b" > /sys/bus/pci/drivers_probe 2>/dev/null
        [ "$(drv_of "$b")" = "$was" ] || echo "$b" > "/sys/bus/pci/drivers/$was/bind" 2>/dev/null
    fi
    rm -f "$STATE/$b"
    if [ "$was" = nvme ]; then
        for k in $(seq 1 30); do
            [ -n "$(blk_of "$b")" ] && [ -b "/dev/$(blk_of "$b" | head -1)" ] && break
            sleep 1
        done
        [ -n "$(blk_of "$b")" ] || { echo "alias-vfio: WARNING: $b is on $(drv_of "$b") but no block device after 30 s" >&2; return 1; }
    fi
    echo "alias-vfio: $b: vfio-pci -> $(drv_of "$b") ($(blk_of "$b" | xargs))"
}

cmd=${1:-}; shift || true
case "$cmd" in
    status)
        [ $# -gt 0 ] || set -- $(ls "$STATE" 2>/dev/null)
        [ $# -gt 0 ] || { echo "alias-vfio: nothing bound by alias-vfio"; exit 0; }
        for b in "$@"; do status_one "$b"; done ;;
    bind)
        [ "$(id -u)" = 0 ] || die "run as root (sudo)"
        [ $# -gt 0 ] || die "bind BDF [BDF]"
        for b in "$@"; do bind_one "$b" "$@"; done ;;
    restore)
        [ "$(id -u)" = 0 ] || die "run as root (sudo)"
        [ $# -gt 0 ] || set -- $(ls "$STATE" 2>/dev/null)
        rc=0; for b in "$@"; do restore_one "$b" || rc=1; done; exit $rc ;;
    *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
