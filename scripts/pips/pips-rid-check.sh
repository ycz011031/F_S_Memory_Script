#!/bin/bash
# pips-rid-check.sh: does a PIPS downstream port's own requester ID translate
# through the IOMMU domain of the device below it? The FPGA background read
# engine (docs/PIPS-BG-READ-ENGINE.md §4.4, design 0x0A08's test T2) relies on
# it. Without the FPGA able to send such a read yet, this checks everything the
# host can show:
#   1. topology: the switch, its ports, the devices below; IOMMU group of each,
#      who is in it, its type, driver, Bus Master Enable
#   2. the IOMMU hardware tables (Intel debugfs dmar_translation_struct, when
#      the kernel has CONFIG_INTEL_IOMMU_DEBUGFS): the port's and the device's
#      context (or scalable-mode PASID) entries: same domain ID and same page
#      table root = the hardware translates both the same way
#   3. --pt: the page tables themselves (debugfs domain_translation_struct):
#      each --iova present for the port and for the device
#   4. --module: the kernel's own view, from a read-only module built here
#      (ridcheck/pips_iommu_peek.c): same iommu_domain for port and device,
#      and iommu_iova_to_phys() of each --iova through both
#   5. --vfio-drive0 (bigserver): steps 1-4 again while drive 0 alone is
#      attached to VFIO by a short alias-nvme run (its region is mapped at
#      IOVA 0x4000000000, so the IOVAs to check are known). Refuses the
#      990 EVO Plus / 990 PRO (reset freeze, HANDOFF §8) and a running holder
#      (while a hold campaign runs, plain steps 1-4 already see VFIO's domains)
# Baselines for the live test: DMAR fault lines and AER counters now.
#
#   bash scripts/pips/pips-rid-check.sh                         # 1, 2: read-only
#   bash scripts/pips/pips-rid-check.sh --module --pt            # + 3, 4
#   bash scripts/pips/pips-rid-check.sh --module --pt --vfio-drive0   # bigserver: + 5
#   ... --iova 0x4000000000[,A,...]                              # IOVAs for 3, 4
#   ... --out DIR                                                 # default ~/pips-rid-check-<host>-<time>
#
# Changes nothing on the host except: mounts debugfs if it is not mounted;
# --module loads and unloads the module; --vfio-drive0 binds drive 0 to
# vfio-pci for ~90 s and puts it back on nvme (the drive is read, never written).
# Needs sudo. Writes summary.txt (verdicts), raw/ (every dump), and a tarball.
# Exit: 0 the assumption holds as far as the host can tell, 1 it fails
# (the port is not in the device's domain), 3 not decided (no debugfs, no module).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
MODULE=0; PT=0; VFIO0=0; IOVAS=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --module) MODULE=1; shift ;;
        --pt) PT=1; shift ;;
        --vfio-drive0) VFIO0=1; shift ;;
        --iova) IOVAS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "pips-rid-check: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT=${OUT:-$HOME/pips-rid-check-$HOSTN-$(date +%m%d-%H%M%S)}
mkdir -p "$OUT/raw" || exit 2
LOG="$OUT/log.txt"; SUM="$OUT/summary.txt"; : > "$SUM"
T0=$SECONDS
say() { echo "[rid-check $(date +%T) +$((SECONDS - T0))s] $*" | tee -a "$LOG"; }
sum() { echo "$*" | tee -a "$SUM" | tee -a "$LOG"; }
# wait_pid <pid> <what>: wait, a heartbeat line every 10 s
wait_pid() {
    local p=$1 n=0
    while kill -0 "$p" 2>/dev/null; do
        sleep 1; n=$((n + 1))
        [ $((n % 10)) = 0 ] && say "  ... $2 still running (${n} s)"
    done
    wait "$p" 2>/dev/null
}

say "start on $HOSTN, kernel $(uname -r); output $OUT"
sudo -v || { echo "pips-rid-check: needs sudo" >&2; exit 2; }
sum "pips-rid-check on $HOSTN, $(date '+%F %T'), kernel $(uname -r), repo $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
sum "cmdline: $(cat /proc/cmdline)"

# ------------------------------------------------------------------ 1. topology
say "1/5 topology"
USP=$(lspci -D -d 10ee:b048 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -z "$USP" ]; then
    sum "VERDICT: no PIPS upstream port (10ee:b048) on this host"; exit 3
fi
PORTS=(); DEVS=(); declare -A DEV_OF
for d in /sys/bus/pci/devices/"$USP"/[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*/; do   # the downstream ports
    [ -e "$d/class" ] || continue
    [ "$(cat "$d/class")" = 0x060400 ] || continue
    p=$(basename "$d"); PORTS+=("$p")
    for e in "$d"[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*; do             # the device below each
        [ -e "$e/class" ] || continue
        DEVS+=("$(basename "$e")"); [ -n "${DEV_OF[$p]:-}" ] || DEV_OF[$p]=$(basename "$e")
    done
done
[ "${#PORTS[@]}" -gt 0 ] || { sum "VERDICT: no downstream ports below $USP"; exit 3; }
fn_info() {   # <bdf>: one line
    local b=$1 g gt drv cmd bme unit
    g=$(basename "$(readlink -f /sys/bus/pci/devices/$b/iommu_group 2>/dev/null)" 2>/dev/null)
    gt=$(cat /sys/kernel/iommu_groups/"$g"/type 2>/dev/null || echo "?")
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/$b/driver 2>/dev/null)" 2>/dev/null)
    cmd=$(sudo setpci -s "$b" COMMAND 2>/dev/null)
    bme=$(( 0x${cmd:-0} >> 2 & 1 ))
    unit=$(basename "$(readlink -f /sys/bus/pci/devices/$b/iommu 2>/dev/null)" 2>/dev/null)
    echo "$b $(cat /sys/bus/pci/devices/$b/vendor):$(cat /sys/bus/pci/devices/$b/device) driver=${drv:-none} group=${g:-none} group_type=$gt unit=${unit:-none} command=0x${cmd:-?} bme=$bme"
}
RP=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$USP)")")
sum ""
sum "== 1. topology (root port $RP)"
sum "usp   $(fn_info "$USP")"
for p in "${PORTS[@]}"; do
    sum "port  $(fn_info "$p")"
    d=${DEV_OF[$p]:-}
    [ -n "$d" ] && sum "  dev $(fn_info "$d")" || sum "  dev (none below)"
done
sum ""
sum "== groups"
for p in "${PORTS[@]}"; do
    d=${DEV_OF[$p]:-}; [ -n "$d" ] || continue
    gp=$(basename "$(readlink -f /sys/bus/pci/devices/$p/iommu_group 2>/dev/null)")
    gd=$(basename "$(readlink -f /sys/bus/pci/devices/$d/iommu_group 2>/dev/null)")
    sum "$p / $d: group $gp / $gd: $( [ "$gp" = "$gd" ] && echo SAME || echo DIFFERENT); members of $gd: $(ls /sys/kernel/iommu_groups/"$gd"/devices 2>/dev/null | xargs)"
done
# VFIO state
sum ""
sum "== VFIO / holders"
for d in "${DEVS[@]}"; do
    g=$(basename "$(readlink -f /sys/bus/pci/devices/$d/iommu_group 2>/dev/null)")
    users=$(sudo find /proc/[0-9]*/fd -lname "/dev/vfio/$g" 2>/dev/null | cut -d/ -f3 | sort -u | xargs)
    sum "$d group $g: /dev/vfio/$g open by: ${users:-nobody}$( [ -n "$users" ] && echo " ($(ps -o comm= -p ${users%% *} 2>/dev/null))")"
done
HOLDER=$(pgrep -af 'alias-nvm[e] .*--hold ' | head -1)
sum "alias-nvme holder: ${HOLDER:-none}"

# baselines for the live test
sum ""
sum "== baselines (for 0x0A08's live tests)"
sum "DMAR fault lines in dmesg now: $(sudo dmesg 2>/dev/null | grep -c -E 'DMAR: \[DMA (Read|Write)|DMAR:.*[Ff]ault')"
for b in "$RP" "$USP" "${PORTS[@]}" "${DEVS[@]}"; do
    a=""
    for k in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
        f=/sys/bus/pci/devices/$b/$k
        [ -r "$f" ] && a="$a $k:$(awk '$1 == "TOTAL_ERR_COR" || $1 == "TOTAL_ERR_NONFATAL" || $1 == "TOTAL_ERR_FATAL" { print $2 }' "$f")"
    done
    sum "AER $b:${a:- (no AER stats)}"
done

# ------------------------------------------------------------------ 2. IOMMU tables (debugfs)
DBG=/sys/kernel/debug/iommu/intel
cfg_has() {   # kernel config option set?
    { [ -r "/boot/config-$(uname -r)" ] && grep -q "^$1=y" "/boot/config-$(uname -r)"; } ||
    { [ -r /proc/config.gz ] && zcat /proc/config.gz | grep -q "^$1=y"; }
}
hw_tables() {   # <label>: dump and compare the context / PASID entries of every port/device pair
    local lab=$1 f="$OUT/raw/dmar_translation_struct-$1.txt"
    say "2/5 IOMMU hardware tables ($lab)"
    sum ""
    sum "== 2. IOMMU hardware tables ($lab)"
    if ! mountpoint -q /sys/kernel/debug; then
        say "  mounting debugfs"; sudo mount -t debugfs none /sys/kernel/debug 2>>"$LOG"
    fi
    if ! sudo test -r "$DBG/dmar_translation_struct"; then
        sum "debugfs $DBG/dmar_translation_struct: not available (CONFIG_INTEL_IOMMU_DEBUGFS $(cfg_has CONFIG_INTEL_IOMMU_DEBUGFS && echo set || echo 'not set, or config not found')): use --module"
        HW_VERDICT=unknown; return
    fi
    sudo timeout 60 cat "$DBG/dmar_translation_struct" > "$f" 2>>"$LOG"
    sum "dump: $(wc -l < "$f") lines ($f)"
    local args=()
    for p in "${PORTS[@]}"; do [ -n "${DEV_OF[$p]:-}" ] && args+=("$p=${DEV_OF[$p]}"); done
    args+=("$USP=${DEV_OF[${PORTS[0]}]:-none}")    # the upstream port as a control (expected: different)
    python3 - "$f" "${args[@]}" <<'PYEOF' | tee -a "$SUM" | tee -a "$LOG"
import re, sys
f, pairs = sys.argv[1], sys.argv[2:]
unit = "?"
ent = {}     # (bus, dev, fn) -> list of (unit, root, ctx, pasid, pte) ; several per BDF in scalable mode
rx = re.compile(r"^\s*([0-9a-f]{1,2}):([0-9a-f]{1,2})\.0?([0-7])\s+0x([0-9a-f]+):0x([0-9a-f]+)\s+0x([0-9a-f]+):0x([0-9a-f]+)"
                r"(?:\s+(\d+)\s+0x([0-9a-f]+):0x([0-9a-f]+):0x([0-9a-f]+))?", re.I)
for line in open(f, errors="replace"):
    m = re.search(r"IOMMU\s+(\S+):\s*Root Table Address", line)
    if m:
        unit = m.group(1).rstrip(":")
        continue
    m = rx.match(line)
    if not m:
        continue
    b, d, fn = (int(m.group(i), 16) for i in (1, 2, 3))
    ctx = (int(m.group(6), 16), int(m.group(7), 16))
    pas = None
    if m.group(8) is not None:
        pas = (int(m.group(8)), int(m.group(9), 16), int(m.group(10), 16), int(m.group(11), 16))   # pasid, val2, val1, val0
    ent.setdefault((b, d, fn), []).append((unit, ctx, pas, line.rstrip()))

def key(bdf):
    m = re.match(r"(?:[0-9a-f]{4}:)?([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$", bdf, re.I)
    return tuple(int(x, 16) for x in m.groups()) if m else None

def decode(es):
    """(unit, mode, did, table) of a function's entries, or None"""
    if not es:
        return None
    unit, ctx, pas, _ = es[0]
    pz = [e for e in es if e[2] is not None and e[2][0] == 0] or [e for e in es if e[2] is not None]
    if pz:                       # scalable mode: RID_PASID's entry
        _, v2, v1, v0 = pz[0][2]
        return (pz[0][0], "sm", v1 & 0xffff, ("pgtt%d" % ((v0 >> 6) & 7), v0 & ~0xfff, v2 & ~0xfff), bool(v0 & 1))
    hi, lo = ctx
    return (unit, "legacy", (hi >> 8) & 0xffff, ("tt%d" % ((lo >> 2) & 3), lo & ~0xfff, (hi & 7)), bool(lo & 1))

verdict = []
for pr in pairs:
    p, d = pr.split("=")
    kp, kd = key(p), key(d)
    ep, ed = (decode(ent.get(kp, [])) if kp else None), (decode(ent.get(kd, [])) if kd else None)
    for lab, k in (("port", kp), ("dev", kd)):
        for e in ent.get(k, [])[:2] if k else []:
            print(f"  raw {lab} {p if lab == 'port' else d} [{e[0]}]: {e[3].strip()}")
    if ep is None:
        r = "PORT-NOT-PRESENT (no context entry: reads under the port's ID would fault)"
    elif ed is None:
        r = "DEV-NOT-PRESENT"
    elif not ep[4]:
        r = "PORT-ENTRY-NOT-PRESENT-BIT"
    elif ep[0] == ed[0] and ep[2] == ed[2] and ep[3] == ed[3]:
        r = "HW-SAME"
    else:
        r = "HW-DIFFERENT"
    fmt = lambda e: "none" if e is None else f"{e[0]} {e[1]} did={e[2]} table={e[3][0]}:0x{e[3][1]:x}:0x{e[3][2]:x} present={int(e[4])}"
    print(f"pair {p}={d}: {r}")
    print(f"  port {fmt(ep)}")
    print(f"  dev  {fmt(ed)}")
    verdict.append(r.split()[0])
print("HWVERDICT " + " ".join(verdict))
PYEOF
    # the first pairs are the ports; the last is the USP control
    local v; v=$(grep '^HWVERDICT' "$SUM" | tail -1 | cut -d' ' -f2-)
    local nport=0 same=0 diff=0
    for x in $v; do
        nport=$((nport + 1)); [ "$nport" -gt "${#PORTS[@]}" ] && break
        [ "$x" = HW-SAME ] && same=$((same + 1)) || diff=$((diff + 1))
    done
    if [ "$diff" = 0 ] && [ "$same" -gt 0 ]; then HW_VERDICT=same; else HW_VERDICT=different; fi
    sum "hardware tables ($lab): $same port(s) share the device's domain, $diff do not -> $HW_VERDICT"
}

# ------------------------------------------------------------------ 3. page tables (debugfs)
pt_check() {   # <label> <iova,...>
    local lab=$1 iovas=$2
    [ "$PT" = 1 ] || return 0
    say "3/5 page tables ($lab): IOVAs $iovas"
    sum ""
    sum "== 3. page tables ($lab)"
    [ -n "$iovas" ] || { sum "no --iova given: skipped"; return 0; }
    local p d f pfns
    pfns=$(for a in ${iovas//,/ }; do printf '%x ' $(( a >> 12 )); done)
    for p in "${PORTS[@]}"; do
        d=${DEV_OF[$p]:-}; [ -n "$d" ] || continue
        for b in "$p" "$d"; do
            f="$DBG/$b/domain_translation_struct"
            if sudo test -r "$f"; then                     # 6.7+: per device
                sudo timeout 120 cat "$f" > "$OUT/raw/pt-$lab-$b.txt" 2>>"$LOG"
            elif sudo test -r "$DBG/domain_translation_struct"; then   # older: every device in one file
                [ -s "$OUT/raw/pt-$lab-all.txt" ] || { say "  dumping every domain's page tables (up to 120 s)"; sudo timeout 120 cat "$DBG/domain_translation_struct" > "$OUT/raw/pt-$lab-all.txt" 2>>"$LOG"; }
                awk -v dev="$b" '/^Device /{ on = index($0, dev) > 0 } on' "$OUT/raw/pt-$lab-all.txt" > "$OUT/raw/pt-$lab-$b.txt"
            else
                sum "$b: no domain_translation_struct in debugfs"; continue
            fi
            local hits=""
            for x in $pfns; do
                grep -q -i -E "^0x0*$x[[:space:]|]" "$OUT/raw/pt-$lab-$b.txt" && hits="$hits 0x$x:yes" || hits="$hits 0x$x:no"
            done
            sum "$b: $(wc -l < "$OUT/raw/pt-$lab-$b.txt") lines; IOVA pfn present:$hits"
        done
    done
}

# ------------------------------------------------------------------ 4. module
K_VERDICT=unknown
mod_check() {   # <label> <iova,...>
    local lab=$1 iovas=$2
    [ "$MODULE" = 1 ] || return 0
    say "4/5 kernel view via pips_iommu_peek ($lab)"
    sum ""
    sum "== 4. kernel view ($lab)"
    local KD="/lib/modules/$(uname -r)/build"
    if [ ! -d "$KD" ]; then
        sum "no kernel headers at $KD: install linux-headers-$(uname -r) (or build tree) to use --module"; return 0
    fi
    if [ ! -e "$OUT/mod/pips_iommu_peek.ko" ]; then
        mkdir -p "$OUT/mod" && cp "$HERE/ridcheck/pips_iommu_peek.c" "$HERE/ridcheck/Makefile" "$OUT/mod/"
        say "  building the module (as $(id -un))"
        make -C "$OUT/mod" > "$OUT/raw/mod-build.txt" 2>&1 || { sum "module build failed (raw/mod-build.txt)"; tail -5 "$OUT/raw/mod-build.txt" | sed 's/^/  /' | tee -a "$SUM"; return 0; }
    fi
    sudo rmmod pips_iommu_peek 2>/dev/null
    local tok="t$$$RANDOM" pairs="" p
    for p in "${PORTS[@]}"; do [ -n "${DEV_OF[$p]:-}" ] && pairs="$pairs,$p=${DEV_OF[$p]}"; done
    pairs="${pairs#,},$USP=${DEV_OF[${PORTS[0]}]}"
    if ! sudo insmod "$OUT/mod/pips_iommu_peek.ko" token="$tok" pairs="$pairs" ${iovas:+iovas="$iovas"} 2> "$OUT/raw/mod-insmod-$lab.txt"; then
        sum "insmod failed: $(cat "$OUT/raw/mod-insmod-$lab.txt") (Secure Boot: $(mokutil --sb-state 2>/dev/null || echo unknown))"; return 0
    fi
    sudo dmesg | grep "pips_iommu_peek\[$tok\]" | sed 's/^\[[^]]*\] //' > "$OUT/raw/mod-$lab.txt"
    sudo rmmod pips_iommu_peek
    sed 's/^/  /' "$OUT/raw/mod-$lab.txt" | tee -a "$SUM" | tee -a "$LOG"
    local np=${#PORTS[@]} n=0 same=0 diff=0 l
    while read -r l; do
        n=$((n + 1)); [ "$n" -gt "$np" ] && break
        case "$l" in *same_domain=1*) same=$((same + 1)) ;; *) diff=$((diff + 1)) ;; esac
    done < <(grep ' group ' "$OUT/raw/mod-$lab.txt")
    local mapped mism
    mapped=$(grep 'iova ' "$OUT/raw/mod-$lab.txt" | grep -v "pair $USP=" | grep -c 'mapped=1')
    mism=$(grep 'iova ' "$OUT/raw/mod-$lab.txt" | grep -v "pair $USP=" | grep -c 'match=0')
    if [ "$diff" = 0 ] && [ "$same" -gt 0 ]; then K_VERDICT=same; else K_VERDICT=different; fi
    sum "kernel view ($lab): $same port(s) in the device's domain, $diff not; IOVA translations present in both: $mapped, port/device translations that differ: $mism -> $K_VERDICT"
}

HW_VERDICT=unknown
hw_tables plain
pt_check plain "$IOVAS"
mod_check plain "$IOVAS"
HW_PLAIN=$HW_VERDICT; K_PLAIN=$K_VERDICT

# ------------------------------------------------------------------ 5. drive 0 under VFIO
V_DONE=0
if [ "$VFIO0" = 1 ]; then
    say "5/5 drive 0 under VFIO"
    sum ""
    sum "== 5. drive 0 attached to VFIO (a short alias-nvme run)"
    D0=${DEV_OF[${PORTS[0]}]:-}
    for p in "${PORTS[@]}"; do   # drive 0 = the device below device-number 0 of the secondary bus
        case "$p" in *:00.0) D0=${DEV_OF[$p]:-}; P0=$p ;; esac
    done
    id="$(cat /sys/bus/pci/devices/$D0/vendor 2>/dev/null):$(cat /sys/bus/pci/devices/$D0/device 2>/dev/null)"
    if [ -n "$HOLDER" ]; then
        sum "skipped: a holder runs ($HOLDER): the drives are already in VFIO's domains; steps 2-4 above saw them"
    elif [ -z "$D0" ] || [ "$(cat /sys/bus/pci/devices/$D0/class)" != 0x010802 ]; then
        sum "skipped: no NVMe drive below ${P0:-port 00.0}"
    elif [ "$id" = 0x144d:0xa80c ] || [ "$id" = 0x144d:0xa80d ]; then
        sum "skipped: $D0 is a 990 PRO / EVO Plus ($id): resetting it after use froze bigserver (HANDOFF §8)"
    else
        NV=$(bash "$HERE/alias/alias-run.sh" --build alias-nvme 2>>"$LOG" | tail -1)
        if [ ! -x "$NV" ]; then sum "skipped: alias-nvme does not build ($NV)"; else
            mkdir -p "$OUT/vfio"
            say "  binding $D0 to vfio-pci"
            if sudo bash "$HERE/alias/alias-vfio.sh" bind "$D0" >> "$LOG" 2>&1; then
                trap 'sudo pkill -INT -f "alias-nvm[e] --dev $D0" 2>/dev/null; sleep 40; sudo bash "$HERE/alias/alias-vfio.sh" restore "$D0" >> "$LOG" 2>&1' INT TERM
                sudo "$NV" --dev "$D0=$OUT/vfio/nv" --queues 1 --qd 4 --bs 4096 --ws 64 --stride 1 \
                    --warm 1 --seconds 75 --heartbeat 10 --ready-file "$OUT/vfio/ready" > "$OUT/vfio/alias-nvme.txt" 2>&1 &
                NVP=$!
                for _ in $(seq 150); do [ -e "$OUT/vfio/ready" ] && break; kill -0 $NVP 2>/dev/null || break; sleep 0.2; done
                if [ -e "$OUT/vfio/ready" ]; then
                    say "  alias-nvme loaded $D0 (region at IOVA 0x4000000000, 64 pages); checking while attached"
                    VI="0x4000000000,0x4000001000,0x400003f000,0x4000040000${IOVAS:+,$IOVAS}"
                    sum "IOVAs: 0x4000000000 0x4000001000 0x400003f000 (mapped, region pages 0, 1, 63) 0x4000040000 (page 64: not mapped)"
                    hw_tables vfio; HW_VFIO=$HW_VERDICT
                    pt_check vfio "$VI"
                    mod_check vfio "$VI"; K_VFIO=$K_VERDICT
                    V_DONE=1
                else
                    sum "alias-nvme did not load $D0 (vfio/alias-nvme.txt):"; tail -5 "$OUT/vfio/alias-nvme.txt" | sed 's/^/  /' | tee -a "$SUM"
                fi
                wait_pid $NVP "alias-nvme (releases $D0 when done)"
                tail -3 "$OUT/vfio/alias-nvme.txt" | sed 's/^/  alias-nvme: /' | tee -a "$SUM"
                say "  putting $D0 back on nvme"
                sudo bash "$HERE/alias/alias-vfio.sh" restore "$D0" >> "$LOG" 2>&1 || sum "WARNING: restore of $D0 failed: sudo bash scripts/pips/alias/alias-vfio.sh restore $D0"
                trap - INT TERM
                sum "DMAR fault lines in dmesg after: $(sudo dmesg 2>/dev/null | grep -c -E 'DMAR: \[DMA (Read|Write)|DMAR:.*[Ff]ault')"
            else
                sum "bind of $D0 refused (log.txt): nothing changed"
            fi
        fi
    fi
fi

# ------------------------------------------------------------------ verdict
sum ""
sum "== VERDICT"
sum "hardware tables, as found: ${HW_PLAIN}; kernel view, as found: ${K_PLAIN}"
[ "$V_DONE" = 1 ] && sum "drive 0 under VFIO: hardware tables ${HW_VFIO:-unknown}; kernel view ${K_VFIO:-unknown}"
rc=3
all="$HW_PLAIN $K_PLAIN ${HW_VFIO:-} ${K_VFIO:-}"
if [[ " $all " == *" different "* ]]; then
    rc=1; sum "FAILS: at least one port is not in its device's domain. 0x0A08 tests the fallbacks (docs/PIPS-0A08-ASSUMPTION-TEST.md §2, §4)"
elif [[ " $all " == *" same "* ]]; then
    rc=0; sum "HOLDS as far as the host shows: each port's requester ID maps to its device's domain. 0x0A08's live test (T2) confirms it on the wire"
else
    sum "NOT DECIDED: no debugfs tables and no module result. Rerun with --module (needs linux-headers-$(uname -r))"
fi
( cd "$(dirname "$OUT")" && tar -czf "$OUT.tar.gz" "$(basename "$OUT")" ) && say "tarball: $OUT.tar.gz"
say "done in $((SECONDS - T0)) s; summary: $SUM"
exit $rc
