#!/bin/bash
# Print the IOMMU mode the running kernel applied to a NIC's DMA:
#
#   off      no IOMMU group            (intel_iommu=off)
#   pt       identity domain           (iommu=pt), DMA is not translated
#   strict   DMA domain                (iommu.strict=1), invalidate per unmap
#   lazy     DMA-FQ domain             (iommu.strict=0), batched invalidation
#   on       translated, mode unknown  (kernel has no iommu_group/type file)
#
#   bash iommu-mode.sh enp153s0f0np0
#
# Read from sysfs rather than /proc/cmdline: the command line says what was
# asked for, the device's domain type says what the kernel actually did. A
# CONFIG_INTEL_IOMMU_DEFAULT_ON kernel translates with no iommu flag at all.
intf="${1:?usage: iommu-mode.sh <interface>}"
grp="/sys/class/net/$intf/device/iommu_group"

[ -e "$grp" ] || { echo off; exit 0; }
case "$(cat "$grp/type" 2>/dev/null)" in
    identity) echo pt ;;
    DMA-FQ)   echo lazy ;;
    DMA)      echo strict ;;
    *)        echo on ;;
esac
