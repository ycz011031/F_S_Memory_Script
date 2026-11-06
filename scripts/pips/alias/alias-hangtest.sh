#!/bin/bash
# One alias-nvme load on bigserver's drives, recorded so that a hang leaves a
# trace on THIS host's disk (no other host needed): the kernel log, the
# generator's heartbeat and a 1 Hz tick, each line fsynced as it comes (the
# journal can lose its last ~30 s in a power cycle). Optionally pcm-iio at a
# set second, as the runner starts it, and --panic, which turns a lockup into
# a panic so the kernel's backtraces land in pstore (EFI variables survive a
# power cycle). Every change is put back at the end; a reboot also undoes it.
#
#   bash scripts/pips/alias/alias-hangtest.sh [options]
#   bash scripts/pips/alias/alias-hangtest.sh --show [DIR]     # after a reboot
#
#   --drives 0|1|01   SSD_SERIALS indices to load (default 01: both)
#   --ws N --stride N the pattern (default 32 4096: the load that hung 11-05)
#   --queues N        I/O queues per drive (default 4), on SSD_CORES[i]
#   --qd N            per queue (default 32); --bs (default 4k)
#   --seconds N       measured seconds after a 10 s warm-up (default 90)
#   --pcm-at S        start pcm-iio S s after alias-nvme starts (the runner:
#                     31), for --pcm-for s (default 20); default: no pcm-iio
#   --panic           soft/hard lockup, RCU stall, NMI -> panic (pstore). Off:
#                     a lockup that would recover stays a lockup
#
# Into ~/alias-hangtest-<time>/: log.txt (this script), kmsg.txt (dmesg -w),
# tick.txt (1 Hz: load, alive), nvme.txt (alias-nvme), pcm-iio.out, pcie.csv.
# --show prints the last lines of each and the pstore records.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
DRIVES=01 WS=32 STRIDE=4096 QUEUES=4 QD=32 BS=4k SECS=90 PCM_AT=0 PCM_FOR=20 PANIC=0 SHOW=""
while [ $# -gt 0 ]; do
    case "$1" in
        --drives) DRIVES="$2"; shift 2 ;;
        --ws) WS="$2"; shift 2 ;;
        --stride) STRIDE="$2"; shift 2 ;;
        --queues) QUEUES="$2"; shift 2 ;;
        --qd) QD="$2"; shift 2 ;;
        --bs) BS="$2"; shift 2 ;;
        --seconds) SECS="$2"; shift 2 ;;
        --pcm-at) PCM_AT="$2"; shift 2 ;;
        --pcm-for) PCM_FOR="$2"; shift 2 ;;
        --panic) PANIC=1; shift ;;
        --show) SHOW="${2:-latest}"; [ $# -ge 2 ] && shift; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "alias-hangtest: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done

if [ -n "$SHOW" ]; then
    [ "$SHOW" = latest ] && SHOW=$(ls -td "$HOME"/alias-hangtest-*/ 2>/dev/null | head -1)
    [ -d "$SHOW" ] || { echo "alias-hangtest: no test folder ($SHOW)" >&2; exit 1; }
    for f in log.txt tick.txt nvme.txt kmsg.txt pcm-iio.out; do
        [ -f "$SHOW/$f" ] || continue
        echo "== $SHOW/$f (last 15)"; tail -n 15 "$SHOW/$f"
    done
    echo "== pstore (records of a panic)"
    sudo ls -la /sys/fs/pstore /var/lib/systemd/pstore 2>&1
    for f in $(sudo find /sys/fs/pstore /var/lib/systemd/pstore -type f 2>/dev/null); do
        echo "-- $f (last 60)"; sudo tail -n 60 "$f"
    done
    exit 0
fi

. "$REPO/utils/setup-server.sh" || exit 1
PCM_BIN=${PCM_BIN:-/usr/local/bin}
PCM_CORE=${PCM_CORE:-15}
OUT=$HOME/alias-hangtest-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT" || exit 1
LOG=$OUT/log.txt
T0=$SECONDS
slog() {   # one line to the terminal and to log.txt, on disk before going on
    local l
    l="$(date +%T.%3N) +$((SECONDS - T0))s  $*"
    echo "$l"; echo "$l" >> "$LOG"; sync "$LOG" 2>/dev/null || sync
}

sudo -v || exit 1
slog "alias-hangtest: into $OUT; drives $DRIVES, ws $WS stride $STRIDE, $QUEUES queues x qd $QD, bs $BS, ${SECS}s; pcm-iio $( [ "$PCM_AT" -gt 0 ] && echo "at ${PCM_AT}s for ${PCM_FOR}s" || echo off); panic $PANIC"
slog "kernel $(uname -r); cmdline $(cat /proc/cmdline)"

# The drives: serial -> BDF while they are still on nvme.
BDFS=() ARGS=() SER=() QS=() CPUS=()
for ((n = 0; n < ${#DRIVES}; n++)); do
    i=${DRIVES:n:1}
    s=${SSD_SERIALS[$i]:-}
    [ -n "$s" ] || { slog "ERROR: no SSD_SERIALS[$i]"; exit 1; }
    b=""
    for c in /sys/class/nvme/nvme*; do
        [ "$(tr -d ' ' < "$c/serial" 2>/dev/null)" = "$s" ] && b=$(basename "$(readlink -f "$c/device")")
    done
    [ -n "$b" ] || { slog "ERROR: drive $i ($s) is not on nvme (alias-vfio.sh status; restore first)"; exit 1; }
    BDFS+=("$b"); ARGS+=(--dev "$b=$OUT/ssd$i"); SER+=("$s"); QS+=("$QUEUES"); CPUS+=("${SSD_CORES[$i]}")
    slog "drive $i: $s at $b, cores ${SSD_CORES[$i]}"
done

PIDS=()
SYSCTL_SAVED=()
BOUND=0
cleanup() {
    slog "cleanup: stopping the generator and pcm-iio, putting things back"
    if [ -n "${NVME_PID:-}" ] && sudo kill -INT "$NVME_PID" 2>/dev/null; then
        for _ in $(seq 40); do sudo kill -0 "$NVME_PID" 2>/dev/null || break; sleep 0.5; done
    fi
    [ -n "${PCM_PID:-}" ] && sudo pkill -9 -f -- "-csv=$OUT/pcie.csv" 2>/dev/null
    if [ "$BOUND" = 1 ]; then
        sudo bash "$HERE/alias-vfio.sh" restore "${BDFS[@]}" 2>&1 | while IFS= read -r l; do slog "$l"; done
    fi
    for kv in "${SYSCTL_SAVED[@]}"; do sudo sysctl -q -w "$kv" >/dev/null 2>&1; done
    [ ${#SYSCTL_SAVED[@]} -gt 0 ] && slog "sysctls back: ${SYSCTL_SAVED[*]}"
    slog "drives now: $(lsblk -d -n -o NAME,SERIAL 2>/dev/null | grep -E "$(IFS='|'; echo "${SER[*]}")" | tr '\n' ' ')"
    for p in "${PIDS[@]}"; do sudo kill "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    if [ -s "$OUT/kmsg.pid" ]; then
        kp=$(cat "$OUT/kmsg.pid"); sudo pkill -P "$kp" 2>/dev/null; sudo kill "$kp" 2>/dev/null
    fi
    slog "done ($((SECONDS - T0)) s): $OUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. the kernel log, a line at a time, synced (root writes it: dmesg needs it)
sudo bash -c 'f=$1; echo $$ > "$2"; dmesg -w -T 2>&1 | while IFS= read -r l; do printf "%s\n" "$l" >> "$f"; sync "$f" 2>/dev/null; done' \
    alias-hangtest-kmsg "$OUT/kmsg.txt" "$OUT/kmsg.pid" &
PIDS+=($!)
# 2. a tick a second: when the host stopped, to the second
(
    while :; do
        printf '%s load %s running %s nvme %s pcm %s\n' "$(date +%T.%3N)" "$(cut -d' ' -f1-3 /proc/loadavg)" \
            "$(cut -d' ' -f4 /proc/loadavg)" "$(pgrep -x alias-nvme >/dev/null && echo up || echo -)" \
            "$(pgrep -x pcm-iio >/dev/null && echo up || echo -)" >> "$OUT/tick.txt"
        sync "$OUT/tick.txt" 2>/dev/null
        sleep 1
    done
) &
PIDS+=($!)
slog "recording: kmsg.txt (dmesg -w), tick.txt (1 Hz), both fsynced per line"

# 3. lockups -> panic, so pstore keeps the backtraces
slog "pstore backend: $(cat /sys/module/pstore/parameters/backend 2>/dev/null || echo none); nmi_watchdog $(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)"
if [ "$PANIC" = 1 ]; then
    for k in kernel.softlockup_panic kernel.hardlockup_panic kernel.panic_on_rcu_stall \
             kernel.unknown_nmi_panic kernel.panic_on_io_nmi kernel.panic_on_unrecovered_nmi; do
        v=$(sysctl -n "$k" 2>/dev/null) || continue
        SYSCTL_SAVED+=("$k=$v")
        sudo sysctl -q -w "$k=1" >/dev/null 2>&1 || slog "  $k: could not set"
    done
    slog "panic on lockup/stall/NMI armed (kernel.panic $(sysctl -n kernel.panic): 0 = stays down for the power cycle)"
    grep -q . /sys/module/pstore/parameters/backend 2>/dev/null && [ "$(cat /sys/module/pstore/parameters/backend)" != "(null)" ] ||
        slog "WARNING: no pstore backend: a panic's backtrace stays only in kmsg.txt (as far as it got)"
fi

# 4. bind, load
sudo bash "$HERE/alias-vfio.sh" bind "${BDFS[@]}" 2>&1 | while IFS= read -r l; do slog "$l"; done
[ "${PIPESTATUS[0]}" = 0 ] || { slog "ERROR: bind failed"; exit 1; }
BOUND=1
NVME=$(bash "$HERE/alias-run.sh" --build alias-nvme 2>&1 | tail -1)
[ -x "$NVME" ] || { slog "ERROR: alias-nvme does not build: $NVME"; exit 1; }
slog "alias-nvme start"
sudo "$NVME" "${ARGS[@]}" --serial "$(IFS=,; echo "${SER[*]}")" --queues "$(IFS=,; echo "${QS[*]}")" \
    --cpus "$(IFS=/; echo "${CPUS[*]}")" --qd "$QD" --bs "$BS" --lba rand --ws "$WS" --stride "$STRIDE" \
    --warm 10 --seconds "$SECS" --heartbeat 5 2>&1 |
    while IFS= read -r l; do printf '%s %s\n' "$(date +%T.%3N)" "$l" >> "$OUT/nvme.txt"; sync "$OUT/nvme.txt" 2>/dev/null; echo "   $l"; done &
NVME_PIPE=$!
for _ in $(seq 50); do NVME_PID=$(pgrep -x alias-nvme | head -1); [ -n "$NVME_PID" ] && break; sleep 0.2; done
TS=$SECONDS

# 5. pcm-iio at its second, as record-host-metrics.sh starts it
if [ "$PCM_AT" -gt 0 ]; then
    while [ $((SECONDS - TS)) -lt "$PCM_AT" ] && kill -0 "$NVME_PIPE" 2>/dev/null; do sleep 0.5; done
    sudo modprobe msr
    slog "pcm-iio START (taskset -c $PCM_CORE $PCM_BIN/pcm-iio 1, ${PCM_FOR}s)"
    sudo timeout -s KILL "$PCM_FOR" taskset -c "$PCM_CORE" "$PCM_BIN/pcm-iio" 1 -csv="$OUT/pcie.csv" > "$OUT/pcm-iio.out" 2>&1 &
    PCM_PID=$!
    sleep 3
    slog "pcm-iio +3 s: $(grep -c . "$OUT/pcie.csv" 2>/dev/null || echo 0) csv lines"
    wait "$PCM_PID" 2>/dev/null
    PCM_PID=""
    slog "pcm-iio stopped: $(grep -c . "$OUT/pcie.csv" 2>/dev/null || echo 0) csv lines"
fi

# 6. wait for the generator (it stops itself after warm-up + seconds)
while kill -0 "$NVME_PIPE" 2>/dev/null; do
    sleep 10
    slog "alive: $(tail -1 "$OUT/nvme.txt" 2>/dev/null | cut -c1-150)"
done
NVME_PID=""
slog "alias-nvme ended: $(grep -E 'done:|FATAL|ERROR|die' "$OUT/nvme.txt" | tail -2 | tr '\n' ' ')"
