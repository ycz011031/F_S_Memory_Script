#!/bin/bash
# After a host died during an alias run (hung, power cycled): collect what the
# PREVIOUS boot left behind, and the state of the drives and the switch now.
# Only reads; changes nothing (no bind, no reset, no rescan, no reprogram).
#
#   bash scripts/pips/alias/alias-postmortem.sh [--hours N] [BDF ...]
#
# BDF: the drives under test (default 0000:b3:00.0 0000:b4:00.0, bigserver's
# SSD 0 and 1); their bridges are added. --hours: how far back to look for the
# runner's output (default 24). Into ~/alias-postmortem-<host>-<time>/, then
# that .tar.gz:
#   boots.txt          the boot list, last -x, and how each of the last 3
#                      boots ended (its last journal lines; a clean one shows
#                      systemd's shutdown, a hang just stops)
#   kernel-prev*.txt   the previous boot's kernel log: all, the last 400 lines,
#                      and the lines that matter (vfio, nvme, pcieport, AER,
#                      DMAR, MCE, lockups, Call Trace); /var/log/kern.log* if
#                      the journal is not persistent
#   journal-prev-tail.txt  the previous boot's last 3000 journal lines (sshd,
#                      systemd, OOM)
#   pstore/, platform.txt  panic records (pstore, /var/crash), rasdaemon,
#                      the BMC's event log (ipmitool sel), if present
#   runs/              the runner's console logs and run folders from the last
#                      N hours (alias-nvme.out: its heartbeat every 10 s)
#   now/               the drives and bridges now: driver, lspci -vvv,
#                      reset_method, power state; vfio modules; cmdline;
#                      iomem.txt (/proc/iomem) and windows.txt: each bridge's
#                      memory windows from the drives up to the root port,
#                      checked against the IOVAs alias-nvme uses (a window
#                      that holds one routes the drive's DMA to a peer)
#   pips-now/          scripts/pips/pips-hang-snapshot.sh (the switch now)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
HOURS=24
BDFS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --hours) HOURS="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "alias-postmortem: unknown option $1 (--help)" >&2; exit 2 ;;
        *) BDFS+=("$1"); shift ;;
    esac
done
[ ${#BDFS[@]} -gt 0 ] || BDFS=(0000:b3:00.0 0000:b4:00.0)
OUT=$HOME/alias-postmortem-$(hostname)-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"/{pstore,runs,now} || exit 1
T0=$SECONDS
NSTEP=7
step() { echo "[$1/$NSTEP] $(date +%T) +$((SECONDS - T0))s  $2"; }
echo "alias-postmortem: into $OUT (sudo for the journal, lspci -vvv, pstore)"
sudo -v || exit 1

step 1 "boots: is the previous boot in the journal, did it shut down cleanly"
{
    echo "== now: $(date '+%F %T'), up since $(uptime -s), kernel $(uname -r)"
    echo "== journalctl --list-boots (last 5)"
    sudo journalctl --list-boots --no-pager 2>&1 | tail -5
    echo "== last -x (last 20)"
    last -x -n 20 2>&1
    for b in -1 -2 -3; do
        echo "== boot $b: its last 12 journal lines"
        sudo journalctl -b "$b" -n 12 --no-pager 2>&1 | cut -c1-200
    done
} > "$OUT/boots.txt"
sed -n '/list-boots/,/last -x/p' "$OUT/boots.txt" | grep -v '^==' | sed 's/^/    /'
for b in -1 -2 -3; do
    echo "    boot $b ended with:"
    sudo journalctl -b "$b" -n 4 --no-pager -o short-precise 2>&1 | grep -v '^--' | cut -c1-150 | sed 's/^/      /'
done

step 2 "the previous boot's kernel log"
PERSIST=1
sudo journalctl -k -b -1 --no-pager > "$OUT/kernel-prev-all.txt" 2>&1 || PERSIST=0
grep -q -i 'no persistent journal\|specifying boot id\|no such boot' "$OUT/kernel-prev-all.txt" && PERSIST=0
if [ "$PERSIST" = 1 ] && [ -s "$OUT/kernel-prev-all.txt" ]; then
    sudo journalctl -b -1 -n 3000 --no-pager > "$OUT/journal-prev-tail.txt" 2>&1
    echo "    journal: $(wc -l < "$OUT/kernel-prev-all.txt") kernel lines; last: $(tail -1 "$OUT/kernel-prev-all.txt" | cut -c1-110)"
else
    echo "    no persistent journal: copying /var/log/kern.log and syslog (the last 20000 lines each)"
    : > "$OUT/kernel-prev-all.txt"
    for f in /var/log/kern.log.1 /var/log/kern.log /var/log/syslog.1 /var/log/syslog /var/log/messages; do
        [ -r "$f" ] || sudo test -r "$f" || continue
        echo "== $f" >> "$OUT/kernel-prev-all.txt"
        sudo tail -n 20000 "$f" >> "$OUT/kernel-prev-all.txt" 2>&1
    done
fi
tail -n 400 "$OUT/kernel-prev-all.txt" > "$OUT/kernel-prev-tail.txt"
echo "    the previous boot's last 6 journal lines (any source):"
tail -6 "$OUT/journal-prev-tail.txt" 2>/dev/null | cut -c1-150 | sed 's/^/      /'
grep -E -i 'vfio|nvme|pcieport|aer|dmar|iommu|dma.?fault|hardware error|mce|machine check|cmpltto|completion timeout|surprise|link (down|up)|soft lockup|hard lockup|rcu.*stall|watchdog|hung task|call trace|bug:|oops|panic|b[234]:0[01]\.0|d3|reset' \
    "$OUT/kernel-prev-all.txt" > "$OUT/kernel-prev.txt"
echo "    $(wc -l < "$OUT/kernel-prev.txt") matching lines; the last 8:"
tail -8 "$OUT/kernel-prev.txt" | cut -c1-160 | sed 's/^/      /'

step 3 "panic records: pstore, /var/crash"
for d in /sys/fs/pstore /var/lib/systemd/pstore; do
    sudo find "$d" -type f 2>/dev/null | while read -r f; do
        sudo cp "$f" "$OUT/pstore/$(echo "$f" | tr / _)" 2>/dev/null
    done
done
ls -la /var/crash > "$OUT/pstore/var-crash.txt" 2>&1
sudo chown -R "$(id -u):$(id -g)" "$OUT/pstore" 2>/dev/null
echo "    $(find "$OUT/pstore" -type f ! -name var-crash.txt | wc -l) pstore file(s); /var/crash: $(ls /var/crash 2>/dev/null | wc -l) entries"

step 4 "platform error logs: rasdaemon, BMC event log (30 s limits)"
{
    echo "== ras-mc-ctl --errors"
    command -v ras-mc-ctl >/dev/null && timeout 30 sudo ras-mc-ctl --errors 2>&1 | tail -80 || echo "(no rasdaemon)"
    echo "== ipmitool sel elist (last 60)"
    command -v ipmitool >/dev/null && timeout 30 sudo ipmitool sel elist 2>&1 | tail -60 || echo "(no ipmitool)"
} > "$OUT/platform.txt" 2>&1
grep -c . "$OUT/platform.txt" | sed 's/^/    lines: /'

step 5 "the runner's output from the last $HOURS h"
n=0
for c in $(find "$REPO/utils/logs" -maxdepth 1 -name '*.console.log' -mmin -$((HOURS * 60)) 2>/dev/null | sort); do
    exp=$(basename "$c" .console.log)
    cp "$c" "$OUT/runs/"
    for r in "$REPO/utils/logs/$exp-RUN-"*; do
        [ -d "$r" ] || continue
        mkdir -p "$OUT/runs/$(basename "$r")"
        find "$r" -maxdepth 1 -type f -size -50M -exec cp {} "$OUT/runs/$(basename "$r")/" \;
    done
    n=$((n + 1))
    echo "    == $exp: last lines of the console"
    tail -6 "$c" | cut -c1-150 | sed 's/^/      /'
    for a in "$REPO/utils/logs/$exp-RUN-"*/alias-nvme.out; do
        [ -f "$a" ] || continue
        echo "    -- $(basename "$(dirname "$a")")/alias-nvme.out, last lines:"
        tail -6 "$a" | cut -c1-150 | sed 's/^/      /'
    done
done
echo "    $n experiment(s) copied"

step 6 "the drives and their bridges now"
{
    echo "== cmdline: $(cat /proc/cmdline)"
    echo "== lsmod vfio"; lsmod | grep -E '^vfio' || echo "(no vfio module loaded)"
    for m in /sys/module/vfio_pci/parameters /sys/module/vfio_iommu_type1/parameters; do
        [ -d "$m" ] && grep -H . "$m"/* 2>/dev/null
    done
    echo "== /run/alias-vfio: $(ls /run/alias-vfio 2>/dev/null | tr '\n' ' ')"
    echo "== lsblk"; lsblk -d -o NAME,SERIAL,SIZE,MOUNTPOINT 2>&1
} > "$OUT/now/summary.txt"
ALL=()
for b in "${BDFS[@]}"; do
    p=$(readlink -f "/sys/bus/pci/devices/$b" 2>/dev/null)
    [ -n "$p" ] && ALL+=("$(basename "$(dirname "$p")")")
    ALL+=("$b")
done
for b in "${ALL[@]}"; do
    d=/sys/bus/pci/devices/$b
    {
        echo "== $b"
        if [ -e "$d" ]; then
            echo "driver $(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)  group $(basename "$(readlink "$d/iommu_group" 2>/dev/null)" 2>/dev/null)"
            for f in reset_method power_state power/control power/runtime_status d3cold_allowed current_link_speed current_link_width; do
                printf '%-22s %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
            done
        else
            echo "ABSENT (not enumerated this boot)"
        fi
    } >> "$OUT/now/summary.txt"
    [ -e "$d" ] && timeout 20 sudo lspci -vvv -s "$b" > "$OUT/now/lspci-$b.txt" 2>&1
done
grep -E '^== 0000|^driver|^reset_method|^power_state|ABSENT' "$OUT/now/summary.txt" | sed 's/^/    /'

# The IOVAs alias-nvme puts DMA at (control region, data region; its
# defaults) against every bridge window from the drives up to the root port.
# In a window, a switch routes the TLP to that port instead of upstream.
sudo cat /proc/iomem > "$OUT/now/iomem.txt" 2>&1
UP=()
for b in "${BDFS[@]}"; do
    p=$(readlink -f "/sys/bus/pci/devices/$b" 2>/dev/null) || continue
    while [ -e "$p/vendor" ]; do UP+=("$(basename "$p")"); p=$(dirname "$p"); done
done
{
    echo "IOVAs used: control 0x10000000-0x1fffffff, data from 0x4000000000 (span up to 1 GiB)"
    for b in $(printf '%s\n' "${UP[@]}" | sort -u); do
        echo "== $b $(cat /sys/bus/pci/devices/$b/class 2>/dev/null)"
        timeout 20 sudo lspci -vv -s "$b" 2>/dev/null | grep -E 'behind bridge|Region [0-9]|Bus: primary|ACSCtl|ACSCap' | sed 's/^\s*/   /'
    done
    echo "== /proc/iomem lines that hold 0x10000000 or 0x4000000000"
    # bash arithmetic, not awk: Ubuntu's mawk has no strtonum
    while IFS= read -r line; do
        r=${line%% :*}; r=${r//[[:space:]]/}
        lo=$((16#${r%-*})) hi=$((16#${r#*-})) 2>/dev/null || continue
        for a in 0x10000000 0x1fffffff 0x4000000000 0x403fffffff; do
            if [ $((lo <= a && hi >= a)) = 1 ]; then echo "$line"; break; fi
        done
    done < "$OUT/now/iomem.txt"
} > "$OUT/now/windows.txt" 2>&1
echo "    bridge windows and ACS (now/windows.txt):"
grep -E '^==|behind bridge|ACSCtl|iomem' "$OUT/now/windows.txt" | cut -c1-150 | sed 's/^/      /'
sed -n '/iomem lines/,$p' "$OUT/now/windows.txt" | tail -n +2 | sed 's/^/      /'

step 7 "the switch now (pips-hang-snapshot.sh)"
bash "$REPO/scripts/pips/pips-hang-snapshot.sh" -o "$OUT/pips-now" --since "1 hour ago" 2>&1 | sed 's/^/    /'
rm -f "$OUT/pips-now.tar.gz"

( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) &&
    echo "alias-postmortem: $OUT.tar.gz ($((SECONDS - T0)) s). Copy it back; drives stay as they are (nothing rebound)."
