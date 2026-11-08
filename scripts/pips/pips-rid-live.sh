#!/bin/bash
# pips-rid-live.sh: the live tests of PIPS design 0x0A08, the assumption-test
# build of the background read engine (docs/PIPS-0A08-ASSUMPTION-TEST.md §4).
# Run it once the 0x0A08 bitstream is on the board. In order:
#   T0  baselines: pips-rid-check.sh (host view), census with the devices
#       under load, straddle and flow-control facts
#   T1  one read under the upstream port's ID: the core takes the engine's
#       request and the sink takes the reply (A4)
#   T2  THE assumption: a read under a downstream port's ID is translated in
#       the device's domain: SC, the page's own tag, no DMAR fault, no leak
#       (A1-A3); then 64 reads; both ports
#   T3  isolation: a page mapped only in drive 0's domain reads through
#       in0's port and faults through in1's (A1)
#   T4  no leak under load: engine trains through in0's port while both
#       devices run (INTERVAL x MAX_OUT x idle-fill / engine-first) (A3)
#   T5  no straddle on RC or RQ during T4 (A5)
#   T6  flow control and head-of-line during T4; drive throughput against
#       the engine-free windows (A6)
#   T7  latency separates IOTLB hit and miss: ws 8 vs ws 4096, then strides
#       512 and 262144 pages (A8; X1 starts here)
#   T8  one IOTLB for all domains: prime P (in0), N pages through in1 (drive
#       1's domain), probe P; control with the N pages through in0 (A7)
#   T9  tag census per device under load: the free tag range for F2 (A9)
#   T10 (--t10, or --fallbacks after a T2 failure) F2: the device's own ID,
#       engine tags only from the free window, the clash detector armed
#   T11 (--t11, or --fallbacks after a T2 fault) F3: pages mapped for the
#       port's own DMA domain by ridcheck/pips_bg_pages.ko
#   T12 (--t12) soak: the chosen mode under both devices' load, --soak-min
# A failure stops the run with the fallback to take (decision tree, test doc
# §4), except where the tree goes on: T2 failing goes to T9 (and T10/T11 with
# --fallbacks). A leak or a clash stops everything at once and the engine is
# never restarted in this run (sw_handoff README §12 rule 7).
#
# bigserver (drives): needs the drives in an alias-nvme holder (hold mode,
# HANDOFF §8): a running one (found by pgrep, or --hold DIR), or
# --start-holder (binds both drives to vfio-pci, never releases them, arms
# the BMC guard: the host then has to be rebooted to get the drives back:
# sync; sudo systemctl reboot -ff; --reboot does it at the end). The holder's
# regions sit at IOVA 0x4000000000 in each drive's own domain, page k tagged
# k (mod backing); "map" commands re-tag them before every data check.
# icx (NICs): no holder; the NICs stay on mlx5. The pages to read come from
# ridcheck/pips_bg_region.ko, loaded for both NICs at the start: 65536 pages
# (256 MiB of IOVA) in each NIC's own DMA domain, page k holding k mod 8192 in
# DW0 and the NIC's number (1, 2) in DW1, so a read shows whose domain
# translated it. Reloading it flushes those IOTLB entries (T8). The load
# windows run alias-rdma READs on both NICs against servers on styx (ssh, as
# run-dualnic-experiment.sh --gen alias; utils/setup-server.sh), or
# --load-cmd 'CMD'. Needs the IOMMU in strict or lazy mode and the kernel
# headers. Nothing to reboot afterwards.
#
#   bash scripts/pips/pips-rid-live.sh                   # T0-T9, holder found
#   bash scripts/pips/pips-rid-live.sh --start-holder    # bigserver after a reboot
#   bash scripts/pips/pips-rid-live.sh --fallbacks       # + T10/T11 when T2 fails
#   bash scripts/pips/pips-rid-live.sh --t12 --soak-min 30
#   bash scripts/pips/pips-rid-live.sh --only T7,T8      # selected tests (T0 always)
#   bash scripts/pips/pips-rid-live.sh --dry-run         # the plan only
#   bash scripts/pips/pips-rid-live.sh --start-holder --reboot --tmux   # a fresh bigserver run, as a campaign
#   bash scripts/pips/pips-rid-live.sh --tmux                       # icx (NICs on mlx5, IOMMU strict or lazy)
# Options:
#   --hold DIR          the holder's folder (default: the running holder's)
#   --start-holder      start one (bigserver; the drives stay held until a reboot)
#   --no-guard          with --start-holder: no BMC guard (not advised)
#   --reboot            end with sync; systemctl reboot -ff (only with --start-holder)
#   --tmux              run in a new tmux session (asks for the sudo password
#                       there; survives a dropped ssh). Attach: tmux attach -t pips-rid-live-1
#   --load-cmd CMD      icx: run CMD as the NIC load instead of the built-in one
#                       (alias-rdma READs, 4 QPs x depth 16, ws 64, both NICs)
#   --quick             T4 grid INTERVAL {1000,1} x MAX_OUT {1,64}, shorter loads
#   --keep-going        do not stop at a failing test
#   --t10 --t11 --t12 --fallbacks   (above)
#   --tagwin LO-HI|off  the engine's tags in every run (default: the largest
#                       range no device used in T0's census; off = all 256,
#                       which collides with the devices' tags in the core: T4
#                       11-07). T10 takes T9's range unless this is LO-HI
#   --f3-port in0|in1|usp   T11's port (default in0)
#   --soak-min N        T12 minutes (30); --soak-interval C (100) --soak-maxout M (64)
#   --no-ridcheck       skip pips-rid-check.sh in T0
#   --out DIR           default ~/pips-rid-live-<host>-<time>
# Output: summary.txt (each test: pass condition, numbers, verdict; the
# decision), results.tsv, T*/ (every engine run's counters, traces, dmesg
# segments), log.txt, and a tarball. Exit: 0 every test run passed, 1 a test
# failed (summary says which fallback), 2 setup, 5 leak or clash.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/pips-lib.sh"

HOLD=""; START_HOLDER=0; GUARD=1; REBOOT=0; LOAD_CMD=""; QUICK=0; KEEP=0
T10=0; T11=0; T12=0; FALLBACKS=0; TAGWIN=""; F3PORT=in0; SOAK_MIN=30; SOAK_IVL=100; SOAK_MO=64
RIDCHECK=1; OUT=""; DRY=0; ONLY=""; IN_TMUX=0; PASS=()
for a in "$@"; do if [ "$a" = --tmux ]; then IN_TMUX=1; else PASS+=("$a"); fi; done
while [ $# -gt 0 ]; do
    case "$1" in
        --hold) HOLD=$2; shift 2 ;;
        --start-holder) START_HOLDER=1; shift ;;
        --no-guard) GUARD=0; shift ;;
        --reboot) REBOOT=1; shift ;;
        --load-cmd) LOAD_CMD=$2; shift 2 ;;
        --quick) QUICK=1; shift ;;
        --keep-going) KEEP=1; shift ;;
        --t10) T10=1; shift ;;
        --t11) T11=1; shift ;;
        --t12) T12=1; shift ;;
        --fallbacks) FALLBACKS=1; shift ;;
        --tagwin) TAGWIN=$2; shift 2
            [ "$TAGWIN" = off ] || [[ "$TAGWIN" =~ ^[0-9]+-[0-9]+$ ]] || { echo "--tagwin LO-HI or off" >&2; exit 2; } ;;
        --f3-port) F3PORT=$2; shift 2 ;;
        --soak-min) SOAK_MIN=$2; shift 2 ;;
        --soak-interval) SOAK_IVL=$2; shift 2 ;;
        --soak-maxout) SOAK_MO=$2; shift 2 ;;
        --no-ridcheck) RIDCHECK=0; shift ;;
        --only) ONLY=",$2,"; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --tmux) shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "pips-rid-live: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
case "$F3PORT" in in0|in1|usp) ;; *) echo "--f3-port: in0, in1 or usp" >&2; exit 2 ;; esac
want() { [ -z "$ONLY" ] || [ "$1" = T0 ] || [[ "$ONLY" == *",$1,"* ]]; }

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT=${OUT:-$HOME/pips-rid-live-$HOSTN-$(date +%m%d-%H%M%S)}
TOKEN="r$$$RANDOM"
T_START=$SECONDS
if [ "$DRY" = 1 ]; then
    cat <<EOF
pips-rid-live (dry run) on $HOSTN, output $OUT
  T0 baselines (pips-rid-check.sh $( [ "$RIDCHECK" = 1 ] && echo on || echo off ), census under load, straddle/TFC)
  T1 usp read; T2 in0/in1 port reads (SC, tag, no fault, no leak); T3 isolation (page 32)
  T4-T6 engine trains under load: $( [ "$QUICK" = 1 ] && echo "INTERVAL {1000,1} x MAX_OUT {1,64}" || echo "INTERVAL {1000,100,10,1} x MAX_OUT {1,8,64,256}") x {idle-fill, engine-first}; engine tags ${TAGWIN:-the largest range free in the census}, MAX_OUT capped to its size
  T7 latency hit/miss + strides 512, 262144 (icx: 512 only); T8 once/cross/twice, N = 32-512, from a flushed IOTLB; T9 census under load
  T10 $( [ "$T10" = 1 ] && echo on || { [ "$FALLBACKS" = 1 ] && echo "if T2 fails" || echo off; }) T11 $( [ "$T11" = 1 ] && echo "on ($F3PORT)" || { [ "$FALLBACKS" = 1 ] && echo "if T2 faults" || echo off; }) T12 $( [ "$T12" = 1 ] && echo "${SOAK_MIN} min" || echo off)
  bigserver holder: $( [ "$START_HOLDER" = 1 ] && echo "started here (drives held until a reboot$( [ "$REBOOT" = 1 ] && echo "; reboot at the end"))" || echo "${HOLD:-the running one (pgrep)}")
  icx: pips_bg_region.ko pages in each NIC's domain; NIC load: ${LOAD_CMD:-built in (alias-rdma READs against styx, both NICs)}
EOF
    exit 0
fi
if [ "$IN_TMUX" = 1 ]; then
    . "$REPO/utils/ssd-lib.sh"   # relaunch_in_tmux: does not return
    relaunch_in_tmux "$HERE/pips-rid-live.sh" "${PASS[@]}" --out "$OUT"
fi
mkdir -p "$OUT" || exit 2
LOG="$OUT/log.txt"; SUM="$OUT/summary.txt"; RES="$OUT/results.tsv"
: > "$SUM"; printf 'test\tverdict\tdetail\n' > "$RES"
say() { echo "[rid-live $(date +%T) +$((SECONDS - T_START))s] $*" | tee -a "$LOG"; }
sum() { echo "$*" | tee -a "$SUM" >> "$LOG"; echo "$*"; }
pipsc() { sudo -n "$PIPS" "$@"; }
# the last KEY=value token in a file: `pips bg` prints some keys one per line, others several to a line
kv() { awk -v k="$1=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) v = substr($i, length(k) + 1) } END { if (v != "") print v }' "$2" 2>/dev/null; }
now_ms() { date +%s%3N; }
hsleep() { local n=0; while [ "$n" -lt "$1" ]; do sleep 1; n=$((n + 1)); [ $((n % 30)) = 0 ] && say "  ... $2 ($n of $1 s)"; done; }
tab() { column -t "$1" 2>/dev/null || cat "$1"; }
# wait_until <seconds> <what> <cmd...>: poll every second, a heartbeat every 10 s
wait_until() {
    local lim=$1 what=$2 n=0; shift 2
    until "$@"; do
        sleep 1; n=$((n + 1))
        [ $((n % 10)) = 0 ] && say "  ... waiting for $what (${n} s)"
        [ "$n" -ge "$lim" ] && return 1
    done
    return 0
}

say "start on $HOSTN, kernel $(uname -r), repo $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null); output $OUT"
sudo -v || { echo "pips-rid-live: needs sudo" >&2; exit 2; }
( while sleep 240; do sudo -n -v 2>/dev/null; done ) & SUDO_KEEP=$!
pips_build >> "$LOG" 2>&1 || { echo "ERROR: pips does not build (log.txt)" >&2; exit 2; }

# ------------------------------------------------------------------ cleanup
LOAD_PID=""; F3_LOADED=0; HOLD_LOAD=""; ABORT=0; NIC_LOAD=0; RGN_LOADED=0
cleanup() {
    pipsc bg stop 3000 >> "$LOG" 2>&1
    [ -n "$HOLD_LOAD" ] && [ -n "$HOLD" ] && touch "$HOLD/stop" 2>/dev/null
    [ -n "$LOAD_PID" ] && { pkill -INT -P "$LOAD_PID" 2>/dev/null; kill -INT "$LOAD_PID" 2>/dev/null; }
    [ "$NIC_LOAD" = 1 ] && nic_alias_stop
    [ "$F3_LOADED" = 1 ] && sudo -n rmmod pips_bg_pages 2>/dev/null
    [ "$RGN_LOADED" = 1 ] && sudo -n rmmod pips_bg_region 2>/dev/null
    kill "$SUDO_KEEP" 2>/dev/null
}
trap 'say "interrupted: stopping the engine and the loads"; cleanup; exit 130' INT TERM
trap cleanup EXIT

# ------------------------------------------------------------------ the build and the topology
pipsc cfg > "$OUT/cfg.txt" 2>&1
DESIGN=$(design_of "$OUT/cfg.txt")
pipsc bg info > "$OUT/bg-info.txt" 2>&1
if [ "$(kv bg_id "$OUT/bg-info.txt")" != 0x52494450 ]; then
    echo "ERROR: no 0x0A08 test engine here: design ${DESIGN:-?}, $(head -3 "$OUT/bg-info.txt" | tr '\n' ' ')" >&2; exit 2
fi
USP=$(pips_find_usp) || exit 2
PRI=$(( $(kv bus_primary "$OUT/bg-info.txt") )); SEC=$(( $(kv bus_secondary "$OUT/bg-info.txt") ))
bdf() { printf '0000:%02x:%02x.%d' "$1" "$2" "$3"; }
P0=$(bdf "$SEC" 0 0); P1=$(bdf "$SEC" 1 0)          # in0's port, in1's port
D0=$(bdf $((SEC + 1)) 0 0); D1=$(bdf $((SEC + 2)) 0 0) # the devices below them
short() { echo "${1#0000:}"; }
RP=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$USP)")")
devclass() { cat "/sys/bus/pci/devices/$1/class" 2>/dev/null; }
KIND=none
case "$(devclass "$D0")" in 0x0108*) KIND=ssd ;; 0x0200*) KIND=nic ;; esac
sum "pips-rid-live on $HOSTN, $(date '+%F %T'), kernel $(uname -r), design $DESIGN, BG_ID RIDP"
sum "topology: root port $RP, usp $USP, in0 port $P0 -> $D0 ($(devclass "$D0")), in1 port $P1 -> $D1 ($(devclass "$D1")); devices: $KIND"
sum "IOMMU: $(cat /proc/cmdline | tr ' ' '\n' | grep -E '^(intel_iommu|iommu)' | xargs)"
sum "engine: $(grep -E '^(bg_caps|bus_primary)' "$OUT/bg-info.txt" | xargs)"
[ "$KIND" = none ] && { sum "no NVMe drive or NIC below in0's port: nothing to test against"; exit 2; }

# ------------------------------------------------------------------ dmesg markers, DMAR, AER
mark() { echo "pips-rid-live[$TOKEN] $1" | sudo -n tee /dev/kmsg > /dev/null; }
kseg() {   # <test> <file>: the kernel log between the test's markers
    sudo -n dmesg 2>/dev/null | awk -v b="pips-rid-live\\[$TOKEN\\] $1 begin" -v e="pips-rid-live\\[$TOKEN\\] $1 end" \
        '$0 ~ b { on = 1 } on { print } $0 ~ e { on = 0 }' > "$2"
}
dmar_all() { grep -c -E 'DMAR: \[DMA (Read|Write)|DMAR:.*[Ff]ault' "$1"; }
dmar_for() { grep -E 'DMAR' "$1" | grep -c -i -E "device \[(0000:)?$(short "$2")\]"; }
aer_snap() {
    local b k f
    for b in "$RP" "$USP" "$P0" "$P1" "$D0" "$D1"; do
        printf '%s' "$b"
        for k in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
            f=/sys/bus/pci/devices/$b/$k
            [ -r "$f" ] && printf ' %s' "$(awk '$1 ~ /^TOTAL_ERR/ { print $2 }' "$f")" || printf ' -'
        done
        echo
    done
}

# ------------------------------------------------------------------ test bookkeeping
declare -A V; declare -A DET
CUR=""; TD=""
begin() {   # <test> <title> <pass condition>
    CUR=$1; TD="$OUT/$1"; mkdir -p "$TD"
    aer_snap > "$TD/aer-before.txt"; mark "$1 begin"
    sum ""; sum "== $1: $2"; sum "   pass: $3"
    say "$1 begin: $2"
}
end() {   # <verdict PASS|FAIL|INFO|SKIP> <detail>
    local v=$1 d=$2 ad
    mark "$CUR end"; aer_snap > "$TD/aer-after.txt"; kseg "$CUR" "$TD/dmesg.txt"
    ad=$(diff "$TD/aer-before.txt" "$TD/aer-after.txt" | grep '^>' | sed 's/^> //' | xargs)
    DMAR_N=$(dmar_all "$TD/dmesg.txt")
    sum "   kernel: $DMAR_N DMAR fault line(s) (usp $(dmar_for "$TD/dmesg.txt" "$USP"), in0 port $(dmar_for "$TD/dmesg.txt" "$P0"), in1 port $(dmar_for "$TD/dmesg.txt" "$P1"), dev0 $(dmar_for "$TD/dmesg.txt" "$D0"), dev1 $(dmar_for "$TD/dmesg.txt" "$D1")); AER: ${ad:-unchanged}"
    [ -n "$ad" ] && [ "$v" = PASS ] && { v=FAIL; d="$d; AER counters moved: $ad"; }
    V[$CUR]=$v; DET[$CUR]=$d
    sum "   $CUR: $v: $d"
    printf '%s\t%s\t%s\n' "$CUR" "$v" "$d" >> "$RES"
    say "$CUR end: $v"
}

# ------------------------------------------------------------------ the engine
# Every run sets everything, so nothing is left from the run before.
ENG_DEF="beat=30 ws=1 count=1 stoponerr=1 clronstart=1 fcoff=0 ridtag=0 tagwin=off order=cyclic src=pattern trace=0 dcheck=0 offset=0 dw=1 tskip=0 hshift=3 timeout_us=1000 nphres=2 arb=idle interval=0 maxout=1 first=0 stride=1 backing=0 seed=1 rid1=none rid2=none rid3=none"
ERC=0
# erun <name> <bg run settings...>: one run, counters in $TD/<name>.txt
erun() {
    local n=$1 f; shift
    f="$TD/$n.txt"
    if [ "$ABORT" = 1 ]; then echo "# not run: aborted after a leak or clash" > "$f"; ERC=5; return 5; fi
    echo "\$ pips bg run $ENG_DEF $*" > "$f"
    pipsc bg run $ENG_DEF "$@" 2>&1 | tee -a "$f" | grep --line-buffered '^# bg run: [0-9]' | while IFS= read -r l; do say "      $n ${l#\# }"; done
    ERC=${PIPESTATUS[0]}
    if [ "$ERC" = 1 ] && grep -q 'cfg_code=12' "$f"; then   # tags quarantined from before: clear and retry
        pipsc bg clear twice >> "$f" 2>&1
        pipsc bg run $ENG_DEF "$@" >> "$f" 2>&1; ERC=$?
    fi
    say "    $n: exit $ERC issued $(kv issued "$f") sc $(kv cpl_sc "$f") ur $(kv cpl_ur "$f") ca $(kv cpl_ca "$f") timeouts $(kv timeouts "$f") malformed $(kv cpl_malformed "$f") mism $(kv data_mismatch "$f") leak $(kv leak_cpl "$f") lat_mean $(kv lat_mean_ns "$f") ns last_data $(kv last_data "$f")"
    # a malformed completion (SC with byte count != 4*dw or the core's "request completed" bit clear) or a
    # timeout: keep the last 64 completions (req_done= per line) for the hardware agent
    local malf tmo; malf=$(kv cpl_malformed "$f"); tmo=$(kv timeouts "$f")
    if [ "${malf:-0}" != 0 ] || [ "${tmo:-0}" != 0 ]; then
        pipsc bg capture 64 > "$TD/$n-capture.txt" 2>&1
    fi
    if [ "$ERC" = 5 ] || [ "$(kv leak_seen "$f")" = 1 ] || [ "$(kv clash_seen "$f")" = 1 ]; then
        ABORT=1
        sum "   !! $n: LEAK or CLASH (leak_cpl $(kv leak_cpl "$f") last rid $(kv leak_last_rid "$f") tag $(kv leak_last_tag "$f") path $(kv leak_last_path "$f"); clash $(kv clash "$f")): the engine is stopped and is not restarted in this run"
        pipsc bg capture 16 > "$TD/$n-capture.txt" 2>&1
    fi
    return "$ERC"
}
cpl_total() { echo $(( $(kv cpl_sc "$1") + $(kv cpl_ur "$1") + $(kv cpl_ca "$1") + $(kv cpl_other "$1") )); }
tblrun() {   # <name> <table file> <settings...>: table mode over the file's entries
    local n=$1 t=$2 e; shift 2
    pipsc bg table load "$t" > "$TD/$n-table.txt" 2>&1 || { echo "# table load failed" > "$TD/$n.txt"; ERC=1; return 1; }
    e=$(kv table_entries "$TD/$n-table.txt")
    erun "$n" src=table ws="$e" "$@"
}

# ------------------------------------------------------------------ bigserver: the holder
REG=0x4000000000
hold_find() {
    [ -n "$HOLD" ] && return 0
    local c
    c=$(pgrep -af 'alias-nvm[e] .*--hold ' | head -1)
    [ -n "$c" ] || return 1
    HOLD=$(echo "$c" | sed -n 's/.*--hold \([^ ]*\).*/\1/p')
    [ -n "$HOLD" ]
}
hold_ok() { grep -q '^ready' "$HOLD/state" 2>/dev/null && [ -n "$(cut -d' ' -f1 "$HOLD/alive" 2>/dev/null)" ] &&
    [ $(( $(now_ms) - $(cut -d' ' -f1 "$HOLD/alive") )) -lt 10000 ]; }
hold_start() {   # as pips-campaign.sh hold_up: both drives, 4 queues, qd 32, 4 KiB
    [ -r "$REPO/utils/setup-server.sh" ] && . "$REPO/utils/setup-server.sh"
    local i b nv bdfs=("$D0" "$D1") sers=() cpus=()
    for i in 0 1; do
        b=${bdfs[$i]}
        [ "$(basename "$(readlink -f /sys/bus/pci/devices/$b/driver 2>/dev/null)")" = nvme ] ||
            { sum "drive $b is not on nvme (driver $(basename "$(readlink -f /sys/bus/pci/devices/$b/driver 2>/dev/null)")): reboot first"; return 1; }
        sers+=("$(cat /sys/bus/pci/devices/$b/nvme/nvme*/serial 2>/dev/null | head -1 | tr -d ' ')")
        cpus+=("${SSD_CORES[$i]:-$((i * 8 + 2)),$((i * 8 + 3)),$((i * 8 + 4)),$((i * 8 + 5))}")
    done
    nv=$(bash "$HERE/alias/alias-run.sh" --build alias-nvme 2>&1 | tail -1)
    [ -x "$nv" ] || { sum "alias-nvme does not build: $nv"; return 1; }
    HOLD="$OUT/hold"; mkdir -p "$HOLD"
    printf '0 %s %s\n1 %s %s\n' "$D0" "${sers[0]}" "$D1" "${sers[1]}" > "$HOLD/drives"
    echo "queues 4 qd 32 bs 4096" > "$HOLD/config"
    sudo -n bash "$HERE/alias/alias-vfio.sh" bind "$D0" "$D1" >> "$LOG" 2>&1 || { sum "could not bind the drives to vfio-pci (log.txt)"; return 1; }
    say "holder: starting alias-nvme --hold $HOLD (the drives stay held until a reboot)"
    sudo -n setsid "$nv" --dev "$D0=$HOLD/init-ssd0" --dev "$D1=$HOLD/init-ssd1" --serial "${sers[0]},${sers[1]}" \
        --queues 4,4 --cpus "${cpus[0]}/${cpus[1]}" --qd 32 --bs 4k --lba rand --ws 64 --stride 1 --heartbeat 10 \
        --hold "$HOLD" >> "$HOLD/holder.txt" 2>&1 < /dev/null &
    wait_until 120 "the holder to be ready" grep -q '^ready' "$HOLD/state" ||
        { sum "the holder did not come up (hold/holder.txt): $(tail -3 "$HOLD/holder.txt" | xargs)"; return 1; }
    if [ "$GUARD" = 1 ]; then
        bash "$HERE/alias/alias-guard.sh" arm "$OUT/guard" "$HOLD" 120 2>&1 | tee -a "$LOG" ||
            { sum "the BMC guard did not arm: the holder keeps the drives; reboot to end"; return 1; }
    fi
}
HN=0
hold_send() {   # <command line>: send it, wait for its done line; 0 if ok
    local name line=$1 lim=${2:-180}
    name=$(echo "$line" | awk '{ print $2 }')
    echo "$line" > "$HOLD/cmd.tmp" && mv "$HOLD/cmd.tmp" "$HOLD/cmd"
    wait_until "$lim" "the holder's '$name'" sh -c "[ \"\$(awk '{ print \$2 }' '$HOLD/done' 2>/dev/null)\" = '$name' ]" ||
        { say "  the holder did not finish '$name' in $lim s"; return 1; }
    grep -q "^[0-9]* $name ok" "$HOLD/done"
}
# hold_map <ws0> <stride0> <ws1> <stride1>: both regions mapped again, every page tagged
BK0=0; BK1=0
hold_map() {
    HN=$((HN + 1))
    local s0=$(( ($1 - 1) * $2 + 1 )) s1=$(( ($3 - 1) * $4 + 1 ))
    BK0=$(( s0 < 65536 ? s0 : 65536 )); BK1=$(( s1 < 65536 ? s1 : 65536 ))
    say "  holder: map drive 0 ws $1 stride $2, drive 1 ws $3 stride $4 (fresh tags; backing $BK0 / $BK1)"
    hold_send "map rl$TOKEN-m$HN 3 $1 $2 cyclic ws1=$3 stride1=$4" 300
}
# hold_load_start <secs> <dir> [extras]: both drives, in the background; waits until loaded
hold_load_start() {
    HN=$((HN + 1)); HOLD_LOAD="rl$TOKEN-l$HN"
    mkdir -p "$2"; rm -f "$2/ready"
    echo "load $HOLD_LOAD 3 64 1 cyclic 2 $1 $2 $2/ready cursor=queue ${3:-}" > "$HOLD/cmd.tmp" && mv "$HOLD/cmd.tmp" "$HOLD/cmd"
    wait_until 120 "the drives' load to start" test -e "$2/ready" || { say "  the load did not start"; return 1; }
    say "  drives under load ($HOLD_LOAD, ${1} s, ws 64 each, 4 queues x qd 32)"
}
hold_load_end() {   # stop the load (if still running), wait for its done line; 0 if ok
    [ -n "$HOLD_LOAD" ] || return 0
    local n=$HOLD_LOAD
    touch "$HOLD/stop"
    wait_until 120 "the load '$n' to end" sh -c "[ \"\$(awk '{ print \$2 }' '$HOLD/done' 2>/dev/null)\" = '$n' ]"
    rm -f "$HOLD/stop"; HOLD_LOAD=""
    grep -q "^[0-9]* $n ok" "$HOLD/done"
}

# ------------------------------------------------------------------ icx: the NIC load and the pages
# The built-in load: per NIC an alias-rdma server on styx (ssh, screen) and a client here that READs from it,
# its NIC writing the responses into a 64-page MR (4 QPs x depth 16, 4 KiB), until stopped. Ports
# BASE_PORTS[i] + 700, as run-dualnic-experiment.sh (styx answered nothing on + 760, 11-07: a firewall lets
# only the campaign's ports through). NI0/NI1: the config index of each NIC.
rsh_try() {
    if [ -n "${CLIENT_PWD:-}" ]; then
        sshpass -p "$CLIENT_PWD" ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    else
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
    fi
}
NI0=0; NI1=1; ALIAS_RDMA=""; R_ALIAS_RDMA=""
nic_port() { echo $(( ${BASE_PORTS[$1]:-$((3000 + 1000 * $1))} + 700 )); }
nic_index() {   # <bdf>: the index of its netdev in SERVER_INTFS, or the default given
    local nd i
    nd=$(ls "/sys/bus/pci/devices/$1/net" 2>/dev/null | head -1)
    for i in "${!SERVER_INTFS[@]}"; do [ "${SERVER_INTFS[$i]}" = "$nd" ] && { echo "$i"; return; }; done
    echo "$2"
}
nic_setup() {   # the built-in load's prerequisites: config, builds on both hosts, data-plane links
    [ -r "$REPO/utils/setup-server.sh" ] || { sum "icx: no utils/setup-server.sh (the NICs' config): no built-in load"; return 1; }
    . "$REPO/utils/setup-server.sh"
    [ -n "${CLIENT_SSH_IP:-}" ] && [ "${#SERVER_INTFS[@]}" -ge 2 ] && [ "${#CLIENT_NIC_IPS[@]}" -ge 2 ] ||
        { sum "icx: utils/setup-server.sh lacks CLIENT_SSH_IP / SERVER_INTFS / CLIENT_NIC_IPS for two NICs: no built-in load"; return 1; }
    NI0=$(nic_index "$D0" 0); NI1=$(nic_index "$D1" 1)
    say "icx: in0's NIC $D0 = ${SERVER_INTFS[$NI0]} -> styx ${CLIENT_NIC_IPS[$NI0]}; in1's NIC $D1 = ${SERVER_INTFS[$NI1]} -> styx ${CLIENT_NIC_IPS[$NI1]}"
    if pgrep -f 'alias-rdm[a] --role client' > /dev/null; then
        sum "icx: an alias-rdma client already runs here (a campaign?): stop it first"; return 1
    fi
    ALIAS_RDMA=$(bash "$HERE/alias/alias-run.sh" --build alias-rdma 2>&1 | tail -1)
    [ -x "$ALIAS_RDMA" ] || { sum "icx: alias-rdma does not build here: $ALIAS_RDMA"; return 1; }
    R_ALIAS_RDMA=$(rsh_try "bash '$HERE/alias/alias-run.sh' --build alias-rdma" 2>&1 | tail -1)
    rsh_try "test -x '$R_ALIAS_RDMA'" || { sum "icx: alias-rdma does not build on styx ($R_ALIAS_RDMA): same repo path there, git pull, libibverbs-dev"; return 1; }
    local i
    for i in "$NI0" "$NI1"; do
        ping -c 2 -W 3 -I "${SERVER_INTFS[$i]}" "${CLIENT_NIC_IPS[$i]}" > /dev/null 2>&1 && continue
        say "  NIC $i: no data-plane link: setup-envir.sh on both ends (as run-dualnic-experiment.sh)"
        ( cd "$REPO/utils" && sudo -n bash setup-envir.sh -i "${SERVER_INTFS[$i]}" -a "${SERVER_NIC_IPS[$i]}" -m "${MTU:-4000}" \
            --ring_buffer "${RING_BUFFER:-1024}" --buf "${SOCK_BUF_MB:-1}" ) >> "$LOG" 2>&1
        rsh_try "cd '$REPO/utils' && sudo bash setup-envir.sh -i ${CLIENT_INTFS[$i]} -a ${CLIENT_NIC_IPS[$i]} -m ${MTU:-4000} --ring_buffer ${RING_BUFFER:-1024} --buf ${SOCK_BUF_MB:-1}" >> "$LOG" 2>&1
        sleep 5
        ping -c 2 -W 3 -I "${SERVER_INTFS[$i]}" "${CLIENT_NIC_IPS[$i]}" > /dev/null 2>&1 ||
            { sum "icx: NIC $i (${SERVER_INTFS[$i]}) cannot reach styx's ${CLIENT_NIC_IPS[$i]}: no built-in load"; return 1; }
    done
    sum "icx: built-in load ready: alias-rdma $ALIAS_RDMA here, $R_ALIAS_RDMA on styx"
}
nic_alias_stop() {
    sudo -n pkill -INT -f 'alias-rdm[a] --role client .*--name ridlive_nic' 2>/dev/null
    wait_until 60 "the alias-rdma clients to end" sh -c "! pgrep -f 'alias-rdm[a] --role client .*--name ridlive_nic' > /dev/null"
    rsh_try "sudo pkill -INT -f 'alias-rdm[a] --role server .*--port ($(nic_port "$NI0")|$(nic_port "$NI1"))( |\$)' > /dev/null 2>&1; screen -wipe > /dev/null 2>&1; true"
    NIC_LOAD=0
}
nic_load_start() {   # <secs> <dir>: secs is ignored (runs until nic_load_end)
    local d=${2:-$TD/load} i n port
    mkdir -p "$d"
    if [ -n "$LOAD_CMD" ]; then
        say "  NIC load: $LOAD_CMD"
        setsid bash -c "$LOAD_CMD" > "$d/load.txt" 2>&1 < /dev/null & LOAD_PID=$!
        sleep 15
        kill -0 "$LOAD_PID" 2>/dev/null || { say "  the NIC load ended at once (load.txt)"; LOAD_PID=""; return 1; }
        return 0
    fi
    [ "$NIC_OK" = 1 ] || return 1
    NIC_LOAD=1
    rsh_try "sudo pkill -INT -f 'alias-rdm[a] --role server .*--port ($(nic_port "$NI0")|$(nic_port "$NI1"))( |\$)' > /dev/null 2>&1; screen -wipe > /dev/null 2>&1; true"
    sleep 1
    for i in "$NI0" "$NI1"; do
        port=$(nic_port "$i")
        rsh_try "screen -dmS ridlive_srv$i bash -c \"sudo $R_ALIAS_RDMA --role server --netdev ${CLIENT_INTFS[$i]} --port $port --heartbeat 30 > /tmp/ridlive-srv$i.log 2>&1\""
    done
    sleep 2
    for i in "$NI0" "$NI1"; do   # the servers listen on styx?
        port=$(nic_port "$i")
        rsh_try "ss -ltn 2>/dev/null | grep -q ':$port '" ||
            say "  WARNING: styx: no listener on TCP $port: $(rsh_try "tail -n 3 /tmp/ridlive-srv$i.log" 2>&1 | tr '\n' ' ' | cut -c1-250)"
    done
    for i in "$NI0" "$NI1"; do
        port=$(nic_port "$i"); rm -f "$d/ready-nic$i"
        sudo -n setsid "$ALIAS_RDMA" --role client --netdev "${SERVER_INTFS[$i]}" --server-ip "${CLIENT_NIC_IPS[$i]}" --port "$port" \
            --qps 4 --depth 16 --bs 4096 --ws 64 --stride 1 --warm 2 --seconds 0 --heartbeat 10 \
            $( [ -n "${SERVER_CORES[$i]:-}" ] && echo "--cpu ${SERVER_CORES[$i]%%,*}" ) \
            --name "ridlive_nic$i" --out "$d/fio-nic$i" --ready-file "$d/ready-nic$i" > "$d/alias-rdma-nic$i.log" 2>&1 < /dev/null &
    done
    n=0
    until [ -e "$d/ready-nic$NI0" ] && [ -e "$d/ready-nic$NI1" ]; do
        sleep 1; n=$((n + 1)); [ $((n % 10)) = 0 ] && say "  ... waiting for the NIC load to start (${n} s)"
        # give up at 90 s, or as soon as a client has exited without getting ready
        dead=0
        for i in "$NI0" "$NI1"; do
            [ -e "$d/ready-nic$i" ] || pgrep -f "alias-rdm[a] --role client .*--name ridlive_nic$i( |\$)" > /dev/null || dead=1
        done
        if [ "$n" -ge 90 ] || { [ "$n" -ge 5 ] && [ "$dead" = 1 ]; }; then
            say "  the NIC load did not start: $(grep -h -E '^ERROR' "$d"/alias-rdma-nic*.log | tr '\n' ' ' | cut -c1-400)"
            for i in "$NI0" "$NI1"; do rsh_try "cat /tmp/ridlive-srv$i.log" > "$d/server-nic$i.log" 2>&1; done
            nic_alias_stop; return 1
        fi
    done
    sleep 4
    say "  NICs under load (alias-rdma READs, 4 QPs x depth 16, ws 64, both NICs; $d)"
}
nic_load_end() {
    if [ -n "$LOAD_PID" ]; then
        kill -INT -- -"$LOAD_PID" 2>/dev/null || kill -INT "$LOAD_PID" 2>/dev/null
        wait_until 120 "the NIC load to end" sh -c "! kill -0 $LOAD_PID 2>/dev/null"
        LOAD_PID=""; return 0
    fi
    [ "$NIC_LOAD" = 1 ] || return 0
    nic_alias_stop
    ! grep -q -E '^ERROR|READ on QP .* failed' "$TD"/load/alias-rdma-nic*.log 2>/dev/null
}
load_start() { if [ "$KIND" = ssd ]; then hold_load_start "$@"; else nic_load_start "$@"; fi; }
load_end() { if [ "$KIND" = ssd ]; then hold_load_end; else nic_load_end; fi; }

# icx: pips_bg_region.ko for both NICs: RGN_N pages from each NIC's base RB0 / RB1, page k = k mod RGN_BK in
# DW0 and the NIC's number in DW1. A reload unmaps (flushing those IOTLB entries) and maps again.
RGN_N=65536; RGN_BK=8192; RB0=""; RB1=""
nic_region_load() {
    local d="$OUT/rgn" r
    if [ ! -e "$d/pips_bg_region.ko" ]; then
        [ -d "/lib/modules/$(uname -r)/build" ] || { sum "icx: no kernel headers (/lib/modules/$(uname -r)/build): install linux-headers-$(uname -r)"; return 1; }
        mkdir -p "$d" && cp "$HERE/ridcheck/pips_bg_region.c" "$HERE/ridcheck/Makefile" "$d/"
        make -C "$d" MODS=pips_bg_region > "$d/build.txt" 2>&1 || { sum "icx: pips_bg_region does not build ($d/build.txt)"; return 1; }
    fi
    lsmod | grep -q '^pips_bg_region ' && { sudo -n rmmod pips_bg_region || return 1; }
    RGN_LOADED=0
    sudo -n insmod "$d/pips_bg_region.ko" dev="$D0,$D1" npages=$RGN_N backing=$RGN_BK token="$TOKEN" 2> "$d/insmod.txt" ||
        { sum "icx: insmod pips_bg_region failed: $(cat "$d/insmod.txt") $(sudo -n dmesg | grep "pips_bg_region\[$TOKEN\]" | tail -2 | xargs)"; return 1; }
    RGN_LOADED=1
    r=$(sudo -n cat /sys/kernel/debug/pips_bg_region/regions 2>/dev/null); printf '%s\n' "$r" > "$d/regions.txt"
    RB0=$(echo "$r" | awk -v d="$D0" '$2 == d { print $4 }'); RB1=$(echo "$r" | awk -v d="$D1" '$2 == d { print $4 }')
    [ -n "$RB0" ] && [ -n "$RB1" ] || { sum "icx: the module's regions are not as expected: $r"; return 1; }
    if echo "$r" | awk '{ for (i = 1; i < NF; i++) if ($i == "domain") print $(i + 1) }' | grep -q -v -E '^dma(-fq)?$'; then
        sum "icx: a NIC is not in a translating DMA domain ($(echo "$r" | xargs)): boot with the IOMMU in strict or lazy mode"; return 1
    fi
    sleep 0.2   # lazy mode: the unmap's flush queue drains within ~10 ms
}

# ------------------------------------------------------------------ setup
if [ "$KIND" = ssd ]; then
    # a holder whose folder was deleted still holds the drives but can't be driven (cmd/state/alive live there);
    # never kill it (drive b4 freezes the host when reset after a load): reboot
    if hold_find && [ ! -d "$HOLD" ]; then
        sum "an alias-nvme holder still runs and holds the drives, but its folder $HOLD is gone, so it can't be used or replaced. Reboot (sync; sudo systemctl reboot -ff), then --start-holder"; exit 2
    fi
    if [ "$START_HOLDER" = 1 ]; then
        hold_find && { sum "a holder already runs ($HOLD): use it (drop --start-holder)"; exit 2; }
        hold_start || exit 2
    else
        hold_find || { sum "no alias-nvme holder runs: start one with --start-holder (the drives then stay held until a reboot)"; exit 2; }
    fi
    hold_ok || { sum "the holder in $HOLD is not alive (state: $(cat "$HOLD/state" 2>/dev/null))"; exit 2; }
    grep -q ' map' "$HOLD/state" || { sum "the holder predates the map command (state: $(cat "$HOLD/state")): its tags are overwritten by every load, so T2's data check cannot run. Reboot, then --start-holder"; exit 2; }
    HD0=$(awk '$1 == 0 { print $2 }' "$HOLD/drives" 2>/dev/null); HD1=$(awk '$1 == 1 { print $2 }' "$HOLD/drives" 2>/dev/null)
    [ "${HD0#0000:}" = "${D0#0000:}" ] && [ "${HD1#0000:}" = "${D1#0000:}" ] ||
        { sum "the holder's drives ($HD0, $HD1) are not the ones below in0/in1 ($D0, $D1): stop"; exit 2; }
    sum "holder: $HOLD ($(cat "$HOLD/state")); regions at IOVA $REG in each drive's domain"
else
    NIC_OK=0
    if [ -n "$LOAD_CMD" ] || nic_setup; then NIC_OK=1; else sum "icx: no NIC load: T0's census, T4-T6 and T9 run without one or are skipped"; fi
    nic_region_load || exit 2
    sum "icx: pips_bg_region.ko: $RGN_N pages at IOVA $RB0 in $D0's domain, $RB1 in $D1's (page k = k mod $RGN_BK in DW0, the NIC's number in DW1)"
fi
pipsc bg stop 3000 >> "$LOG" 2>&1
pipsc bg clear twice >> "$LOG" 2>&1

# ------------------------------------------------------------------ T0
begin T0 "baselines: host view, census under load, straddle and flow control" "RC_STRADDLE = 0 and RQ_STRADDLE = 0; census tag maps saved"
if [ "$RIDCHECK" = 1 ]; then
    say "  pips-rid-check.sh --module --pt (host view; a few minutes)"
    IV=$REG; [ "$KIND" = nic ] && IV=$RB0
    bash "$HERE/pips-rid-check.sh" --module --pt --iova "$IV,$((IV + 0x1000)),$((IV + 0x3f000))" --out "$TD/ridcheck" > "$TD/ridcheck.txt" 2>&1
    sum "   host view (pips-rid-check.sh, exit $?): $(grep -E '^(HOLDS|FAILS|NOT DECIDED)' "$TD/ridcheck/summary.txt" 2>/dev/null | head -1 | cut -c1-160)"
fi
pipsc bg facts clear >> "$LOG" 2>&1; pipsc bg census clear >> "$LOG" 2>&1
T0_LOAD=0
if load_start 45 "$TD/load"; then
    T0_LOAD=1; hsleep 30 "census under load"
    pipsc bg census > "$TD/census.txt" 2>&1; pipsc bg facts > "$TD/facts.txt" 2>&1
    load_end || sum "   WARNING: the load ended with an error"
else
    sleep 5; pipsc bg census > "$TD/census.txt" 2>&1; pipsc bg facts > "$TD/facts.txt" 2>&1
fi
sum "   census: in0 $(kv in0_mrd "$TD/census.txt") MRd, tags $(kv in0_tags "$TD/census.txt") (max $(kv in0_tag_max "$TD/census.txt"), free $(kv in0_free_max "$TD/census.txt")); in1 $(kv in1_mrd "$TD/census.txt") MRd, tags $(kv in1_tags "$TD/census.txt") (free $(kv in1_free_max "$TD/census.txt"))"
sum "   facts: rc_straddle $(kv rc_straddle "$TD/facts.txt") rq_straddle $(kv rq_straddle "$TD/facts.txt") tfc_present $(kv tfc_present "$TD/facts.txt") nph_av $(kv tfc_nph_av "$TD/facts.txt") (min $(kv tfc_nph_min "$TD/facts.txt")) npd_av $(kv tfc_npd_av "$TD/facts.txt") hol_device $(kv hol_device "$TD/facts.txt")"
# The engine's tags. The core (client tags on) tracks requests by tag alone, and the devices' tags pass through
# to it unchanged, so an engine read on a tag a device has in flight comes back SC with "request completed" clear:
# CPL_MALFORMED, then a timeout (11-07: 32 of 32 T4 trains, every failing tag in drive 0's 0-127). Every run
# from here keeps the engine in the largest range no device used in this census, unless --tagwin.
free_win() {   # <census file>: "LO-HI N", the largest tag range unused by every input and completion path
    [ -n "$(kv in0_tags "$1")" ] || { echo "none 0"; return; }
    echo "$(kv in0_tags "$1"),$(kv in1_tags "$1"),$(kv cpl0_tags "$1"),$(kv cpl1_tags "$1")" | awk -F, '{
        for (i = 1; i <= NF; i++) {
            if ($i == "" || $i == "none") continue
            n = split($i, r, "-"); lo = r[1] + 0; hi = (n > 1 ? r[2] : r[1]) + 0
            for (t = lo; t <= hi; t++) used[t] = 1
        }
        s = -1; bl = -1; bn = 0
        for (t = 0; t <= 256; t++) {
            if (t < 256 && !(t in used)) { if (s < 0) s = t }
            else if (s >= 0) { if (t - s > bn) { bn = t - s; bl = s }; s = -1 }
        }
        if (bn) printf "%d-%d %d\n", bl, bl + bn - 1, bn; else print "none 0"
    }'
}
read -r FW FWN <<< "$(free_win "$TD/census.txt")"
# Headroom: a device takes more tags when it waits longer (icx 11-07: NIC 0 used 0-5 in T0's census, 0-21
# under T4's engine-first trains, 23 reads inside the window 6-255). A free range ending at 255 is cut to
# its upper half, from 128, when that leaves at least 64 tags.
if [ "${FW#*-}" = 255 ] && [ "${FW%-*}" -lt 128 ] 2>/dev/null; then FW=128-255; FWN=128; fi
case "${TAGWIN:-}" in
    off) ENG_WIN=off; WIN_N=256; sum "   engine tags: all 256 (--tagwin off): reads on a device's live tag come back malformed" ;;
    ?*)  ENG_WIN=$TAGWIN; WIN_N=$(( ${TAGWIN#*-} - ${TAGWIN%-*} + 1 )); sum "   engine tags: $ENG_WIN (--tagwin; the census left $FW free)" ;;
    *)   if [ "$T0_LOAD" = 1 ] && [ "${FWN:-0}" -ge 16 ]; then ENG_WIN=$FW; WIN_N=$FWN
             sum "   engine tags: $ENG_WIN ($WIN_N), from the largest range no device used under load (its upper half when it reaches 255)$( [ "$FWN" -lt 64 ] && echo "; MAX_OUT is capped at $WIN_N")"
         elif [ "${FWN:-0}" -ge 16 ]; then ENG_WIN=$FW; WIN_N=$FWN   # no load: the idle census is still better than all 256
             sum "   WARNING: engine tags: $ENG_WIN ($WIN_N), from an idle census (no load ran): a loaded device may use more tags"
         else ENG_WIN=off; WIN_N=256
             sum "   WARNING: engine tags: all 256 (census: $( [ "$T0_LOAD" = 1 ] && echo "free range $FW ($FWN) < 16" || echo "no load ran, free range $FW ($FWN)")): reads may collide with the devices' tags (malformed + timeout)"
         fi ;;
esac
ENG_DEF=${ENG_DEF/tagwin=off/tagwin=$ENG_WIN}
cap_mo() { echo $(( $1 > WIN_N ? WIN_N : $1 )); }
if [ "$(kv rc_straddle "$TD/facts.txt")" = 0 ] && [ "$(kv rq_straddle "$TD/facts.txt")" = 0 ]; then
    end PASS "no straddle$( [ "$T0_LOAD" = 0 ] && echo " (no load ran: idle traffic only)")"
else
    end FAIL "straddled beats: the sink and the router need straddle handling before any engine read (A5)"
fi

decide_stop() {   # <why>: stop here unless --keep-going
    [ "$KEEP" = 1 ] && { sum "   (--keep-going: going on)"; return 1; }
    STOPPED="$1"; return 0
}
STOPPED=""
[ "${V[T0]}" = FAIL ] && decide_stop "T0: straddle"

# The pages: bigserver: the holder's regions at REG in both drives' domains (hold_map sets them and BK0/BK1);
# icx: pips_bg_region's, B0 in NIC 0's domain, B1 in NIC 1's. A table mixing both ports reads from BB with
# the offsets O0/O1 (pages); the regions are size-aligned, so the offsets keep k mod backing.
nic_bases() {
    if [ "$KIND" = ssd ]; then B0=$REG; B1=$REG; BB=$REG; O0=0; O1=0; return; fi
    B0=$RB0; B1=$RB1; BK0=$RGN_BK; BK1=$RGN_BK
    if [ $((RB0)) -le $((RB1)) ]; then BB=$RB0; else BB=$RB1; fi
    O0=$(( (RB0 - BB) / 4096 )); O1=$(( (RB1 - BB) / 4096 ))
}
t8_ok() {   # a mixed table reaches both regions from BB: indices < 2^30; the data check needs offsets = 0 mod backing
    T8DC="dcheck=1 backing=$BK0"; [ $(( O0 % BK0 )) = 0 ] && [ $(( O1 % BK0 )) = 0 ] || T8DC="dcheck=0"
    [ $(( (O0 > O1 ? O0 : O1) + 70000 )) -lt $(( 1 << 30 )) ]
}
nic_bases

# ------------------------------------------------------------------ T1
if [ -z "$STOPPED" ] && want T1; then
    begin T1 "one read under the upstream port's ID (A4)" "one completion comes back (UR/CA expected: nothing is mapped for the usp), timeouts 0, no leak"
    [ "$KIND" = ssd ] && hold_map 64 1 16 1
    erun usp rid=usp base="$B0" ws=1 count=1
    f="$TD/usp.txt"
    pipsc bg capture 1 > "$TD/capture.txt" 2>&1
    sum "   completion: sc $(kv cpl_sc "$f") ur $(kv cpl_ur "$f") ca $(kv cpl_ca "$f") other $(kv cpl_other "$f") timeouts $(kv timeouts "$f"); $(grep '^cap ' "$TD/capture.txt" | cut -c1-200)"
    if [ "$(cpl_total "$f")" = 1 ] && [ "$(kv timeouts "$f")" = 0 ] && [ "$(kv leak_cpl "$f")" = 0 ]; then
        end PASS "the core sent the request and the sink took the reply (status $(kv last_cpl_status "$f"))"
    else
        end FAIL "no completion (timeouts $(kv timeouts "$f")): the beat format (A4) or the root complex dropped it: capture.txt, axis_ila_bg"
        decide_stop "T1: no completion for the usp read"
    fi
fi

# ------------------------------------------------------------------ T2
T2_KIND=""
if [ -z "$STOPPED" ] && want T2; then
    begin T2 "the main assumption: a downstream port's ID reads through its device's domain (A1-A3)" \
        "per port: SC, payload = the page's tag, no DMAR fault, LEAK_CPL 0, AER unchanged; then 64 (in0) / 16 (in1) reads, all SC, no data mismatch"
    ok=1; why=""
    [ "$KIND" = ssd ] && hold_map 64 1 16 1
    erun in0-one rid=in0 base=$B0 first=5 ws=1 count=1 dcheck=1 backing=$BK0
    erun in0-64 rid=in0 base=$B0 ws=64 count=64 dcheck=1 backing=$BK0
    erun in1-one rid=in1 base=$B1 first=7 ws=1 count=1 dcheck=1 backing=$BK1
    erun in1-16 rid=in1 base=$B1 ws=16 count=16 dcheck=1 backing=$BK1
    for p in in0 in1; do
        o="$TD/$p-one.txt"; m="$TD/$p-$([ $p = in0 ] && echo 64 || echo 16).txt"; want_tag=$([ $p = in0 ] && echo 5 || echo 7)
        n=$([ $p = in0 ] && echo 64 || echo 16)
        line="$p: one read sc $(kv cpl_sc "$o") ur $(kv cpl_ur "$o") ca $(kv cpl_ca "$o") timeouts $(kv timeouts "$o") data $(kv last_data "$o") (tag $want_tag); $n reads: sc $(kv cpl_sc "$m")/$n mismatch $(kv data_mismatch "$m") lat_mean $(kv lat_mean_ns "$m") ns"
        sum "   $line"
        if [ "$(kv cpl_sc "$o")" = 1 ] && [ $(( $(kv last_data "$o") )) = "$want_tag" ] && [ "$(kv cpl_sc "$m")" = "$n" ] && [ "$(kv data_mismatch "$m")" = 0 ]; then :; else
            ok=0; why="$why $p"
            if [ "$(cpl_total "$o")" = 0 ]; then T2_KIND=${T2_KIND:-nocpl}; else T2_KIND=${T2_KIND:-fault}; fi
        fi
    done
    if [ "$KIND" = nic ]; then   # DW1 = the NIC whose region answered: each port must reach its own NIC's
        for p in in0 in1; do
            want_n=$([ $p = in0 ] && echo 1 || echo 2); pb=$([ $p = in0 ] && echo "$B0" || echo "$B1")
            erun "$p-id" rid=$p base="$pb" first=9 ws=1 count=1 dw=2
            pipsc bg capture 1 > "$TD/$p-id-capture.txt" 2>&1
            d1=$(grep -o 'dw1=0x[0-9a-f]*' "$TD/$p-id-capture.txt" | head -1 | cut -d= -f2)
            sum "   $p: a 2-DW read: sc $(kv cpl_sc "$TD/$p-id.txt") DW0 $(grep -o 'dw0=0x[0-9a-f]*' "$TD/$p-id-capture.txt" | head -1 | cut -d= -f2) DW1 ${d1:-?} (want $want_n: $p's own NIC)"
            [ "$(kv cpl_sc "$TD/$p-id.txt")" = 1 ] && [ $(( ${d1:-0} )) = "$want_n" ] || { ok=0; why="$why $p(DW1 $(( ${d1:-0} )), not its own NIC's region)"; T2_KIND=${T2_KIND:-fault}; }
        done
    fi
    if [ "$T2_KIND" != skip ]; then
        kseg T2 "$TD/dmesg-now.txt"
        fp0=$(dmar_for "$TD/dmesg-now.txt" "$P0"); fp1=$(dmar_for "$TD/dmesg-now.txt" "$P1")
        [ "$fp0$fp1" != 00 ] && { ok=0; why="$why dmar(in0 port $fp0, in1 port $fp1)"; T2_KIND=${T2_KIND:-fault}; }
        if [ "$ok" = 1 ]; then
            end PASS "both ports read their device's pages with the right tags: A1-A3 hold (F0)"
        else
            end FAIL "failed for:$why ($T2_KIND): $( [ "$T2_KIND" = fault ] && echo "UR/CA or DMAR naming the port: A1 fails -> T11 (F3), then T9-T10 (F2)" || echo "no completion: A2/A3 (root complex or sink/route): capture, leak, axis_ila_bg; then F2")"
        fi
    fi
fi
F0=0; [ "${V[T2]:-}" = PASS ] && F0=1

# ------------------------------------------------------------------ T3
if [ -z "$STOPPED" ] && [ "$F0" = 1 ] && want T3; then
    begin T3 "isolation: each port uses its own device's domain (A1)" \
        "page 32 of device 0's pages: in0's port SC with tag 32; in1's port UR/CA (bigserver: mapped only in drive 0's domain), or on icx SC from another mapping (DW1 not 1)"
    [ "$KIND" = ssd ] && hold_map 64 1 16 1
    erun in0-p32 rid=in0 base=$B0 first=32 ws=1 count=1 dcheck=1 backing=$BK0
    erun in1-p32 rid=in1 base=$B0 first=32 ws=1 count=1 dw=2
    pipsc bg capture 1 > "$TD/in1-p32-capture.txt" 2>&1
    a="$TD/in0-p32.txt"; b="$TD/in1-p32.txt"
    d1=$(grep -o 'dw1=0x[0-9a-f]*' "$TD/in1-p32-capture.txt" | head -1 | cut -d= -f2)
    kseg T3 "$TD/dmesg-now.txt"; f1=$(dmar_for "$TD/dmesg-now.txt" "$P1")
    sum "   in0 port: sc $(kv cpl_sc "$a") data $(kv last_data "$a"); in1 port: sc $(kv cpl_sc "$b") ur $(kv cpl_ur "$b") ca $(kv cpl_ca "$b") data $(kv last_data "$b") DW1 ${d1:-?}; DMAR naming in1's port: $f1"
    iso=""
    if [ "$(kv cpl_sc "$b")" = 0 ] && [ "$(cpl_total "$b")" = 1 ]; then iso="UR/CA through in1's port"
    elif [ "$KIND" = nic ] && [ "$(kv cpl_sc "$b")" = 1 ] && [ $(( ${d1:-1} )) != 1 ]; then iso="in1's port reached another mapping at that IOVA (DW1 ${d1}: $( [ $(( d1 )) = 2 ] && echo "in1's own NIC's region" || echo "not a region page"))"; fi
    if [ "$(kv cpl_sc "$a")" = 1 ] && [ $(( $(kv last_data "$a") )) = 32 ] && [ -n "$iso" ]; then
        end PASS "each port translates in its own device's domain: $iso$( [ "$f1" = 0 ] && [ "$(kv cpl_sc "$b")" = 0 ] && echo " (no DMAR line naming in1's port: rate-limited or not logged)")"
    else
        end FAIL "the ports do not keep to their devices' domains (in1's port read page 32: data $(kv last_data "$b") DW1 ${d1:-?}): F0 is not isolated"
        decide_stop "T3: isolation"
    fi
fi

# ------------------------------------------------------------------ T4, T5, T6
if [ -z "$STOPPED" ] && [ "$F0" = 1 ] && want T4; then
    if [ "$QUICK" = 1 ]; then IVLS="1000 1"; MOS="1 64"; else IVLS="1000 100 10 1"; MOS="1 8 64 256"; fi
    MOS=$(for m in $MOS; do cap_mo "$m"; done | awk '!s[$1]++' | xargs)   # MAX_OUT <= the tag window
    ncombo=$(( $(echo $IVLS | wc -w) * $(echo $MOS | wc -w) * 2 ))
    begin T4 "no leak under load: $ncombo engine trains through in0's port while both devices run, engine tags $ENG_WIN (A3)" \
        "every train: LEAK_CPL 0, CPL_UNEXPECTED 0, CPL_MALFORMED 0, CPL_SC = ISSUED, timeouts 0; WIN_HITS 0 (no device tag in the engine's window); the devices' load ends ok; no DMAR fault; AER unchanged"
    pipsc bg census clear >> "$LOG" 2>&1
    LS=$(( 90 + ncombo * 30 ))   # 20 s per train + 3 s gap + run overhead, two 20 s baselines
    [ "$KIND" = ssd ] && hold_map 64 1 64 1
    if load_start "$LS" "$TD/load"; then
        printf 'name\tt0_ms\tt1_ms\n' > "$TD/windows.tsv"
        say "  20 s without the engine (baseline A)"; t0=$(now_ms); sleep 20; printf 'base-a\t%s\t%s\n' "$t0" "$(now_ms)" >> "$TD/windows.tsv"
        bad=""; pipsc bg facts clear >> "$LOG" 2>&1
        printf 'combo\tinterval\tmax_out\tarb\tissued\tcpl_sc\ttimeouts\tmalformed\tunexpected\tleak\trate_mrd_s\tlat_mean_ns\trc_straddle\trq_straddle\thol_engine\thol_device\tnph_min\n' > "$TD/trains.tsv"
        RCS=0; RQS=0
        for arb in idle engine; do for i in $IVLS; do for m in $MOS; do
            [ "$ABORT" = 1 ] && break 3
            c="t-$arb-i$i-m$m"
            base=(base=$B0 ws=64)
            t0=$(now_ms)
            erun "$c" rid=in0 "${base[@]}" count=0 interval="$i" maxout="$m" arb="$arb" secs=20
            printf '%s\t%s\t%s\n' "$c" "$t0" "$(now_ms)" >> "$TD/windows.tsv"
            f="$TD/$c.txt"
            RCS=$(( RCS + $(kv rc_straddle "$f") )); RQS=$(( RQS + $(kv rq_straddle "$f") ))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$i" "$m" "$arb" "$(kv issued "$f")" "$(kv cpl_sc "$f")" \
                "$(kv timeouts "$f")" "$(kv cpl_malformed "$f")" "$(kv cpl_unexpected "$f")" "$(kv leak_cpl "$f")" "$(kv issue_rate_mrd_s "$f")" "$(kv lat_mean_ns "$f")" \
                "$(kv rc_straddle "$f")" "$(kv rq_straddle "$f")" "$(kv hol_engine "$f")" "$(kv hol_device "$f")" "$(kv tfc_nph_min "$f")" >> "$TD/trains.tsv"
            [ "$(kv leak_cpl "$f")" = 0 ] && [ "$(kv cpl_unexpected "$f")" = 0 ] && [ "$(kv cpl_malformed "$f")" = 0 ] && [ "$(kv cpl_sc "$f")" = "$(kv issued "$f")" ] && [ "$(kv timeouts "$f")" = 0 ] || bad="$bad $c"
            pipsc bg facts clear >> "$LOG" 2>&1
            sleep 3
        done; done; done
        say "  20 s without the engine (baseline B)"; t0=$(now_ms); sleep 20; printf 'base-b\t%s\t%s\n' "$t0" "$(now_ms)" >> "$TD/windows.tsv"
        load_end; lok=$?
        tab "$TD/trains.tsv" | sed 's/^/   /' | tee -a "$SUM" > /dev/null
        # the devices' throughput in each window (bigserver: the holder's per-second IOPS logs; icx: alias-rdma's)
        if ls "$TD"/load/fio-*_iops.1.log > /dev/null 2>&1; then
            python3 - "$TD" "$KIND" "$NI0" <<'PYEOF' | tee "$TD/iops.tsv" | sed 's/^/   /' | tee -a "$SUM"
import glob, re, sys, collections
d, kind, ni0 = sys.argv[1], sys.argv[2], int(sys.argv[3])
per = {0: collections.Counter(), 1: collections.Counter()}
for f in glob.glob(f"{d}/load/fio-*_iops.1.log"):
    m = re.search(r"fio-(ssd|nic)(\d)", f)
    if not m:
        continue
    dev = int(m.group(2)) if m.group(1) == "ssd" else (0 if int(m.group(2)) == ni0 else 1)
    for l in open(f):
        p = l.split(",")
        if len(p) > 1:
            per[dev][int(p[0]) // 1000] += float(p[1])
win = [l.rstrip("\n").split("\t") for l in open(f"{d}/windows.tsv")][1:]
print(f"window\tkiops_{kind}0\tkiops_{kind}1\tseconds")
for name, a, b in win:
    s0, s1 = int(a) // 1000 + 1, int(b) // 1000 - 1
    secs = [s for s in range(s0, s1 + 1) if s in per[0]]
    if not secs:
        print(f"{name}\t-\t-\t0"); continue
    k0 = sum(per[0][s] for s in secs) / len(secs) / 1e3
    k1 = sum(per[1][s] for s in secs) / len(secs) / 1e3
    print(f"{name}\t{k0:.1f}\t{k1:.1f}\t{len(secs)}")
PYEOF
        fi
        [ "$lok" = 0 ] || bad="$bad load-failed"
        pipsc bg census > "$TD/census-after.txt" 2>&1
        WH=$(kv win_hits "$TD/census-after.txt")
        sum "   device MRds with a tag in the engine's window ($ENG_WIN) over T4: win_hits ${WH:-?}; device tags in0 $(kv in0_tags "$TD/census-after.txt"), in1 $(kv in1_tags "$TD/census-after.txt")"
        [ "$ENG_WIN" = off ] || [ "${WH:-1}" = 0 ] || bad="$bad win_hits=${WH:-?}"
        if [ -z "$bad" ]; then end PASS "no leak, every read SC, the load clean, over $ncombo trains"
        else end FAIL "trains that failed:$bad"; decide_stop "T4: leak or errors under load"; fi
        T4D=$TD   # T6 reads T4's iops.tsv (begin moves TD)
        # T5
        begin T5 "straddle under load (A5)" "RC_STRADDLE = 0 and RQ_STRADDLE = 0 over every T4 train"
        if [ "$RCS" = 0 ] && [ "$RQS" = 0 ]; then end PASS "none"; else end FAIL "rc $RCS, rq $RQS: the sink and the router need straddle handling"; decide_stop "T5: straddle"; fi
        # T6
        begin T6 "flow control and head-of-line (A6)" "idle-fill trains cost the devices no throughput (within 3% of the engine-free windows)"
        verdict=$(python3 - "$T4D" <<'PYEOF'
import sys
d = sys.argv[1]
try:
    rows = [l.rstrip("\n").split("\t") for l in open(f"{d}/iops.tsv")][1:]
except OSError:
    print("INFO no per-second device throughput (icx: judge from the NIC load's own report)"); sys.exit()
v = {r[0]: (float(r[1]), float(r[2])) for r in rows if r[1] != "-"}
base = [v[k] for k in ("base-a", "base-b") if k in v]
if not base:
    print("INFO no baseline window"); sys.exit()
b0 = sum(x[0] for x in base) / len(base); b1 = sum(x[1] for x in base) / len(base)
worst = {"idle": 0.0, "engine": 0.0}
for k, (x0, x1) in v.items():
    if not k.startswith("t-"):
        continue
    arb = k.split("-")[1]
    loss = max(1 - x0 / b0 if b0 else 0, 1 - x1 / b1 if b1 else 0)
    worst[arb] = max(worst[arb], loss)
ok = worst["idle"] <= 0.03
print(("PASS" if ok else "FAIL") + f" baseline {b0:.0f}/{b1:.0f} kIOPS; worst loss idle-fill {worst['idle']*100:.1f}%, engine-first {worst['engine']*100:.1f}%")
PYEOF
)
        tfcp=$(kv tfc_present "$TD/../T0/facts.txt")
        sum "   TFC present $tfcp; per train hol_engine / hol_device / nph_min: trains.tsv"
        end "${verdict%% *}" "${verdict#* }$( [ "$tfcp" = 0 ] && echo "; no TFC port: engine-first needs 0x0A09 credit gating, or stay with idle-fill")"
    else
        end SKIP "no load could be started"
    fi
fi

# ------------------------------------------------------------------ T7
HIT_THR=""
if [ -z "$STOPPED" ] && [ "$F0" = 1 ] && want T7; then
    begin T7 "per-read latency separates IOTLB hit and miss (A8)" "engine alone, MAX_OUT 1, INTERVAL 1000: the latency distributions of ws 8 (hits) and ws 4096 (misses) do not overlap, or overlap with <= 5% misclassified at the threshold"
    if [ "$KIND" = ssd ]; then
        hold_map 4096 1 64 1
        erun hit rid=in0 base=$REG ws=8 count=4160 tskip=64 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/hit.csv" > "$TD/hit-trace.txt" 2>&1
        erun miss rid=in0 base=$REG ws=4096 count=4096 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/miss.csv" > "$TD/miss-trace.txt" 2>&1
        hold_map 1024 512 64 1
        erun s512 rid=in0 base=$REG ws=1024 stride=512 count=4096 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/s512.csv" > "$TD/s512-trace.txt" 2>&1
        hold_map 256 262144 64 1
        erun s262144 rid=in0 base=$REG ws=256 stride=262144 count=4096 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/s262144.csv" > "$TD/s262144-trace.txt" 2>&1
    else   # icx: NIC 0's region (256 MiB of IOVA): ws 4096 cyclic misses the 32 x 8 IOTLB; stride 512 (one set) fits, 1 GiB does not
        erun hit rid=in0 base=$B0 ws=8 count=4160 tskip=64 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/hit.csv" > "$TD/hit-trace.txt" 2>&1
        erun miss rid=in0 base=$B0 ws=4096 count=4096 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/miss.csv" > "$TD/miss-trace.txt" 2>&1
        erun s512 rid=in0 base=$B0 ws=128 stride=512 count=4096 interval=1000 trace=1 dcheck=1 backing=$BK0
        pipsc bg trace "$TD/s512.csv" > "$TD/s512-trace.txt" 2>&1
        sum "   icx: s512 = 128 pages 2 MiB apart; no 1 GiB stride run (the region is 256 MiB)"
    fi
    if [ -s "$TD/hit.csv" ] && [ -s "$TD/miss.csv" ]; then
        out=$(python3 - "$TD" <<'PYEOF'
import csv, glob, os, sys
d = sys.argv[1]
def lat(f):
    r = [int(x["lat_cycles"]) for x in csv.DictReader(open(f)) if x["timed_out"] == "0" and x["status"] == "0" and x["lat_cycles"] != "65535"]
    return sorted(r)
def q(a, p): return a[min(len(a) - 1, int(p * len(a)))] * 4 if a else float("nan")
res = {}
for f in sorted(glob.glob(f"{d}/*.csv")):
    n = os.path.basename(f)[:-4]
    a = lat(f); res[n] = a
    print(f"{n}: n={len(a)} p1={q(a,.01):.0f} p10={q(a,.1):.0f} p50={q(a,.5):.0f} p90={q(a,.9):.0f} p99={q(a,.99):.0f} ns")
h, m = res.get("hit", []), res.get("miss", [])
if h and m:
    hp99, mp1 = q(h, .99), q(m, .01)
    thr = (q(h, .9) + q(m, .1)) / 2
    over = sum(1 for x in h if x * 4 > thr) / len(h) + sum(1 for x in m if x * 4 <= thr) / len(m)
    print(f"THRESHOLD_NS {thr:.0f}")
    word = "SEPARATE" if hp99 < mp1 else "SEPARABLE" if over <= 0.05 else "OVERLAP"
    print(word + f" hit p99 {hp99:.0f} ns, miss p1 {mp1:.0f} ns; misclassified at {thr:.0f} ns: {over*100:.2f}%")
PYEOF
)
        echo "$out" | grep -v '^THRESHOLD' | sed 's/^/   /' | tee -a "$SUM" > /dev/null; echo "$out" > "$TD/latency.txt"
        HIT_THR=$(echo "$out" | sed -n 's/^THRESHOLD_NS //p')
        case "$out" in
            *SEPARATE*) end PASS "hit and miss separate; threshold $HIT_THR ns (the stride runs give the walk levels: latency.txt)" ;;
            *SEPARABLE*) end PASS "hit and miss separable per read at $HIT_THR ns ($(echo "$out" | grep -o 'misclassified.*') : count misses as fractions, not one by one)" ;;
            *) end FAIL "hit and miss latencies overlap: the engine can't count misses one by one (A8); use ws-level averages"
               [ -n "$HIT_THR" ] || HIT_THR="" ;;
        esac
    else
        end SKIP "no traces"
    fi
fi

# ------------------------------------------------------------------ T8
# One IOTLB for all domains (A7), and its replacement. The first T8 (11-07 01:37) read P twice before the
# filler and reused the filler pages: P then survived 256 misses x 16 rounds and later runs, so it measured
# nothing. Now every run starts from a flushed IOTLB (bigserver: the holder's map unmaps and maps both
# regions) and reads each page once except P:
#   once  : P, N fresh drive-0 pages (in0's port), P: the capacity C where P starts to miss
#   cross : P, N fresh drive-1 pages through in1's port, P: misses as "once" at N >= C -> one shared IOTLB
#   twice : P, P, N fresh drive-0 pages, P: hits where "once" misses -> reuse protects an entry
if [ -z "$STOPPED" ] && [ "$F0" = 1 ] && want T8; then
    begin T8 "one IOTLB for all domains (A7); does reuse protect an entry" \
        "from a flushed IOTLB, fresh pages: 'once' sets the capacity C (P misses >= 0.5); 'cross' misses at N >= C as 'once' -> shared, else partitioned; 'twice' vs 'once' at N >= C -> reuse protection"
    [ -n "$HIT_THR" ] || sum "   no hit/miss threshold from T7: the miss fractions are not computed"
    [ "$KIND" = nic ] && sum "   icx: every run reloads pips_bg_region.ko (its unmap flushes the regions' IOTLB entries)"
    printf 'n\tcase\tprobes\tprobe_miss\tfill_miss\tprobe_p50_ns\tfirst_p50_ns\tprobe_by_round\n' > "$TD/t8.tsv"
    for N in 32 64 96 128 192 256 384 512; do
        R=$(( 4096 / (N + 3) )); [ "$R" -gt 16 ] && R=16
        for case in once cross twice; do
            [ "$ABORT" = 1 ] && break 2
            t="$TD/$case-$N.tbl"
            if [ "$KIND" = ssd ]; then
                hold_map 8192 1 8192 1 > /dev/null   # flushes both regions' IOTLB entries; tags = page mod 8192
            else
                nic_region_load > /dev/null || { sum "   icx: the region reload failed: stop T8"; break 2; }
                nic_bases
            fi
            t8_ok || { sum "   icx: the NICs' regions are too far apart for one table ($B0, $B1): stop T8"; break 2; }
            awk -v N="$N" -v R="$R" -v c="$case" -v o0="$O0" -v o1="$O1" 'BEGIN { for (r = 0; r < R; r++) {
                print (o0 + r) ":0"; if (c == "twice") print (o0 + r) ":0"
                for (j = 0; j < N; j++) print (c == "cross" ? o1 + 1000 + r * N + j ":1" : o0 + 1000 + r * N + j ":0")
                print (o0 + r) ":0" } }' > "$t"
            b=$BB
            n=$(wc -l < "$t")
            tblrun "$case-$N" "$t" rid=in0 rid1=in1 base="$b" count="$n" interval=1000 maxout=1 trace=1 $T8DC
            pipsc bg trace "$TD/$case-$N.csv" > /dev/null 2>&1
            python3 - "$TD/$case-$N.csv" "$N" "$R" "$case" "${HIT_THR:-0}" <<'PYEOF' >> "$TD/t8.tsv"
import csv, sys
f, N, R, case, thr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], float(sys.argv[5])
rows = {int(x["seq"]): x for x in csv.DictReader(open(f))}
def ns(s):
    x = rows.get(s)
    return None if x is None or x["timed_out"] != "0" or x["lat_cycles"] == "65535" else int(x["lat_cycles"]) * 4
k = 2 if case == "twice" else 1
S = k + N + 1
probe, first, fill = [], [], []
for r in range(R):
    b = r * S
    for lst, s in ((probe, b + S - 1), (first, b)):
        v = ns(s)
        if v is not None: lst.append(v)
    fill += [v for v in (ns(s) for s in range(b + k, b + k + N)) if v is not None]
med = lambda a: sorted(a)[len(a) // 2] if a else float("nan")
miss = lambda a: (sum(1 for x in a if x > thr) / len(a)) if a and thr > 0 else float("nan")
rounds = "".join("-" if ns(r * S + S - 1) is None else "." if thr > 0 and ns(r * S + S - 1) > thr else "h" for r in range(R))
print(f"{N}\t{case}\t{len(probe)}\t{miss(probe):.2f}\t{miss(fill):.2f}\t{med(probe):.0f}\t{med(first):.0f}\t{rounds}")
PYEOF
            say "    $case-$N: $(tail -1 "$TD/t8.tsv" | cut -f3-8 | tr '\t' ' ') (probes probe_miss fill_miss probe_p50 first_p50 probe_by_round)"
        done
    done
    tab "$TD/t8.tsv" | sed 's/^/   /' | tee -a "$SUM" > /dev/null
    verdict=$(python3 - "$TD/t8.tsv" <<'PYEOF'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])][1:]
v = {(int(r[0]), r[1]): float(r[3]) for r in rows if r[3] != "nan"}
ns = sorted({n for n, _ in v})
once = {n: v[(n, "once")] for n in ns if (n, "once") in v}
if not once:
    print("INFO no miss fractions (no threshold from T7, or runs missing): judge t8.tsv's latencies by eye"); sys.exit()
big = [n for n in ns if once.get(n, 0) >= 0.5]
if not big:
    print(f"INFO P read once survives up to N {max(once)} fresh misses (once: " + ", ".join(f"{n} {once[n]:.2f}" for n in sorted(once)) + "): no capacity found, no conclusion on A7")
    sys.exit()
C = big[0]
avg = lambda c: [v[(n, c)] for n in big if (n, c) in v]
o, x, w = avg("once"), avg("cross"), avg("twice")
om = sum(o) / len(o)
line = []
if x:
    xm = sum(x) / len(x)
    if xm >= 0.5 * om:
        line.append(f"PASS shared: from N {C} (P misses {om:.2f} after device 0's pages) P misses {xm:.2f} after device 1's pages: traffic in one domain evicts another's entries (A7)")
    else:
        line.append(f"FAIL partitioned: from N {C} P misses {om:.2f} after device 0's pages but {xm:.2f} after device 1's: entries are kept per domain (A7 fails: F1/F3 can't evict device 0's entries; F0 is unaffected, it reads in device 0's own domain)")
else:
    line.append(f"INFO capacity C ~ {C} (once misses {om:.2f}); no cross runs")
if w:
    wm = sum(w) / len(w)
    line.append(f"NOTE reuse: P read twice misses {wm:.2f} from N {C} vs {om:.2f} read once: " +
                ("a reused entry is protected (not plain LRU): an evictor must reuse its pages to displace a device's hot entries" if wm < 0.5 * om else "two back-to-back reads earn no protection"))
line.append("NOTE once by N: " + ", ".join(f"{n} {once[n]:.2f}" for n in sorted(once)))
print("\n".join(line))
PYEOF
)
    echo "$verdict" | sed -n '2,$p' | sed 's/^NOTE /   /' | tee -a "$SUM" > /dev/null
    first=$(echo "$verdict" | head -1)
    end "${first%% *}" "${first#* }"
fi

# ------------------------------------------------------------------ T9
CENSUS_FREE=""
if [ -z "$STOPPED" ] && want T9; then
    begin T9 "tag census per device under load (A9)" "a contiguous range of >= 64 tags unused by the device, per input: F2's window"
    pipsc bg census clear >> "$LOG" 2>&1
    if [ "$KIND" = ssd ]; then hold_map 64 1 64 1; fi
    if load_start 150 "$TD/load"; then
        hsleep 120 "the census under load"; pipsc bg census > "$TD/census.txt" 2>&1; load_end
        for p in in0 in1; do
            sum "   $p: $(kv ${p}_mrd "$TD/census.txt") MRd, tags used $(kv ${p}_tags "$TD/census.txt") ($(kv ${p}_tags_n "$TD/census.txt")), largest free range $(kv ${p}_free_max "$TD/census.txt") ($(kv ${p}_free_max_n "$TD/census.txt"))"
        done
        f0=$(kv in0_free_max_n "$TD/census.txt"); f1=$(kv in1_free_max_n "$TD/census.txt")
        CENSUS_FREE=$(kv in0_free_max "$TD/census.txt")
        if [ "${f0:-0}" -ge 64 ] && [ "${f1:-0}" -ge 64 ]; then end PASS "free windows: in0 $CENSUS_FREE, in1 $(kv in1_free_max "$TD/census.txt") (repeat at the target experiment's load: the set can grow with queue depth)"
        else end FAIL "no free range of 64 tags (in0 ${f0:-0}, in1 ${f1:-0}): F2 is not viable at this load"; fi
    else
        end SKIP "no load could be started"
    fi
fi

# ------------------------------------------------------------------ T11 (F3)
RUN11=$T11; [ "$FALLBACKS" = 1 ] && [ "$T2_KIND" = fault ] && RUN11=1
F3_OK=0
if [ "$ABORT" = 0 ] && [ "$RUN11" = 1 ] && want T11; then
    case "$F3PORT" in in0) FP=$P0 ;; in1) FP=$P1 ;; usp) FP=$USP ;; esac
    begin T11 "F3: pages in $F3PORT's port's own DMA domain ($FP), mapped by pips_bg_pages.ko" "64 reads through that port: all SC with the right page index; then hit/miss latency in that domain"
    KD="/lib/modules/$(uname -r)/build"
    if [ ! -d "$KD" ]; then end SKIP "no kernel headers ($KD): install linux-headers-$(uname -r)"
    else
        mkdir -p "$TD/mod" && cp "$HERE/ridcheck/pips_bg_pages.c" "$HERE/ridcheck/Makefile" "$TD/mod/"
        if ! make -C "$TD/mod" MODS=pips_bg_pages > "$TD/mod-build.txt" 2>&1; then end FAIL "the module does not build (mod-build.txt)"
        elif ! sudo -n insmod "$TD/mod/pips_bg_pages.ko" dev="$FP" npages=4096 token="$TOKEN" 2> "$TD/insmod.txt"; then end FAIL "insmod: $(cat "$TD/insmod.txt")"
        else
            F3_LOADED=1
            sudo -n dmesg | grep "pips_bg_pages\[$TOKEN\]" | sed 's/^\[[^]]*\] //' | tee -a "$SUM" > "$TD/mod.txt"
            sudo -n cat /sys/kernel/debug/pips_bg_pages/iovas > "$TD/iovas.txt"
            FB=$(awk '$1 == "base" { print $2 }' "$TD/iovas.txt")
            awk 'NF == 2 && $1 ~ /^[0-9]+$/ { print $1 ":0" }' "$TD/iovas.txt" > "$TD/all.tbl"
            maxi=$(awk -F: '{ if ($1 > m) m = $1 } END { print m + 0 }' "$TD/all.tbl")
            bk=1; while [ "$bk" -le "$maxi" ]; do bk=$((bk * 2)); done
            head -64 "$TD/all.tbl" > "$TD/64.tbl"
            tblrun f3-64 "$TD/64.tbl" rid=$F3PORT base="$FB" count=64 dcheck=1 backing=$bk
            f="$TD/f3-64.txt"
            sum "   64 reads: sc $(kv cpl_sc "$f") ur $(kv cpl_ur "$f") ca $(kv cpl_ca "$f") timeouts $(kv timeouts "$f") mismatch $(kv data_mismatch "$f")"
            if [ "$(kv cpl_sc "$f")" = 64 ] && [ "$(kv data_mismatch "$f")" = 0 ]; then
                F3_OK=1
                head -8 "$TD/all.tbl" > "$TD/8.tbl"
                tblrun f3-hit "$TD/8.tbl" rid=$F3PORT base="$FB" count=4160 tskip=64 interval=1000 trace=1
                pipsc bg trace "$TD/f3-hit.csv" > "$TD/f3-hit-trace.txt" 2>&1
                tblrun f3-miss "$TD/all.tbl" rid=$F3PORT base="$FB" count=4096 interval=1000 trace=1
                pipsc bg trace "$TD/f3-miss.csv" > "$TD/f3-miss-trace.txt" 2>&1
                sum "   latency in the port's domain: hit p50 $(kv trace_lat_ns_p50 "$TD/f3-hit-trace.txt") ns, miss p50 $(kv trace_lat_ns_p50 "$TD/f3-miss-trace.txt") ns"
                end PASS "F3 reads work through $F3PORT's port. It serves X3 only if this domain's traffic evicts the drive's entries (A7, T8; with F0 broken, judge by the drive's own latency under F3 traffic)"
            else
                end FAIL "F3 reads fail too (the port's domain type is in mod.txt): F3 not usable -> T9/T10 (F2)"
            fi
            sudo -n rmmod pips_bg_pages && F3_LOADED=0
        fi
    fi
fi

# ------------------------------------------------------------------ T10 (F2)
RUN10=$T10; [ "$FALLBACKS" = 1 ] && [ -n "$T2_KIND" ] && [ "$T2_KIND" != skip ] && [ "${V[T2]:-}" = FAIL ] && [ "$F3_OK" = 0 ] && [ "${V[T9]:-}" = PASS ] && RUN10=1
if [ "$ABORT" = 0 ] && [ "$RUN10" = 1 ] && want T10; then
    W=$CENSUS_FREE; [ "${TAGWIN:-off}" != off ] && W=$TAGWIN
    begin T10 "F2: drive 0's own ID, engine tags only in $W, sink RID+tag, the clash detector armed" "idle: the T2 checks; under load: T4's trains; CLASH 0, WIN_HITS 0, LEAK_CPL 0, the load clean, the data right"
    if [ -z "$W" ] || [ "$W" = none ]; then end SKIP "no tag window (T9, or --tagwin LO-HI)"
    else
        lo=${W%-*}; hi=${W#*-}; wn=$((hi - lo + 1)); mo=$(( wn < 8 ? wn : 8 ))
        F2KV="rid=dev0 unsafe=1 tagwin=$W ridtag=1"
        pipsc bg census clear >> "$LOG" 2>&1
        [ "$KIND" = ssd ] && hold_map 64 1 64 1
        B=$B0
        erun f2-idle-64 $F2KV base=$B ws=64 count=64 maxout=$mo dcheck=1 backing=$BK0
        bad=""
        f="$TD/f2-idle-64.txt"; [ "$(kv cpl_sc "$f")" = 64 ] && [ "$(kv clash "$f")" = 0 ] && [ "$(kv leak_cpl "$f")" = 0 ] && [ "$(kv data_mismatch "$f")" = 0 ] || bad="$bad idle"
        sum "   idle: sc $(kv cpl_sc "$f")/64 mismatch $(kv data_mismatch "$f") clash $(kv clash "$f") leak $(kv leak_cpl "$f") win_hits $(kv win_hits "$f")"
        if [ -z "$bad" ] && load_start 200 "$TD/load"; then
            for i in 100 10 1; do for m in 1 "$mo"; do
                [ "$ABORT" = 1 ] && break 2
                erun "f2-i$i-m$m" $F2KV base=$B ws=64 count=0 interval=$i maxout=$m secs=20
                f="$TD/f2-i$i-m$m.txt"
                [ "$(kv clash "$f")" = 0 ] && [ "$(kv leak_cpl "$f")" = 0 ] && [ "$(kv cpl_sc "$f")" = "$(kv issued "$f")" ] || bad="$bad i$i-m$m"
            done; done
            load_end || bad="$bad load-failed"
        fi
        pipsc bg census > "$TD/census.txt" 2>&1
        wh=$(kv win_hits "$TD/census.txt")
        sum "   window hits by the device during T10: $wh"
        [ "${wh:-0}" = 0 ] || bad="$bad win_hits=$wh"
        if [ -z "$bad" ]; then end PASS "F2 works at this load: window $W, no clash"
        else end FAIL "F2 failed:$bad -> F4 (no in-switch evictor) at this load"; fi
    fi
fi

# ------------------------------------------------------------------ T12 (soak)
if [ "$ABORT" = 0 ] && [ "$T12" = 1 ] && [ -z "$STOPPED" ] && want T12; then
    MODE=""; [ "$F0" = 1 ] && MODE=F0
    SOAK_MO=$(cap_mo "$SOAK_MO"); W=$CENSUS_FREE; [ "${TAGWIN:-off}" != off ] && W=$TAGWIN
    [ -z "$MODE" ] && [ "${V[T10]:-}" = PASS ] && MODE=F2
    begin T12 "soak: ${MODE:-no mode} at INTERVAL $SOAK_IVL, MAX_OUT $SOAK_MO, idle-fill, both devices under load, $SOAK_MIN min" "as T4: no leak, every read SC, the load clean, no host trouble"
    if [ -z "$MODE" ]; then end SKIP "no working mode (F0 or F2)"
    else
        S=$((SOAK_MIN * 60))
        [ "$KIND" = ssd ] && hold_map 64 1 64 1
        if load_start $((S + 60)) "$TD/load"; then
            if [ "$MODE" = F0 ]; then KVS="rid=in0"; else KVS="rid=dev0 unsafe=1 tagwin=$W ridtag=1"; fi
            erun soak $KVS base=$B0 ws=64 count=0 interval=$SOAK_IVL maxout=$SOAK_MO arb=idle secs=$S beat=60
            load_end; lok=$?
            f="$TD/soak.txt"
            sum "   issued $(kv issued "$f") sc $(kv cpl_sc "$f") timeouts $(kv timeouts "$f") unexpected $(kv cpl_unexpected "$f") leak $(kv leak_cpl "$f") rate $(kv issue_rate_mrd_s "$f")/s lat_mean $(kv lat_mean_ns "$f") ns; load $([ $lok = 0 ] && echo ok || echo FAILED)"
            if [ "$lok" = 0 ] && [ "$(kv leak_cpl "$f")" = 0 ] && [ "$(kv cpl_sc "$f")" = "$(kv issued "$f")" ] && [ "$(kv cpl_unexpected "$f")" = 0 ]; then end PASS "$MODE held for $SOAK_MIN min"
            else end FAIL "errors in the soak (soak.txt)"; fi
        else end SKIP "no load could be started"; fi
    fi
fi

# ------------------------------------------------------------------ decision
sum ""
sum "== DECISION (test doc §4)"
for t in T0 T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12; do [ -n "${V[$t]:-}" ] && sum "   $t ${V[$t]}: ${DET[$t]}"; done
[ -n "$STOPPED" ] && sum "   stopped after: $STOPPED"
rc=0
if [ "$ABORT" = 1 ]; then
    rc=5; sum "-> LEAK or CLASH: the engine was stopped and not restarted. Report the capture, LEAK_LAST and the ILA before anything else (README §12 rule 7)"
elif [ "${V[T1]:-}" = FAIL ]; then
    rc=1; sum "-> A4: the core or the root complex does not take the engine's request: ILA axis_ila_bg on the RQ beat, capture; FPGA side"
elif [ "$F0" = 1 ] && [ "${V[T3]:-PASS}" = PASS ]; then
    sum "-> F0: the downstream ports' IDs read in their devices' domains. T4-T8 set the rates, the mux mode, credit gating: 0x0A09 = the engine's extras only"
    for t in T4 T5 T6 T7 T8; do [ "${V[$t]:-}" = FAIL ] && { rc=1; sum "   but $t failed: ${DET[$t]}"; }; done
elif [ "${V[T2]:-}" = FAIL ]; then
    rc=1
    if [ "$T2_KIND" = fault ]; then sum "-> A1 fails (the port's ID faults): F3 (T11: ${V[T11]:-not run$( [ "$FALLBACKS" = 0 ] && echo ", rerun with --fallbacks")}), then F2 (T9 ${V[T9]:-not run}, T10 ${V[T10]:-not run})"
    else sum "-> no completion for the port's reads: A2/A3 (root complex or sink/route): capture, LEAK_CPL, axis_ila_bg; then F2 (T9 ${V[T9]:-not run}, T10 ${V[T10]:-not run})"; fi
    [ "${V[T11]:-}" = PASS ] && sum "   F3 reads work: use F3 for X3 only if the port's domain traffic evicts the drive's entries"
    [ "${V[T10]:-}" = PASS ] && sum "   F2 works at the tested load"
    [ "${V[T11]:-}" != PASS ] && [ "${V[T10]:-}" = FAIL ] && sum "   F2 failed: F4, no in-switch evictor; the study keeps the alias campaigns"
else
    for t in "${!V[@]}"; do [ "${V[$t]}" = FAIL ] && rc=1; done
fi
pipsc bg info > "$OUT/bg-info-end.txt" 2>&1
sum ""
sum "done in $(( (SECONDS - T_START) / 60 )) min; output $OUT"
if [ "$KIND" = ssd ]; then
    sum "the drives stay held by the holder ($HOLD); end with a reboot: sync; sudo systemctl reboot -ff"
else
    [ "$RGN_LOADED" = 1 ] && sudo -n rmmod pips_bg_region && RGN_LOADED=0
    sum "icx: pips_bg_region unloaded$( [ "$RGN_LOADED" = 1 ] && echo " (rmmod FAILED: sudo rmmod pips_bg_region)"); the NICs stay on mlx5, nothing to reboot"
fi
( cd "$(dirname "$OUT")" && tar -czf "$OUT.tar.gz" "$(basename "$OUT")" ) && say "tarball: $OUT.tar.gz"
if [ "$REBOOT" = 1 ] && [ "$START_HOLDER" = 1 ]; then
    say "rebooting in 10 s (--reboot): sync; systemctl reboot -ff"
    cleanup; trap - EXIT; sync; sleep 10; sudo -n systemctl reboot -ff
fi
exit $rc
