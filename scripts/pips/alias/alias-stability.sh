#!/bin/bash
# ~20 min stability test of the hold design on bigserver: one alias-nvme
# holds both drives behind PIPS for the whole test (alias-nvme --hold) and
# runs a series of loads with pauses between them: pattern changes (the
# IOMMU region remapped), one drive or both, the PIPS batcher setting changed
# while the traffic pauses, pcm-iio during some loads. The drives are never
# released (b4's reset after a load froze the host, HANDOFF §8), so the test
# ends with an immediate reboot: sync; systemctl reboot -ff (no process is
# stopped, nothing is released; the platform reset puts the drives back on
# nvme). User-approved for this test (11-05); campaigns otherwise never reboot.
#
#   bash scripts/pips/alias/alias-stability.sh [options]       # in tmux
#
#   --loads N        loads to run (default 14, ~75 s each: ~18 min + setup)
#   --secs N         measured seconds per load (default 60, after a 10 s warm-up)
#   --wd-timeout S   BMC watchdog countdown (default 120): a frozen host, or a
#                    holder whose heartbeat is stale for 45 s, is hard-reset by
#                    the BMC within that time
#   --no-wd          no BMC watchdog (the kernel's panic-on-lockup still reboots)
#   --no-reboot      at the end: stop petting the watchdog (it is turned off),
#                    keep the drives held, print the reboot line, exit
#   --dry-run        print the plan and the commands, touch nothing
#
# The watchdog is the BMC's IPMI timer, outside the CPUs: a host frozen in a
# PCIe access cannot run any software watchdog. A root process resets the
# timer every 10 s while the holder's heartbeat (DIR/alive, written each
# second) is fresh; when it is stale, or the host is frozen, nobody resets it
# and the BMC hard-resets the machine (action "hard reset": slot power stays,
# so the FPGA should keep its bitstream). Also armed: kernel panic on soft /
# hard lockup, RCU stall and NMI, with kernel.panic=10 (reboot 10 s after a
# panic; pstore keeps the backtrace).
#
# Output ~/alias-stability-<time>/, fsynced line by line so it survives a
# reset: log.txt (this script), holder.txt (alias-nvme), kmsg.txt, tick.txt
# (1 Hz), wd.txt (watchdog), loads/<n>-<name>/ (fio-format JSON and IOPS logs,
# pcm-iio CSV), summary.txt; and ~/alias-stability-<time>.tar.gz before the
# reboot. After a reset: bash scripts/pips/alias/alias-hangtest.sh --show DIR
# shows the same kind of files, or just tail them.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
NLOADS=14 SECS=60 WARM=10 WD_TIMEOUT=120 WD=1 REBOOT=1 DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --loads) NLOADS="$2"; shift 2 ;;
        --secs) SECS="$2"; shift 2 ;;
        --wd-timeout) WD_TIMEOUT="$2"; shift 2 ;;
        --no-wd) WD=0; shift ;;
        --no-reboot) REBOOT=0; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "alias-stability: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done

# NAME MASK WS STRIDE ORDER PCM PIPS-CFG: MASK bit i = SSD i; PCM 1 = pcm-iio
# for 20 s inside the load; PIPS-CFG = `pips cfg set` fields, set while paused.
PLAN=(
    "base-both      3    64    1 cyclic  0 depth=1 time=0 pb=0"
    "conf-both      3    32 4096 cyclic  1 depth=1 time=0 pb=0"
    "cap4k-both     3  4096    1 cyclic  0 depth=16 time=218 pb=1"
    "cap64k-both    3 65536    1 cyclic  1 depth=16 time=218 pb=1"
    "conf16-both    3    16 4096 cyclic  0 depth=1 time=0 pb=0"
    "ssd0-conf      1    32 4096 cyclic  1 depth=1 time=0 pb=0"
    "ssd1-conf      2    32 4096 cyclic  0 depth=16 time=218 pb=1"
    "conf64-both    3    64 4096 cyclic  1 depth=16 time=218 pb=1"
    "s512-both      3    32  512 cyclic  0 depth=1 time=0 pb=0"
    "shuf4k-both    3  4096    1 shuffle 1 depth=1 time=0 pb=0"
    "rand256-both   3   256    1 random  0 depth=16 time=218 pb=1"
    "conf-both-2    3    32 4096 cyclic  1 depth=16 time=218 pb=1"
    "base-both-2    3    64    1 cyclic  0 depth=1 time=0 pb=0"
    "conf-both-3    3    32 4096 cyclic  1 depth=1 time=0 pb=0"
)

PIPS=$REPO/scripts/pips/pips
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$HOME/alias-stability-$STAMP
CTL=$OUT/ctl
T0=$SECONDS

if [ "$DRY" = 1 ]; then
    echo "alias-stability --dry-run: $NLOADS loads x (${WARM}+${SECS} s + ~5 s pause) = ~$(( NLOADS * (WARM + SECS + 5) / 60 )) min, watchdog $( [ "$WD" = 1 ] && echo "${WD_TIMEOUT}s" || echo off), end: $( [ "$REBOOT" = 1 ] && echo "sync; systemctl reboot -ff" || echo "hold, no reboot")"
    for ((n = 1; n <= NLOADS; n++)); do
        read -r name mask ws stride order pcm cfg <<< "${PLAN[$(( (n - 1) % ${#PLAN[@]} ))]}"
        printf '  %2d %-13s drives %s ws %-6s stride %-5s %-8s pcm %s  pips cfg set %s\n' "$n" "$name" "$mask" "$ws" "$stride" "$order" "$pcm" "$cfg"
    done
    echo "  holder: sudo alias-nvme --dev <b3>=... --dev <b4>=... --queues 4,4 --qd 32 --bs 4k --hold $CTL"
    exit 0
fi

. "$REPO/utils/setup-server.sh" || exit 1
PCM_BIN=${PCM_BIN:-/usr/local/bin}
PCM_CORE=${PCM_CORE:-15}
mkdir -p "$OUT/loads" "$CTL" || exit 1
LOG=$OUT/log.txt
slog() {   # to the terminal and log.txt, on disk before going on
    local l
    l="$(date +%T.%3N) +$((SECONDS - T0))s  $*"
    echo "$l"; echo "$l" >> "$LOG"; sync "$LOG" 2>/dev/null || sync
}
die() { slog "ERROR: $*"; exit 1; }

sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null; done ) &
SUDO_KEEP=$!
slog "alias-stability: into $OUT; $NLOADS loads, ${WARM}+${SECS} s each; watchdog $( [ "$WD" = 1 ] && echo "BMC ${WD_TIMEOUT}s" || echo off); end $( [ "$REBOOT" = 1 ] && echo "reboot -ff" || echo "no reboot")"
slog "kernel $(uname -r); cmdline $(cat /proc/cmdline)"

# ---------------------------------------------------------------- preflight
lspci -s b1:00.0 | grep -q . || die "PIPS (b1:00.0) is not enumerated: reprogram the FPGA, reboot"
BDFS=() SER=() CPUS=()
for i in 0 1; do
    s=${SSD_SERIALS[$i]:-}
    b=""
    for c in /sys/class/nvme/nvme*; do
        [ "$(tr -d ' ' < "$c/serial" 2>/dev/null)" = "$s" ] && b=$(basename "$(readlink -f "$c/device")")
    done
    [ -n "$b" ] || die "SSD $i ($s) is not on nvme (alias-vfio.sh status; reboot if it is held)"
    BDFS+=("$b"); SER+=("$s"); CPUS+=("${SSD_CORES[$i]}")
    slog "SSD $i: $s at $b, cores ${SSD_CORES[$i]}, PCI status 0x$(sudo setpci -s "$b" STATUS)"
done
[ -x "$PCM_BIN/pcm-iio" ] && [ -f "$REPO/utils/opCode-6-$(awk -F: '/^model[[:space:]]*:/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo).txt" ] ||
    die "pcm-iio or its event file in utils/ is missing"
[ -x "$PIPS" ] || die "no $PIPS (make -C scripts/pips)"
slog "PIPS: $(sudo "$PIPS" cfg 2>&1 | head -1)"
NVME=$(bash "$HERE/alias-run.sh" --build alias-nvme 2>&1 | tail -1)
[ -x "$NVME" ] || die "alias-nvme does not build: $NVME"
"$NVME" --help 2>&1 | grep -q -- --hold || die "$NVME has no --hold (rebuild: git pull)"
if [ "$WD" = 1 ]; then
    command -v ipmitool >/dev/null || die "no ipmitool (or run with --no-wd)"
    lsmod | grep -q '^ipmi_watchdog' && die "the ipmi_watchdog driver is loaded and owns the BMC timer (or run with --no-wd)"
    timeout 20 sudo ipmitool mc watchdog get > "$OUT/wd-before.txt" 2>&1 || die "ipmitool mc watchdog get failed: $(tail -1 "$OUT/wd-before.txt")"
    slog "BMC watchdog before: $(grep -iE 'timer is|use:' "$OUT/wd-before.txt" | tr -s ' ' | tr '\n' ';')"
fi

# ---------------------------------------------------------------- recorders
sudo bash -c 'f=$1; echo $$ > "$2"; dmesg -w -T 2>&1 | while IFS= read -r l; do printf "%s\n" "$l" >> "$f"; sync "$f" 2>/dev/null; done' \
    alias-stability-kmsg "$OUT/kmsg.txt" "$OUT/kmsg.pid" &
(
    while :; do
        a=$(cat "$CTL/alive" 2>/dev/null)
        printf '%s load %s running %s holder %s\n' "$(date +%T.%3N)" "$(cut -d' ' -f1-3 /proc/loadavg)" \
            "$(cut -d' ' -f4 /proc/loadavg)" "${a:--}" >> "$OUT/tick.txt"
        sync "$OUT/tick.txt" 2>/dev/null
        sleep 1
    done
) &
TICK=$!
slog "recording kmsg.txt, tick.txt (fsynced per line)"

# ---------------------------------------------------------------- reboot on hang
SYSCTL_SAVED=()
for k in kernel.softlockup_panic kernel.hardlockup_panic kernel.panic_on_rcu_stall \
         kernel.unknown_nmi_panic kernel.panic_on_io_nmi kernel.panic_on_unrecovered_nmi kernel.panic; do
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    SYSCTL_SAVED+=("$k=$v")
    [ "$k" = kernel.panic ] && nv=10 || nv=1
    sudo sysctl -q -w "$k=$nv" >/dev/null 2>&1 || slog "  $k: could not set"
done
slog "kernel: panic on lockup/stall/NMI, reboot 10 s after a panic (pstore: $(cat /sys/module/pstore/parameters/backend 2>/dev/null))"

wd_off() {
    [ "$WD" = 1 ] || return 0
    touch "$OUT/wd.stop"
    for _ in $(seq 30); do [ -e "$OUT/wd.stopped" ] && break; sleep 0.5; done
    timeout 20 sudo ipmitool mc watchdog off >/dev/null 2>&1
    slog "BMC watchdog off: $(timeout 20 sudo ipmitool mc watchdog get 2>&1 | grep -i 'timer is' | tr -s ' ')"
}

if [ "$WD" = 1 ]; then
    cnt=$(( WD_TIMEOUT * 10 ))
    lsb=$(printf '0x%02x' $(( cnt & 0xff ))) msb=$(printf '0x%02x' $(( (cnt >> 8) & 0xff )))
    # Set Watchdog Timer: use SMS/OS (0x04), action hard reset (0x01), no
    # pre-timeout, clear the SMS/OS expiration flag (0x10), countdown in 100 ms
    sudo ipmitool raw 0x06 0x24 0x04 0x01 0x00 0x10 "$lsb" "$msb" > "$OUT/wd-set.txt" 2>&1 ||
        die "Set Watchdog Timer failed: $(cat "$OUT/wd-set.txt")"
    sudo ipmitool mc watchdog reset > /dev/null 2>&1 || die "ipmitool mc watchdog reset failed"
    slog "BMC watchdog armed: hard reset after ${WD_TIMEOUT}s without a reset; $(timeout 20 sudo ipmitool mc watchdog get 2>&1 | grep -iE 'timer is|present countdown' | tr -s ' ' | tr '\n' ';')"
    # The petter, as root, on its own: resets the timer every 10 s while the
    # holder's heartbeat is fresh (or the holder is not up yet); stops at wd.stop.
    sudo bash -c '
        out=$1; ctl=$2; to=$3; echo $$ > "$out/wd.pid"
        say() { printf "%s %s\n" "$(date +%T.%3N)" "$*" >> "$out/wd.txt"; sync "$out/wd.txt" 2>/dev/null; }
        say "petter up (timeout ${to}s, holder heartbeat stale after 45 s)"
        n=0; stale=0
        while [ ! -e "$out/wd.stop" ]; do
            now=$(date +%s%3N); a=$(cut -d" " -f1 "$ctl/alive" 2>/dev/null)
            if [ -n "$a" ] && [ $(( now - a )) -gt 45000 ]; then
                [ "$stale" = 0 ] && say "STALE: holder heartbeat $(( (now - a) / 1000 )) s old: not resetting the timer; the BMC resets the host within ${to}s"
                stale=1
            else
                [ "$stale" = 1 ] && say "heartbeat fresh again: resetting the timer again"
                stale=0
                timeout 15 ipmitool mc watchdog reset >/dev/null 2>&1 || say "ipmitool mc watchdog reset failed"
                n=$((n + 1)); [ $((n % 6)) = 1 ] && say "pet $n (holder: ${a:-not up yet})"
            fi
            sleep 10
        done
        say "petter stopping (wd.stop)"; touch "$out/wd.stopped"' alias-stability-wd "$OUT" "$CTL" "$WD_TIMEOUT" &
fi

cleanup() {
    [ -n "${CLEANED:-}" ] && return; CLEANED=1
    [ -n "${PCM_PID:-}" ] && sudo pkill -9 -f -- "-csv=$OUT/loads/" 2>/dev/null
    wd_off
    for kv in "${SYSCTL_SAVED[@]}"; do sudo sysctl -q -w "$kv" >/dev/null 2>&1; done
    slog "sysctls back: ${SYSCTL_SAVED[*]}"
    kill "$TICK" "$SUDO_KEEP" 2>/dev/null
    [ -s "$OUT/kmsg.pid" ] && { kp=$(cat "$OUT/kmsg.pid"); sudo pkill -P "$kp" 2>/dev/null; sudo kill "$kp" 2>/dev/null; }
    if [ "${HOLDER_UP:-0}" = 1 ]; then
        slog "the holder keeps the drives (never released): end with   sync; sudo systemctl reboot -ff"
    elif [ "${BOUND:-0}" = 1 ]; then
        slog "the holder never came up: the drives were never opened, so restoring them is safe"
        sudo bash "$HERE/alias-vfio.sh" restore "${BDFS[@]}" 2>&1 | while IFS= read -r l; do slog "$l"; done
    fi
}
trap cleanup EXIT
trap 'slog "interrupted: stopping (the holder keeps the drives)"; exit 130' INT TERM

# ---------------------------------------------------------------- holder
sudo bash "$HERE/alias-vfio.sh" bind "${BDFS[@]}" 2>&1 | while IFS= read -r l; do slog "$l"; done
[ "${PIPESTATUS[0]}" = 0 ] || die "bind failed"
BOUND=1
slog "holder start"
sudo setsid "$NVME" --dev "${BDFS[0]}=$OUT/loads/init-ssd0" --dev "${BDFS[1]}=$OUT/loads/init-ssd1" \
    --serial "${SER[0]},${SER[1]}" --queues 4,4 --cpus "${CPUS[0]}/${CPUS[1]}" --qd 32 --bs 4k --lba rand \
    --ws 64 --stride 1 --heartbeat 10 --hold "$CTL" 2>&1 |
    while IFS= read -r l; do printf '%s %s\n' "$(date +%T.%3N)" "$l" >> "$OUT/holder.txt"; sync "$OUT/holder.txt" 2>/dev/null; echo "   $l"; done &
for _ in $(seq 120); do grep -q '^ready' "$CTL/state" 2>/dev/null && break; sleep 0.5; done
grep -q '^ready' "$CTL/state" 2>/dev/null || die "the holder did not come up: $(tail -3 "$OUT/holder.txt" | tr '\n' ' ')"
HOLDER_UP=1
slog "holder ready ($(cat "$CTL/state")): drives open, held until the reboot"

# ---------------------------------------------------------------- loads
ok=0 bad=0
for ((n = 1; n <= NLOADS; n++)); do
    read -r name mask ws stride order pcm cfg <<< "${PLAN[$(( (n - 1) % ${#PLAN[@]} ))]}"
    D=$OUT/loads/$(printf '%02d' "$n")-$name
    mkdir -p "$D"
    sudo "$PIPS" cfg set $cfg > "$D/pips-cfg.txt" 2>&1 || slog "WARNING: pips cfg set $cfg: $(tail -1 "$D/pips-cfg.txt")"
    slog "load $n/$NLOADS $name: drives $mask, ws $ws stride $stride $order, pcm $pcm, pips $cfg ($(sudo "$PIPS" cfg 2>&1 | head -1))"
    rm -f "$CTL/done"
    echo "load $name $mask $ws $stride $order $WARM $SECS $D" > "$CTL/cmd.tmp" && mv "$CTL/cmd.tmp" "$CTL/cmd"
    t=$SECONDS PCM_PID=""
    while [ ! -e "$CTL/done" ]; do
        sleep 1
        el=$((SECONDS - t))
        if [ "$pcm" = 1 ] && [ -z "$PCM_PID" ] && [ "$el" -ge $((WARM + 5)) ]; then
            sudo modprobe msr
            slog "  pcm-iio START (20 s)"
            ( cd "$REPO/utils" && exec sudo timeout -s KILL 20 taskset -c "$PCM_CORE" "$PCM_BIN/pcm-iio" 1 -csv="$D/pcie.csv" ) > "$D/pcm-iio.out" 2>&1 &
            PCM_PID=$!
        fi
        [ $((el % 15)) = 0 ] && slog "  t=${el}s holder: $(grep 'alias-nvme: t=' "$OUT/holder.txt" | tail -1 | cut -d' ' -f2- | cut -c1-140)"
        [ "$el" -gt $((WARM + SECS + 90)) ] && { slog "  load $n did not finish in $((WARM + SECS + 90)) s: stopping the test (holder state: $(cat "$CTL/alive" 2>/dev/null))"; break 2; }
    done
    [ -n "$PCM_PID" ] && wait "$PCM_PID" 2>/dev/null; PCM_PID=""
    res=$(cat "$CTL/done")
    case "$res" in *" ok") ok=$((ok + 1)) ;; *) bad=$((bad + 1)) ;; esac
    rows=$( [ -f "$D/pcie.csv" ] && grep -c . "$D/pcie.csv" || echo -)
    slog "load $n $name: $res; $(grep -E 'done: ' "$OUT/holder.txt" | tail -$(( mask == 3 ? 2 : 1 )) | sed 's/.*alias-nvme: //' | tr '\n' ';') pcm rows $rows"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$name" "$mask" "$ws" "$stride" "$res" "$rows" >> "$OUT/summary.txt"
    sleep 5          # the pause: traffic stopped, drives held
done
slog "loads: $ok ok, $bad failed (summary.txt); $((SECONDS - T0)) s"

# ---------------------------------------------------------------- end
( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) && sync
slog "packed $OUT.tar.gz"
if [ "$REBOOT" = 1 ]; then
    cleanup
    slog "rebooting now: sync; systemctl reboot -ff (no process stopped, the drives are not released)"
    sync; sleep 1
    sudo systemctl reboot -ff
    sleep 60
    slog "still up 60 s after reboot -ff?"
fi
