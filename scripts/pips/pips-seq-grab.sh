#!/bin/bash
# What the page-order figures need from a PIPS sweep's TLP logs: the TLP
# sequence on the switch's output (one block per run of a page), and page
# switches per I/O when that output is regrouped in windows of W TLPs, with
# the IOTLB simulation. Runs pips-page-seq.py on one log per point and
# batcher setting, on the host that holds the logs, and packs the results.
#
#   bash scripts/pips/pips-seq-grab.sh ssd|nic [options]
#
#   --sweep NAME     sweep name before the setting (default
#                    dualssd-pips-strict-1-id0a04 / dualnic-pips-strict-1-id0a04)
#   --sets "S ..."   batcher settings (default: the eight 0x0A04 ones,
#                    d1t0 d1t0c1 d4t22 d4t22c1 d8t22 d8t22c1 d16t64 d16t64c1)
#   --points "P ..." run names. ssd default: 4k-j8-both 4k-j16-both
#                    4k-j32-both 16k-j8-both 64k-j8-both 1m-j8-both 1m-j16-both.
#                    nic default: f5-both f15-both f30-both f5-nic0only
#                    f30-nic0only
#   --show N         runs of the sequence to list per log, from record 100000
#                    (default 600)
#   --logs DIR       where the sweep logs are (default utils/logs)
#   -j N             logs at a time (default 4)
#   -o DIR           output folder (default ~/seq-<sweep>); refused if it exists
#
# Logs used, the first match of:
#   ssd  <logs>/<sweep>-<set>/<point>-RUN-*/pips-log*.bin*
#   nic  <logs>/<sweep>-<set>-uncapped-<point>-RUN-*/pips-log*.bin*
# A 4 KiB point whose run was dropped for missing pcm-iio rows still has its
# log, and is used. Sweeps with "-strict-" in the name get --strict (a page's
# new visit always misses in the IOTLB simulation).
#
# Output in DIR, then DIR.tar.gz of it:
#   seq-<set>-<point>.txt   pips-page-seq.py's report: interleaving, what-if,
#                           simulated IOTLB misses, and the sequence (--show)
#   seq.jsonl               one JSON line per log (--json), with its path
#   manifest.txt            the log used for each point, missing ones, the
#                           git revision and the command line
# Copy DIR.tar.gz back next to the sweep results (dualssd/1016/, dualnic/1016/).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

KIND=${1:-}
case "$KIND" in
    ssd|nic) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "pips-seq-grab: first argument must be ssd or nic" >&2; exit 2 ;;
esac
SWEEP="dual${KIND}-pips-strict-1-id0a04"
SETS="d1t0 d1t0c1 d4t22 d4t22c1 d8t22 d8t22c1 d16t64 d16t64c1"
if [ "$KIND" = ssd ]; then
    POINTS="4k-j8-both 4k-j16-both 4k-j32-both 16k-j8-both 64k-j8-both 1m-j8-both 1m-j16-both"
else
    POINTS="f5-both f15-both f30-both f5-nic0only f30-nic0only"
fi
SHOW=600; JOBS=4; OUT=""; LOGS="$REPO/utils/logs"
while [ $# -gt 0 ]; do
    case "$1" in
        --sweep) SWEEP="$2"; shift 2 ;;
        --sets) SETS="$2"; shift 2 ;;
        --points) POINTS="$2"; shift 2 ;;
        --show) SHOW="$2"; shift 2 ;;
        --logs) LOGS="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "pips-seq-grab: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-$HOME/seq-$SWEEP}
OUT=${OUT%/}
if [ -e "$OUT" ] || [ -e "$OUT.tar.gz" ]; then
    echo "pips-seq-grab: $OUT or $OUT.tar.gz exists; remove it or pass -o" >&2
    exit 1
fi
[ -d "$LOGS" ] || { echo "pips-seq-grab: no log folder $LOGS (--logs)" >&2; exit 1; }
mkdir -p "$OUT"

STRICT=""
case "$SWEEP" in *-strict-*) STRICT="--strict" ;; esac
PY=${PYTHON:-python3}
SEQ="$HERE/pips-page-seq.py"

jobs_file="$OUT/.jobs"
: > "$jobs_file"
{
    echo "pips-seq-grab $KIND  $(date '+%F %T')  host $(hostname)"
    echo "repo revision $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "sweep $SWEEP  sets: $SETS"
    echo "points: $POINTS"
    echo "pips-page-seq.py --kind $KIND --iotlb 1x64,16x4,64x1 $STRICT --show $SHOW --from 100000"
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
        for f in $pat; do
            [ -e "$f" ] && { log=$f; break; }
        done
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
echo "pips-seq-grab: $n logs, $missing missing, $JOBS at a time, into $OUT"

one() {
    local set=$1 point=$2 log=$3
    local base="$set-$point"
    if $PY "$SEQ" "$log" --kind "$KIND" --iotlb 1x64,16x4,64x1 $STRICT --json "$OUT/.$base.json" \
           --show "$SHOW" --from 100000 > "$OUT/seq-$base.txt" 2> "$OUT/.$base.err"; then
        echo "  done  $base"
    else
        echo "  FAIL  $base: $(tail -n 1 "$OUT/.$base.err")"
    fi
}
export -f one
export PY SEQ KIND STRICT OUT SHOW
xargs -P "$JOBS" -n 3 bash -c 'one "$@"' _ < "$jobs_file"

cat "$OUT"/.*.json > "$OUT/seq.jsonl" 2>/dev/null
done_n=$(wc -l < "$OUT/seq.jsonl")
for e in "$OUT"/.*.err; do
    [ -s "$e" ] && { echo "--- $(basename "$e")"; cat "$e"; } >> "$OUT/manifest.txt"
done
rm -f "$OUT"/.*.json "$OUT"/.*.err "$jobs_file"
echo "analysed $done_n of $n logs" >> "$OUT/manifest.txt"
( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) \
    || { echo "pips-seq-grab: tar failed; the results are in $OUT" >&2; exit 1; }
echo "pips-seq-grab: $done_n of $n logs analysed, $missing missing (manifest.txt)"
echo "  $OUT.tar.gz"
[ "$done_n" -eq "$n" ] && [ "$n" -gt 0 ]
