#!/bin/bash
# Is the FPGA on this host running our PIPS switch, and which build? One
# command for both testbeds (bigserver: drives behind PIPS; icx: NICs behind
# PIPS): it finds every Xilinx (10ee) function in sysfs, so no BDF is needed.
# Read-only: no rescan, no reset, no config or register write.
#
#   bash scripts/pips/pips-id.sh [-s BDF] [-q]
#
#   -s BDF   check only this upstream port (default: every 10ee:b048)
#   -q       only the key=value summary lines
#
# Checks, in order, each one needing the one before it:
#   1. a Xilinx function on PCIe at all (none: not programmed, or not rescanned)
#   2. the PIPS ports: upstream 10ee:b048, downstream 10ee:b148 and 10ee:b348
#      below it (another Xilinx ID: a different bitstream)
#   3. BAR0 32 KB, assigned, memory space on
#   4. BAR0 +0x800 reads 0x50495053 ("PIPS") and +0x804 map v2.x
#      (0xFFFFFFFF: the switch stopped answering, see pips-hang-snapshot.sh)
#   5. the design ID (regfile +0x20, through the AXI window: `pips cfg`)
# Then what is below the switch, which names the setup (drives = ssd, NICs = nic).
# Steps 3-5 read BAR0: root, or sudo (asks for a password if it needs one).
#
# Last lines, for scripts:
#   pips_bdf=0000:97:00.0 id=0x50495053 version=2.1 design_id=0x0a07 setup=nic verdict=pips
# verdict: pips (ours, design ID read), not-pips (Xilinx, not our switch),
# no-fpga (no Xilinx function), no-answer (PIPS ports, BAR0 reads all ones),
# no-access (not root, no sudo).
# Exit status: 0 pips, 1 not-pips or no-answer, 3 no-fpga, 4 no-access, 2 usage.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pips-lib.sh
source "$HERE/pips-lib.sh"

ONLY="" QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--bdf) ONLY="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "pips-id: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
case "$ONLY" in ??:??.?) ONLY="0000:$ONLY" ;; esac

T0=$SECONDS
NSTEP=4
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
step() { say "[$1/$NSTEP] $(date +%T) +$((SECONDS - T0))s  $2"; }
sysfs() { cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null; }
link_of() {   # "Gen4 x8 (max Gen4 x8)" from sysfs, no root needed
    local s w ms mw
    s=$(sysfs "$1" current_link_speed); w=$(sysfs "$1" current_link_width)
    ms=$(sysfs "$1" max_link_speed); mw=$(sysfs "$1" max_link_width)
    [ -n "$s" ] || { echo "no link info"; return; }
    printf '%s x%s (max %s x%s)' "$(gen_of "$s")" "$w" "$(gen_of "$ms")" "$mw"
}
gen_of() {
    case "$1" in
        2.5*) echo Gen1 ;; 5.0*|5\ *) echo Gen2 ;; 8.0*) echo Gen3 ;; 16.0*) echo Gen4 ;;
        32.0*) echo Gen5 ;; 64.0*) echo Gen6 ;; *) echo "${1:-?}" ;;
    esac
}
# Design IDs (scripts/pips/PIO-MANUAL.md §6, "Design ID"; FPGA repo commits).
# Add a line with every new build.
design_note() {
    case "$1" in
        none)   echo "older than 0x0A02 (before e389cca): no DESIGN_ID register, log v1" ;;
        0x0a02) echo "e389cca, 10-11: DESIGN_ID, log v1" ;;
        0x0a03) echo "2c6c3f5, 10-14: drain config reg1" ;;
        0x0a04) echo "591d854, 10-15: log format v2" ;;
        0x0a05) echo "64193c6, 10-17: batching FIFO 512 rows" ;;
        0x0a06) echo "9673e37 + d44fdd0, 10-23/24: page batcher" ;;
        0x0a07) echo "28ff5b6, 10-27: rate caps, refused-cycle counters" ;;
        *)      echo "not in this script's table: see PIO-MANUAL.md, \"Design ID\", and pips.tcl" ;;
    esac
}

# ---------------------------------------------------------------- 1. Xilinx functions
step 1 "Xilinx (10ee) functions on PCIe (sysfs)"
XIL=() USPS=()
for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10ee ] || continue
    b=$(basename "$d"); XIL+=("$b")
    [ "$(cat "$d/device")" = 0xb048 ] && USPS+=("$b")
done
for b in "${XIL[@]}"; do
    case "$(sysfs "$b" device)" in
        0xb048) role="PIPS upstream port" ;;
        0xb148) role="PIPS downstream port zero (log in1)" ;;
        0xb348) role="PIPS downstream port one  (log in0)" ;;
        *)      role="not a PIPS port (class $(sysfs "$b" class))" ;;
    esac
    say "    $b  10ee:$(sysfs "$b" device | sed 's/^0x//')  $role"
done
if [ ${#XIL[@]} -eq 0 ]; then
    say "    none: the FPGA is not programmed, or was programmed after boot and not rescanned"
    say "    (echo 1 | sudo tee /sys/bus/pci/rescan; this script does not rescan)"
    echo "pips_bdf=none id=none version=none design_id=none setup=none verdict=no-fpga"
    exit 3
fi
if [ -n "$ONLY" ]; then
    [ "$(sysfs "$ONLY" vendor):$(sysfs "$ONLY" device)" = 0x10ee:0xb048 ] ||
        { echo "pips-id: $ONLY is not a PIPS upstream port (10ee:b048)" >&2; exit 2; }
    USPS=("$ONLY")
fi
if [ ${#USPS[@]} -eq 0 ]; then
    say "    Xilinx functions, but no PIPS upstream port (10ee:b048): another bitstream"
    echo "pips_bdf=none id=none version=none design_id=none setup=none verdict=not-pips"
    exit 1
fi

# ---------------------------------------------------------------- 2-4 per upstream port
# The password is asked here, once: under `timeout` (below) sudo cannot prompt.
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo > /dev/null; then
    if sudo -n true 2>/dev/null; then SUDO="sudo -n"
    else
        say "pips-id: BAR0 needs root: sudo asks for your password"
        sudo -v && SUDO="sudo -n"
    fi
fi
pips_build > /dev/null || say "pips-id: could not build $PIPS (make, gcc): BAR0 checks skipped"

RC=0 SUMMARY=()
for USP in "${USPS[@]}"; do
    say ""
    step 2 "$USP: PIPS ports and the path to the root port"
    rp=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$USP")")")
    say "    root port      $rp  $(sysfs "$rp" vendor | sed 's/^0x//'):$(sysfs "$rp" device | sed 's/^0x//')  link $(link_of "$rp")"
    say "    upstream port  $USP  link $(link_of "$USP")"
    dsps=0 eps=() nvme=0 nic=0 other=0
    for b in $(pips_below "$USP"); do
        v=$(sysfs "$b" vendor); dv=$(sysfs "$b" device); cls=$(sysfs "$b" class)
        drv=$(basename "$(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" 2>/dev/null)
        case "$v:$dv" in
            0x10ee:0xb148|0x10ee:0xb348) dsps=$((dsps + 1))
                say "    downstream     $b  10ee:${dv#0x}  link $(link_of "$b")"; continue ;;
        esac
        case "$cls" in
            0x010802) kind="NVMe drive"; nvme=$((nvme + 1)) ;;
            0x0200*|0x0207*) kind="network"; nic=$((nic + 1)) ;;
            0x0604*) kind="bridge"; other=$((other + 1)) ;;
            *) kind="class $cls"; other=$((other + 1)) ;;
        esac
        eps+=("$b")
        say "    device         $b  ${v#0x}:${dv#0x}  $kind, driver ${drv:-none}, link $(link_of "$b")"
    done
    [ "$dsps" -eq 2 ] || say "    WARNING: $dsps PIPS downstream ports below $USP (expected 2: 10ee:b148, 10ee:b348)"
    if   [ "$nvme" -gt 0 ] && [ "$nic" -eq 0 ]; then setup=ssd
    elif [ "$nic" -gt 0 ] && [ "$nvme" -eq 0 ]; then setup=nic
    elif [ "$nic" -gt 0 ]; then setup=mixed
    else setup=none; fi
    say "    setup: $setup ($nvme NVMe, $nic network, $other other below the switch)"

    id=none ver=none design=none verdict=pips
    step 3 "$USP: BAR0 and the PIPS identity registers"
    res=$(head -1 "/sys/bus/pci/devices/$USP/resource" 2>/dev/null)
    start=$(echo "$res" | awk '{print $1}'); end=$(echo "$res" | awk '{print $2}')
    cmd=$(od -An -tx2 -j4 -N2 "/sys/bus/pci/devices/$USP/config" 2>/dev/null | tr -d ' ')
    if [ -z "$end" ] || [ $((end)) -eq 0 ]; then
        say "    no BAR0: not our PIO bitstream (or an old one)"; verdict=not-pips
    elif [ $((end - start + 1)) -ne 32768 ]; then
        say "    BAR0 is $((end - start + 1)) bytes, the PIPS PIO is 32 KB: not our build, or one with the 1 KB BAR"
        verdict=not-pips
    elif [ $((start)) -eq 0 ]; then
        say "    BAR0 has no address (Region 0 <unassigned>): boot with pci=realloc"; verdict=no-answer
    elif [ -n "$cmd" ] && [ $((0x$cmd & 2)) -eq 0 ]; then
        say "    memory space disabled (Mem-): setpci -s $USP COMMAND=0x02:0x02 (this script does not)"
        verdict=no-answer
    elif [ ! -x "$PIPS" ]; then
        verdict=no-access
    elif [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
        say "    not root and no sudo: BAR0 not read"; verdict=no-access
    else
        say "    BAR0 $start, 32 KB"
        out=$(timeout 15 $SUDO "$PIPS" -s "$USP" rd 0x800 2 2>&1); st=$?
        id=$(echo "$out" | sed -n 's/^0x0800: //p'); vr=$(echo "$out" | sed -n 's/^0x0804: //p')
        if [ $st -ne 0 ] || [ -z "$id" ]; then
            say "    pips rd failed (exit $st): $(echo "$out" | tail -1)"
            case "$out" in *"run as root"*|*"a password is required"*|*"not in the sudoers"*) verdict=no-access ;;
                           *) verdict=no-answer ;; esac
            id=none
        else
            ver=$(( vr >> 16 )).$(( vr & 0xFFFF ))
            if [ "$id" = 0xffffffff ]; then
                say "    ID reads 0xFFFFFFFF: no completion (switch stopped answering, link down, or BAR"
                say "    moved: pips-hang-snapshot.sh before reprogramming)"; verdict=no-answer; ver=none
            elif [ "$id" != 0x50495053 ]; then
                say "    ID reads $id, PIPS is 0x50495053: not our bitstream"; verdict=not-pips
            elif [ $(( vr >> 16 )) -ne 2 ]; then
                say "    ID \"PIPS\", register map v$ver: this tool knows v2.x only"; verdict=not-pips
            else
                say "    ID $id \"PIPS\", register map v$ver"
            fi
        fi
    fi

    step 4 "$USP: design ID (regfile +0x20 through the AXI window)"
    if [ "$verdict" = pips ]; then
        cfg=$(timeout 15 $SUDO "$PIPS" -s "$USP" cfg 2>&1); st=$?
        design=$(echo "$cfg" | sed -n 's/^design_id=//p' | head -1)
        if [ $st -ne 0 ] || [ -z "$design" ]; then
            say "    pips cfg failed (exit $st): $(echo "$cfg" | tail -1)"; design=none; verdict=no-answer
        else
            say "    DESIGN ID $design: $(design_note "$design")"
            say "    $(echo "$cfg" | grep -E '^(log_format|cfg|drain|pb|rcap)=' | xargs)"
        fi
    else
        say "    skipped ($verdict)"
    fi
    case "$verdict" in pips) ;; no-access) [ $RC -eq 0 ] && RC=4 ;; *) RC=1 ;; esac
    SUMMARY+=("pips_bdf=$USP id=$id version=$ver design_id=$design setup=$setup verdict=$verdict")
done

say ""
[ "$QUIET" -eq 1 ] || {
    case "$RC" in
        0) echo "RESULT: our PIPS switch, design ID $design ($(design_note "$design")), $setup setup" ;;
        4) echo "RESULT: PIPS ports present, BAR0 not read (run as root)" ;;
        *) echo "RESULT: not our design, or not answering: see the lines above" ;;
    esac
}
printf '%s\n' "${SUMMARY[@]}"
exit $RC
