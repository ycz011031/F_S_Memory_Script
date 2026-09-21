#!/bin/bash
# Shared helpers for the local minimal-traffic scripts. Sourced, not executed.

# ------------------------------------------------------------------- output
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_red=""; c_grn=""; c_yel=""; c_dim=""; c_off=""; }

ok()   { printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$c_yel" "$c_off" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$*"; FAILED=$((FAILED+1)); }
info() { printf '  %s      %s%s\n' "$c_dim" "$*" "$c_off"; }
step() { printf '\n%s\n' "== $* =="; }
die()  { printf '\n%sERROR%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# -------------------------------------------------------------- config load
load_config() {
    local here="$1"
    [ -f "$here/config.sh" ] || die "no config.sh next to this script ($here)"
    # shellcheck disable=SC1090
    . "$here/config.sh"

    if [ "${REPO_DIR:-auto}" = "auto" ]; then
        REPO_DIR=$(cd "$here/../.." && pwd)
    fi

    local missing=()
    for v in SERVER_INTF SERVER_IP CLIENT_INTF CLIENT_IP SSH_HOST SSH_USER; do
        [ -z "${!v}" ] && missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        printf '\n%sconfig.sh is not filled in.%s Missing: %s\n\n' \
            "$c_red" "$c_off" "${missing[*]}" >&2
        printf 'Get the values with:\n  ip -br addr\n  bash %s/scripts/collect-setup-info.sh\n\n' "$REPO_DIR" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------ remote
# rsh <command...>  -- run on the client machine, non-interactive
rsh() { ssh $SSH_OPTS "$SSH_USER@$SSH_HOST" "$@"; }

# ------------------------------------------------------------------- cores
# pick_cores <interface> <count> -- cores on the NUMA node local to the NIC.
# Skips core 0 (IRQ/kernel noise) and prefers one core per physical core
# (no hyperthread siblings) so flows do not contend on a shared pipeline.
# Emits a comma-separated list on stdout. Falls back to a simple range.
pick_cores() {
    local intf="$1" count="$2" node cores
    node=$(cat "/sys/class/net/$intf/device/numa_node" 2>/dev/null)
    case "$node" in ''|*[!0-9-]*) node=-1 ;; esac

    if [ "$node" -ge 0 ] && command -v lscpu >/dev/null 2>&1; then
        # CPU,CORE,SOCKET,NODE -- dedupe on CORE to avoid HT siblings
        cores=$(lscpu -p=CPU,CORE,NODE 2>/dev/null | grep -v '^#' \
            | awk -F, -v n="$node" '$3==n && $1!=0 {if(!seen[$2]++) print $1}' \
            | head -n "$count" | paste -sd,)
    fi
    if [ -z "${cores:-}" ]; then
        cores=$(lscpu -p=CPU,CORE 2>/dev/null | grep -v '^#' \
            | awk -F, '$1!=0 {if(!seen[$2]++) print $1}' \
            | head -n "$count" | paste -sd,)
    fi
    [ -z "${cores:-}" ] && cores="0"
    printf '%s' "$cores"
}

# max_core_id <list> -- highest core number in a comma list
max_core_id() { printf '%s' "$1" | tr ',' '\n' | sort -n | tail -1; }
