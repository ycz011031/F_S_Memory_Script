#!/bin/bash
# Print the IOMMU mode the running kernel applied to a device's DMA:
#
#   off      no IOMMU group            (intel_iommu=off)
#   pt       identity domain           (iommu=pt), DMA is not translated
#   strict   DMA domain                (iommu.strict=1), invalidate per unmap
#   lazy     DMA-FQ domain             (iommu.strict=0), batched invalidation
#   on       translated, mode unknown  (kernel has no iommu_group/type file)
#
#   bash iommu-mode.sh enp153s0f0np0      # network interface
#   bash iommu-mode.sh nvme0n1            # block device (/dev/ optional)
#   bash iommu-mode.sh 0000:b3:00.0       # PCI function
#
# Read from sysfs rather than /proc/cmdline: the command line says what was
# asked for, the device's domain type says what the kernel actually did. A
# CONFIG_INTEL_IOMMU_DEFAULT_ON kernel translates with no iommu flag at all.
dev="${1:?usage: iommu-mode.sh <interface | block device | PCI address>}"
dev="${dev#/dev/}"

if [ -e "/sys/class/net/$dev" ]; then
    grp="/sys/class/net/$dev/device/iommu_group"
elif [ -e "/sys/bus/pci/devices/$dev" ]; then
    grp="/sys/bus/pci/devices/$dev/iommu_group"
else
    # A block device's sysfs path runs through its PCI function, e.g.
    # .../0000:b3:00.0/nvme/nvme0/nvme0n1. Under native NVMe multipath the
    # disk sits under nvme-subsystem instead, so follow one of its paths.
    p=$(readlink -f "/sys/class/block/$dev" 2>/dev/null)
    case "$p" in
        */nvme-subsystem/*)
            for m in "/sys/class/block/$dev/multipath/"*; do p=$(readlink -f "$m"); break; done ;;
    esac
    bdf=$(printf '%s' "$p" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1)
    if [ -z "$bdf" ]; then
        echo "iommu-mode.sh: $dev is not a network interface, PCI block device or PCI address" >&2
        exit 1
    fi
    grp="/sys/bus/pci/devices/$bdf/iommu_group"
fi

[ -e "$grp" ] || { echo off; exit 0; }
case "$(cat "$grp/type" 2>/dev/null)" in
    identity) echo pt ;;
    DMA-FQ)   echo lazy ;;
    DMA)      echo strict ;;
    *)        echo on ;;
esac
