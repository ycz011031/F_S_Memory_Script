#!/bin/bash
# Where each drive's completions land, for the fio cores in SSD_CORES
# (utils/setup-server.sh), and whether that placement is safe. Read-only.
#
#   bash scripts/ssd-irq-placement.sh            # the table and the verdict
#   bash scripts/ssd-irq-placement.sh --check    # the same, exit 1 if unsafe
#
# An I/O submitted on CPU c goes to the drive's blk-mq queue whose cpu_list
# holds c (/sys/block/<dev>/mq/<n>/cpu_list, queue n+1), and completes on that
# queue's interrupt CPU (/proc/irq/<irq>/effective_affinity_list; NVMe
# interrupts are kernel-managed and cannot be moved). In strict IOMMU mode
# every completion waits on a synchronous IOTLB invalidation in that
# interrupt. UNSAFE when:
#   - both drives' completions reach the same interrupt CPU (bigserver from the
#     10-25 boot: CPUs 36-40 complete both drives on CPU 40, 41-45 on CPU 45),
#     which livelocked those CPUs for minutes (kernel soft lockups,
#     qi_submit_sync from nvme_irq; HANDOFF §8 "0x0A06 campaign");
#   - a drive's fio core is one of the interrupt CPUs either drive uses.
# Uneven co-runs borrow the other drive's cores unless SSD_SPLIT_CORES=0
# (run-dualssd-experiment.sh): the check counts those too when it is 1.
# The layout is fixed per boot: run it after every reboot.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../utils/setup-server.sh"
. "$HERE/../utils/ssd-lib.sh"
CHECK=0; [ "${1:-}" = --check ] && CHECK=1

declare -p SSD_SERIALS SSD_CORES >/dev/null 2>&1 || { echo "SSD_SERIALS / SSD_CORES not set in utils/setup-server.sh" >&2; exit 2; }
DEVS=(); CTRLS=()
for i in 0 1; do
    ssd_resolve "${SSD_SERIALS[$i]}" || exit 2
    DEVS[$i]=$(basename "$SSD_DEV")                       # nvme0n1
    CTRLS[$i]=${DEVS[$i]%n*}                              # nvme0
done
# irq_cpu <ctrl> <queue>: the effective interrupt CPU of that queue
irq_cpu() {
    local d
    for d in /proc/irq/*/; do
        [ -e "$d$1q$2" ] && { cat "$d/effective_affinity_list"; return; }
    done
    echo "?"
}
# queue_of <dev> <cpu>: the blk-mq queue (nvme queue number) that CPU submits on
queue_of() {
    local q
    for q in /sys/block/"$1"/mq/*; do
        tr -d ' ' < "$q/cpu_list" | tr ',' '\n' | awk -v c="$2" -F- '
            { lo = $1; hi = ($2 == "" ? $1 : $2); if (c >= lo && c <= hi) f = 1 } END { exit !f }' &&
            { echo $(( $(basename "$q") + 1 )); return; }
    done
    echo "?"
}

declare -A IRQS0 IRQS1
bad=0
echo "drive  device     fio core -> queue -> interrupt CPU"
for i in 0 1; do
    cores="${SSD_CORES[$i]}"
    [ "${SSD_SPLIT_CORES:-1}" = 1 ] && cores="$cores,${SSD_CORES[$((1 - i))]}"   # what an uneven run may borrow
    line=""
    for c in $(echo "$cores" | tr ',' ' '); do
        q=$(queue_of "${DEVS[$i]}" "$c"); cpu=$(irq_cpu "${CTRLS[$i]}" "$q")
        line="$line $c->q$q->$cpu"
        if [ "$i" = 0 ]; then IRQS0[$cpu]=1; else IRQS1[$cpu]=1; fi
    done
    printf '%-6s %-10s%s\n' "$i" "${DEVS[$i]}" "$line"
done
shared=""
for c in "${!IRQS0[@]}"; do [ -n "${IRQS1[$c]:-}" ] && shared="$shared $c"; done
[ -n "$shared" ] && { echo "UNSAFE: both drives complete on CPU(s)$shared"; bad=1; }
for i in 0 1; do
    for c in $(echo "${SSD_CORES[$i]}" | tr ',' ' '); do
        if [ -n "${IRQS0[$c]:-}" ] || [ -n "${IRQS1[$c]:-}" ]; then
            echo "UNSAFE: drive $i runs fio on CPU $c, an interrupt CPU"; bad=1
        fi
    done
done
echo "interrupt CPUs: drive 0 {${!IRQS0[*]}}, drive 1 {${!IRQS1[*]}}; SSD_SPLIT_CORES=${SSD_SPLIT_CORES:-1}"
if [ "$bad" = 0 ]; then echo "placement OK"; else echo "placement UNSAFE: change SSD_CORES (and SSD_SPLIT_CORES) in utils/setup-server.sh"; fi
[ "$CHECK" = 1 ] && [ "$bad" = 1 ] && exit 1
exit 0
