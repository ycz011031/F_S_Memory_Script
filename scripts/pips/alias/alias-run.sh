#!/bin/bash
# Run one of the alias generators built for this host (build/<host>/), building
# it first when it is missing or older than its source.
#
#   bash scripts/pips/alias/alias-run.sh alias-rdma --role server --netdev ens1f1np1
#   bash scripts/pips/alias/alias-run.sh --build alias-nvme     # build only, print the path
#   bash scripts/pips/alias/alias-run.sh --path alias-rdma      # the path, no build
#
# Build as the user (the runners do it in their preflight), then run under
# sudo: a first build under sudo would leave build/ owned by root.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=run
case "${1:-}" in
    --build) MODE=build; shift ;;
    --path)  MODE=path; shift ;;
    -h|--help|"") sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
TOOL=$1; shift
case "$TOOL" in alias-nvme|alias-rdma) ;; *) echo "alias-run: alias-nvme or alias-rdma, not '$TOOL'" >&2; exit 2 ;; esac
HOSTN=$(hostname -s 2>/dev/null || hostname)
BIN="$HERE/build/$HOSTN/$TOOL"
if [ "$MODE" = path ]; then echo "$BIN"; exit 0; fi
if [ ! -x "$BIN" ] || [ "$HERE/${TOOL}.c" -nt "$BIN" ] || [ "$HERE/alias_common.h" -nt "$BIN" ]; then
    echo "alias-run: building $TOOL for $HOSTN..." >&2
    make -s -C "$HERE" "${TOOL#alias-}" HOST="$HOSTN" >&2 || {
        echo "alias-run: build of $TOOL failed$( [ "$TOOL" = alias-rdma ] && echo " (libibverbs-dev installed?)")" >&2
        exit 2
    }
fi
if [ "$MODE" = build ]; then echo "$BIN"; exit 0; fi
exec "$BIN" "$@"
