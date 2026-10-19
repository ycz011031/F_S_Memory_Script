#!/bin/bash
# Everything the PIPS report needs from one testbed's TLP logs, in one run:
# page order and the batcher model (pips-seq-grab.sh -> pips-page-seq.py) per
# sweep, then payload or control by TLP length (pips-traffic.py) over every
# log of those sweeps together, so each design gets its own verdict. By
# default the two designs' sweeps on this host: the 10-15/16 sweep on 0x0A04
# (eight settings, cap off and on) and the 10-17/18 depth sweep on 0x0A05
# (from its manifest).
#
#   bash scripts/pips/pips-analyze.sh ssd          # bigserver: the drives
#   bash scripts/pips/pips-analyze.sh nic          # icx: the NICs
#   bash scripts/pips/pips-analyze.sh ssd --tmux   # the same in a tmux session
#
#   --sweeps "a04 dsweep1"  which default sweeps (a04: dual<kind>-pips-strict-1-id0a04
#                     from utils/logs; dsweep1: ~/dual<kind>-pips-strict-dsweep1.manifest.tsv)
#   --manifest FILE   also this sweep, by its manifest (repeatable)
#   --no-lengths      page order only
#   -j N              logs at a time in both phases (default 8)
#   -o DIR            output folder (default ~/pips-analyze-<kind>-<date>); refused if it exists
#   --tmux            run in a new tmux session (pips-analyze-<kind>); attach to watch
# Environment: HEARTBEAT=seconds between liveness lines (default 60),
# PIPS_LINK=gen3x8 to override the model's uplink, PYTHON=python3.
#
# Liveness: a line per log as each finishes in both phases, and in the page
# phase every HEARTBEAT seconds a line with the count done and what each
# running log is doing (decoding, what-if, model k/N <setting>).
#
# Output, then DIR.tar.gz of it (copy it back; dualssd/ or dualnic/<date>/):
#   seq-<sweep>/      per sweep: seq-<setting>-<point>.txt, seq.jsonl, manifest.txt
#   logs.txt          every TLP log the page phase used, one path per line
#   traffic.txt       pips-traffic.py's report: per log, then the size rule and
#                     verdict per kind, design, IOMMU mode and setting
#   traffic.jsonl, traffic-sizes.csv   the same per log, and per log, device and size
#   analyze.log       this run's output
# Time: the page phase is about 1-2 min per log (29 model settings on 0x0A04
# logs, 22 on 0x0A05), so with -j 8 about 4-6 h for the drives' ~1,400 logs and
# under 1 h for the NICs' ~120; the length phase ~10 s per log.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

KIND=${1:-}
case "$KIND" in
    ssd|nic) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "pips-analyze: first argument must be ssd or nic" >&2; exit 2 ;;
esac
SWEEPS="a04 dsweep1"; MANIFESTS=(); LENGTHS=1; JOBS=8; OUT=""; TMUX=0; ARGS=("$KIND" "$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --sweeps) SWEEPS="$2"; shift 2 ;;
        --manifest) MANIFESTS+=("$2"); shift 2 ;;
        --no-lengths) LENGTHS=0; shift ;;
        -j) JOBS="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        --tmux) TMUX=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "pips-analyze: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-$HOME/pips-analyze-$KIND-$(date +%Y%m%d-%H%M)}
OUT=${OUT%/}
if [ "$TMUX" = 1 ]; then
    command -v tmux >/dev/null || { echo "pips-analyze: no tmux" >&2; exit 1; }
    rest=(); for x in "${ARGS[@]}"; do [ "$x" = --tmux ] || rest+=("$(printf '%q' "$x")"); done
    tmux new-session -d -s "pips-analyze-$KIND" "bash $(printf '%q' "$0") ${rest[*]} -o $(printf '%q' "$OUT"); exec bash" &&
        echo "pips-analyze: running in tmux session pips-analyze-$KIND (tmux attach -t pips-analyze-$KIND); output $OUT"
    exit $?
fi
if [ -e "$OUT" ] || [ -e "$OUT.tar.gz" ]; then
    echo "pips-analyze: $OUT or $OUT.tar.gz exists; remove it or pass -o" >&2
    exit 1
fi
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/analyze.log") 2>&1
PY=${PYTHON:-python3}
T0=$SECONDS
say() { echo "== $(date '+%F %T') +$(( (SECONDS - T0) / 60 )) min  $*"; }

# The sweeps: (label, pips-seq-grab.sh arguments)
LABELS=(); GRABARGS=()
for s in $SWEEPS; do
    case "$s" in
        a04) LABELS+=("dual$KIND-pips-strict-1-id0a04"); GRABARGS+=("$KIND") ;;
        dsweep1)
            m="$HOME/dual$KIND-pips-strict-dsweep1.manifest.tsv"
            if [ -s "$m" ]; then LABELS+=("dual$KIND-pips-strict-dsweep1"); GRABARGS+=("--manifest $m")
            else say "WARNING: no $m: the 0x0A05 depth sweep is left out"; fi ;;
        *) echo "pips-analyze: --sweeps: '$s' is not a04 or dsweep1 (other sweeps: --manifest)" >&2; exit 2 ;;
    esac
done
for m in ${MANIFESTS[@]+"${MANIFESTS[@]}"}; do
    [ -s "$m" ] || { echo "pips-analyze: no manifest $m" >&2; exit 1; }
    LABELS+=("$(sed -n 's/^# sweep=//p' "$m" | head -1)"); GRABARGS+=("--manifest $m")
done
[ ${#LABELS[@]} -gt 0 ] || { echo "pips-analyze: no sweeps" >&2; exit 1; }
{
    echo "pips-analyze $KIND  $(date '+%F %T')  host $(hostname)  repo $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
    echo "sweeps: ${LABELS[*]}; $JOBS logs at a time; lengths: $([ $LENGTHS = 1 ] && echo yes || echo no)"
} | tee "$OUT/README.txt"

say "phase 1: page order and the batcher model, ${#LABELS[@]} sweep(s)"
failed=0
for i in "${!LABELS[@]}"; do
    lab=${LABELS[$i]}
    say "page order: $lab ($((i + 1))/${#LABELS[@]})"
    # shellcheck disable=SC2086
    bash "$HERE/pips-seq-grab.sh" ${GRABARGS[$i]} -j "$JOBS" -o "$OUT/seq-$lab" || failed=$((failed + 1))
    rm -f "$OUT/seq-$lab.tar.gz"                     # packed with everything at the end
done
awk '$1 == "log" { print $4 }' "$OUT"/seq-*/manifest.txt 2>/dev/null > "$OUT/logs.txt"
say "phase 1 done: $(wc -l < "$OUT/logs.txt") logs, $failed sweep(s) with failures"

if [ "$LENGTHS" = 1 ] && [ -s "$OUT/logs.txt" ]; then
    say "phase 2: payload or control by TLP length, $(wc -l < "$OUT/logs.txt") logs (a line per log)"
    $PY "$HERE/pips-traffic.py" --list "$OUT/logs.txt" -j "$JOBS" --jsonl "$OUT/traffic.jsonl" \
        --csv "$OUT/traffic-sizes.csv" > "$OUT/traffic.txt" 2>&1 &
    TP=$!
    last=0
    while kill -0 "$TP" 2>/dev/null; do               # relay its per-log lines as they come
        sleep 5
        n=$(wc -l < "$OUT/traffic.txt")
        [ "$n" -gt "$last" ] && sed -n "$((last + 1)),${n}p" "$OUT/traffic.txt" | cut -c1-160
        last=$n
    done
    wait "$TP"; rc=$?
    n=$(wc -l < "$OUT/traffic.txt"); [ "$n" -gt "$last" ] && sed -n "$((last + 1)),${n}p" "$OUT/traffic.txt" | tail -40
    say "phase 2 done (exit $rc): verdicts at the end of traffic.txt"
fi

( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" ) &&
    say "packed: $OUT.tar.gz ($(du -h "$OUT.tar.gz" | cut -f1))"
