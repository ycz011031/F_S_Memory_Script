#!/bin/bash
# What the page-order figures need from a PIPS sweep's TLP logs: the TLP
# sequence as it entered the switch (rebuilt from each TLP's time in the
# batcher, v2 logs) and as it left (one block per run of a page), page
# switches per I/O when either is regrouped in windows of W TLPs, the IOTLB
# simulation, and the batcher model run on the arrival order (the log's own
# setting, to check the model, the eight 0x0A04 settings and a depth sweep,
# cap off and on, also with the other build's FIFO size).
# Runs pips-page-seq.py on one log per point and batcher setting, on the host
# that holds the logs, and packs the results.
#
#   bash scripts/pips/pips-seq-grab.sh ssd|nic [options]
#   bash scripts/pips/pips-seq-grab.sh --manifest ~/<sweep>.manifest.tsv [options]
#
#   --manifest FILE  a PIPS sweep's manifest (SWEEP-LOGS.md): its runs and only
#                    those, the TLP log each row names, rows of other sweep IDs
#                    and datapath checks left out. Kind, sweep and settings
#                    come from it (--sets, --points still narrow them); the
#                    model default becomes "self,<every setting of the
#                    sweep>,sweep,sweepc1" plus the cap-on sweep with the other
#                    FIFO size (sweepc1f128 on a 0x0a05 sweep, else
#                    sweepc1f512), and the output ~/seq-<sweep>. On a sweep of
#                    design 0x0a06 or later (the page batcher) no model runs
#                    unless --model or PIPS_PB_MODEL is given: the recorded
#                    order, arrival order (rebuilt from pkt_wait), what-ifs and
#                    IOTLB simulation only
#   --sweep NAME     sweep name before the setting (default
#                    dualssd-pips-strict-1-id0a04 / dualnic-pips-strict-1-id0a04)
#   --sets "S ..."   batcher settings (default: the eight 0x0A04 ones,
#                    d1t0 d1t0c1 d4t22 d4t22c1 d8t22 d8t22c1 d16t64 d16t64c1)
#   --points "P ..." run names, or "all" (default): every run of the sweep's
#                    first setting that has a log, uneven co-runs (4k-j2+16-both)
#                    and one-NIC runs included, datapath checks (any name with
#                    "datapath") left out
#   --model LIST     batcher model settings, as pips-page-seq.py --model
#                    (default self,std,sweep,sweepc1,sweepc1f512; "" for none).
#                    The model sends no faster than the uplink: gen3x8 for
#                    ssd, gen4x8 for nic (pips-page-seq.py --link; PIPS_LINK
#                    in the environment overrides it), at the rate measured
#                    first on this sweep's logs: the calibration pass below
#                    (PIPS_LINK_RATE=bytes-per-cycle in the environment skips it)
#   --show N         runs of each sequence to list per log, from record 100000
#                    (default 600)
#   --logs DIR       where the sweep logs are (default utils/logs)
#   -j N             logs at a time (default 4; each takes about a minute)
#   -o DIR           output folder (default ~/seq-<sweep>); refused if it exists
#
# Logs used, the first match of:
#   ssd  <logs>/<sweep>-<set>/<point>-RUN-*/pips-log*.bin*
#   nic  <logs>/<sweep>-<set>-uncapped-<point>-RUN-*/pips-log*.bin*
# A 4 KiB point whose run was dropped for missing pcm-iio rows still has its
# log, and is used. Sweeps with "-strict-" in the name get --strict (a page's
# new visit always misses in the IOTLB simulation).
#
# Calibration (with a model, v2 logs): pips-page-seq.py --calibrate on every
# log first (a few seconds each): each log's output as logged lacks the stalls
# inside packets, and the uplink rate that puts them back is fitted to the
# log's duration. The median over the clean logs (one segment, a full link)
# is the uplink's rate, passed to every log as --link-rate. Too few clean logs
# (light load, or the NICs, whose datapath and not the link limits): no
# --link-rate, so LINK_EFF of the raw rate. A line per log as it finishes.
#
# Output in DIR, then DIR.tar.gz of it:
#   calibrate.txt           the fit per log and the rate chosen
#   seq-<set>-<point>.txt   pips-page-seq.py's report: interleaving, what-ifs,
#                           simulated IOTLB misses, the model, and both
#                           sequences (--show, --port out,arr)
#   seq.jsonl               one JSON line per log (--json), with its path
#   manifest.txt            the log used for each point, missing ones, the
#                           git revision and the command line
# A line per log as it finishes ([done/total], seconds), and every HEARTBEAT
# seconds (default 60) a line with the count done and, for each log still
# running, the stage it is in (pips-page-seq.py --progress). Copy DIR.tar.gz
# back next to the sweep results (dualssd/1016/, dualnic/1016/).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

KIND=${1:-}; MANIFEST=""
case "$KIND" in
    ssd|nic) shift ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "pips-seq-grab: first argument must be ssd, nic or --manifest FILE" >&2; exit 2 ;;
esac
# A manifest's "# key=value" header lines: sweep_id, sweep, kind, ...
mhead() { sed -n "s/^# $1=//p" "$MANIFEST" | head -1; }
if [ -n "$MANIFEST" ]; then
    [ -s "$MANIFEST" ] || { echo "pips-seq-grab: no manifest $MANIFEST" >&2; exit 1; }
    KIND=$(mhead kind)
    case "$KIND" in ssd|nic) ;; *) echo "pips-seq-grab: $MANIFEST names no kind (ssd|nic)" >&2; exit 1 ;; esac
fi
SWEEP="dual${KIND}-pips-strict-1-id0a04"
SETS="d1t0 d1t0c1 d4t22 d4t22c1 d8t22 d8t22c1 d16t64 d16t64c1"
POINTS=all
MODEL="self,std,sweep,sweepc1,sweepc1f512"
SET_GIVEN=0; MODEL_GIVEN=0
SHOW=600; JOBS=4; OUT=""; LOGS="$REPO/utils/logs"
while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2
            echo "pips-seq-grab: --manifest goes first, in place of ssd|nic" >&2; exit 2 ;;
        --sweep) SWEEP="$2"; shift 2 ;;
        --sets) SETS="$2"; SET_GIVEN=1; shift 2 ;;
        --points) POINTS="$2"; shift 2 ;;
        --model) MODEL="$2"; MODEL_GIVEN=1; shift 2 ;;
        --show) SHOW="$2"; shift 2 ;;
        --logs) LOGS="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "pips-seq-grab: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
ROWS=""
if [ -n "$MANIFEST" ]; then
    SWEEP_ID=$(mhead sweep_id); SWEEP=$(mhead sweep)
    [ -n "$SWEEP_ID" ] && [ -n "$SWEEP" ] || { echo "pips-seq-grab: $MANIFEST has no sweep_id/sweep" >&2; exit 1; }
    # setting, point, TLP log of this sweep's measured runs (not datapath checks)
    ROWS=$(awk -F'\t' -v id="$SWEEP_ID" '/^#/ || $1 == "sweep_id" { next }
                                         $1 == id && $4 == "point" && $8 != "" { print $2, $3, $8 }' "$MANIFEST")
    other=$(awk -F'\t' -v id="$SWEEP_ID" '!/^#/ && $1 != "sweep_id" && $1 != id' "$MANIFEST" | wc -l)
    [ "$other" -gt 0 ] && echo "pips-seq-grab: WARNING: $other row(s) of $MANIFEST carry another sweep ID; left out" >&2
    [ -n "$ROWS" ] || { echo "pips-seq-grab: $MANIFEST lists no runs with a TLP log" >&2; exit 1; }
    msets=$(printf '%s\n' "$ROWS" | awk '!seen[$1]++ { print $1 }' | tr '\n' ' ')
    [ "$SET_GIVEN" = 1 ] || SETS=${msets% }
    other_fifo=sweepc1f512
    [ "$(mhead design_id)" = 0x0a05 ] && other_fifo=sweepc1f128
    [ "$MODEL_GIVEN" = 1 ] || MODEL="self,$(echo $msets | tr ' ' ','),sweep,sweepc1,$other_fifo"
    # The page batcher (0x0a06 on) reorders by page and has its own triggers:
    # the in-order FIFO model does not describe it. Recorded order only, unless
    # PIPS_PB_MODEL in the environment names models (e.g. "self,sweepc1": the
    # page_batch_en 0 logs' own setting as the model sees it, for the check of
    # HANDOFF §8 0x0A06 result 10; "self" is left out on p1 logs).
    case "$(mhead design_id)" in
        0x0a0[6-9]|0x0a[1-9a-f]?) [ "$MODEL_GIVEN" = 1 ] || MODEL="${PIPS_PB_MODEL:-}" ;;
    esac
fi
OUT=${OUT:-$HOME/seq-$SWEEP}
OUT=${OUT%/}
if [ -e "$OUT" ] || [ -e "$OUT.tar.gz" ]; then
    echo "pips-seq-grab: $OUT or $OUT.tar.gz exists; remove it or pass -o" >&2
    exit 1
fi
[ -n "$MANIFEST" ] || [ -d "$LOGS" ] || { echo "pips-seq-grab: no log folder $LOGS (--logs)" >&2; exit 1; }
mkdir -p "$OUT"

STRICT=""
case "$SWEEP" in *-strict-*) STRICT="--strict" ;; esac
PY=${PYTHON:-python3}
SEQ="$HERE/pips-page-seq.py"
MODEL_ARG=""
[ -n "$MODEL" ] && MODEL_ARG="--model $MODEL"
[ -n "$MODEL" ] && [ -n "${PIPS_LINK:-}" ] && MODEL_ARG="$MODEL_ARG --link $PIPS_LINK"

if [ -n "$MANIFEST" ] && [ "$POINTS" = all ]; then   # every measured point the manifest lists
    POINTS=$(printf '%s\n' "$ROWS" | awk '!seen[$2]++ { print $2 }' | tr '\n' ' ')
    POINTS=${POINTS% }
elif [ "$POINTS" = all ]; then                 # every run of the first setting with a log
    first=${SETS%% *}
    if [ "$KIND" = ssd ]; then
        cands=$(ls -d "$LOGS/$SWEEP-$first"/*-RUN-* 2>/dev/null | sed 's#.*/##; s#-RUN-.*##')
    else
        cands=$(ls -d "$LOGS/$SWEEP-$first"-uncapped-*-RUN-* 2>/dev/null \
                | sed "s#.*/$SWEEP-$first-uncapped-##; s#-RUN-.*##")
    fi
    POINTS=$(printf '%s\n' $cands | grep -v 'datapath' | sort -u | tr '\n' ' ')
    POINTS=${POINTS% }
    [ -n "$POINTS" ] || { echo "pips-seq-grab: no runs under $LOGS for $SWEEP-$first" >&2; exit 1; }
fi

jobs_file="$OUT/.jobs"
: > "$jobs_file"
{
    echo "pips-seq-grab $KIND  $(date '+%F %T')  host $(hostname)"
    echo "repo revision $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "sweep $SWEEP  sets: $SETS"
    [ -n "$MANIFEST" ] && echo "manifest $MANIFEST  sweep_id $SWEEP_ID"
    echo "points: $POINTS"
    echo "pips-page-seq.py --kind $KIND --iotlb 1x64,16x4,64x1 $STRICT $MODEL_ARG --show $SHOW --from 100000 --port out,arr"
    echo
} > "$OUT/manifest.txt"
missing=0
for set in $SETS; do
    for point in $POINTS; do
        if [ "$KIND" = ssd ]; then
            pat="$LOGS/$SWEEP-$set/$point-RUN-*/pips-log*.bin*"
        else
            pat="$LOGS/$SWEEP-$set-uncapped-$point-RUN-*/pips-log*.bin*"
        fi
        log=""
        if [ -n "$MANIFEST" ]; then            # the manifest's own row, relative to the repo
            pat="manifest row $set $point"
            f=$(printf '%s\n' "$ROWS" | awk -v s="$set" -v p="$point" '$1 == s && $2 == p { print $3; exit }')
            [ -n "$f" ] && case "$f" in /*) ;; *) f="$REPO/$f" ;; esac
            [ -n "$f" ] && [ -e "$f" ] && log=$f
        else
            for f in $pat; do
                [ -e "$f" ] && { log=$f; break; }
            done
        fi
        if [ -z "$log" ]; then
            echo "missing  $set $point  ($pat)" >> "$OUT/manifest.txt"
            missing=$((missing + 1))
            continue
        fi
        echo "log      $set $point  $log" >> "$OUT/manifest.txt"
        echo "$set $point $log" >> "$jobs_file"
    done
done
n=$(wc -l < "$jobs_file")
echo "pips-seq-grab: $n logs ($(echo "$POINTS" | wc -w) points), $missing missing, $JOBS at a time, into $OUT"

LINK_ARG=""
[ -n "$MODEL" ] && [ -n "${PIPS_LINK:-}" ] && LINK_ARG="--link $PIPS_LINK"
if [ -n "$MODEL" ] && [ -n "${PIPS_LINK_RATE:-}" ]; then
    MODEL_ARG="$MODEL_ARG --link-rate $PIPS_LINK_RATE"
    echo "uplink rate $PIPS_LINK_RATE bytes per cycle (PIPS_LINK_RATE)" | tee -a "$OUT/manifest.txt"
elif [ -n "$MODEL" ] && [ "$n" -gt 0 ]; then
    echo "pips-seq-grab: calibrating the uplink on $n logs (a line per log)"
    cal() {
        local set=$1 point=$2 log=$3 line
        line=$($PY "$SEQ" "$log" --kind "$KIND" $LINK_ARG --calibrate 2>/dev/null | sed -n 's/^calibrate: //p')
        echo "$set $point ${line:-failed}" >> "$OUT/calibrate.txt"
        echo "  calibrate [$(wc -l < "$OUT/calibrate.txt")/$CTOTAL] $set $point: ${line:-failed}"
    }
    export -f cal
    export PY SEQ KIND OUT LINK_ARG
    CTOTAL=$n; export CTOTAL
    : > "$OUT/calibrate.txt"
    xargs -P "$JOBS" -n 3 bash -c 'cal "$@"' _ < "$jobs_file"
    # "<set> <point> segments S lost L fit F clean C": the median fit of the clean ones
    rate=$(awk '$NF == 1 { print $(NF-2) }' "$OUT/calibrate.txt" | sort -g |
           awk '{ v[NR] = $1 } END { if (NR >= 3) printf "%.3f %d %.3f %.3f", v[int((NR + 1) / 2)], NR, v[1], v[NR] }')
    if [ -n "$rate" ]; then
        set -- $rate
        MODEL_ARG="$MODEL_ARG --link-rate $1"
        msg="uplink rate $1 bytes per cycle: the median fit of $2 clean logs (range $3-$4; calibrate.txt)"
    else
        msg="uplink rate: fewer than 3 clean logs (calibrate.txt), so the default (pips-page-seq.py --link-rate)"
    fi
    echo "pips-seq-grab: $msg"
    echo "$msg" >> "$OUT/manifest.txt"
fi

one() {
    local set=$1 point=$2 log=$3
    local base="$set-$point" t0=$SECONDS st
    if $PY "$SEQ" "$log" --kind "$KIND" --iotlb 1x64,16x4,64x1 $STRICT $MODEL_ARG --json "$OUT/.$base.json" \
           --show "$SHOW" --from 100000 --port out,arr --progress > "$OUT/seq-$base.txt" 2> "$OUT/.$base.err"; then
        st="done"
    else
        st="FAIL ($(grep -v '^pips-page-seq: +' "$OUT/.$base.err" | tail -n 1))"
    fi
    echo "$base" >> "$OUT/.finished"
    echo "  [$(wc -l < "$OUT/.finished")/$TOTAL] $st  $base  $((SECONDS - t0)) s"
}
export -f one
TOTAL=$n
: > "$OUT/.finished"
export PY SEQ KIND STRICT OUT SHOW MODEL_ARG TOTAL
T0=$SECONDS
heartbeat() {                                  # liveness: what each running log is doing
    while sleep "${HEARTBEAT:-60}"; do
        local d run="" e b
        d=$(wc -l < "$OUT/.finished" 2>/dev/null || echo 0)
        for e in "$OUT"/.*.err; do
            [ -e "$e" ] || continue
            b=$(basename "$e" .err); b=${b#.}
            grep -qxF "$b" "$OUT/.finished" 2>/dev/null && continue
            run="$run | $b: $(tail -n 1 "$e" | sed 's/^pips-page-seq: //' | cut -c1-48)"
        done
        echo "  ... $(date +%T) $d/$TOTAL done, $(( (SECONDS - T0) / 60 )) min${run}"
    done
}
heartbeat &
HB=$!
trap 'kill $HB 2>/dev/null' EXIT
xargs -P "$JOBS" -n 3 bash -c 'one "$@"' _ < "$jobs_file"
kill $HB 2>/dev/null

cat "$OUT"/.*.json > "$OUT/seq.jsonl" 2>/dev/null
done_n=$(wc -l < "$OUT/seq.jsonl")
for e in "$OUT"/.*.err; do                   # errors only: the progress lines are left out
    grep -v '^pips-page-seq: +' "$e" > "$e.x" 2>/dev/null
    [ -s "$e.x" ] && { echo "--- $(basename "$e")"; cat "$e.x"; } >> "$OUT/manifest.txt"
    rm -f "$e.x"
done
rm -f "$OUT"/.*.json "$OUT"/.*.err "$jobs_file" "$OUT/.finished"
echo "analysed $done_n of $n logs" >> "$OUT/manifest.txt"
( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) \
    || { echo "pips-seq-grab: tar failed; the results are in $OUT" >&2; exit 1; }
echo "pips-seq-grab: $done_n of $n logs analysed, $missing missing (manifest.txt)"
echo "  $OUT.tar.gz"
[ "$done_n" -eq "$n" ] && [ "$n" -gt 0 ]
