#!/usr/bin/env bash
# Can the icx campaign (pips-campaign.sh nic ...) run against styx as it is?
# Run on icx. Read-only on icx; on styx it only writes a few MB of test files
# (removed again) and starts one screen session that exits by itself.
#
# Written 11-08, when styx's disk filled (df: 0 available, 100%) and its repo
# could not fetch. The campaign does not need styx's repo to be current: it
# needs styx's copies of the files it runs there to match icx's, a built
# alias-rdma it will not try to rebuild, and room for root to write (the loads
# run under sudo, and ext4 keeps a reserve only root can use). This checks all
# of that the way the runner does it (run-dualnic-experiment.sh):
#   1 ssh, sudo -n, the tools (iperf3, ifconfig, python, screen, network_setup.py)
#   2 the files styx runs: utils/setup-envir.sh, utils/tcp/run-netapp-tput.sh,
#     scripts/pips/alias/{alias-rdma.c,alias_common.h,alias-run.sh,Makefile},
#     scripts/nic-host-snapshot.sh: same content as icx's (git hash-object)
#   3 alias-rdma: built for styx and not older than its source (else the runner
#     rebuilds it, as the user, which fails on a full disk)
#   4 the interfaces (CLIENT_INTFS) are up and have an RDMA device
#   5 the disk: free for root vs for the user, inodes, and its growth over
#     --watch seconds, projected over --hours
#   6 writes as the runs do them: root under utils/logs (iperf3 client logs),
#     the alias server's redirect (bash as the user, sudo alias-rdma writing
#     into /tmp/alias-srv-nic<i>.log), a screen session, a user write (git,
#     nstat history, snapshots: these may fail without stopping the runs)
#
# Usage: bash scripts/pips/styx-check.sh [--watch 60] [--hours 36] [--need-gb 2]
# Exit 0: safe to run. 1: not safe (FAIL lines). 2: usage.
# Report: printed, and saved to utils/logs/styx-check-<stamp>.txt.
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "$SELF")/../.." && pwd)
WATCH=60 HOURS=36 NEED_GB=2
while [ $# -gt 0 ]; do
    case $1 in
        --watch) WATCH=$2; shift 2 ;;
        --hours) HOURS=$2; shift 2 ;;
        --need-gb) NEED_GB=$2; shift 2 ;;
        -h|--help) sed -n '2,30p' "$SELF"; exit 0 ;;
        *) echo "styx-check: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
[ -f "$REPO/utils/setup-server.sh" ] || { echo "styx-check: no utils/setup-server.sh (run this on icx)" >&2; exit 2; }
. "$REPO/utils/setup-server.sh"
# The runner sends commands with icx's paths: the repo sits at the same path on styx.
R=${REPO_DIR:-$REPO}
declare -p CLIENT_INTFS >/dev/null 2>&1 || { echo "styx-check: setup-server.sh sets no CLIENT_INTFS" >&2; exit 2; }

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$REPO/utils/logs"
REPORT="$REPO/utils/logs/styx-check-$STAMP.txt"
exec > >(tee "$REPORT") 2>&1
T0=$(date +%s)
say()  { printf '%s +%3ds  %s\n' "$(date +%T)" $(( $(date +%s) - T0 )) "$*"; }
FAILS=() WARNS=()
ok()   { say "  ok    $*"; }
fail() { say "  FAIL  $*"; FAILS+=("$*"); }
warn() { say "  warn  $*"; WARNS+=("$*"); }

rsh() {
    if [ -n "${CLIENT_PWD:-}" ]; then
        sshpass -p "$CLIENT_PWD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
            "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
            "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    fi
}

say "styx-check: $CLIENT_USERNAME@$CLIENT_SSH_IP, repo $R, interfaces ${CLIENT_INTFS[*]}"
say "report: $REPORT"

# ----------------------------------------------------------------- 1 basics
say "1/6 ssh, sudo, tools"
if ! rsh true 2>/dev/null; then
    fail "ssh to $CLIENT_USERNAME@$CLIENT_SSH_IP"
    say "verdict: NOT SAFE (no ssh; nothing else checked)"; exit 1
fi
ok "ssh"
SHOST=$(rsh 'hostname -s 2>/dev/null || hostname')
rsh 'sudo -n true' 2>/dev/null && ok "sudo -n" || fail "sudo -n on styx (the runs sudo over ssh, no TTY)"
for t in iperf3 ifconfig python screen git; do
    rsh "command -v $t >/dev/null" && ok "$t" || fail "$t missing on styx"
done
NSPATH="${DEP_DIR:-$HOME}/Understanding-network-stack-overheads-SIGCOMM-2021/network_setup.py"
rsh "test -f '$NSPATH'" && ok "network_setup.py" || fail "network_setup.py missing on styx ($NSPATH)"
rsh "test -f '$R/utils/setup-server.sh'" && ok "styx's utils/setup-server.sh" || fail "styx has no $R/utils/setup-server.sh (setup-envir.sh sources it)"

# ----------------------------------------------------- 2 the files styx runs
say "2/6 the files styx runs, against icx's (content, not commit)"
FILES="utils/setup-envir.sh utils/tcp/run-netapp-tput.sh scripts/pips/alias/alias-rdma.c
       scripts/pips/alias/alias_common.h scripts/pips/alias/alias-run.sh scripts/pips/alias/Makefile
       scripts/nic-host-snapshot.sh"
SH=$(rsh "cd '$R' && for f in $(echo $FILES); do printf '%s ' \"\$f\"; git hash-object \"\$f\" 2>/dev/null || echo missing; done")
for f in $FILES; do
    mine=$(git -C "$REPO" hash-object "$f" 2>/dev/null || echo missing)
    theirs=$(awk -v f="$f" '$1 == f { print $2 }' <<< "$SH")
    if [ "$theirs" = "$mine" ]; then ok "$f"
    elif [ "$f" = scripts/nic-host-snapshot.sh ]; then warn "$f differs or is missing on styx (only the snapshots use it)"
    else fail "$f: styx ${theirs:-?} vs icx $mine (styx runs its own copy)"; fi
done
rsh "grep -q -- '--no_kill' '$R/utils/tcp/run-netapp-tput.sh'" && ok "run-netapp-tput.sh has --no_kill" ||
    fail "styx's run-netapp-tput.sh has no --no_kill"
SHEAD=$(rsh "git -C '$R' rev-parse HEAD 2>/dev/null")
if [ -n "$SHEAD" ] && git -C "$REPO" cat-file -e "$SHEAD" 2>/dev/null; then
    say "  info  styx at $(git -C "$REPO" log -1 --format='%h %cd %s' --date=short "$SHEAD" | cut -c1-90)"
    say "  info  icx  at $(git -C "$REPO" log -1 --format='%h %cd %s' --date=short HEAD | cut -c1-90) ($(git -C "$REPO" rev-list --count "$SHEAD..HEAD" 2>/dev/null) commits ahead)"
else
    say "  info  styx at ${SHEAD:-?} (not in icx's history)"
fi

# ---------------------------------------------------------- 3 alias-rdma
say "3/6 alias-rdma built for $SHOST"
BIN="$R/scripts/pips/alias/build/$SHOST/alias-rdma"
A="$R/scripts/pips/alias"
st=$(rsh "if [ ! -x '$BIN' ]; then echo missing; elif [ '$A/alias-rdma.c' -nt '$BIN' ] || [ '$A/alias_common.h' -nt '$BIN' ]; then echo stale; else echo current; fi")
case $st in
    current) ok "$BIN (newer than its source: the runner will not rebuild it)" ;;
    stale)   fail "$BIN is older than alias-rdma.c/alias_common.h: the runner rebuilds it as $CLIENT_USERNAME, which needs user disk space" ;;
    *)       fail "$BIN missing: the runner builds it as $CLIENT_USERNAME, which needs user disk space" ;;
esac
[ "$st" = missing ] || { n=$(rsh "ldd '$BIN' 2>/dev/null | grep -c 'not found'"); [ "${n:-0}" = 0 ] && ok "its libraries resolve" || fail "$BIN: $n libraries not found"; }

# ---------------------------------------------------------- 4 interfaces
say "4/6 interfaces"
for c in "${CLIENT_INTFS[@]}"; do
    s=$(rsh "cat /sys/class/net/$c/operstate 2>/dev/null; ls /sys/class/net/$c/device/infiniband 2>/dev/null | head -1" | xargs)
    case $s in
        "up "?*) ok "$c up, RDMA ${s#up }" ;;
        up)      fail "$c up but no RDMA device (alias-rdma needs one)" ;;
        "")      fail "$c not found on styx" ;;
        *)       warn "$c is ${s%% *} (setup-envir.sh brings it up; RDMA ${s#* })" ;;
    esac
done

# ---------------------------------------------------------- 5 the disk
say "5/6 the disk (/ , $R, /tmp)"
fsinfo() {   # bsize blocks bfree bavail files ffree mount
    rsh "for p in / '$R' /tmp; do stat -f -c '%S %b %f %a %c %d' \"\$p\" | tr '\n' ' '; df -P \"\$p\" | awk 'NR==2 { print \$6 }'; done"
}
F1=$(fsinfo); t1=$(date +%s)
awk '!seen[$7]++' <<< "$F1" | while read -r bs b f a c d m; do
    say "  info  $m: $(( b * bs >> 30 )) GiB, root can use $(( f * bs >> 20 )) MiB, user $(( a * bs >> 20 )) MiB; inodes free $d of $c"
done
read -r BS _ FREE1 AV1 _ IFREE _ <<< "$(head -1 <<< "$F1")"
ROOT_MB=$(( FREE1 * BS >> 20 ))
[ "$(awk '{ print $7 }' <<< "$F1" | sort -u | wc -l)" = 1 ] || say "  info  $R or /tmp on another filesystem: the checks below use / (the first line)"
say "  watching free space for ${WATCH}s (is something filling it?)"
left=$WATCH
while [ "$left" -gt 0 ]; do
    s=$(( left < 15 ? left : 15 )); sleep "$s"; left=$(( left - s ))
    cur=$(rsh "stat -f -c '%f' /"); say "  ...   root-usable $(( cur * BS >> 20 )) MiB ($left s left)"
done
F2=$(fsinfo); t2=$(date +%s)
read -r _ _ FREE2 _ <<< "$(head -1 <<< "$F2")"
dmb=$(( (FREE1 - FREE2) * BS >> 20 )); dt=$(( t2 - t1 ))
need_mb=$(( NEED_GB * 1024 ))
if [ "$dmb" -gt 0 ]; then
    proj=$(( dmb * HOURS * 3600 / dt ))
    say "  info  free space fell $dmb MiB in ${dt}s: ~$proj MiB over $HOURS h"
    if [ "$proj" -ge "$(( FREE2 * BS >> 20 ))" ]; then fail "at this rate the root reserve runs out within $HOURS h: something on styx is filling the disk"
    else warn "the disk is still filling ($dmb MiB in ${dt}s), not fast enough to run out in $HOURS h"; fi
else
    ok "free space steady over ${dt}s"
fi
ROOT_MB=$(( FREE2 * BS >> 20 ))
[ "$ROOT_MB" -ge "$need_mb" ] && ok "root can use $ROOT_MB MiB (need $need_mb; the campaign writes well under 100 MB on styx)" ||
    fail "root can use only $ROOT_MB MiB (want $need_mb)"
[ "${IFREE:-0}" -gt 10000 ] && ok "inodes free: $IFREE" || fail "inodes free: ${IFREE:-?}"

# ----------------------------------------------------- 6 writes as the runs do
say "6/6 writes as the runs do them"
d="$R/utils/logs/.styx-check-$STAMP"
if rsh "sudo -n mkdir -p '$d' && sudo -n sh -c 'head -c 8388608 /dev/zero > \"$d/w\" && sync' && [ \$(stat -c %s '$d/w') = 8388608 ]"; then
    ok "root writes 8 MiB under utils/logs (iperf3 client logs, reports)"
else fail "root cannot write under $R/utils/logs (the iperf3 clients log there)"; fi
rsh "sudo -n rm -rf '$d'"
for i in "${!CLIENT_INTFS[@]}"; do
    f=/tmp/alias-srv-nic$i.log
    if rsh "bash -c \"sudo -n sh -c 'head -c 1048576 /dev/zero' > $f\" && [ \$(stat -c %s $f) = 1048576 ]" 2>/dev/null; then
        ok "the alias server's log $f (user's redirect, root writing)"
    else fail "$f: the alias server's redirect fails (bash as $CLIENT_USERNAME opens it, sudo alias-rdma writes)"; fi
    rsh ": > $f" 2>/dev/null
done
rsh "screen -dmS styxcheck$$ sleep 3 && sleep 1 && screen -ls | grep -q styxcheck$$" &&
    ok "screen starts a detached session" || fail "screen -dmS does not start (the loads run in screen)"
if rsh "head -c 1048576 /dev/zero > ~/.styx-check-$STAMP 2>/dev/null && [ \$(stat -c %s ~/.styx-check-$STAMP) = 1048576 ]"; then
    ok "user writes work (git pull, nstat history, snapshots)"
else
    warn "user ($CLIENT_USERNAME) writes fail: no git sync, no styx snapshots, maybe no client nstat counters; the loads run as root and are not affected"
fi
rsh "rm -f ~/.styx-check-$STAMP" 2>/dev/null

# ---------------------------------------------------------- verdict
say "----"
for w in "${WARNS[@]}"; do say "warn: $w"; done
for f in "${FAILS[@]}"; do say "FAIL: $f"; done
if [ ${#FAILS[@]} = 0 ]; then
    say "verdict: SAFE to run the icx campaign against styx (${#WARNS[@]} warnings)"; exit 0
else
    say "verdict: NOT SAFE (${#FAILS[@]} failures above)"; exit 1
fi
