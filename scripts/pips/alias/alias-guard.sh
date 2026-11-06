#!/bin/bash
# Reboot bigserver when it hangs while alias-nvme --hold has the drives: the
# BMC's IPMI watchdog (outside the CPUs: a host frozen in a PCIe access runs
# no software at all) and the kernel's panic on soft / hard lockup, RCU stall
# and NMI with kernel.panic=10. As in alias-stability.sh, which tested it.
#
#   bash scripts/pips/alias/alias-guard.sh arm DIR HOLD [TIMEOUT]
#   bash scripts/pips/alias/alias-guard.sh disarm DIR
#   bash scripts/pips/alias/alias-guard.sh status DIR
#
# arm: the kernel settings (the old values saved in DIR/guard-sysctl.txt),
# the BMC timer (hard reset after TIMEOUT s, default 120, without a reset),
# and a root petter that resets it every 10 s while HOLD/alive (the holder's
# heartbeat, each second) is under 45 s old, or there is no holder yet. A
# stale heartbeat, or a frozen host, stops the resets: the BMC resets the
# machine ("hard reset" keeps slot power: the FPGA keeps its bitstream).
# Again in the same boot (a resumed campaign) it keeps the running petter and
# the saved values. Log DIR/wd.txt, fsynced per line.
# disarm: the petter stops, the timer off, the kernel settings back.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}; DIR=${2:-}
[ -n "$cmd" ] && [ -n "$DIR" ] || { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }
mkdir -p "$DIR" || exit 1
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
say() { echo "alias-guard: $*"; }
petter_alive() {
    [ -s "$DIR/wd.pid" ] && [ "$(cat "$DIR/wd.boot" 2>/dev/null)" = "$BOOT" ] && sudo -n kill -0 "$(cat "$DIR/wd.pid")" 2>/dev/null
}

case "$cmd" in
arm)
    HOLD=${3:?alias-guard arm DIR HOLD [TIMEOUT]}; TO=${4:-120}
    command -v ipmitool >/dev/null || { say "ERROR: no ipmitool"; exit 1; }
    lsmod | grep -q '^ipmi_watchdog' && { say "ERROR: the ipmi_watchdog driver owns the BMC timer"; exit 1; }
    # kernel: panic on what it can see, reboot 10 s after a panic
    if [ "$(cat "$DIR/guard-sysctl.boot" 2>/dev/null)" != "$BOOT" ]; then
        : > "$DIR/guard-sysctl.txt"
        for k in kernel.softlockup_panic kernel.hardlockup_panic kernel.panic_on_rcu_stall \
                 kernel.unknown_nmi_panic kernel.panic_on_io_nmi kernel.panic_on_unrecovered_nmi kernel.panic; do
            v=$(sysctl -n "$k" 2>/dev/null) && echo "$k=$v" >> "$DIR/guard-sysctl.txt"
        done
        echo "$BOOT" > "$DIR/guard-sysctl.boot"
    fi
    while IFS='=' read -r k _; do
        [ "$k" = kernel.panic ] && nv=10 || nv=1
        sudo -n sysctl -q -w "$k=$nv" >/dev/null 2>&1 || say "WARNING: $k not set"
    done < "$DIR/guard-sysctl.txt"
    say "kernel: panic on lockup/stall/NMI, reboot 10 s after a panic (pstore $(cat /sys/module/pstore/parameters/backend 2>/dev/null))"
    # the BMC timer: use SMS/OS, action hard reset, countdown in 100 ms
    cnt=$(( TO * 10 ))
    sudo -n ipmitool raw 0x06 0x24 0x04 0x01 0x00 0x10 "$(printf '0x%02x' $(( cnt & 0xff )))" "$(printf '0x%02x' $(( (cnt >> 8) & 0xff )))" \
        > "$DIR/wd-set.txt" 2>&1 || { say "ERROR: Set Watchdog Timer: $(cat "$DIR/wd-set.txt")"; exit 1; }
    sudo -n ipmitool mc watchdog reset >/dev/null 2>&1 || { say "ERROR: ipmitool mc watchdog reset"; exit 1; }
    say "BMC watchdog: hard reset after ${TO}s without a reset; $(timeout 20 sudo -n ipmitool mc watchdog get 2>&1 | grep -iE 'timer is' | tr -s ' ')"
    if petter_alive; then
        say "petter already running (pid $(cat "$DIR/wd.pid")): kept"
        exit 0
    fi
    rm -f "$DIR/wd.stop" "$DIR/wd.stopped"
    echo "$BOOT" > "$DIR/wd.boot"
    sudo -n setsid bash -c '
        out=$1; hold=$2; to=$3; echo $$ > "$out/wd.pid"
        log() { printf "%s %s\n" "$(date +%T.%3N)" "$*" >> "$out/wd.txt"; sync "$out/wd.txt" 2>/dev/null; }
        log "petter up (timeout ${to}s; the holder heartbeat counts as stale after 45 s)"
        n=0; stale=0
        while [ ! -e "$out/wd.stop" ]; do
            now=$(date +%s%3N); a=$(cut -d" " -f1 "$hold/alive" 2>/dev/null)
            if [ -n "$a" ] && [ $(( now - a )) -gt 45000 ]; then
                [ "$stale" = 0 ] && log "STALE: holder heartbeat $(( (now - a) / 1000 )) s old: no more resets; the BMC resets the host within ${to}s"
                stale=1
            else
                [ "$stale" = 1 ] && log "heartbeat fresh again: resets resume"
                stale=0
                timeout 15 ipmitool mc watchdog reset >/dev/null 2>&1 || log "ipmitool mc watchdog reset failed"
                n=$((n + 1)); [ $((n % 30)) = 1 ] && log "pet $n (holder: ${a:-not up})"
            fi
            sleep 10
        done
        log "petter stopping (wd.stop)"; touch "$out/wd.stopped"' alias-guard-petter "$DIR" "$HOLD" "$TO" \
        < /dev/null > /dev/null 2>&1 &
    for _ in $(seq 20); do petter_alive && break; sleep 0.25; done
    petter_alive && say "petter up (pid $(cat "$DIR/wd.pid")), log $DIR/wd.txt" || { say "ERROR: the petter did not start"; exit 1; }
    ;;
disarm)
    if petter_alive; then
        touch "$DIR/wd.stop"
        for _ in $(seq 30); do [ -e "$DIR/wd.stopped" ] && break; sleep 0.5; done
    fi
    timeout 20 sudo -n ipmitool mc watchdog off >/dev/null 2>&1
    say "BMC watchdog off: $(timeout 20 sudo -n ipmitool mc watchdog get 2>&1 | grep -i 'timer is' | tr -s ' ')"
    if [ "$(cat "$DIR/guard-sysctl.boot" 2>/dev/null)" = "$BOOT" ]; then
        while IFS= read -r kv; do sudo -n sysctl -q -w "$kv" >/dev/null 2>&1; done < "$DIR/guard-sysctl.txt"
        say "kernel settings back: $(tr '\n' ' ' < "$DIR/guard-sysctl.txt")"
    fi
    ;;
status)
    petter_alive && echo "petter: pid $(cat "$DIR/wd.pid")" || echo "petter: not running"
    timeout 20 sudo -n ipmitool mc watchdog get 2>&1 | grep -iE 'timer is|present countdown|action'
    tail -n 3 "$DIR/wd.txt" 2>/dev/null
    ;;
*) say "arm | disarm | status"; exit 2 ;;
esac
