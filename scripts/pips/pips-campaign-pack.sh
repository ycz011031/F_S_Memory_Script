#!/usr/bin/env bash
# Pack a pips-campaign output folder the way pips-campaign.sh's own "pack"
# step does, for a campaign that ended without packing (killed, host trouble,
# Ctrl-C before the pack) or to repack one. Read-only on the campaign's files:
# it only adds to the folder (sweeplogs/, results/, runs/, bg/stopped/,
# README.txt if missing) and writes <folder>.tar.gz next to it.
#
#   bash scripts/pips/pips-campaign-pack.sh ~/pips-campaign-nic-c11091541
#   bash scripts/pips/pips-campaign-pack.sh ~/pips-campaign-nic-c11091541 --force   # even if it looks alive
#
# What goes in (as pips-campaign.sh): every sweep folder of the campaign's
# stamp (utils/logs/dual<kind>-pips-strict-<stamp>*/ with a pips-sweep.log),
# its ~/<sweep>.txt / .manifest.tsv / -id*.jsonl / -id*.txt results, and per
# run the small files only (configs, summaries, bg-*.txt, fio/alias outputs,
# .rpt under 1 MB; never the TLP log or pcm's raw output). The runs that
# stopped the engine (bg/stop-*) keep their engine files in bg/stopped/.
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "$SELF")/../.." && pwd)
OUT=${1:-}; FORCE=0; [ "${2:-}" = --force ] && FORCE=1
[ -n "$OUT" ] && [ -d "$OUT" ] || { echo "usage: $0 ~/pips-campaign-<kind>-<stamp> [--force]" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)
b=$(basename "$OUT"); KIND=${b#pips-campaign-}; KIND=${KIND%%-*}; STAMP=${b##*-}
case "$KIND" in nic|ssd) ;; *) echo "pack: $b is not pips-campaign-<nic|ssd>-<stamp>" >&2; exit 2 ;; esac
RESULTS=${RESULTS_DIR:-$HOME}
T0=$(date +%s)
say() { printf '%s +%3ds  %s\n' "$(date +%T)" $(( $(date +%s) - T0 )) "$*"; }

say "pack $b (kind $KIND, stamp $STAMP)"
[ -f "$OUT/campaign.log" ] && { say "campaign.log ends:"; tail -4 "$OUT/campaign.log" | sed 's/^/    /'; }
[ -f "$OUT/.state" ] && say "last state: $(cat "$OUT/.state")"
if [ -e "$OUT/DONE" ]; then say "DONE marker present: the campaign finished"
else
    alive=$(pgrep -af "pips-campaign.sh $KIND" | grep -v pips-campaign-pack | head -3)
    if [ -n "$alive" ] && [ "$FORCE" = 0 ]; then
        echo "pack: a pips-campaign.sh $KIND is still running (below) and $b has no DONE marker:" >&2
        echo "$alive" | sed 's/^/    /' >&2
        echo "  let it finish (it packs itself), or pass --force to pack what is there now" >&2
        exit 1
    fi
    say "no DONE marker and no campaign running: packing what is there"
fi
mkdir -p "$OUT/sweeplogs" "$OUT/results" "$OUT/runs" || exit 1

# The campaign's sweeps: folders of its stamp that hold a pips-sweep.log
# (run folders of the same stamp have none).
names=()
for d in "$REPO"/utils/logs/dual"$KIND"-pips-strict-"$STAMP"*/; do
    [ -f "$d/pips-sweep.log" ] && names+=("$(basename "$d")")
done
say "${#names[@]} sweep(s) of $STAMP under utils/logs; done per progress.tsv: $(grep -c '^done' "$OUT/progress.tsv" 2>/dev/null || echo 0)"
[ "${#names[@]}" -gt 0 ] || { echo "pack: no sweep folders utils/logs/dual$KIND-pips-strict-$STAMP*/" >&2; }

nruns=0; i=0
for n in "${names[@]}"; do
    i=$((i + 1))
    cp -p "$RESULTS/$n.txt" "$RESULTS/$n.manifest.tsv" "$OUT/results/" 2>/dev/null
    cp -p "$RESULTS/$n"-id*.jsonl "$RESULTS/$n"-id*.txt "$OUT/results/" 2>/dev/null
    cp -rp "$REPO/utils/logs/$n" "$OUT/sweeplogs/"
    m="$REPO/utils/logs/$n/manifest.tsv"; [ -f "$m" ] || m="$RESULTS/$n.manifest.tsv"
    k=0
    if [ -f "$m" ]; then
        while IFS=$'\t' read -r _ _ _ _ _ ld rd _; do
            [ -n "$ld" ] || continue
            ( cd "$REPO" && find "$ld" -maxdepth 1 -type f \( -name 'pips-cfg.txt' -o -name 'pips-status*.txt' \
                  -o -name 'pips-log-summary.*' -o -name 'sweep-id.txt' -o -name 'nstat-client.txt' \
                  -o -name 'pips-log-record.txt' -o -name 'windows.txt' -o -name 'pips-bp.tsv' \
                  -o -name 'iommu-ops.txt' -o -name 'fio-nic*.json' -o -name 'fio-ssd*.json' \
                  -o -name 'alias-rdma-nic*.log' -o -name 'alias-nvme.out' -o -name 'bg-run.txt' -o -name 'bg-hist.txt' \
                  -o -name 'bg-cmd.txt' -o -name 'bg-run-try*.txt' \) -print0 2>/dev/null |
              xargs -0 -r cp --parents -t "$OUT/runs/" )
            ( cd "$REPO" && [ -d "$rd" ] && find "$rd"* -maxdepth 1 -type f -name '*.rpt' -size -1M -print0 2>/dev/null |
              xargs -0 -r cp --parents -t "$OUT/runs/" )
            k=$((k + 1))
        done < <(grep -v '^#' "$m" | tail -n +2)
    else
        say "  $n: no manifest (cut short before its first run?)"
    fi
    nruns=$((nruns + k))
    say "  [$i/${#names[@]}] $n: $k run(s)"
done
say "packed the small files of $nruns runs"

for sf in "$OUT"/bg/stop-*; do
    [ -f "$sf" ] || continue
    sed -n 's/^(run logs \(.*\))$/\1/p' "$sf" | while read -r d; do
        [ -d "$d" ] || continue
        mkdir -p "$OUT/bg/stopped/${d##*/logs/}" &&
            cp "$d"/bg-*.txt "$d"/*.err "$d"/alias-nvme.out "$OUT/bg/stopped/${d##*/logs/}/" 2>/dev/null
    done
    say "engine stop file $(basename "$sf"): $(head -1 "$sf")"
done

if [ ! -f "$OUT/README.txt" ]; then
    {
        echo "pips-campaign $KIND $STAMP on $(hostname), packed by pips-campaign-pack.sh $(date '+%F %T') (the campaign did not pack itself)"
        echo "sweeps: ${names[*]:-none}"
        grep -h '^NOTE\|NOTE:' "$OUT/campaign.log" 2>/dev/null | sed 's/^.*NOTE: */NOTE: /' | sort -u
    } > "$OUT/README.txt"
    say "README.txt written (notes from campaign.log)"
fi

TAR="$OUT.tar.gz"
say "tar: $TAR ..."
( cd "$(dirname "$OUT")" && tar -czf "$TAR" "$(basename "$OUT")" ) &
tp=$!
while kill -0 "$tp" 2>/dev/null; do sleep 10; kill -0 "$tp" 2>/dev/null && say "  ... tar running, $(du -h "$TAR" 2>/dev/null | cut -f1) so far"; done
wait "$tp" || { echo "pack: tar failed" >&2; exit 1; }
say "tarball: $TAR ($(du -h "$TAR" | cut -f1))"
echo "copy back: scp $(id -un)@$(hostname):$TAR ."
