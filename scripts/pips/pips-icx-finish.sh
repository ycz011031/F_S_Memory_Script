#!/usr/bin/env bash
# Finish the icx 0x0A08 stress campaign c11091541, which died at ~01:38 on 11-11
# (HANDOFF "Last updated" 11-11). Run on icx. It resumes that campaign in place
# (same folder, same stamp), so the finished sweeps are skipped and the final
# pack holds the whole campaign:
#   iprep   the module and region again (a leftover module is removed first)
#   irepl   the replacement-policy tables again, now with order=cyclic (all 14
#           were refused on 11-09); the refused set is kept as repl-refused-1109/
#   irdma   the rest of alias-rdma: m16 r (cut, runs again) and t, then c16 v16
#           h50 m50 hx mx for f, r and t (20 sweeps, four batcher settings each)
#   icross  the engine in NIC 1's domain (6 sweeps)
#   iend    module unloaded; then the pack: ~/pips-campaign-nic-c11091541.tar.gz
# About 16 h (the dry run prints the plan and ETA). No reboot, NICs stay on mlx5.
#
#   bash scripts/pips/pips-icx-finish.sh --dry-run     # the plan, nothing runs
#   bash scripts/pips/pips-icx-finish.sh               # styx check, then launch in tmux
#   options: --no-repl (skip the tables), --no-styx-check, --stamp <c...>
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
STAMP=c11091541; DRY=0; REPL=1; STYX=1
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1; shift ;;
        --no-repl) REPL=0; shift ;;
        --no-styx-check) STYX=0; shift ;;
        --stamp) STAMP=$2; shift 2 ;;
        -h|--help) sed -n '2,22p' "$SELF"; exit 0 ;;
        *) echo "pips-icx-finish: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
OUT="$HOME/pips-campaign-nic-$STAMP"
T0=$(date +%s)
say() { printf '%s +%3ds  %s\n' "$(date +%T)" $(( $(date +%s) - T0 )) "$*"; }

say "pips-icx-finish: campaign $STAMP ($OUT)"
[ -d "$OUT" ] || { echo "pips-icx-finish: no $OUT on this host (run on icx)" >&2; exit 1; }
[ -e "$OUT/DONE" ] && { echo "pips-icx-finish: $OUT has a DONE marker: nothing to finish" >&2; exit 1; }
if pgrep -af "pips-campaign.sh nic" | grep -v pips-icx-finish | grep -q .; then
    echo "pips-icx-finish: a pips-campaign.sh nic is running:" >&2; pgrep -af "pips-campaign.sh nic" >&2; exit 1
fi
say "progress: $(grep -c '^done' "$OUT/progress.tsv") sweeps done; last state: $(cat "$OUT/.state" 2>/dev/null)"
say "since the last launch (for why it ended): uptime $(uptime -p 2>/dev/null)"
last -x 2>/dev/null | grep -E 'reboot|shutdown|crash' | head -3 | sed 's/^/    /'
lsmod 2>/dev/null | grep -q '^pips_bg_region ' && say "pips_bg_region is still loaded (iend never ran): iprep removes and reloads it"

if [ "$STYX" = 1 ] && [ "$DRY" = 0 ]; then
    say "styx check (its disk was full on 11-08/09) ..."
    if ! bash "$HERE/styx-check.sh" --watch 30 > "$OUT/styx-check-finish.txt" 2>&1; then
        tail -12 "$OUT/styx-check-finish.txt" | sed 's/^/    /'
        echo "pips-icx-finish: styx-check says NOT SAFE ($OUT/styx-check-finish.txt); --no-styx-check to launch anyway" >&2
        exit 1
    fi
    say "styx: $(grep -o 'verdict: .*' "$OUT/styx-check-finish.txt")"
fi

if [ "$REPL" = 1 ] && [ "$DRY" = 0 ]; then
    if grep -q $'^step\tirepl\t' "$OUT/progress.tsv"; then
        cp -p "$OUT/progress.tsv" "$OUT/progress.tsv.before-finish"
        grep -v $'^step\tirepl\t' "$OUT/progress.tsv.before-finish" > "$OUT/progress.tsv"
        [ -d "$OUT/bg/nic/repl" ] && [ ! -e "$OUT/bg/nic/repl-refused-1109" ] && mv "$OUT/bg/nic/repl" "$OUT/bg/nic/repl-refused-1109"
        say "irepl: marked to run again (refused set kept as bg/nic/repl-refused-1109; progress.tsv.before-finish saved)"
    fi
fi
PH="iprep $( [ "$REPL" = 1 ] && echo irepl) irdma icross iend"
say "launching: pips-campaign.sh nic --bg --stamp $STAMP --only \"$PH\"$( [ "$DRY" = 1 ] && echo " --dry-run" || echo " --tmux")"
if [ "$DRY" = 1 ]; then
    exec bash "$HERE/pips-campaign.sh" nic --bg --stamp "$STAMP" --only "$PH" --dry-run
fi
exec bash "$HERE/pips-campaign.sh" nic --bg --stamp "$STAMP" --only "$PH" --tmux
