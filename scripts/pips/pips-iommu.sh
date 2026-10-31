#!/bin/bash
# The IOMMU mode of the devices behind the PIPS switch, changed at runtime
# through sysfs: no reboot, no GRUB change. For the 0x0A07 paper campaign's
# E2 (lazy vs strict, passthrough as the control) and E8 (strict vs
# passthrough); HANDOFF §8 "0x0A07 paper campaign".
#
#   bash scripts/pips/pips-iommu.sh show            # groups, members, drivers, mode
#   bash scripts/pips/pips-iommu.sh mode            # the mode of them all: strict, lazy, pt
#   bash scripts/pips/pips-iommu.sh check lazy      # could it change, without changing anything
#   bash scripts/pips/pips-iommu.sh set lazy        # strict | lazy | pt
#   bash scripts/pips/pips-iommu.sh set strict --keep 192.17.100.255
#
# Modes: strict = DMA domain (the hosts' boot setting, iommu.strict=1), lazy =
# DMA-FQ (batched invalidation, as iommu.strict=0), pt = identity (no
# translation, as iommu=pt). Written to /sys/kernel/iommu_groups/<g>/type for
# the group of every endpoint below the PIPS upstream port (10ee:b048).
# strict -> lazy the kernel does live, drivers bound. Every other change
# needs the group's endpoint drivers unbound: the tool unbinds them (nvme,
# mlx5_core), writes the type, binds them back and waits up to 90 s for the
# drives' namespaces and the interfaces to return. The drives come back
# under their serials (the runners look them up so), maybe as other nvmeN;
# the interfaces under their names, down and unconfigured (the runners set
# IP, MTU and rings every run). The boot's mode stays in the kernel command
# line: a reboot always puts it back.
#
# Kernel rules: before 6.4 (bigserver's 5.15) the kernel changes a group only
# when it holds ONE device, bridges included, live change included; 6.4 on
# (icx's 6.8) any group whose endpoint drivers are unbound. DMA-FQ is
# accepted from 5.15.
#
# Refuses, before touching anything:
#   - a group member outside the switch with a driver other than pcieport
#   - an interface that carries the default route, an ssh connection of this
#     host (either direction), or the route to a --keep IP
#   - a drive with a mounted, swapped or held (md, dm) namespace or partition
#   - fio or iperf3 running
# Exit: 0 done (or already so), 2 usage, 3 refused or the kernel said no
# (the devices are back as they were), 4 a device did not come back: stop
# and look (show, dmesg); a reboot puts it right.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pips-lib.sh"
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

CMD=${1:-}; shift 2>/dev/null
MODE=""
case "$CMD" in
    show|mode) ;;
    check|set) MODE=${1:-}; shift 2>/dev/null ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
KEEP=(); USP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP+=("$2"); shift 2 ;;
        --bdf) USP="$2"; shift 2 ;;
        *) echo "pips-iommu: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
type_of() { case "$1" in strict) echo DMA ;; lazy) echo DMA-FQ ;; pt) echo identity ;; *) return 1 ;; esac; }
mode_of() { case "$1" in DMA) echo strict ;; DMA-FQ) echo lazy ;; identity) echo pt ;; *) echo "$1" ;; esac; }
if [ -n "$MODE" ] || [ "$CMD" = check ] || [ "$CMD" = set ]; then
    TARGET=$(type_of "$MODE") || { echo "pips-iommu: mode must be strict, lazy or pt" >&2; exit 2; }
fi
say() { echo "pips-iommu $(date +%T): $*"; }

USP=${USP:-$(pips_find_usp)} || exit 3
BELOW=( $(pips_below "$USP") )
dev() { echo "/sys/bus/pci/devices/$1"; }
is_bridge() { case "$(cat "$(dev "$1")/class" 2>/dev/null)" in 0x0604*) return 0 ;; esac; return 1; }
below_usp() { [[ " ${BELOW[*]} " == *" $1 "* ]]; }
drv_of() { [ -e "$(dev "$1")/driver" ] && basename "$(readlink -f "$(dev "$1")/driver")"; }
group_of() { [ -e "$(dev "$1")/iommu_group" ] && basename "$(readlink -f "$(dev "$1")/iommu_group")"; }
members() { ls "/sys/kernel/iommu_groups/$1/devices" 2>/dev/null; }
gtype() { cat "/sys/kernel/iommu_groups/$1/type" 2>/dev/null; }
netdevs_of() { ls "$(dev "$1")/net" 2>/dev/null; }
nvme_serials_of() { cat "$(dev "$1")"/nvme/nvme*/serial 2>/dev/null | xargs; }
namespaces_of() {   # /dev/nvmeXnY whose controller is this function
    local d; for d in $(pips_nvme_below "$USP"); do [ "$(blk_bdf "$d")" = "$1" ] && echo "$d"; done
}

EPS=(); GRPS=()
for b in "${BELOW[@]}"; do
    is_bridge "$b" && continue
    EPS+=("$b")
    g=$(group_of "$b") || { echo "pips-iommu: $b has no IOMMU group: the IOMMU is off (intel_iommu=off); nothing to change" >&2; exit 3; }
    [[ " ${GRPS[*]} " == *" $g "* ]] || GRPS+=("$g")
done
[ ${#EPS[@]} -gt 0 ] || { echo "pips-iommu: no endpoint below the PIPS upstream port $USP" >&2; exit 3; }

KVER=$(uname -r); KMAJ=${KVER%%.*}; KMIN=${KVER#*.}; KMIN=${KMIN%%.*}
OLD_RULES=0; { [ "$KMAJ" -lt 6 ] || { [ "$KMAJ" -eq 6 ] && [ "$KMIN" -lt 4 ]; }; } && OLD_RULES=1

show() {
    echo "PIPS upstream port $USP, kernel $KVER ($( [ "$OLD_RULES" = 1 ] && echo "one-device groups only" || echo "multi-device groups"))"
    local g m t
    for g in "${GRPS[@]}"; do
        t=$(gtype "$g")
        echo "group $g  type $t ($(mode_of "$t"))  $(members "$g" | wc -l) device(s)"
        for m in $(members "$g"); do
            printf '    %-14s %-8s %-11s %-7s %s\n' "$m" "$(is_bridge "$m" && echo bridge || echo endpoint)" \
                "$(drv_of "$m" || echo -)" "$(below_usp "$m" && echo behind || echo OUTSIDE)" \
                "$(n=$(netdevs_of "$m" | xargs); s=$(nvme_serials_of "$m"); echo "${n:+net: $n}${s:+nvme serial: $s}")"
        done
    done
}
cur_mode() {
    local g; for g in "${GRPS[@]}"; do mode_of "$(gtype "$g")"; done | sort -u | paste -sd+
}
case "$CMD" in
    show) show; exit 0 ;;
    mode) cur_mode; exit 0 ;;
esac

# Interfaces that must stay up: the default route's, every ssh connection's
# (either direction), each --keep IP's route.
keep_devs() {
    local ip
    ip -o route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{ print $2 }'
    {
        ss -tnH state established '( sport = :22 or dport = :22 )' 2>/dev/null | awk '{ print $4 }' |
            sed -E 's/^\[?(::ffff:)?([^]]*)\]?:[0-9]+$/\2/'
        [ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION%% *}"
        for ip in ${KEEP[@]+"${KEEP[@]}"}; do echo "$ip"; done
    } | sort -u | while read -r ip; do
        [ -n "$ip" ] && ip -o route get "$ip" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{ print $2 }'
    done
}
drive_busy() {   # <bdf>: why its namespaces cannot go, or nothing
    local d n p
    for d in $(namespaces_of "$1"); do
        n=$(basename "$d")
        lsblk -nro NAME,MOUNTPOINT "$d" 2>/dev/null | awk 'NF > 1 { print "  " $1 " is mounted on " $2 }'
        for p in "/sys/class/block/$n" "/sys/class/block/$n/$n"*; do
            [ -d "$p/holders" ] && [ -n "$(ls "$p/holders" 2>/dev/null)" ] && echo "  $(basename "$p") is held by $(ls "$p/holders" | xargs)"
        done
        grep -q "^/dev/$n" /proc/swaps 2>/dev/null && echo "  $n is swap"
    done
}

# plan_group <g>: sets LIVE (1 = the kernel changes it with drivers bound),
# UNBIND ("bdf:driver" ...), FATAL (why it cannot change at all), REASONS
# (why the drivers cannot be unbound), ALREADY
plan_group() {
    local g=$1 cur m d n kd
    LIVE=0; UNBIND=(); FATAL=(); REASONS=(); ALREADY=0
    cur=$(gtype "$g")
    [ "$cur" = "$TARGET" ] && { ALREADY=1; return 0; }
    n=$(members "$g" | wc -l)
    if [ "$OLD_RULES" = 1 ] && [ "$n" -ne 1 ]; then
        FATAL+=("kernel $KVER changes a group only when it holds one device; group $g holds $n ($(members "$g" | xargs)): the switch's ports have no ACS. Use the GRUB setting and a reboot instead (lazy: iommu.strict=0; pt: iommu=pt)")
        return 0
    fi
    [ "$TARGET" = DMA-FQ ] && [ "$cur" = DMA ] && LIVE=1
    kd=" $(keep_devs | sort -u | xargs) "
    for m in $(members "$g"); do
        d=$(drv_of "$m") || continue
        if ! below_usp "$m"; then
            [ "$d" = pcieport ] || REASONS+=("$m (outside the switch, driver $d) shares group $g")
            continue
        fi
        is_bridge "$m" && continue
        UNBIND+=("$m:$d")
        for n in $(netdevs_of "$m"); do
            [[ "$kd" == *" $n "* ]] && REASONS+=("$n ($m) carries the default route, an ssh connection or a --keep route")
        done
        while read -r n; do [ -n "$n" ] && REASONS+=("drive $m:$n"); done <<< "$(drive_busy "$m")"
    done
}

check_all() {   # prints the plan; 0 if every group can change
    local g ok=0
    if pgrep -x fio >/dev/null || pgrep -x iperf3 >/dev/null; then
        echo "  REFUSED: fio or iperf3 is running"; ok=1
    fi
    for g in "${GRPS[@]}"; do
        plan_group "$g"
        if [ "$ALREADY" = 1 ]; then echo "  group $g: already $(mode_of "$TARGET")"; continue; fi
        if [ ${#FATAL[@]} -gt 0 ] || { [ ${#REASONS[@]} -gt 0 ] && [ "$LIVE" = 0 ]; }; then
            for r in ${FATAL[@]+"${FATAL[@]}"} ${REASONS[@]+"${REASONS[@]}"}; do echo "  REFUSED group $g: $r"; done
            ok=1; continue
        fi
        if [ "$LIVE" = 1 ]; then
            echo "  group $g: $(gtype "$g") -> $TARGET live, drivers stay bound$( [ ${#REASONS[@]} -gt 0 ] && echo " (no fallback: ${#REASONS[@]} refusal(s) for unbinding)")"
        else
            echo "  group $g: $(gtype "$g") -> $TARGET with ${UNBIND[*]:-nothing} unbound and bound back"
        fi
    done
    return $ok
}

say "$CMD $MODE ($TARGET) for ${#EPS[@]} endpoint(s) behind $USP in group(s) ${GRPS[*]}"
if [ "$CMD" = check ]; then
    check_all; rc=$?
    [ "$rc" = 0 ] && say "check: possible" || say "check: NOT possible"
    exit $(( rc ? 3 : 0 ))
fi

sudo -n true 2>/dev/null || { echo "pips-iommu: sudo needs a password: sudo -v first" >&2; exit 3; }
check_all || { say "refused: nothing changed"; exit 3; }

write_type() {   # <group> <type>
    local err
    err=$(echo "$2" | sudo -n tee "/sys/kernel/iommu_groups/$1/type" 2>&1 >/dev/null) && return 0
    say "  writing $2 to group $1 failed: $err"
    sudo -n dmesg 2>/dev/null | grep -iE 'iommu|default domain|bound' | tail -3 | sed 's/^/    kernel: /'
    return 1
}
RC=0
for g in "${GRPS[@]}"; do
    plan_group "$g"
    [ "$ALREADY" = 1 ] && continue
    if [ "$LIVE" = 1 ]; then
        if write_type "$g" "$TARGET"; then say "group $g: now $(gtype "$g") (live)"; continue; fi
        [ ${#REASONS[@]} -gt 0 ] && { RC=3; continue; }
        say "group $g: live change refused; trying with the drivers unbound"
    fi
    # What must come back: each function's driver, drive serials and
    # namespace count, interface names.
    want_ns=0; want_net=(); want_ser=()
    for u in "${UNBIND[@]}"; do
        b=${u%%:*}
        want_ns=$(( want_ns + $(namespaces_of "$b" | wc -l) ))
        want_net+=( $(netdevs_of "$b") ); want_ser+=( $(nvme_serials_of "$b") )
    done
    for u in "${UNBIND[@]}"; do
        b=${u%%:*}; say "group $g: unbinding $b from ${u#*:}"
        echo "$b" | sudo -n tee "$(dev "$b")/driver/unbind" >/dev/null || say "  unbind $b failed"
    done
    write_type "$g" "$TARGET" || RC=3
    for u in "${UNBIND[@]}"; do
        b=${u%%:*}; d=${u#*:}
        [ -n "$(drv_of "$b")" ] && continue
        say "group $g: binding $b to $d"
        echo "$b" | sudo -n tee "/sys/bus/pci/drivers/$d/bind" >/dev/null 2>&1 ||
            echo "$b" | sudo -n tee /sys/bus/pci/drivers_probe >/dev/null 2>&1
    done
    back=0
    for k in $(seq 1 45); do
        sleep 2
        miss=""
        for u in "${UNBIND[@]}"; do [ -n "$(drv_of "${u%%:*}")" ] || miss="$miss ${u%%:*}(no driver)"; done
        for n in ${want_net[@]+"${want_net[@]}"}; do [ -e "/sys/class/net/$n" ] || miss="$miss $n"; done
        have_ser=" $(for u in "${UNBIND[@]}"; do nvme_serials_of "${u%%:*}"; done | xargs) "
        for s in ${want_ser[@]+"${want_ser[@]}"}; do [[ "$have_ser" == *" $s "* ]] || miss="$miss serial:$s"; done
        ns=0; for u in "${UNBIND[@]}"; do ns=$(( ns + $(namespaces_of "${u%%:*}" | wc -l) )); done
        [ "$ns" -ge "$want_ns" ] || miss="$miss namespaces:$ns/$want_ns"
        if [ -z "$miss" ]; then back=1; break; fi
        [ $(( k % 5 )) = 0 ] && say "  waiting for:$miss"
    done
    command -v udevadm >/dev/null && udevadm settle -t 20 2>/dev/null
    if [ "$back" = 1 ]; then
        say "group $g: now $(gtype "$g") ($(mode_of "$(gtype "$g")")); every device back"
    else
        say "group $g: DEVICES DID NOT COME BACK:$miss"; RC=4
    fi
done
show
say "mode now: $(cur_mode)"
exit $RC
