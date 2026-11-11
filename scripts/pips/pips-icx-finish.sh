#!/usr/bin/env bash
# The rest of the icx 0x0A08 stress campaign, as a new campaign of its own
# (11-11). c11091541 died at ~01:38 on 11-11 after itcp (complete) and alias-rdma
# off..m16 f; its results were copied back and cleaned off icx, so this does not
# resume it: it runs what is missing and packs a new
# ~/pips-campaign-nic-<stamp>.tar.gz. The engine-off baseline is c11091541's
# (user, 11-11). Run on icx:
#   iprep   the module and region (a leftover module from c11091541 is removed)
#           and the tag census
#   irepl   the replacement-policy tables, now with order=cyclic (all 14 were
#           refused in c11091541); minutes
#   irdma   alias-rdma f, r, t at levels m16 c16 v16 h50 m50 hx mx (21 sweeps,
#           four batcher settings each; m16 f repeats c11091541's as a check)
#   iend    module unloaded, then the pack
# Time (45 min per alias-rdma sweep in c11091541, both modes):
#   default (NIC 0 alone and both)  ~16 h      --nic0-only  ~8 h 10
#   --cross adds the 6 cross sweeps (engine in NIC 1's domain): +2 h 20 (+1 h 10 NIC 0 only)
# No reboot, NICs stay on mlx5.
#
#   bash scripts/pips/pips-icx-finish.sh --nic0-only --dry-run   # the plan, nothing runs
#   bash scripts/pips/pips-icx-finish.sh --nic0-only             # styx check, then launch in tmux
#   --levels "...", --cross, --no-repl, --no-styx-check
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
LEVELS="m16 c16 v16 h50 m50 hx mx"; MODES="nic0only both"; DRY=0; REPL=1; CROSS=0; STYX=1
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1; shift ;;
        --levels) LEVELS=$2; shift 2 ;;
        --nic0-only) MODES="nic0only"; shift ;;
        --cross) CROSS=1; shift ;;
        --no-repl) REPL=0; shift ;;
        --no-styx-check) STYX=0; shift ;;
        -h|--help) sed -n '2,25p' "$SELF"; exit 0 ;;
        *) echo "pips-icx-finish: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
T0=$(date +%s)
say() { printf '%s +%3ds  %s\n' "$(date +%T)" $(( $(date +%s) - T0 )) "$*"; }

say "pips-icx-finish: a new nic --bg campaign for the rest of c11091541 (levels $LEVELS; modes $MODES)"
if pgrep -af "pips-campaign.sh nic" | grep -v pips-icx-finish | grep -q .; then
    echo "pips-icx-finish: a pips-campaign.sh nic is running:" >&2; pgrep -af "pips-campaign.sh nic" >&2; exit 1
fi
say "uptime $(uptime -p 2>/dev/null); recent boots and crashes (why c11091541 ended):"
last -x 2>/dev/null | grep -E 'reboot|shutdown|crash' | head -3 | sed 's/^/    /'
lsmod 2>/dev/null | grep -q '^pips_bg_region ' && say "pips_bg_region is still loaded (c11091541's iend never ran): iprep removes and reloads it"

if [ "$STYX" = 1 ] && [ "$DRY" = 0 ]; then
    f="$HOME/styx-check-finish-$(date +%m%d%H%M).txt"
    say "styx check (its disk was full on 11-08/09) ... ($f)"
    if ! bash "$HERE/styx-check.sh" --watch 30 > "$f" 2>&1; then
        tail -12 "$f" | sed 's/^/    /'
        echo "pips-icx-finish: styx-check says NOT SAFE ($f); --no-styx-check to launch anyway" >&2
        exit 1
    fi
    say "styx: $(grep -o 'verdict: .*' "$f")"
fi

PH="iprep $( [ "$REPL" = 1 ] && echo "irepl ")irdma $( [ "$CROSS" = 1 ] && echo "icross ")iend"
args=(nic --bg --fresh --levels "$LEVELS" --nic-modes "$MODES" --only "$PH")
say "launching: pips-campaign.sh ${args[*]}$( [ "$DRY" = 1 ] && echo " --dry-run" || echo " --tmux")"
if [ "$DRY" = 1 ]; then
    exec bash "$HERE/pips-campaign.sh" "${args[@]}" --dry-run
fi
exec bash "$HERE/pips-campaign.sh" "${args[@]}" --tmux
