#!/bin/bash
# Dual-SSD cross sweep through the PIPS switch, once per batcher setting. For
# each DEPTH:TIME pair, with the drain depth cap off and then on, it sets the
# batcher through BAR0 (pips cfg set), runs the whole cross sweep -- every
# block size at every instance count, plus the uneven co-runs (--asy) -- with
# the switch's TLP log recorded in every run and checked whole or cut, then
# moves to the next setting. At the end it puts the original setting back and
# prints every setting side by side. dualnic_pips_sweep.sh is the same for
# the NICs.
#
#   ./dualssd_pips_sweep.sh                                # settings "1:0 8:22", cap off and on
#   ./dualssd_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64"   # DEPTH:TIME pairs, in order
#   ./dualssd_pips_sweep.sh --cfgs "8:22:1"                # and batch_mrd on
#   ./dualssd_pips_sweep.sh --caps 0                       # cap off only (as before 0x0a03)
#   ./dualssd_pips_sweep.sh --single --tmux
#   ./dualssd_pips_sweep.sh "4k 1m" "1 4 16" 1             # block sizes, instances, runs
#
# Options:
#   --cfgs "DEPTH:TIME[:MRD] ..."  batcher settings: DEPTH depth_threshold and
#                     TIME time_threshold, 0-255 each; MRD batch_mrd, 0 or 1
#                     (default 0). Default "1:0 8:22": the reset value (no
#                     batching), then depth 8 / time 0x16, the old XSCT setting.
#   --caps "0 1"      drain_depth_cap values run with every --cfgs setting, in
#                     order (default "0 1": twice the runs). 0 = a drain sends
#                     the whole FIFO (reset value, and every build before
#                     design 0x0a03); 1 = at most DEPTH packets per drain. Cap
#                     1 needs design 0x0a03 or later; the sweep refuses to
#                     start without it.
#   --no-asy          the even grid only
#   --asy-low "2 4 8", --asy-high "16 32", --no-swap, --single, --single-ssd N
#                     as dualssd_cross_sweep.sh (--single = drive 0 alone)
#   -o NAME           name the sweep (default dualssd-pips-<iommu>-<N>)
#   --tmux            run it in a new tmux session instead of this terminal
# Runner options go in DUALSSD_ARGS, e.g. DUALSSD_ARGS="--membw 0"; this adds
# --pips-log 1 (run-dualssd-experiment.sh -h). Arguments: block sizes
# (default "4k 8k 16k 64k 1m"), instances per drive (default "1 2 4 8 16 32"),
# repeats (default 1).
#
# Each setting is one cross sweep named <NAME>-id<XXXX>-d<DEPTH>t<TIME>[m1][c1]
# (id<XXXX> = the FPGA design ID, e.g. id0a04; c1 = cap on), with all that
# dualssd_cross_sweep.sh writes: ~/<that>.jsonl and .txt, utils/logs/<that>/,
# utils/reports/<that>/. Each run's log folder also holds its TLP log,
# pips-log-id<XXXX>.bin.gz (the whole recording from FPGA DDR), with
# pips-log-summary.txt/.json and pips-cfg.txt; its report folder pips-log.rpt
# with the status: FULL, CUT, +DROPS, NO_TRAILER, BAD or FAILED. Then:
#   ~/<NAME>.txt                       every setting side by side, the grids,
#                                      and the log check (which runs not FULL);
#                                      its first lines name the design ID
#   utils/logs/<NAME>/pips-sweep.log   this output
#   utils/logs/<NAME>/cfg-<setting>.txt  the batcher registers as set
# On a build without a design ID (older than 0x0a02) names have no id<XXXX>.
#
# Time per setting: ~90 runs (30 even points + 60 uneven, + the datapath
# check), ~1.5 h with DUALSSD_ARGS="--membw 0", ~3 h with pcm-memory; the
# log adds ~5 s per run. --single doubles the even points; the default --caps
# doubles the settings. Stop with Ctrl-C, or:
#   pkill -f 'dualssd_pips_swee[p]'; pkill -f 'dualssd_swee[p]'; pkill -f 'run-dualssd-experimen[t]'
# Either way the original batcher setting and drain cap are put back.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HERE=$(dirname "$SELF")
. "$HERE/../../utils/ssd-lib.sh"
. "$HERE/../pips/pips-lib.sh"

# --tmux: start over inside a tmux session, with the same arguments minus it.
PASS=(); IN_TMUX=0
for a in "$@"; do if [ "$a" = --tmux ]; then IN_TMUX=1; else PASS+=( "$a" ); fi; done
set -- ${PASS[@]+"${PASS[@]}"}

CFGS="1:0 8:22"; CAPS="0 1"; NAME=""; ASY=1; SINGLE_SSD=""; OPTS=(); POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --cfgs)        CFGS="$2"; shift 2 ;;
        --caps)        CAPS="$2"; shift 2 ;;
        --no-asy)      ASY=0; shift ;;
        -o|--out)      NAME="$2"; shift 2 ;;
        --asy-low|--asy-high) OPTS+=( "$1" "$2" ); shift 2 ;;
        --no-swap)     OPTS+=( "$1" ); shift ;;
        --single)      SINGLE_SSD="${SINGLE_SSD:-0}"; shift ;;
        --single-ssd)  SINGLE_SSD="$2"; shift 2 ;;
        -h|--help)     sed -n '2,58p' "$SELF"; exit 0 ;;
        -*)            echo "unknown option: $1" >&2; exit 2 ;;
        *)             POS+=( "$1" ); shift ;;
    esac
done
[ "$ASY" = 1 ] && OPTS+=( --asy )
[ -n "$SINGLE_SSD" ] && OPTS+=( --single-ssd "$SINGLE_SSD" )

# Every setting checked before anything runs: "d:t" or "d:t:m", each with
# every --caps value (cap off first by default).
for c in $CAPS; do
    case "$c" in 0|1) ;; *) echo "--caps: '$c' is not 0 or 1" >&2; exit 2 ;; esac
done
TAGS=(); VALS=(); WANT_CAP=0
for c in $CFGS; do
    IFS=: read -r d t m extra <<< "$c"
    m=${m:-0}
    case "$d$t" in *[!0-9]*|'') d=x ;; esac
    if [ "$d" = x ] || [ -z "$t" ] || [ -n "${extra:-}" ] || [ "$d" -gt 255 ] || [ "$t" -gt 255 ] ||
       { [ "$m" != 0 ] && [ "$m" != 1 ]; }; then
        echo "--cfgs: '$c' is not DEPTH:TIME[:MRD] (0-255, 0-255, 0 or 1)" >&2; exit 2
    fi
    for cap in $CAPS; do
        TAGS+=( "$(pips_tag $(( d | t << 8 | m << 16 )) "$cap")" ); VALS+=( "$d $t $m $cap" )
        [ "$cap" = 1 ] && WANT_CAP=1
    done
done
[ ${#TAGS[@]} -gt 0 ] || { echo "--cfgs/--caps: no settings" >&2; exit 2; }
[ "$(printf '%s\n' "${TAGS[@]}" | sort -u | wc -l)" -eq ${#TAGS[@]} ] ||
    { echo "--cfgs/--caps: a setting is listed twice" >&2; exit 2; }

[ "$IN_TMUX" = 1 ] && relaunch_in_tmux "$SELF" ${PASS[@]+"${PASS[@]}"}

cd "$HERE/.." || exit 1
. ../utils/setup-server.sh
BSIZES="${POS[0]:-4k 8k 16k 64k 1m}"
INSTANCES="${POS[1]:-1 2 4 8 16 32}"
RUNS="${POS[2]:-1}"

# -------------------------------------------------------------- preflight
sudo -n true 2>/dev/null || die "sudo needs a password: run 'sudo -v' in this terminal first"
pips_lock || exit 1
pips_build || die "cannot build $PIPS"
USP=$(pips_find_usp) || exit 1
P() { sudo -n "$PIPS" -s "$USP" "$@"; }
out=$(P cfg 2>&1) ||
    { printf '%s\n' "$out" >&2; die "the PIPS switch does not answer: run scripts/pips/pips-bringup.sh"; }
CFG0=$(cfg_of <(printf '%s\n' "$out")); CAP0=$(cap_of <(printf '%s\n' "$out"))
DESIGN=$(design_of <(printf '%s\n' "$out")); IDT=$(pips_idtag "$DESIGN")
[ -n "$CFG0" ] || die "could not read the batcher setting: $out"
# The drain cap register exists from design 0x0a03; without it only cap 0 runs.
HAVE_CAP=""; pips_design_ge "$DESIGN" 0x0a03 && HAVE_CAP=1
[ "$WANT_CAP" = 1 ] && [ -z "$HAVE_CAP" ] &&
    die "--caps 1: design ${DESIGN:-?} has no drain depth cap (needs 0x0a03 or later); use --caps 0"

declare -p SSD_SERIALS >/dev/null 2>&1 || die "SSD_SERIALS is not set in utils/setup-server.sh"
IOMMU=$(for s in "${SSD_SERIALS[@]}"; do
            ssd_resolve "$s" && bash ../utils/iommu-mode.sh "$SSD_BDF"
        done | sort -u | paste -sd+)
[ -n "$IOMMU" ] || exit 1

DIR="${RESULTS_DIR:-$HOME}"
taken() {   # <name> -> true if it or any of its settings has results in $DIR
    local s
    [ -e "$DIR/$1.txt" ] && return 0
    for s in d id; do
        compgen -G "$DIR/$1-$s*t*.jsonl" >/dev/null || compgen -G "$DIR/$1-$s*t*.txt" >/dev/null &&
            return 0
    done
    return 1
}
if [ -z "$NAME" ]; then
    n=1; while taken "dualssd-pips-$IOMMU-$n"; do n=$((n + 1)); done
    NAME="dualssd-pips-$IOMMU-$n"
elif taken "$NAME"; then
    die "a sweep named '$NAME' already has results in $DIR; pick another -o NAME"
fi
UTILS="$(cd ../utils && pwd)"
LOGDIR="$UTILS/logs/$NAME"
mkdir -p "$LOGDIR"
exec > >(trap '' INT TERM; exec tee -a "$LOGDIR/pips-sweep.log") 2>&1

# Put the original setting and drain cap back however the sweep ends, without
# log_enable: raising it would start a recording.
restore() {
    local v
    v=$(printf '0x%08x' $(( CFG0 & ~0x1000000 )))
    if P cfg set raw="$v" ${HAVE_CAP:+cap="$CAP0"} > "$LOGDIR/cfg-restored.txt" 2>&1; then
        echo "######## batcher setting restored: $(pips_tag "$v" "$CAP0") ($v)"
    else
        echo "######## WARNING: could not restore the batcher setting $v:" \
             "$(tail -1 "$LOGDIR/cfg-restored.txt")" >&2
    fi
}
trap restore EXIT
STOP=0
trap 'STOP=1' INT TERM

echo "######## dual-SSD PIPS sweep $NAME"
echo "######## settings: ${TAGS[*]}   (each a full cross sweep$( [ "$ASY" = 1 ] && echo " with --asy"))"
echo "######## grid: bs $BSIZES x instances $INSTANCES, $RUNS run(s)$( [ -n "$SINGLE_SSD" ] && echo ", drive $SINGLE_SSD alone too")"
echo "######## PIPS: $USP, design ${DESIGN:-?}, batcher before: $(pips_tag "$CFG0" "$CAP0") ($CFG0)"
echo "######## IOMMU: $IOMMU   kernel $(uname -r)   runner args: ${DUALSSD_ARGS:-} --pips-log 1"
echo "######## per setting: $NAME${IDT:+-$IDT}-<setting>"
echo "######## logs: $LOGDIR/"

# ----------------------------------------------------------------- sweep
DONE=(); NOTES=(); t0=$SECONDS
for k in "${!TAGS[@]}"; do
    tag=${TAGS[$k]}; read -r d t m cap <<< "${VALS[$k]}"
    sub="$NAME${IDT:+-$IDT}-$tag"
    echo
    echo "######## [$((k + 1))/${#TAGS[@]}] batcher $tag: depth $d, time $t, batch_mrd $m," \
         "drain cap $cap ($(( (SECONDS - t0) / 60 )) min in)"
    if ! P cfg set depth="$d" time="$t" mrd="$m" log=0 ${HAVE_CAP:+cap="$cap"} \
            > "$LOGDIR/cfg-$tag.txt" 2>&1; then
        NOTES+=( "$tag: NOT RUN, setting it failed: $(tail -1 "$LOGDIR/cfg-$tag.txt")" )
        echo "######## ${NOTES[-1]}" >&2
        continue
    fi
    echo "######## set: $(grep -E '^(cfg|drain|design_id)=' "$LOGDIR/cfg-$tag.txt" | xargs)"
    DUALSSD_ARGS="${DUALSSD_ARGS:-} --pips-log 1" \
        bash "$HERE/dualssd_sweep.sh" -o "$sub" ${OPTS[@]+"${OPTS[@]}"} \
        "$INSTANCES" "$BSIZES" "$RUNS"
    rc=$?
    DONE+=( "$sub" )
    P cfg > "$LOGDIR/cfg-$tag-after.txt" 2>/dev/null
    now=$(cfg_of "$LOGDIR/cfg-$tag-after.txt")
    if [ -n "$now" ] && [ "$(pips_tag "$now" "$(cap_of "$LOGDIR/cfg-$tag-after.txt")")" != "$tag" ]; then
        NOTES+=( "$tag: the batcher read $(pips_tag "$now" "$(cap_of "$LOGDIR/cfg-$tag-after.txt")") at the end: changed during the sweep" )
        echo "######## WARNING: ${NOTES[-1]}" >&2
    fi
    if [ "$STOP" = 1 ] || [ "$rc" = 130 ] || [ "$rc" = 143 ]; then
        NOTES+=( "stopped by hand during $tag" )
        echo "######## STOPPED by hand" >&2
        break
    fi
done

# --------------------------------------------------------------- summary
FILES=()
for s in ${DONE[@]+"${DONE[@]}"}; do [ -s "$DIR/$s.jsonl" ] && FILES+=( "$DIR/$s.jsonl" ); done
{
    echo "dual-SSD PIPS sweep $NAME  $(date '+%F %T')  host $(hostname)"
    echo "design_id=${DESIGN:-none}"
    echo "IOMMU $IOMMU  kernel $(uname -r)  PIPS design ${DESIGN:-?}"
    echo "settings: ${TAGS[*]}   bs: $BSIZES   instances: $INSTANCES   runs: $RUNS" \
         "$( [ "$ASY" = 1 ] && echo "  + uneven co-runs")"
    echo "per setting: ~/$NAME${IDT:+-$IDT}-<setting>.jsonl/.txt, utils/logs/$NAME${IDT:+-$IDT}-<setting>/"
    for x in ${NOTES[@]+"${NOTES[@]}"}; do echo "NOTE: $x"; done
    echo
    if [ ${#FILES[@]} -gt 0 ]; then
        python3 ../scripts/dualssd-results.py summary "${FILES[@]}"
        if [ "$(echo $BSIZES | wc -w)" -gt 1 ] && [ "$(echo $INSTANCES | wc -w)" -gt 1 ]; then
            echo
            python3 ../scripts/dualssd-results.py grid "${FILES[@]}"
        fi
    else
        echo "no results recorded"
    fi
} > "$DIR/$NAME.txt"
echo
echo "=============================================================="
echo "  DUAL-SSD PIPS SWEEP $NAME: ${#DONE[@]} of ${#TAGS[@]} setting(s) run"
echo "=============================================================="
cat "$DIR/$NAME.txt"
echo
echo "=============================================================="
# The log check again, as the last thing on screen: the configurations whose
# runs did not all record a FULL log, and the count of each status.
echo "  log check:"
sed -n '/^PIPS TLP log per configuration/,/^  logs: /p' "$DIR/$NAME.txt" | grep -E 'NOT ALL FULL|^  logs: '
for x in ${NOTES[@]+"${NOTES[@]}"}; do echo "  NOTE: $x"; done
echo "  everything side by side: $DIR/$NAME.txt   (design ${DESIGN:-?})"
echo "  per setting: $DIR/$NAME${IDT:+-$IDT}-<setting>.{jsonl,txt}, $UTILS/logs/$NAME${IDT:+-$IDT}-<setting>/"
[ "$STOP" = 1 ] && exit 130
exit 0
