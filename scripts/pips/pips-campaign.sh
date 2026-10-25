#!/bin/bash
# The design 0x0A06 campaign on one testbed, start to finish: every sweep
# (page_batch_en across the depth sweep, cap off, ctrl_push off, grant quantum,
# the completion threshold, and on the NICs the alone/paced/wire-speed tests of
# the packet splitting), then the analysis of those sweeps and the analysis
# still pending on the 0x0A04/0x0A05 logs (HANDOFF §8 "Next" item 0), then ONE
# tarball in ~ with everything to copy back. Raw TLP logs stay on the host;
# the tarball has the results, manifests, status registers, page-order
# listings (the snippet for the report) and the analysis outputs.
#
#   bash scripts/pips/pips-campaign.sh ssd --tmux       # bigserver: the drives
#   bash scripts/pips/pips-campaign.sh nic --tmux       # icx: the NICs
#   bash scripts/pips/pips-campaign.sh nic --dry-run    # the plan, ETA and commands only
#
# Options:
#   --tmux            run in a new tmux session (asks for the sudo password
#                     there; survives a dropped ssh). Attach: tmux attach -t <name>
#   --dry-run         print the plan, the ETA and every sweep command; run nothing
#   --only "P ..."    run only these phases (names: --dry-run lists them)
#   --skip "P ..."    leave these phases out
#   --no-analysis     sweeps only, then pack (no page order, lengths, pending)
#   --no-pending      leave out the pending 0x0A04/0x0A05 analysis
#   --no-wire         NIC: leave out the 50G wire-speed phase
#   --no-hw           NIC: leave out the hardware-paced phase
#   -j N              logs at a time in the analysis (default: half the CPUs, at most 16)
#   --stamp S         the label prefix of this campaign's sweeps (default c<MMDDhhmm>)
# Environment: HEARTBEAT=seconds between liveness lines (default 300),
# RESULTS_DIR (default ~), DUALSSD_ARGS (default "--membw 0").
#
# Every sweep: design 0x0a06 only (refused otherwise), IOMMU as booted (no
# reboot), drain cap on unless the phase says, the completion threshold at
# 31 DW on both inputs (w31: conservative, data taken for a completion only
# costs batching; 0x0A04/0x0A05 logs: drive completions 4 DW, mlx5 16 DW,
# drive 1's smallest data 4-32 DW at 0.5% of its writes and its 36 DW at 14%,
# NIC data from 32 DW), the status registers read in every run (0x24 before
# the run, 0x24/0x28/0x2C after the window: pips_stat_* in the results).
#
# If the switch stops answering (design ID not 0x0a06, or reads 0xFFFFFFFF):
# a read-only snapshot (pips-hang-snapshot.sh) is taken at once, every switch
# phase still to come is skipped with a warning, and the campaign goes on with
# the analysis and the packing. Warnings are repeated at the end.
#
# Output: ~/pips-campaign-<kind>-<stamp>/ and ~/pips-campaign-<kind>-<stamp>.tar.gz
#   campaign.log      everything printed (the sweeps' own output included)
#   plan.txt          phases, points, estimates; notes.txt: warnings, skips
#   results/          each sweep's ~/<name>.txt, .manifest.tsv, per-setting .jsonl/.txt
#   sweeplogs/<name>/ the sweep folder (pips-sweep.log, cfg-*.txt, manifest)
#   runs/             per run the small files: pips-cfg.txt, pips-status*.txt,
#                     pips-log-summary.*, sweep-id.txt, nstat, and its reports/ (.rpt)
#   status.txt/.tsv   pips-status-table.py over every sweep: spills, stuck, MRd wait
#   analyze-new/      pips-analyze.sh on this campaign's sweeps (recorded and
#                     arrival order, listings, IOTLB simulation; lengths)
#   analyze-pending/  pips-analyze.sh on the 0x0A04/0x0A05 sweeps (item 0)
#   snapshots/        NIC: nic-host-snapshot.sh of icx and styx, before and
#                     after; the hang snapshot if one was taken
# Liveness: the sweeps print every run; the campaign prints a phase banner
# with the ETA, and a heartbeat line every HEARTBEAT seconds.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HERE=$(dirname "$SELF")
REPO=$(cd "$HERE/../.." && pwd)
. "$REPO/utils/ssd-lib.sh"            # relaunch_in_tmux
. "$HERE/pips-lib.sh"
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; }

KIND=${1:-}
case "$KIND" in
    ssd|nic) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "pips-campaign: first argument must be ssd or nic" >&2; exit 2 ;;
esac
PASS=("$KIND"); IN_TMUX=0
for a in "$@"; do if [ "$a" = --tmux ]; then IN_TMUX=1; else PASS+=("$a"); fi; done
DRY=0; ONLY=""; SKIP=""; ANALYSIS=1; PENDING=1; WIRE=1; HW=1; JOBS=""; STAMP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tmux) shift ;;
        --dry-run) DRY=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --no-analysis) ANALYSIS=0; shift ;;
        --no-pending) PENDING=0; shift ;;
        --no-wire) WIRE=0; shift ;;
        --no-hw) HW=0; shift ;;
        -j) JOBS="$2"; shift 2 ;;
        --stamp) STAMP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "pips-campaign: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
STAMP=${STAMP:-c$(date +%m%d%H%M)}
case "$STAMP" in [A-Za-z]*) ;; *) echo "--stamp: must start with a letter" >&2; exit 2 ;; esac
case "$STAMP" in *[!A-Za-z0-9]*) echo "--stamp: letters and digits only" >&2; exit 2 ;; esac
if [ "$IN_TMUX" = 1 ] && [ "$DRY" = 0 ]; then
    # Keep the stamp: the tmux copy must name the same folder.
    relaunch_in_tmux "$SELF" "${PASS[@]}" --stamp "$STAMP"
fi
[ -n "$JOBS" ] || { JOBS=$(( $(nproc 2>/dev/null || echo 8) / 2 )); [ "$JOBS" -gt 16 ] && JOBS=16; [ "$JOBS" -lt 1 ] && JOBS=1; }
RESULTS=${RESULTS_DIR:-$HOME}
OUT="$HOME/pips-campaign-$KIND-$STAMP"
SWEEPS_DIR="$REPO/scripts/sosp24-experiments"
if [ "$KIND" = ssd ]; then
    DRV="$SWEEPS_DIR/dualssd_pips_sweep.sh"; MIN_PER_PT=1.05
else
    DRV="$SWEEPS_DIR/dualnic_pips_sweep.sh"; MIN_PER_PT=2.6
fi

# ------------------------------------------------------------------ phases
# The settings. Depths and times are the 10-17 depth sweep's (HANDOFF §8 "Depth
# sweep"): T = 14 (D - 1) + 8 cycles, 255 (the 8-bit maximum) from depth 24.
DEPTHS="1:0 2:22 4:50 8:106 16:218 24:255 36:255 64:255"
DEPTH_LO="1:0 2:22 4:50 8:106 16:218"; DEPTH_HI="24:255 36:255 64:255"
THR="thr=31"
# ssd point grids: the main grid (32 instances and the swapped uneven runs left
# out: 32 gave what 16 did, the heavier side moved little), the knob grid
# (fewer points, full link and light load, one uneven pair) and drive 0's.
SSD_MAIN=( --asy-low "2 4 8" --asy-high 16 --no-swap "4k 8k 16k 64k 1m" "1 2 4 8 16" 1 )   # 25 + 15 points
SSD_KNOB=( --asy-low 2 --asy-high 16 --no-swap "4k 16k 1m" "1 4 16" 1 )                    # 9 + 3
SSD_DRV0=( --single --no-asy "4k 8k 16k 1m" "1 16" 1 )                                    # 8 x 2 modes
# nic: flows per NIC (A:B = uneven, A on NIC 0, B on NIC 1, alternating the
# heavy side), and rates: uncapped, and 50 Gbps per NIC, so the two together
# (100) stay under the weakest link they share, the switch's Gen4 x8 uplink
# (~107 Gbps of payload measured) and styx's one Gen3 x16 card (126 raw).
NIC_MAIN=( "5 10 15 30 5:30 30:10" "uncapped 50" 1 )                                       # 12 points
NIC_KNOB=( "5 30 5:30" "uncapped 50" 1 )                                                   # 6
NIC_ALONE=( --modes "nic0only both" "5" "uncapped 50 25" 1 )                              # 6
NIC_HW=( --modes "nic0only both" "5" "hw50 hw25" 1 )                                      # 4
NIC_WIRE=( --modes "nic0only both" "5" "uncapped" 1 )                                     # 2

if [ "$KIND" = ssd ]; then
    PHASES=(main cap0 push quant thr drv0)
else
    PHASES=(mainlo cap0 push quant thr alone hw mainhi wire)
fi
# est_points <phase>: runs it takes (each sweep adds its datapath check)
est_points() {
    case "$KIND:$1" in
        ssd:main)   echo $(( 16 * 40 + 1 )) ;;
        ssd:cap0)   echo $(( 6 * 12 + 1 )) ;;
        ssd:push)   echo $(( 2 * 12 + 1 )) ;;
        ssd:quant)  echo $(( 3 * (12 + 1) )) ;;
        ssd:thr)    echo $(( 2 * 12 + 1 )) ;;
        ssd:drv0)   echo $(( 2 * 16 + 1 )) ;;
        nic:mainlo) echo $(( 10 * 12 + 1 )) ;;
        nic:mainhi) echo $(( 6 * 12 + 1 )) ;;
        nic:cap0)   echo $(( 6 * 6 + 1 )) ;;
        nic:push)   echo $(( 2 * 6 + 1 )) ;;
        nic:quant)  echo $(( 3 * (6 + 1) )) ;;
        nic:thr)    echo $(( 2 * 6 + 1 )) ;;
        nic:alone)  echo $(( 4 * 6 + 1 + 2 * 6 + 1 )) ;;
        nic:hw)     echo $(( 2 * (4 + 1) )) ;;
        nic:wire)   echo $(( 2 * (2 + 1) )) ;;
        *) echo 0 ;;
    esac
}
describe() {
    case "$KIND:$1" in
        ssd:main)   echo "page_batch_en 0/1 x the 8 depths, cap on, w31; bs 4k-1m x 1-16 per drive + 2/4/8+16" ;;
        ssd:cap0)   echo "cap off at d1/d8/d64, page_batch_en 0/1; knob grid" ;;
        ssd:push)   echo "ctrl_push off (o1), per page, d8t106/d64t255; knob grid" ;;
        ssd:quant)  echo "grant quantum 64/256/1024 beats, per page, d64t255; knob grid" ;;
        ssd:thr)    echo "completion threshold 4 DW (the NVMe entry exactly), per page, d8/d64; knob grid" ;;
        ssd:drv0)   echo "items 2/4: drive 0 alone and 1+1/16+16 at 4k-1m, d1t0 cap off and on" ;;
        nic:mainlo) echo "page_batch_en 0/1 x depths 1-16, cap on, w31; flows 5/10/15/30, 5:30, 30:10; uncapped and 50G" ;;
        nic:mainhi) echo "the same at depths 24/36/64 (last switch phase: d24 stopped 0x0A05's NIC sweep)" ;;
        nic:cap0)   echo "cap off at d1/d8/d16, page_batch_en 0/1; flows 5/30/5:30, uncapped and 50G" ;;
        nic:push)   echo "ctrl_push off (o1), per page, d8/d16; knob grid" ;;
        nic:quant)  echo "grant quantum 64/256/1024 beats, per page, d16t218; knob grid" ;;
        nic:thr)    echo "completion threshold 16 DW (the mlx5 entry exactly), per page, d8/d16; knob grid" ;;
        nic:alone)  echo "packet splitting: NIC0 alone vs both, 5 flows, uncapped/50G/25G (iperf3), at d1t0, d16t64 (cap off), d4t22c1; page_batch_en 0/1" ;;
        nic:hw)     echo "the same paced in styx's NIC hardware (tx_maxrate) at 50G/25G, d16t64 and d4t22c1, page_batch_en 0" ;;
        nic:wire)   echo "NIC0's link (both ends) forced to 50G: alone vs both, 5 flows, d16t64 and d4t22c1; restored after" ;;
    esac
}
want_phase() {
    local p=$1
    [ -n "$ONLY" ] && ! [[ " $ONLY " == *" $p "* ]] && return 1
    [[ " $SKIP " == *" $p "* ]] && return 1
    [ "$p" = wire ] && [ "$WIRE" = 0 ] && return 1
    [ "$p" = hw ] && [ "$HW" = 0 ] && return 1
    return 0
}
for p in $ONLY $SKIP; do
    [[ " ${PHASES[*]} " == *" $p "* ]] || { echo "pips-campaign: no phase '$p' for $KIND (${PHASES[*]})" >&2; exit 2; }
done
RUN_PHASES=(); for p in "${PHASES[@]}"; do want_phase "$p" && RUN_PHASES+=("$p"); done

# analysis estimate, minutes: the new sweeps' logs (no model: ~25 s each, and
# ~10 s for the lengths), and the pending analysis (HANDOFF §8 "Next" item 0)
est_analysis() {
    local pts=0 p
    for p in "${RUN_PHASES[@]}"; do pts=$(( pts + $(est_points "$p") )); done
    local new=$(( pts * 35 / 60 / JOBS + 10 )) pend=0
    if [ "$PENDING" = 1 ]; then
        if [ "$KIND" = ssd ]; then pend=$(( 180 * 16 / (JOBS < 16 ? JOBS : 16) )); else pend=$(( 50 * 8 / (JOBS < 8 ? JOBS : 8) )); fi
    fi
    [ "$ANALYSIS" = 1 ] || { new=0; pend=0; }
    echo "$new $pend"
}
fmt_min() { printf '%dh%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
clock_in() { date -d "+$1 min" '+%a %H:%M' 2>/dev/null || echo "+$(fmt_min "$1")"; }

plan() {
    local p n m tot=0
    echo "pips-campaign $KIND, stamp $STAMP, $(hostname), $(date '+%F %T'), repo $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
    echo "sweeps named dual$KIND-pips-<iommu>-$STAMP<phase>; ${MIN_PER_PT} min per run (estimate)"
    printf '  %-7s %5s %8s  %s\n' phase runs time what
    for p in "${RUN_PHASES[@]}"; do
        n=$(est_points "$p"); m=$(awk -v n="$n" -v r="$MIN_PER_PT" 'BEGIN { printf "%d", n * r + 0.5 }')
        tot=$(( tot + m ))
        printf '  %-7s %5d %8s  %s  (done ~%s)\n' "$p" "$n" "$(fmt_min "$m")" "$(describe "$p")" "$(clock_in "$tot")"
    done
    read -r an ap <<< "$(est_analysis)"
    echo "  sweeps: $(fmt_min "$tot")"
    echo "  analysis: new sweeps $(fmt_min "$an"), pending 0x0A04/0x0A05 $(fmt_min "$ap") (-j $JOBS)"
    echo "  ETA, everything packed: $(fmt_min $(( tot + an + ap + 10 ))) from now, ~$(clock_in $(( tot + an + ap + 10 )))"
    for p in "${PHASES[@]}"; do want_phase "$p" || echo "  (phase $p left out)"; done
}

# ------------------------------------------------------------------ helpers
T0=$SECONDS
say() { echo "======== $(date '+%F %T') +$(fmt_min $(( (SECONDS - T0) / 60 )))  $*"; }
NOTES=(); MANIFESTS=(); NAMES=(); SWITCH_DEAD=0; STOPPED=0
note() { NOTES+=("$*"); echo "$*" >> "$OUT/notes.txt" 2>/dev/null; say "NOTE: $*"; }
banner() {
    echo; echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    for l in "$@"; do echo "!!!!  $l"; done
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; echo
}
# The switch answers with the expected build. 20 s at most.
switch_ok() {
    local out
    out=$(timeout 20 sudo -n "$PIPS" cfg 2>&1) || { LAST_SWITCH="$out"; return 1; }
    LAST_SWITCH="$out"
    [ "$(design_of <(printf '%s\n' "$out"))" = 0x0a06 ]
}
switch_dead() {   # <where>
    [ "$SWITCH_DEAD" = 1 ] && return 0
    SWITCH_DEAD=1
    banner "THE PIPS SWITCH STOPPED ANSWERING ($1)" \
           "$(printf '%s' "$LAST_SWITCH" | tail -2 | tr '\n' ' ')" \
           "Every switch phase still to come is SKIPPED. Taking a read-only snapshot now;" \
           "do not reprogram before reading it. Then XSCT (scripts/pips/pips-xsct.tcl):" \
           "pips_connect, pips_cfg, pips_status, pips_dma: JTAG works without PCIe."
    note "switch stopped answering $1; later switch phases skipped; snapshot in snapshots/hang"
    [ "$DRY" = 1 ] || bash "$HERE/pips-hang-snapshot.sh" -o "$OUT/snapshots/hang" --since "6 hours ago" 2>&1 | tail -20
}

# sweep_run <label> <driver args...>: one sweep of this campaign
CUR_PHASE=""; CUR_LABEL=""
sweep_run() {
    local label="$STAMP$1" rc m; shift
    if [ "$STOPPED" = 1 ]; then note "sweep $label not run: campaign stopped by hand"; return 1; fi
    if [ "$SWITCH_DEAD" = 1 ]; then note "sweep $label SKIPPED: the switch is not answering"; return 1; fi
    if [ "$DRY" = 1 ]; then
        printf '    %s%s --tag %s --datapath-once' "$( [ "$KIND" = ssd ] && echo "DUALSSD_ARGS=\"${DUALSSD_ARGS:---membw 0}\" ")" \
            "bash ${DRV#"$REPO"/}" "$label"
        printf ' %q' "$@"; echo
        return 0
    fi
    switch_ok || { switch_dead "before sweep $label"; return 1; }
    CUR_LABEL=$label; echo "$CUR_PHASE $label" > "$OUT/.state"
    say "sweep $label ($CUR_PHASE): $(describe "$CUR_PHASE")"
    if [ "$KIND" = ssd ]; then
        DUALSSD_ARGS="${DUALSSD_ARGS:---membw 0}" bash "$DRV" --tag "$label" --datapath-once "$@"
    else
        bash "$DRV" --tag "$label" --datapath-once "$@"
    fi
    rc=$?
    m=$(ls "$RESULTS"/dual"$KIND"-pips-*-"$label".manifest.tsv 2>/dev/null | head -1)
    local nm=none
    if [ -n "$m" ]; then
        nm=$(basename "$m" .manifest.tsv)
        MANIFESTS+=("$m"); NAMES+=("$nm")
    else
        note "sweep $label left no manifest (exit $rc): it did not start; see campaign.log"
    fi
    if [ -e "$OUT/.lockup-stop" ]; then
        STOPPED=1
        note "sweep $label STOPPED by the soft-lockup guard ($(cat "$OUT/.lockup-stop")): see journalctl -k"
        banner "KERNEL SOFT LOCKUPS: the campaign stopped its sweeps (soft-lockup guard)." \
               "Check the drives' interrupt CPUs against SSD_CORES (HANDOFF §8 0x0A06 campaign)."
    elif [ "$rc" = 130 ]; then
        STOPPED=1; note "sweep $label stopped by hand"
    fi
    [ "$rc" = 0 ] || [ "$rc" = 130 ] || note "sweep $label exited $rc"
    if grep -qs 'ID reads 0xffffffff' "$REPO/utils/logs/$nm/pips-sweep.log" || ! switch_ok; then
        switch_dead "during sweep $label"
    fi
    return 0
}

# ------------------------------------------------------------------ NIC extras
if [ "$KIND" = nic ]; then
    . "$REPO/utils/setup-server.sh"
    rsh_try() {
        if [ -n "${CLIENT_PWD:-}" ]; then
            sshpass -p "$CLIENT_PWD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
                "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
        else
            ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
                "$CLIENT_USERNAME@$CLIENT_SSH_IP" "$@"
        fi
    }
    rcp_back() {
        if [ -n "${CLIENT_PWD:-}" ]; then sshpass -p "$CLIENT_PWD" scp "$CLIENT_USERNAME@$CLIENT_SSH_IP:$1" "$2"
        else scp -o BatchMode=yes "$CLIENT_USERNAME@$CLIENT_SSH_IP:$1" "$2"; fi
    }
    if ! declare -p SERVER_INTFS CLIENT_INTFS >/dev/null 2>&1; then
        [ "$DRY" = 1 ] || { echo "ERROR: utils/setup-server.sh sets no SERVER_INTFS/CLIENT_INTFS (not icx's?)" >&2; exit 1; }
        SERVER_INTFS=(srv-nic0 srv-nic1); CLIENT_INTFS=(cli-nic0 cli-nic1)
    fi
    S0=${SERVER_INTFS[0]}; C0=${CLIENT_INTFS[0]}
    link_of() { awk '/Speed:/ { s = $2 } /Auto-negotiation:/ { a = $2 } /Link detected:/ { l = $3 }
                     END { print s, a, l }'; }
    # wire_wait <speed Mb/s>: both ends of NIC0's link up at that speed (90 s)
    wire_wait() {
        local k s c
        for k in $(seq 1 18); do
            sleep 5
            s=$(ethtool "$S0" 2>/dev/null | link_of); c=$(rsh_try "ethtool $C0" 2>/dev/null | link_of)
            echo "    wire: $S0 $s | $C0 $c"
            [[ "$s" == "${1}Mb/s "*" yes" ]] && [[ "$c" == "${1}Mb/s "*" yes" ]] && return 0
        done
        return 1
    }
    snapshot_nics() {   # <tag before|after>
        say "NIC snapshots ($1): icx here, styx over ssh (read-only)"
        bash "$REPO/scripts/nic-host-snapshot.sh" -o "$OUT/snapshots/icx-$1" "${SERVER_INTFS[@]}" > /dev/null 2>&1 ||
            note "icx snapshot ($1) failed"
        rm -f "$OUT/snapshots/icx-$1.tar.gz"
        local r="/tmp/nic-snapshot-styx-$STAMP-$1"
        if rsh_try "cd '$REPO' && bash scripts/nic-host-snapshot.sh -o '$r' ${CLIENT_INTFS[*]}" > /dev/null 2>&1 &&
           rcp_back "$r.tar.gz" "$OUT/snapshots/styx-$1.tar.gz" 2>/dev/null; then
            rsh_try "rm -rf '$r' '$r.tar.gz'" >/dev/null 2>&1
        else
            note "styx snapshot ($1) failed (is scripts/nic-host-snapshot.sh in styx's copy of the repo?)"
        fi
    }
fi

# phase_run <phase>
phase_run() {
    local p=$1 q
    CUR_PHASE=$p
    case "$KIND:$p" in
        ssd:main)  sweep_run main --cfgs "$DEPTHS" --caps 1 --pbs "0 1" --set "$THR" "${SSD_MAIN[@]}" ;;
        ssd:cap0)  sweep_run cap0 --cfgs "1:0 8:106 64:255" --caps 0 --pbs "0 1" --set "$THR" "${SSD_KNOB[@]}" ;;
        ssd:push)  sweep_run push --cfgs "8:106 64:255" --caps 1 --pbs 1 --set "$THR pushoff=1" "${SSD_KNOB[@]}" ;;
        ssd:quant) for q in 64 256 1024; do
                       sweep_run "q$q" --cfgs "64:255" --caps 1 --pbs 1 --set "$THR quantum=$q" "${SSD_KNOB[@]}"
                   done ;;
        ssd:thr)   sweep_run thr4 --cfgs "8:106 64:255" --caps 1 --pbs 1 --set "thr=4" "${SSD_KNOB[@]}" ;;
        ssd:drv0)  sweep_run drv0 --cfgs "1:0" --caps "0 1" --pbs 0 --set "$THR" "${SSD_DRV0[@]}" ;;
        nic:mainlo) sweep_run mainlo --cfgs "$DEPTH_LO" --caps 1 --pbs "0 1" --set "$THR" "${NIC_MAIN[@]}" ;;
        nic:mainhi) sweep_run mainhi --cfgs "$DEPTH_HI" --caps 1 --pbs "0 1" --set "$THR" "${NIC_MAIN[@]}" ;;
        nic:cap0)  sweep_run cap0 --cfgs "1:0 8:106 16:218" --caps 0 --pbs "0 1" --set "$THR" "${NIC_KNOB[@]}" ;;
        nic:push)  sweep_run push --cfgs "8:106 16:218" --caps 1 --pbs 1 --set "$THR pushoff=1" "${NIC_KNOB[@]}" ;;
        nic:quant) for q in 64 256 1024; do
                       sweep_run "q$q" --cfgs "16:218" --caps 1 --pbs 1 --set "$THR quantum=$q" "${NIC_KNOB[@]}"
                   done ;;
        nic:thr)   sweep_run thr16 --cfgs "8:106 16:218" --caps 1 --pbs 1 --set "thr=16" "${NIC_KNOB[@]}" ;;
        nic:alone) sweep_run alonea --cfgs "1:0 16:64" --caps 0 --pbs "0 1" --set "$THR" "${NIC_ALONE[@]}"
                   sweep_run aloneb --cfgs "4:22" --caps 1 --pbs "0 1" --set "$THR" "${NIC_ALONE[@]}" ;;
        nic:hw)    if [ "$DRY" = 0 ] && [ "${HW_OK:-0}" != 1 ]; then
                       note "phase hw SKIPPED: styx's $C0 refused tx_maxrate at the start"; return 0
                   fi
                   sweep_run hwa --cfgs "16:64" --caps 0 --pbs 0 --set "$THR" "${NIC_HW[@]}"
                   sweep_run hwb --cfgs "4:22" --caps 1 --pbs 0 --set "$THR" "${NIC_HW[@]}" ;;
        nic:wire)  phase_wire ;;
    esac
}

# NIC0's link forced to 50G at both ends for two small sweeps, then put back as
# it was. Ethernet only: the PCIe links are not touched.
phase_wire() {
    if [ "$DRY" = 1 ]; then
        echo "    sudo ethtool -s $S0 speed 50000 autoneg off; styx: sudo ethtool -s $C0 speed 50000 autoneg off"
        sweep_run wirea --cfgs "16:64" --caps 0 --pbs 0 --set "$THR" "${NIC_WIRE[@]}"
        sweep_run wireb --cfgs "4:22" --caps 1 --pbs 0 --set "$THR" "${NIC_WIRE[@]}"
        echo "    then both ends back to their speed and autonegotiation as found"
        return 0
    fi
    [ "$SWITCH_DEAD" = 1 ] && { note "phase wire SKIPPED: the switch is not answering"; return 0; }
    local s0 c0 ss sa cs ca ok=1
    s0=$(ethtool "$S0" 2>/dev/null | link_of); c0=$(rsh_try "ethtool $C0" 2>/dev/null | link_of)
    read -r ss sa _ <<< "$s0"; read -r cs ca _ <<< "$c0"
    say "wire: NIC0 link as found: $S0 $s0 | $C0 $c0; forcing 50G at both ends"
    sudo -n ethtool -s "$S0" speed 50000 autoneg off || ok=0
    rsh_try "sudo -n ethtool -s $C0 speed 50000 autoneg off" || ok=0
    if [ "$ok" = 1 ] && wire_wait 50000; then
        sweep_run wirea --cfgs "16:64" --caps 0 --pbs 0 --set "$THR" "${NIC_WIRE[@]}"
        sweep_run wireb --cfgs "4:22" --caps 1 --pbs 0 --set "$THR" "${NIC_WIRE[@]}"
    else
        note "phase wire: NIC0's link did not come up at 50G (the cable or the card may not do it); nothing run"
    fi
    say "wire: putting NIC0's link back"
    if [ "$sa" = on ]; then sudo -n ethtool -s "$S0" autoneg on; else sudo -n ethtool -s "$S0" speed "${ss%Mb/s}" autoneg off; fi
    if [ "$ca" = on ]; then rsh_try "sudo -n ethtool -s $C0 autoneg on"; else rsh_try "sudo -n ethtool -s $C0 speed ${cs%Mb/s} autoneg off"; fi
    if ! wire_wait "${ss%Mb/s}"; then
        banner "NIC0's LINK DID NOT COME BACK AT ${ss} after the wire-speed test." \
               "Put it back by hand:" \
               "  sudo ethtool -s $S0 $( [ "$sa" = on ] && echo "autoneg on" || echo "speed ${ss%Mb/s} autoneg off")" \
               "  ssh $CLIENT_USERNAME@$CLIENT_SSH_IP sudo ethtool -s $C0 $( [ "$ca" = on ] && echo "autoneg on" || echo "speed ${cs%Mb/s} autoneg off")"
        note "NIC0's link did not come back at $ss after the wire test: fix by hand (campaign.log)"
    fi
}

# ------------------------------------------------------------------ dry run
if [ "$DRY" = 1 ]; then
    plan
    echo
    echo "commands:"
    for p in "${RUN_PHASES[@]}"; do echo "  [$p]"; phase_run "$p"; done
    exit 0
fi

# ------------------------------------------------------------------ preflight
[ -e "$OUT" ] || [ -e "$OUT.tar.gz" ] && { echo "pips-campaign: $OUT exists; pass another --stamp" >&2; exit 1; }
mkdir -p "$OUT/snapshots" "$OUT/results" "$OUT/sweeplogs" "$OUT/runs" || exit 1
exec > >(trap '' INT TERM; exec tee -a "$OUT/campaign.log") 2>&1
exec 7>/tmp/pips-campaign.lock
flock -n 7 || { echo "ERROR: another pips-campaign is running (/tmp/pips-campaign.lock)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "ERROR: sudo needs a password: run with --tmux, or 'sudo -v' first" >&2; exit 1; }
( while sleep 240; do sudo -n -v 2>/dev/null; done ) & SUDO_KEEP=$!
plan | tee "$OUT/plan.txt"
echo
pips_build || { echo "ERROR: cannot build $PIPS" >&2; exit 1; }
switch_ok || { echo "ERROR: the switch does not answer as design 0x0a06:" >&2; printf '%s\n' "$LAST_SWITCH" | tail -5 >&2; exit 1; }
say "switch: $(printf '%s\n' "$LAST_SWITCH" | grep -E '^(cfg|drain|pb|thr|design_id)=' | xargs)"
sudo -n "$PIPS" status > "$OUT/status-at-start.txt" 2>&1 && say "status registers at start: $(grep -E '^(stat_flags|ovf_count|mrd_wait_max_us)' "$OUT/status-at-start.txt" | xargs)"
free=$(df -Pk "$HOME" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
[ "${free:-0}" -lt 20 ] && note "only ${free} GB free in $HOME: the TLP logs take ~1-2 MB per run"
say "disk: ${free} GB free in $HOME; analysis -j $JOBS"
if [ "$KIND" = ssd ]; then
    # Both drives completing on one CPU livelocks it in strict mode (10-25).
    bash "$REPO/scripts/ssd-irq-placement.sh" --check | tee "$OUT/irq-placement.txt" ||
        { echo "ERROR: the drives' fio cores are unsafe for this boot's interrupt layout (above)." >&2; exit 1; }
fi
if [ "$KIND" = nic ]; then
    say "client: syncing styx's repo (git pull --ff-only), as run-dualnic-experiment.sh --sync-client"
    rsh_try "cd '$REPO' && git fetch -q origin && git checkout -q $(git -C "$REPO" rev-parse --abbrev-ref HEAD) && git pull -q --ff-only" ||
        note "styx's repo did not sync: the runs use whatever it has"
    HW_OK=0
    if rsh_try "sudo -n sh -c 'echo 10000 > /sys/class/net/$C0/queues/tx-0/tx_maxrate && echo 0 > /sys/class/net/$C0/queues/tx-0/tx_maxrate'" 2>/dev/null; then
        HW_OK=1; say "styx $C0 takes tx_maxrate: hardware pacing available"
    else
        note "styx $C0 refuses tx_maxrate: phase hw will be skipped"
    fi
    snapshot_nics before
fi

# The heartbeat also guards the host: LOCKUP_STOP (default 2) or more kernel
# soft lockups within one heartbeat interval stop the campaign's sweeps, as
# Ctrl-C would (each sweep puts the switch's setting back), and the campaign
# goes on to the analysis and the packing. On bigserver (10-25) strict-mode
# invalidations piled onto one interrupt CPU livelocked it for minutes at a
# time; driving load into that spoils every run and risks a shared machine.
CAMP_T0=$(date +%s)
heartbeat() {
    local prev=0 lk
    while sleep "${HEARTBEAT:-300}"; do
        local st n=0 m
        st=$(cat "$OUT/.state" 2>/dev/null)
        m=$(ls -t "$REPO"/utils/logs/dual"$KIND"-pips-*-"${st##* }"/manifest.tsv 2>/dev/null | head -1)
        [ -n "$m" ] && n=$(grep -vc '^#' "$m")
        lk=$(sudo -n journalctl -k --since "@$CAMP_T0" 2>/dev/null | grep -c 'soft lockup')
        echo "  ... campaign alive $(date '+%H:%M'), +$(fmt_min $(( (SECONDS - T0) / 60 ))): ${st:-starting}, $(( n > 0 ? n - 1 : 0 )) runs in its manifest, ${lk:-?} soft lockups so far"
        if [ $(( ${lk:-0} - prev )) -ge "${LOCKUP_STOP:-2}" ] && [ ! -e "$OUT/.lockup-stop" ]; then
            echo "!!!!!!!! $(( lk - prev )) kernel soft lockups in the last ${HEARTBEAT:-300} s: STOPPING the sweeps (soft-lockup guard)"
            date '+%F %T' > "$OUT/.lockup-stop"
            pkill -INT -f 'dual(ssd|nic)_pips_swee[p]|dualssd_swee[p]|dualnic_flow_swee[p]|run-dual(ssd|nic)-experimen[t]'
        fi
        prev=${lk:-$prev}
    done
}
heartbeat & HB=$!
on_exit() { kill "$HB" "$SUDO_KEEP" 2>/dev/null; }
trap on_exit EXIT
trap 'STOPPED=1; note "campaign interrupted by hand"' INT TERM

# ------------------------------------------------------------------ sweeps
done_min=0
for i in "${!RUN_PHASES[@]}"; do
    p=${RUN_PHASES[$i]}
    left=0; for q in "${RUN_PHASES[@]:$i}"; do left=$(( left + $(est_points "$q") )); done
    left=$(awk -v n="$left" -v r="$MIN_PER_PT" 'BEGIN { printf "%d", n * r }')
    read -r an ap <<< "$(est_analysis)"
    echo
    say "PHASE $((i + 1))/${#RUN_PHASES[@]} $p: $(describe "$p")"
    say "      sweeps left ~$(fmt_min "$left"), everything packed ~$(clock_in $(( left + an + ap + 10 )))"
    [ "$STOPPED" = 1 ] && { note "phase $p not run: stopped by hand"; continue; }
    phase_run "$p"
done
echo
say "sweeps done: ${#NAMES[@]} sweep(s): ${NAMES[*]:-none}"
sudo -n "$PIPS" status > "$OUT/status-at-end.txt" 2>&1
[ "$KIND" = nic ] && snapshot_nics after

# ------------------------------------------------------------------ analysis
if [ "${#MANIFESTS[@]}" -gt 0 ]; then
    python3 "$HERE/pips-status-table.py" "${MANIFESTS[@]}" --repo "$REPO" --tsv "$OUT/status.tsv" > "$OUT/status.txt" 2>&1
    say "status registers: $(grep -E '^[0-9]+ runs, [0-9]+ flagged|^no runs' "$OUT/status.txt" | head -1)"
    grep -q 'STUCK' "$OUT/status.txt" && grep -E '<-- .*STUCK' "$OUT/status.txt" | head -3 | while read -r l; do note "stuck: $l"; done
fi
if [ "$ANALYSIS" = 1 ] && [ "${#MANIFESTS[@]}" -gt 0 ]; then
    margs=(); for m in "${MANIFESTS[@]}"; do margs+=(--manifest "$m"); done
    say "analysis 1/2: this campaign's ${#MANIFESTS[@]} sweep(s): recorded and arrival order, listings, IOTLB, lengths (-j $JOBS)"
    HEARTBEAT=120 bash "$HERE/pips-analyze.sh" "$KIND" --sweeps "" "${margs[@]}" -j "$JOBS" -o "$OUT/analyze-new" ||
        note "analysis of the new sweeps exited $? (analyze-new/analyze.log)"
    rm -f "$OUT/analyze-new.tar.gz"
fi
if [ "$ANALYSIS" = 1 ] && [ "$PENDING" = 1 ]; then
    say "analysis 2/2: pending, the 0x0A04/0x0A05 sweeps with the fixed model (HANDOFF §8 Next item 0)"
    pend=(); [ "$KIND" = ssd ] && pend=(--no-lengths)
    HEARTBEAT=120 bash "$HERE/pips-analyze.sh" "$KIND" "${pend[@]}" -j "$JOBS" -o "$OUT/analyze-pending" ||
        note "pending analysis exited $? (analyze-pending/analyze.log)"
    rm -f "$OUT/analyze-pending.tar.gz"
fi

# ------------------------------------------------------------------ pack
say "packing"
for n in ${NAMES[@]+"${NAMES[@]}"}; do
    cp -p "$RESULTS/$n.txt" "$RESULTS/$n.manifest.tsv" "$OUT/results/" 2>/dev/null
    cp -p "$RESULTS/$n"-id*.jsonl "$RESULTS/$n"-id*.txt "$OUT/results/" 2>/dev/null
    [ -d "$REPO/utils/logs/$n" ] && cp -rp "$REPO/utils/logs/$n" "$OUT/sweeplogs/"
done
# Per run, the small files only (never the TLP log or pcm's raw output).
nruns=0
for m in ${MANIFESTS[@]+"${MANIFESTS[@]}"}; do
    while IFS=$'\t' read -r _ _ _ _ _ ld rd _; do
        [ -n "$ld" ] || continue
        ( cd "$REPO" && find "$ld" -maxdepth 1 -type f \( -name 'pips-cfg.txt' -o -name 'pips-status*.txt' \
              -o -name 'pips-log-summary.*' -o -name 'sweep-id.txt' -o -name 'nstat-client.txt' \
              -o -name 'pips-log-record.txt' -o -name 'windows.txt' \) -print0 2>/dev/null |
          xargs -0 -r cp --parents -t "$OUT/runs/" )
        ( cd "$REPO" && [ -d "$rd" ] && find "$rd"* -maxdepth 1 -type f -name '*.rpt' -size -1M -print0 2>/dev/null |
          xargs -0 -r cp --parents -t "$OUT/runs/" )
        nruns=$((nruns + 1))
    done < <(grep -v '^#' "$m" | tail -n +2)
done
say "packed the small files of $nruns runs"
{
    echo "pips-campaign $KIND $STAMP on $(hostname), $(date '+%F %T'), +$(fmt_min $(( (SECONDS - T0) / 60 )))"
    echo "sweeps: ${NAMES[*]:-none}"
    echo "switch: $( [ "$SWITCH_DEAD" = 1 ] && echo "STOPPED ANSWERING (snapshots/hang)" || echo "answered to the end")"
    for x in ${NOTES[@]+"${NOTES[@]}"}; do echo "NOTE: $x"; done
} > "$OUT/README.txt"
TAR="$OUT.tar.gz"
( cd "$(dirname "$OUT")" && tar -czf "$TAR" "$(basename "$OUT")" ) && say "tarball: $TAR ($(du -h "$TAR" | cut -f1))"

echo
echo "=============================================================="
echo "  PIPS CAMPAIGN $KIND $STAMP: done in $(fmt_min $(( (SECONDS - T0) / 60 )))"
echo "  copy back: scp $(id -un)@$(hostname):$TAR ."
echo "=============================================================="
cat "$OUT/README.txt"
if [ "$SWITCH_DEAD" = 1 ] || [ ${#NOTES[@]} -gt 0 ]; then
    banner "READ THE NOTES ABOVE: $( [ "$SWITCH_DEAD" = 1 ] && echo "the switch stopped answering; ")${#NOTES[@]} note(s)"
fi
exit 0
