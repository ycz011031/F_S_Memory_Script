# pips-bg-lib.sh: the --bg campaign of pips-campaign.sh (design 0x0A08: the
# switch's background read engine as a cheap IOMMU stressor; HANDOFF §8
# "0x0A08 stress campaign"). Sourced by pips-campaign.sh after its helpers;
# uses its KIND OUT STAMP DRY RUNS HERE REPO PIPS HOLD_DIR, say, note,
# sweep_run, hold_up, hold_fresh, guard.
#
# bigserver (ssd): two halves, in this order (VFIO can't be undone without a reboot):
#   native  the drives on the kernel's nvme driver, IOMMU as booted (strict):
#           every I/O mapped and unmapped (invalidations). The engine reads a
#           256 MiB region that ridcheck/pips_bg_region.ko maps in each drive's
#           own DMA domain (the group's, which the port above the drive shares).
#           fio loads: random reads 4k-1m, sequential reads, deeper queues.
#   vfio    one alias-nvme --hold (as the alias campaigns): static pages. The
#           engine reads a region the holder maps apart from the drives' own
#           ("bgmap"). alias-nvme loads. Ends with the campaign's reboot.
# icx (nic): one half, no VFIO, no reboot. The NICs stay on mlx5; the module's
#           region in each NIC's domain (as on bigserver's native half). Loads:
#           iperf3 TCP (map/unmap per packet, strict) and alias-rdma READs into
#           an MR registered once (static pages: fits / one-set rotation /
#           capacity). Also the IOTLB's replacement policy from engine traces.
# Each half: prep (region, a 64-read data check through in0 and in1, the tag
# census under the half's heaviest load -> the engine's tag window and MAX_OUT),
# alone (the engine with the devices idle: reads/s and latency against MAX_OUT
# and rate, with pcm-iio; the capacity knee by latency; vfio also the
# replacement probe T8b, icx the policy tables), stress (one sweep per engine
# level: the runner's PIPS_BG), heavy/cross. A problem with the engine
# (non-SC completion, timeout, data mismatch, a device tag in the window)
# stops the engine for the rest of that half (PIPS_BG_STOPFILE); a leak or
# clash stops it for good. The engine-off sweeps (the base runs) run anyway.
# Kernel soft lockups in the native half end the native half (not the campaign).

BG_DEF="count=0 stoponerr=1 clronstart=1 fcoff=0 ridtag=0 src=pattern trace=0 dcheck=1 offset=0 dw=1 tskip=0 hshift=4 timeout_us=1000 nphres=2 arb=engine first=0 seed=1 rid1=none rid2=none rid3=none"
BG_LEVELS="off h16 m1 m4 m16 c16 v16 d16 h50 m50 hx mx"
BG_HEAVY_LEVELS="off m16 v16 mx"
BG_CROSS_N_LEVELS="m16 v16 mx"
BG_CROSS_V_LEVELS="m16 c16 v16 mx"
BG_NBS="4k 8k 16k 64k 1m"; BG_HBS="4k 8k 64k"; BG_XBS="4k 64k"   # fio block sizes: nstress, nheavy, ncross
# The base fio runs widened (user, 11-07): 8k (above), deeper queues, sequential reads.
BG_DEEP_QD="128 512"; BG_DEEP_BS="4k 8k"; BG_DEEP_LEVELS="off h16 m16 v16 mx"   # ndeep: 4 instances x iodepth (32 elsewhere)
BG_SEQ_BS="4k 8k 1m"; BG_SEQ_LEVELS="off h16 m16 v16 mx"                         # nseq: fio --rw read, 4 instances
BG_NEXTRA=""; BG_DEEPWIN=0             # runner options of the native sweeps; ndeep's own tag window
BG_T8B_MAX=0                           # T8b tables (0 = all 155)
BN_NPAGES=65536; BN_BK=4096            # native region per device: 256 MiB on 16 MiB of memory
BV_WS=2097152; BV_BK=65536             # vfio stress region: 8 GiB of IOVA on 256 MiB
BV_BASE=0x2000000000
BG_SETS="1:0 16:218"; BG_PBS="0 1"     # d1t0c1 (batching off), d16t218c1; page_batch_en 0/1
BG_THR="thr=31"
# vfio drive patterns: f fits (no misses alone), e at the capacity edge (shared
# cursor: strict order; alias campaign 2: alone fits to 56, both 48 each), t thrash
BG_VPATS="f e t"
# icx: levels (no d16: a 2 MiB stride costs nothing there, T7), TCP flows per
# NIC, alias-rdma patterns (bg_ipat), replacement tables (0 = all)
BG_ILEVELS="off h16 m1 m4 m16 c16 v16 h50 m50 hx mx"
BG_ICROSS_LEVELS="m16 v16 mx"
BG_IFLOWS="5 30"
BG_IPATS="f r t"
BG_IREPL_MAX=0
# --smoke: every step once, small: the levels off, m16 and mx, one run, 4k,
# d1t0c1 and d16t218c1 (pb 0), ws 32 and 128 in the knee, 6 T8b tables, the
# fitting vfio pattern only; ndeep at qd 512 and nseq at 4k with m16; icx 5
# flows, patterns f and r, 4 policy tables
bg_smoke() {
    BG_LEVELS="off m16 mx"; BG_HEAVY_LEVELS="mx"; BG_CROSS_N_LEVELS="m16"; BG_CROSS_V_LEVELS="m16"
    BG_NBS="4k"; BG_HBS="4k"; BG_XBS="4k"; BG_X1_WS="32 128"; BG_T8B_MAX=6; BG_VPATS="f"; BG_PBS="0"; RUNS=1
    BG_DEEP_QD="512"; BG_DEEP_BS="4k"; BG_DEEP_LEVELS="m16"; BG_SEQ_BS="4k"; BG_SEQ_LEVELS="m16"
    BG_ILEVELS="off m16 mx"; BG_ICROSS_LEVELS="m16"; BG_IFLOWS="5"; BG_IPATS="f r"; BG_IREPL_MAX=4
}
bg_vpat() {
    case "$1" in
        f) echo "--gen alias --ws 32 --stride 1 --order cyclic" ;;
        e) echo "--gen alias --ws 48 --stride 1 --order cyclic --cursor shared" ;;
        t) echo "--gen alias --ws 65536 --stride 1 --order cyclic" ;;
    esac
}
bg_vpat_what() { case "$1" in f) echo "ws 32 (fits)" ;; e) echo "ws 48 shared cursor (capacity edge)" ;; t) echo "ws 65536 (thrash)" ;; esac; }
# icx alias-rdma patterns (alias campaign 2): IP_EXTRA runner options, IP_QPS QPs per NIC
bg_ipat() {
    case "$1" in
        f) IP_EXTRA="--gen alias --ws 64 --stride 1 --order cyclic --depth 16 --rdma-bs 4096"; IP_QPS=4
           IP_WHAT="ws 64 (fits), 4 QPs" ;;
        r) IP_EXTRA="--gen alias --ws 64 --stride 4096 --order cyclic --depth 16 --rdma-bs 4096 --rdma-mtu 2048"; IP_QPS=32
           IP_WHAT="ws 64 in one set (rotation: 7.4 misses per page alone, 2.0 with d16t218c1), 32 QPs, MTU 2048" ;;
        t) IP_EXTRA="--gen alias --ws 65536 --stride 1 --order cyclic --depth 16 --rdma-bs 4096"; IP_QPS=4
           IP_WHAT="ws 65536 (capacity: every page misses), 4 QPs" ;;
        *) return 1 ;;
    esac
}

# bg_level <level> <half>: LV_PAT (pattern keys), LV_INT (INTERVAL, 4 ns clocks), LV_WHAT
bg_level() {
    LV_INT=16
    case "$1" in
        h16) LV_PAT="ws=8 stride=1 order=cyclic"; LV_WHAT="hits (ws 8), 15.6 M reads/s" ;;
        h50) LV_PAT="ws=8 stride=1 order=cyclic"; LV_INT=5; LV_WHAT="hits, 50 M/s" ;;
        hx)  LV_PAT="ws=8 stride=1 order=cyclic"; LV_INT=1; LV_WHAT="hits, as fast as MAX_OUT allows" ;;
        m1)  LV_PAT="ws=65536 stride=1 order=random"; LV_INT=250; LV_WHAT="one-shot misses (random over 65536 pages), 1 M/s" ;;
        m4)  LV_PAT="ws=65536 stride=1 order=random"; LV_INT=62; LV_WHAT="one-shot misses, 4 M/s" ;;
        m16) LV_PAT="ws=65536 stride=1 order=random"; LV_WHAT="one-shot misses, 15.6 M/s" ;;
        m50) LV_PAT="ws=65536 stride=1 order=random"; LV_INT=5; LV_WHAT="one-shot misses, 50 M/s" ;;
        mx)  LV_PAT="ws=65536 stride=1 order=random"; LV_INT=1; LV_WHAT="one-shot misses, as fast as MAX_OUT allows" ;;
        c16) if [ "$2" = nic ]; then LV_PAT="ws=128 stride=1 order=cyclic"; LV_WHAT="128 pages reused (4 of each set's 8 ways: capacity taken, hits), 15.6 M/s"
             else LV_PAT="ws=96 stride=1 order=cyclic"; LV_WHAT="96 pages reused (they fit: capacity taken, hits), 15.6 M/s"; fi ;;
        v16) if [ "$2" = nic ]; then LV_PAT="ws=512 stride=1 order=cyclic"; LV_WHAT="512 pages reused (twice the 32 x 8 entries: LRU misses every read), 15.6 M/s"
             else LV_PAT="ws=256 stride=1 order=cyclic"; LV_WHAT="256 pages reused (over capacity: reused misses), 15.6 M/s"; fi ;;
        d16) if [ "$2" = native ]; then LV_PAT="ws=128 stride=512 order=random"; LV_WHAT="misses 2 MiB apart (128 leaf tables), 15.6 M/s"
             elif [ "$2" = vfio ]; then LV_PAT="ws=4096 stride=512 order=random"; LV_WHAT="misses 2 MiB apart (4096 leaf tables, 8 GiB), 15.6 M/s"
             else return 1; fi ;;
        off) LV_PAT=""; LV_INT=0; LV_WHAT="engine off" ;;
        *) return 1 ;;
    esac
}

# progress.tsv "step" lines for the steps that are not sweeps
step_done() { grep -q "^step"$'\t'"$1"$'\t' "$OUT/progress.tsv" 2>/dev/null; }
step_mark() { printf 'step\t%s\t%s\n' "$1" "$(date '+%F %T')" >> "$OUT/progress.tsv"; }
bgkv() { awk -v k="$1=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) v = substr($i, length(k) + 1) } END { if (v != "") print v }' "$2" 2>/dev/null; }

# ------------------------------------------------------------------ state
# The module's half: "native" on bigserver, "nic" on icx (the same BN_* state;
# pips-campaign.sh sets it once KIND is known).
BN_H=native
BG_DEAD=0          # a leak or clash: the engine is never started again
BN_OK=0; BV_OK=0   # the half's engine is usable (region mapped, data check passed, window found)
BN_STOP=0          # the native half ended early (soft lockups, or nothing left to do there)
BG_HELD=0          # the drives are held by this campaign's alias-nvme (the vfio half)
bg_env_save() {    # <half>
    local h=$1
    if [ "$h" != vfio ]; then
        printf 'BN_D0=%s\nBN_D1=%s\nBN_B0=%s\nBN_B1=%s\nBN_WIN=%s\nBN_MO=%s\nBN_OK=%s\nBN_WIND=%s\nBN_MOD=%s\n' \
            "$BN_D0" "$BN_D1" "$BN_B0" "$BN_B1" "$BN_WIN" "$BN_MO" "$BN_OK" "$BN_WIND" "$BN_MOD" > "$OUT/bg/$h.env"
    else
        printf 'BV_B0=%s\nBV_B1=%s\nBV_WIN=%s\nBV_MO=%s\nBV_OK=%s\n' "$BV_B0" "$BV_B1" "$BV_WIN" "$BV_MO" "$BV_OK" > "$OUT/bg/vfio.env"
    fi
}
BN_D0=""; BN_D1=""; BN_B0=""; BN_B1=""; BN_WIN=""; BN_MO=""; BN_WIND=""; BN_MOD=""; BV_B0=""; BV_B1=""; BV_WIN=""; BV_MO=""
bg_init() {
    mkdir -p "$OUT/bg/$BN_H" 2>/dev/null
    [ "$KIND" = ssd ] && mkdir -p "$OUT/bg/vfio" 2>/dev/null
    [ -s "$OUT/bg/$BN_H.env" ] && . "$OUT/bg/$BN_H.env"
    [ -s "$OUT/bg/vfio.env" ] && . "$OUT/bg/vfio.env"
    [ -e "$OUT/bg/DEAD" ] && BG_DEAD=1
    if [ "$KIND" = ssd ] && { hold_fresh || bg_drives_not_nvme; }; then BG_HELD=1; fi
    return 0
}
bg_drives_not_nvme() {   # true if a drive of SSD_SERIALS is not on nvme (held, or on vfio-pci)
    local i s c f
    for i in 0 1; do
        s=${SSD_SERIALS[$i]:-}; f=0
        for c in /sys/class/nvme/nvme*; do [ "$(tr -d ' ' < "$c/serial" 2>/dev/null)" = "$s" ] && f=1; done
        [ "$f" = 0 ] && return 0
    done
    return 1
}
bg_nvme_bdf() {   # <serial> -> the PCI function of that drive on nvme
    local c
    for c in /sys/class/nvme/nvme*; do
        [ "$(tr -d ' ' < "$c/serial" 2>/dev/null)" = "$1" ] && { basename "$(readlink -f "$c/device")"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------------ the engine
pipsb() { sudo -n "$PIPS" "$@"; }
# eng_run <file> <keys...>: one engine run (pips bg run), its output in <file>; 0 if clean
eng_run() {
    local f=$1 rc e=0 k v; shift
    if [ "$BG_DEAD" = 1 ]; then echo "# not run: the engine is stopped for good" > "$f"; return 5; fi
    echo "\$ pips bg run $BG_DEF $*" > "$f"
    pipsb bg run $BG_DEF "$@" beat=5 >> "$f" 2>&1; rc=$?
    if [ "$rc" = 1 ] && grep -q 'cfg_code=12' "$f"; then   # tags quarantined from before: clear and retry
        pipsb bg clear twice >> "$f" 2>&1
        pipsb bg run $BG_DEF "$@" beat=5 >> "$f" 2>&1; rc=$?
    fi
    for k in cpl_ur cpl_ca cpl_other cpl_poisoned cpl_malformed cpl_unexpected timeouts data_mismatch leak_cpl; do
        v=$(bgkv "$k" "$f"); case "$v" in ''|*[!0-9]*) v=0 ;; esac; e=$((e + v))
    done
    if [ "$rc" = 5 ] || [ "$(bgkv leak_seen "$f")" = 1 ] || [ "$(bgkv clash_seen "$f")" = 1 ]; then
        BG_DEAD=1; date '+%F %T' > "$OUT/bg/DEAD"; echo "leak or clash in $(basename "$f")" >> "$OUT/bg/DEAD"
        pipsb bg capture 16 > "${f%.txt}-capture.txt" 2>&1
        note "read engine: LEAK or CLASH in $(basename "$f") ($(bgkv leak_cpl "$f") leaked completions): the engine is stopped for the rest of the campaign"
        return 5
    fi
    [ "$e" -gt 0 ] && pipsb bg capture 16 > "${f%.txt}-capture.txt" 2>&1
    ENG_RATE=$(bgkv issue_rate_mrd_s "$f"); ENG_LAT=$(bgkv lat_mean_ns "$f"); ENG_ERR=$e
    [ "$rc" = 0 ] && [ "$e" = 0 ]
}
eng_hist() { pipsb bg hist > "$1" 2>&1; }

# The tag window: the largest range no device used in the census. A range
# ending at 255 that starts below 128 is cut to 128-255 (pips-rid-live.sh's
# rule, icx 11-07: NIC 0's tags grew from 0-5 to 0-21 under load); otherwise,
# when wide, 16 tags next to the devices' are kept clear. MAX_OUT the window's
# size, at most 128 (T4 ran 128).
bg_free_win() {   # <census file> -> "LO-HI N" or "none 0"
    [ -n "$(bgkv in0_tags "$1")" ] || { echo "none 0"; return; }
    echo "$(bgkv in0_tags "$1"),$(bgkv in1_tags "$1"),$(bgkv cpl0_tags "$1"),$(bgkv cpl1_tags "$1")" | awk -F, '{
        for (i = 1; i <= NF; i++) {
            if ($i == "" || $i == "none") continue
            n = split($i, r, "-"); lo = r[1] + 0; hi = (n > 1 ? r[2] : r[1]) + 0
            for (t = lo; t <= hi; t++) used[t] = 1
        }
        s = -1; bl = -1; bn = 0
        for (t = 0; t <= 256; t++) {
            if (t < 256 && !(t in used)) { if (s < 0) s = t }
            else if (s >= 0) { if (t - s > bn) { bn = t - s; bl = s }; s = -1 }
        }
        if (!bn) { print "none 0"; exit }
        lo = bl; hi = bl + bn - 1
        if (hi == 255 && lo < 128) lo = 128
        else if (bn >= 80) { if (lo > 0) lo += 16; else hi -= 16 }
        printf "%d-%d %d\n", lo, hi, hi - lo + 1
    }'
}

# bg_spec <level> <half> [in0|in1]: the runner's PIPS_BG for a stress level
bg_spec() {
    local lv=$1 h=$2 rid=${3:-in0} base bk win mo
    bg_level "$lv" "$h" || return 1
    if [ "$h" != vfio ]; then bk=$BN_BK; win=$BN_WIN; mo=$BN_MO; base=$BN_B0; [ "$rid" = in1 ] && base=$BN_B1
        [ "$BG_DEEPWIN" = 1 ] && { win=$BN_WIND; mo=$BN_MOD; }
    else bk=$BV_BK; win=$BV_WIN; mo=$BV_MO; base=$BV_B0; [ "$rid" = in1 ] && base=$BV_B1; fi
    echo "$BG_DEF rid=$rid base=$base backing=$bk tagwin=$win maxout=$mo $LV_PAT interval=$LV_INT"
}

# bg_check_read <dir> <half>: 64 reads through in0 and in1 into each device's region, data checked
bg_check_read() {
    local d=$1 h=$2 b0 b1 bk p ok=0 f
    if [ "$h" != vfio ]; then b0=$BN_B0; b1=$BN_B1; bk=$BN_BK; else b0=$BV_B0; b1=$BV_B1; bk=$BV_BK; fi
    for p in in0 in1; do
        f="$d/check-$p.txt"
        eng_run "$f" rid=$p base=$( [ "$p" = in0 ] && echo "$b0" || echo "$b1") backing=$bk ws=64 stride=1 order=cyclic \
            count=64 maxout=1 interval=0 tagwin=off secs=10 || true
        if [ "$(bgkv cpl_sc "$f")" = 64 ] && [ "$(bgkv data_mismatch "$f")" = 0 ] && [ "${ENG_ERR:-1}" = 0 ]; then
            say "  data check $p: 64 of 64 SC, tags right, latency $(bgkv lat_mean_ns "$f") ns"
        else
            say "  data check $p: FAILED: sc $(bgkv cpl_sc "$f") ur $(bgkv cpl_ur "$f") ca $(bgkv cpl_ca "$f") mismatch $(bgkv data_mismatch "$f") timeouts $(bgkv timeouts "$f") ($f)"
            ok=1
        fi
    done
    return $ok
}

# bg_census <half> [deep]: the devices' tags under the half's heaviest load -> window, MAX_OUT
# (deep: the native half's ndeep loads, its own window BN_WIND / BN_MOD)
bg_census() {
    local h=$1 v=${2:-} d="$OUT/bg/$1" t fw n c=census qd mo
    [ -n "$v" ] && c="census-$v"
    t=$(date +%H%M%S)
    unset PIPS_BG
    pipsb bg census clear > /dev/null 2>&1
    if [ "$h" = native ] && [ "$v" = deep ]; then
        qd=$(echo $BG_DEEP_QD | tr ' ' '\n' | sort -n | tail -1)
        say "  census (deep queues): fio both drives, 4 instances x qd $qd, 4k random then 4k sequential (~1 min)"
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/nq${qd}x4k" --ssds 2 -J 4 --bs 4k \
              --iodepth "$qd" --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run1.txt" 2>&1
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/nq${qd}x4kseq" --ssds 2 -J 4 --bs 4k \
              --iodepth "$qd" --rw read --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run2.txt" 2>&1
    elif [ "$h" = native ]; then
        say "  census: fio both drives, 16 instances x qd 32 at 4k, 4 at 1m, 4 at 4k sequential (~3 min)"
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/n16x4k" --ssds 2 -J 16 --bs 4k \
              --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run1.txt" 2>&1
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/n4x1m" --ssds 2 -J 4 --bs 1m \
              --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run2.txt" 2>&1
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/n4x4kseq" --ssds 2 -J 4 --bs 4k \
              --rw read --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run3.txt" 2>&1
    elif [ "$h" = nic ]; then
        say "  census: both NICs, iperf3 30 flows each, then alias-rdma 32 QPs each (one-set rotation, MTU 2048) (~5 min)"
        ( cd "$REPO/scripts" && bash ./run-dualnic-experiment.sh -E "bgcensus-$STAMP-$t-tcp30" --nics 2 -S 30 -C 30 --uncapped \
              -d 10 --results "$d/$c.jsonl" ) > "$d/$c-run1.txt" 2>&1 < /dev/null
        bg_ipat r
        ( cd "$REPO/scripts" && bash ./run-dualnic-experiment.sh -E "bgcensus-$STAMP-$t-rdma32" --nics 2 -S 32 -C 32 --uncapped \
              $IP_EXTRA -d 10 --results "$d/$c.jsonl" ) > "$d/$c-run2.txt" 2>&1 < /dev/null
    else
        say "  census: alias loads on both drives, ws 64 then ws 65536 (~2 min)"
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/vw64" --ssds 2 -J 4 --bs 4k \
              --gen alias --ws 64 --stride 1 --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run1.txt" 2>&1
        ( cd "$REPO/scripts" && bash ./run-dualssd-experiment.sh -E "bgcensus-$STAMP-$t/vw65536" --ssds 2 -J 4 --bs 4k \
              --gen alias --ws 65536 --stride 1 --membw 0 -d 10 --warm 5 --results "$d/$c.jsonl" ) > "$d/$c-run2.txt" 2>&1
    fi
    pipsb bg census > "$d/$c.txt" 2>&1
    say "  census: in0 $(bgkv in0_mrd "$d/$c.txt") reads, tags $(bgkv in0_tags "$d/$c.txt"); in1 $(bgkv in1_mrd "$d/$c.txt") reads, tags $(bgkv in1_tags "$d/$c.txt"); completions $(bgkv cpl0_tags "$d/$c.txt") / $(bgkv cpl1_tags "$d/$c.txt")"
    if [ "$(bgkv in0_mrd "$d/$c.txt")" = 0 ] || [ -z "$(bgkv in0_mrd "$d/$c.txt")" ]; then
        note "$h $c: no device reads counted (the loads did not run? $d/$c-run*.txt)"; return 1
    fi
    read -r fw n <<< "$(bg_free_win "$d/$c.txt")"
    if [ "${n:-0}" -lt 32 ]; then note "$h $c: the largest free tag range is $fw ($n tags): under 32, the engine stays off for these loads"; return 1; fi
    mo=$(( n < 128 ? n : 128 ))
    if [ "$v" = deep ]; then BN_WIND=$fw; BN_MOD=$mo
    elif [ "$h" != vfio ]; then BN_WIN=$fw; BN_MO=$mo
    else BV_WIN=$fw; BV_MO=$mo; fi
    say "  engine tags $fw ($n), MAX_OUT $mo"
    return 0
}

# bg_pcm <name> <half>: pcm-iio for 10 s while the engine runs alone; reports in $OUT/bg/<half>/pcm/<name>.rpt
bg_pcm() {
    local n=$1 h=$2 o="bgalone-$STAMP/$2-$1" dev
    if [ "$KIND" = nic ]; then dev=( --cores "${SERVER_CORES[0]%%,*}" --intf "${SERVER_INTFS[0]}" )
    else dev=( --cores "${SSD_CORES[0]:-2}" --pattern "$SSD_PCIE_PATTERN" ); fi
    ( cd "$REPO/utils" && sudo -n bash record-host-metrics.sh -f 0 --iio 0 --type 0 --cpu-util 0 --retx 0 --bw 0 \
          --pcie 1 --membw 0 --dur 10 --iommu-ops 0 "${dev[@]}" -o "$o" ) \
        > "$OUT/bg/$h/pcm-$n.out" 2>&1
    mkdir -p "$OUT/bg/$h/pcm"
    cp "$REPO/utils/reports/$o/pcie.rpt" "$OUT/bg/$h/pcm/$n.rpt" 2>/dev/null
}

# ------------------------------------------------------------------ the module (native half, icx)
bn_mod_load() {   # (re)load pips_bg_region on both devices (BN_D0, BN_D1); BN_B0/BN_B1
    local d="$OUT/bg/$BN_H" r
    if [ ! -e "$d/mod/pips_bg_region.ko" ]; then
        [ -d "/lib/modules/$(uname -r)/build" ] || { note "$BN_H: no kernel headers (/lib/modules/$(uname -r)/build): no region, no engine"; return 1; }
        mkdir -p "$d/mod" && cp "$HERE/ridcheck/pips_bg_region.c" "$HERE/ridcheck/Makefile" "$d/mod/"
        make -C "$d/mod" MODS=pips_bg_region > "$d/mod/build.txt" 2>&1 ||
            { note "$BN_H: pips_bg_region does not build ($d/mod/build.txt: $(tail -2 "$d/mod/build.txt" | tr '\n' ' '))"; return 1; }
    fi
    lsmod 2>/dev/null | grep -q '^pips_bg_region ' && sudo -n rmmod pips_bg_region
    if ! sudo -n insmod "$d/mod/pips_bg_region.ko" dev="$BN_D0,$BN_D1" npages=$BN_NPAGES backing=$BN_BK token="$STAMP" \
            2> "$d/insmod.txt"; then
        note "$BN_H: insmod pips_bg_region failed: $(cat "$d/insmod.txt") $(sudo -n dmesg | grep 'pips_bg_region' | tail -2 | tr '\n' ' ')"
        return 1
    fi
    r=$(sudo -n cat /sys/kernel/debug/pips_bg_region/regions 2>/dev/null)
    printf '%s\n' "$r" > "$d/regions.txt"
    BN_B0=$(printf '%s\n' "$r" | awk -v x="$BN_D0" '$2 == x && $12 == 1 { print $4 }')
    BN_B1=$(printf '%s\n' "$r" | awk -v x="$BN_D1" '$2 == x && $12 == 1 { print $4 }')
    [ -n "$BN_B0" ] && [ -n "$BN_B1" ] || { note "$BN_H: the module's regions are not as expected: $r"; return 1; }
    return 0
}
bn_mod_unload() { lsmod 2>/dev/null | grep -q '^pips_bg_region ' && sudo -n rmmod pips_bg_region; return 0; }

# ------------------------------------------------------------------ vfio: the holder's engine region
# bv_bgmap <ws> <stride> [backing]: the engine region in both drives' domains (flushes the old one)
BVN=0
bv_bgmap() {
    BVN=$((BVN + 1))
    local name="bg$STAMP-$BVN-$(date +%H%M%S)" bk=${3:-} prev cur n=0
    prev=$(cat "$HOLD_DIR/done" 2>/dev/null)
    echo "bgmap $name 3 $1 $2 base=$BV_BASE${bk:+ backing=$bk}" > "$HOLD_DIR/cmd.tmp" && mv "$HOLD_DIR/cmd.tmp" "$HOLD_DIR/cmd"
    while :; do
        cur=$(cat "$HOLD_DIR/done" 2>/dev/null)
        if [ "$cur" != "$prev" ]; then
            case "$cur" in
                *" $name ok"*) break ;;
                *bad-command*|*FAILED*) note "vfio: bgmap $1 $2 refused: $(grep 'bgmap\|not understood' "$HOLD_DIR/holder.txt" | tail -2 | tr '\n' ' ')"; return 1 ;;
            esac
        fi
        sleep 0.5; n=$((n + 1))
        [ $((n % 60)) = 0 ] && say "  ... waiting for the holder's bgmap ($((n / 2)) s)"
        [ "$n" -ge 600 ] && { note "vfio: the holder did not answer bgmap $1 $2 in 300 s"; return 1; }
    done
    BV_B0=$(awk '{ print $2 }' "$HOLD_DIR/bg-0" 2>/dev/null); BV_B1=$(awk '{ print $2 }' "$HOLD_DIR/bg-1" 2>/dev/null)
    [ -n "$BV_B0" ] && [ -n "$BV_B1" ]
}

# bg_flush <half>: the engine region's IOTLB entries gone (native, nic: reload the
# module; vfio: map the small region again: 65536 pages on 4096, BG_FLUSH_BK)
BG_FLUSH_BK=4096
bg_flush() { if [ "$1" != vfio ]; then bn_mod_load; else bv_bgmap 65536 1 "$BG_FLUSH_BK"; fi; }

# ------------------------------------------------------------------ the engine alone (devices idle)
# X2: reads/s and latency against MAX_OUT (interval 1), then against INTERVAL at MAX_OUT with pcm-iio.
bg_x2() {
    local h=$1 d="$OUT/bg/$1/x2" mo p pat iv pid bk base win
    mkdir -p "$d"
    if [ "$h" != vfio ]; then bk=$BN_BK; base=$BN_B0; win=$BN_WIN; mo=$BN_MO; else bk=$BV_BK; base=$BV_B0; win=$BV_WIN; mo=$BV_MO; fi
    local pats="hit miss deep"; [ "$h" = vfio ] && pats="hit miss deep2m"
    for p in $pats; do
        case "$p" in
            hit) pat="ws=8 stride=1 order=cyclic" ;;
            miss) pat="ws=65536 stride=1 order=random" ;;
            deep) pat="ws=128 stride=512 order=random" ;;
            deep2m) pat="ws=4096 stride=512 order=random" ;;
        esac
        for m in 1 2 4 8 16 32 64 "$mo"; do
            [ "$m" -le "$mo" ] || continue
            eng_run "$d/$p-mo$m.txt" rid=in0 base=$base backing=$bk tagwin=$win maxout=$m $pat interval=1 secs=4 || true
            eng_hist "$d/$p-mo$m-hist.txt"
            say "  x2 $h $p MAX_OUT $m: $(awk -v r="${ENG_RATE:-0}" 'BEGIN { printf "%.1f", r / 1e6 }') M reads/s, latency ${ENG_LAT:-?} ns"
            [ "$BG_DEAD" = 1 ] && return 1
        done
        for iv in 250 62 16 5 2 1; do
            ( pipsb bg run $BG_DEF rid=in0 base=$base backing=$bk tagwin=$win maxout=$mo $pat interval=$iv secs=25 beat=5 \
                  > "$d/$p-iv$iv.txt" 2>&1 ) & pid=$!
            sleep 3
            bg_pcm "x2-$p-iv$iv" "$h"
            wait "$pid"
            eng_hist "$d/$p-iv$iv-hist.txt"
            say "  x2 $h $p INTERVAL $iv: $(awk -v r="$(bgkv issue_rate_mrd_s "$d/$p-iv$iv.txt")" 'BEGIN { printf "%.1f", r / 1e6 }') M/s, latency $(bgkv lat_mean_ns "$d/$p-iv$iv.txt") ns; pcm: IOTLB misses/s $(awk '/^IOTLB_misses:/ { print $2 }' "$OUT/bg/$h/pcm/x2-$p-iv$iv.rpt" 2>/dev/null)"
        done
    done
}
# vfio: the deepest walk, pages 1 GiB apart (its own region), at MAX_OUT 1 and the most
bv_x2_deep1g() {
    local d="$OUT/bg/vfio/x2" m
    mkdir -p "$d"
    bv_bgmap 32 262144 || return 1
    for m in 1 "$BV_MO"; do
        eng_run "$d/deep1g-mo$m.txt" rid=in0 base=$BV_B0 backing=65536 tagwin=$BV_WIN maxout=$m ws=32 stride=262144 order=random interval=1 secs=4 || true
        eng_hist "$d/deep1g-mo$m-hist.txt"
        say "  x2 vfio deep1g MAX_OUT $m: $(awk -v r="${ENG_RATE:-0}" 'BEGIN { printf "%.1f", r / 1e6 }') M/s, latency ${ENG_LAT:-?} ns"
    done
}
# X1: the capacity knee by latency: ws N cyclic and random, one read at a time, the last 4096 reads traced
BG_X1_WS="16 32 48 64 80 96 112 128 144 160 192 224 256 320 384 512"
bg_x1() {
    local h=$1 d="$OUT/bg/$1/x1" o w bk win base
    mkdir -p "$d"
    for o in cyclic random; do
        for w in $BG_X1_WS; do
            bg_flush "$h" || return 1
            if [ "$h" != vfio ]; then bk=$BN_BK; base=$BN_B0; win=$BN_WIN; else bk=$BG_FLUSH_BK; base=$BV_B0; win=$BV_WIN; fi
            eng_run "$d/$o-w$w.txt" rid=in0 base=$base backing=$bk tagwin=$win maxout=1 ws=$w stride=1 order=$o \
                interval=0 count=$((30 * w + 4096)) trace=1 tskip=$((30 * w)) secs=30 || true
            pipsb bg trace "$d/$o-w$w.csv" 4096 > "$d/$o-w$w-trace.txt" 2>&1
            say "  x1 $h $o ws $w: latency mean ${ENG_LAT:-?} ns, trace p50 $(bgkv trace_lat_ns_p50 "$d/$o-w$w-trace.txt") p90 $(bgkv trace_lat_ns_p90 "$d/$o-w$w-trace.txt") ns"
            [ "$BG_DEAD" = 1 ] && return 1
        done
    done
}
# T8b, the replacement probe (vfio): after a flush, per table: 192 fresh pages
# (the IOTLB full), then rounds of P read k times (back to back, or each read
# d fresh pages apart), N fresh pages, P again (the probe: hit or miss by its
# latency). tables/<name>.txt + roles.tsv; one read at a time, traced.
bg_t8b_tables() {
    python3 - "$1" "$BG_T8B_MAX" <<'PYEOF'
import os, sys
d = sys.argv[1]
nmax = int(sys.argv[2])
os.makedirs(os.path.join(d, "tables"), exist_ok=True)
cfgs = []
for iv in (0, 2500):
    for k in (1, 2, 4, 8, 32):
        for n in (4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256):
            cfgs.append((k, 0, n, iv))
for k in (2, 4, 8):
    for dd in (4, 16, 64):
        for n in (16, 32, 64, 128, 256):
            cfgs.append((k, dd, n, 0))
if nmax and nmax < len(cfgs):
    cfgs = [cfgs[i * len(cfgs) // nmax] for i in range(nmax)]
roles = open(os.path.join(d, "roles.tsv"), "w")
roles.write("table\tk\td\tn\tinterval\tentry\trole\tround\tpage\n")
index = open(os.path.join(d, "index.tsv"), "w")
for (k, dd, n, iv) in cfgs:
    name = f"k{k}d{dd}n{n}i{iv}"
    nxt = 0
    ent = []
    def fresh(role, rnd):
        global nxt
        ent.append((nxt, role, rnd)); nxt += 1
    for _ in range(192):
        fresh("warm", -1)
    per = k + (k - 1) * dd + n + 1
    rounds = min(16, (4096 - 192) // per)
    for r in range(rounds):
        p = nxt; nxt += 1
        for j in range(k):
            ent.append((p, "prime", r))
            if j < k - 1:
                for _ in range(dd):
                    fresh("space", r)
        for _ in range(n):
            fresh("fresh", r)
        ent.append((p, "probe", r))
    with open(os.path.join(d, "tables", name + ".txt"), "w") as f:
        f.write("".join(f"{pg}\n" for pg, _, _ in ent))
    for i, (pg, role, r) in enumerate(ent):
        roles.write(f"{name}\t{k}\t{dd}\t{n}\t{iv}\t{i}\t{role}\t{r}\t{pg}\n")
    index.write(f"{name}\t{len(ent)}\t{iv}\n")
print(len(cfgs))
PYEOF
}
# bg_tables_run <half> <dir> <base> <backing> <win>: every table in <dir>/index.tsv,
# each after a flush, one read at a time, traced (T8b; the icx policy tables)
bg_tables_run() {
    local h=$1 d=$2 base=$3 bk=$4 win=$5 name n iv i=0 tot
    tot=$(grep -c . "$d/index.tsv")
    while IFS=$'\t' read -r -u 4 name n iv; do
        i=$((i + 1))
        bg_flush "$h" || return 1
        if [ "$h" = vfio ]; then base=$BV_B0; else base=$BN_B0; fi   # a remap may put the region elsewhere
        pipsb bg table load "$d/tables/$name.txt" > "$d/$name-load.txt" 2>&1 || { note "$h tables $name: table load failed"; continue; }
        eng_run "$d/$name.txt" rid=in0 base=$base backing=$bk tagwin=$win maxout=1 src=table ws=$n count=$n \
            interval=$iv trace=1 tskip=0 secs=30 || true
        pipsb bg trace "$d/$name.csv" 4096 > "$d/$name-trace.txt" 2>&1
        [ $((i % 20)) = 0 ] && say "  tables: $i of $tot done"
        [ "$BG_DEAD" = 1 ] && return 1
    done 4< "$d/index.tsv"
    say "  tables: $i done (traces in $d/*.csv, roles.tsv says which read is which)"
}
bv_t8b() {
    local d="$OUT/bg/vfio/t8b" tot
    mkdir -p "$d"
    tot=$(bg_t8b_tables "$d") || { note "vfio: T8b tables not made"; return 1; }
    say "  T8b: $tot tables (192 warm pages; P read k times, N fresh, P probed; one read at a time)"
    bg_tables_run vfio "$d" "$BV_B0" "$BG_FLUSH_BK" "$BV_WIN"
}
# icx: the replacement policy of the 32 x 8 IOTLB (alias campaign 2 item 3: LRU,
# tree-PLRU or FIFO), every read in one set (region pages SET + 32 j), traced:
#   fA/fB/fE  A..H fresh (fills the set), A again, I fresh, then one probe:
#             A (FIFO misses), B (LRU misses), E (tree-PLRU misses); repeated
#             with fresh pages
#   u<P>s<S>  uniform random reads over a pool of P pages in the set
#   h6f<K>    6 hot pages cyclic, a fresh page every K reads (scan pressure)
# roles.tsv names each read; the analysis replays them through each policy.
bg_irepl_tables() {
    python3 - "$1" "$BG_IREPL_MAX" <<'PYEOF'
import os, random, sys
d, nmax = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.join(d, "tables"), exist_ok=True)
SET, NJ = 5, 2048                       # set 5 of 32; region pages SET + 32 j, j < 2048
pg = lambda j: SET + 32 * j
tabs = []
for probe in "ABE":
    ent, j = [], 0
    while j + 9 <= NJ and len(ent) + 11 <= 4096:
        p = {c: pg(j + i) for i, c in enumerate("ABCDEFGHI")}; j += 9
        ent += [(p[c], "fill") for c in "ABCDEFGH"] + [(p["A"], "touch"), (p["I"], "insert"), (p[probe], "probe")]
    tabs.append((f"f{probe}", ent))
for pool in (9, 10, 12, 16):
    for seed in (1, 2):
        r = random.Random(1000 * pool + seed)
        ent = [(pg(i), "warm") for i in range(pool)]
        ent += [(pg(r.randrange(pool)), "rand") for _ in range(4096 - pool)]
        tabs.append((f"u{pool}s{seed}", ent))
for k in (1, 2, 3):
    ent, nxt, t = [], 6, 0
    while len(ent) < 4096 and nxt < NJ:
        ent.append((pg(t % 6), "hot")); t += 1
        if t % k == 0 and len(ent) < 4096:
            ent.append((pg(nxt), "fresh")); nxt += 1
    tabs.append((f"h6f{k}", ent))
if nmax and nmax < len(tabs):
    tabs = [tabs[i * len(tabs) // nmax] for i in range(nmax)]
roles = open(os.path.join(d, "roles.tsv"), "w")
roles.write("table\tentry\trole\tpage\n")
index = open(os.path.join(d, "index.tsv"), "w")
for name, ent in tabs:
    with open(os.path.join(d, "tables", name + ".txt"), "w") as f:
        f.write("".join(f"{p}\n" for p, _ in ent))
    for i, (p, role) in enumerate(ent):
        roles.write(f"{name}\t{i}\t{role}\t{p}\n")
    index.write(f"{name}\t{len(ent)}\t0\n")
print(len(tabs))
PYEOF
}
bi_repl() {
    local d="$OUT/bg/nic/repl" tot
    mkdir -p "$d"
    tot=$(bg_irepl_tables "$d") || { note "icx: replacement tables not made"; return 1; }
    say "  replacement policy: $tot tables in one set (fill/touch/insert/probe; random pools; hot + fresh)"
    bg_tables_run nic "$d" "$BN_B0" "$BN_BK" "$BN_WIN"
}

# ------------------------------------------------------------------ the phases
bg_dry_init() {   # the dry run's specs: placeholders for what the prep phases find
    BN_B0='<n-region0>'; BN_B1='<n-region1>'; BN_WIN='<win>'; BN_MO='<mo>'; BN_WIND='<deep-win>'; BN_MOD='<deep-mo>'
    BV_B0='<v-region0>'; BV_B1='<v-region1>'; BV_WIN='<win>'; BV_MO='<mo>'
}
bg_phases() {
    if [ "$KIND" = ssd ]; then echo "nprep nalone nstress nseq nheavy ncross ndeep nend vprep valone vstress vcross"
    else echo "iprep ialone irepl itcp irdma icross iend"; fi
}
nw() { echo $#; }
# icx's iperf3 runs take ~2.6 min, its alias runs ~1.6 (MIN_PER_PT): TCP runs count 13/8
bg_nsweeps() {   # <phase>: runs (each sweep adds its datapath run) or minutes / MIN_PER_PT for the steps
    local s=$(( $(nw $BG_SETS) * $(nw $BG_PBS) ))
    case "$1" in
        nprep) echo 5 ;;
        nalone) echo $(( 10 + $(nw $BG_X1_WS) )) ;;
        nstress) echo $(( $(nw $BG_LEVELS) * (s * 2 * $(nw $BG_NBS) * RUNS + 1) )) ;;
        nseq) echo $(( $(nw $BG_SEQ_LEVELS) * (s * 2 * $(nw $BG_SEQ_BS) * RUNS + 1) )) ;;
        nheavy) echo $(( $(nw $BG_HEAVY_LEVELS) * (s * $(nw $BG_HBS) * RUNS + 1) )) ;;
        ncross) echo $(( $(nw $BG_CROSS_N_LEVELS) * (s * 2 * $(nw $BG_XBS) + 1) )) ;;
        ndeep) echo $(( 2 + $(nw $BG_DEEP_QD) * $(nw $BG_DEEP_LEVELS) * (s * 2 * $(nw $BG_DEEP_BS) * RUNS + 1) )) ;;
        nend) echo 0 ;;
        vprep) echo 5 ;;
        valone) echo $(( 12 + $(nw $BG_X1_WS) + ${BG_T8B_MAX/#0/155} / 8 )) ;;
        vstress) echo $(( $(nw $BG_LEVELS) * $(nw $BG_VPATS) * (s * 2 * RUNS + 1) )) ;;
        vcross) echo $(( $(nw $BG_CROSS_V_LEVELS) * $(nw $BG_VPATS | awk '{ print ($1 < 2 ? $1 : 2) }') * (s * 2 + 1) )) ;;
        iprep) echo 5 ;;
        ialone) echo $(( 10 + $(nw $BG_X1_WS) )) ;;
        irepl) echo 4 ;;
        itcp) echo $(( $(nw $BG_ILEVELS) * (s * 2 * $(nw $BG_IFLOWS) * RUNS + 1) * 13 / 8 )) ;;
        irdma) echo $(( $(nw $BG_ILEVELS) * $(nw $BG_IPATS) * (s * 2 * RUNS + 1) )) ;;
        icross) echo $(( $(nw $BG_ICROSS_LEVELS) * $(nw $(echo $BG_IPATS | tr ' ' '\n' | grep -v t)) * (s * 2 + 1) )) ;;
        iend) echo 0 ;;
        *) echo 0 ;;
    esac
}
bg_describe() {
    case "$1" in
        nprep)   echo "native (drives on nvme, IOMMU as booted): pips_bg_region.ko maps 256 MiB in each drive's DMA domain; 64-read data check through in0/in1; tag census under fio (16 x 4k, 4 x 1m, 4 x 4k sequential) -> the engine's tag window and MAX_OUT" ;;
        nalone)  echo "native, the engine alone: reads/s and latency against MAX_OUT and INTERVAL (hits, one-shot misses, 2 MiB apart; pcm-iio); the capacity knee by latency (ws 16-512, cyclic and random)" ;;
        nstress) echo "native: fio random reads $BG_NBS x 4 per drive, drive 0 alone and both, d1t0c1/d16t218c1 x pb $BG_PBS, $RUNS run(s); engine levels $BG_LEVELS (one sweep each, light to heavy)" ;;
        nseq)    echo "native: fio SEQUENTIAL reads (--rw read, each instance its own slice) $BG_SEQ_BS x 4 per drive, drive 0 alone and both, same settings, $RUNS run(s); levels $BG_SEQ_LEVELS" ;;
        nheavy)  echo "native: fio $BG_HBS x 16 per drive, both; levels $BG_HEAVY_LEVELS" ;;
        ncross)  echo "native: the engine in drive 1's domain (in1), fio $BG_XBS x 4, drive 0 alone and both; levels $BG_CROSS_N_LEVELS, 1 run" ;;
        ndeep)   echo "native: DEEPER QUEUES: tag census under them (own tag window), then fio random reads $BG_DEEP_BS x 4 per drive at iodepth $BG_DEEP_QD (32 elsewhere), drive 0 alone and both, same settings, $RUNS run(s); levels $BG_DEEP_LEVELS" ;;
        nend)    echo "native: unload the module (the region unmapped)" ;;
        vprep)   echo "vfio: bind both drives, one alias-nvme --hold (as the alias campaigns; the BMC guard armed), the engine's own region (bgmap, 8 GiB of IOVA), data check, tag census under alias loads" ;;
        valone)  echo "vfio, the engine alone: the capacity knee (ws 16-512), T8b replacement probe (${BG_T8B_MAX/#0/155} tables), reads/s and latency (hits, misses, 2 MiB and 1 GiB apart; pcm-iio)" ;;
        vstress) echo "vfio: alias 4k x 4 queues, patterns $(for p in $BG_VPATS; do printf '%s; ' "$(bg_vpat_what "$p")"; done)drive 0 alone and both, d1t0c1/d16t218c1 x pb $BG_PBS, $RUNS run(s); engine levels $BG_LEVELS" ;;
        vcross)  echo "vfio: the engine in drive 1's domain (in1) while drive 0 runs alone (and both), patterns $(for p in $(echo $BG_VPATS | tr ' ' '
' | grep -v t); do printf '%s; ' "$(bg_vpat_what "$p")"; done)levels $BG_CROSS_V_LEVELS, 1 run" ;;
        iprep)   echo "icx (NICs on mlx5, IOMMU as booted): pips_bg_region.ko maps 256 MiB in each NIC's DMA domain; 64-read data check through in0/in1; tag census under iperf3 (30 flows) and alias-rdma (32 QPs) on both NICs -> tag window and MAX_OUT" ;;
        ialone)  echo "icx, the engine alone: reads/s and latency against MAX_OUT and INTERVAL (hits, one-shot misses, one set; pcm-iio); the capacity knee by latency (ws 16-512)" ;;
        irepl)   echo "icx, the engine alone: the IOTLB's replacement policy (LRU, tree-PLRU, FIFO), ${BG_IREPL_MAX/#0/14} traced tables in one set" ;;
        itcp)    echo "icx: iperf3 TCP (map/unmap per packet), $BG_IFLOWS flows per NIC, NIC0 alone and both, uncapped, d1t0c1/d16t218c1 x pb $BG_PBS, $RUNS run(s); engine levels $BG_ILEVELS" ;;
        irdma)   echo "icx: alias-rdma READs into a static MR, patterns $(for p in $BG_IPATS; do bg_ipat "$p"; printf '%s: %s; ' "$p" "$IP_WHAT"; done)NIC0 alone and both, same settings, $RUNS run(s); levels $BG_ILEVELS" ;;
        icross)  echo "icx: the engine in NIC 1's domain (in1), alias patterns $(echo $BG_IPATS | tr ' ' '\n' | grep -v t | xargs), NIC0 alone and both; levels $BG_ICROSS_LEVELS, 1 run" ;;
        iend)    echo "icx: unload the module (the region unmapped)" ;;
    esac
}
bg_levels_line() {
    local lv h=native; [ "$KIND" = nic ] && h=nic
    for lv in $( [ "$KIND" = nic ] && echo "$BG_ILEVELS" || echo "$BG_LEVELS"); do bg_level "$lv" "$h"; printf '    %-4s %s\n' "$lv" "$LV_WHAT"; done
}

# bg_sweeps <half> <prefix> <rid> <levels> <grid...>: one sweep per level (per
# pattern: vfio BG_VPATS, icx alias BG_IPATS, whose QPs replace @QPS@ in the
# grid). The engine-off sweeps run even when the half has no usable engine.
bg_sweeps() {
    local h=$1 pre=$2 rid=$3 levels=$4 lv p pats="-" ok=1 why=""; shift 4
    [ "$h" = vfio ] && [ "$pre" != bvh ] && pats=$BG_VPATS
    [ "$pre" = bvx ] && pats=$(echo $BG_VPATS | tr ' ' '\n' | grep -v t | xargs)
    [ "$pre" = bir ] && pats=$BG_IPATS
    [ "$pre" = bix ] && pats=$(echo $BG_IPATS | tr ' ' '\n' | grep -v t | xargs)
    export PIPS_BG_STOPFILE="$OUT/bg/stop-$h"
    if [ "$DRY" = 0 ]; then
        if [ "$h" != vfio ] && [ "$BN_OK" != 1 ]; then ok=0; why="no usable engine in the $h half"; fi
        if [ "$h" = vfio ] && [ "$BV_OK" != 1 ]; then ok=0; why="no usable engine in the vfio half"; fi
        if [ "$BG_DEEPWIN" = 1 ] && [ -z "$BN_WIND" ]; then ok=0; why="no tag window for the deep queues (census-deep)"; fi
    fi
    for lv in $levels; do
        for p in $pats; do
            if [ "$lv" != off ]; then
                if [ "$ok" = 0 ]; then note "sweep $pre$lv${p#-} not run: $why"; continue; fi
                if [ "$DRY" = 0 ] && [ "$BG_DEAD" = 1 ]; then note "sweep $pre$lv${p#-} not run: the engine is stopped for good"; continue; fi
                if [ "$DRY" = 0 ] && [ -e "$PIPS_BG_STOPFILE" ]; then note "sweep $pre$lv${p#-} not run: the engine was stopped in this half ($(head -1 "$PIPS_BG_STOPFILE"))"; continue; fi
                export PIPS_BG="$(bg_spec "$lv" "$h" "$rid")" PIPS_BG_LABEL="$lv${rid/in0/}"
            else
                unset PIPS_BG; export PIPS_BG_LABEL=off
            fi
            if [ "$h" = native ] && [ "$BN_STOP" = 1 ]; then note "sweep $pre$lv not run: the native half was ended (soft lockups)"; unset PIPS_BG; return 0; fi
            [ "$DRY" = 1 ] && echo "    PIPS_BG_LABEL=$PIPS_BG_LABEL PIPS_BG=\"${PIPS_BG:-}\""
            local g=("$@")
            RUNNER_EXTRA=$BG_NEXTRA
            if [ "$h" = vfio ] && [ "$p" != - ]; then RUNNER_EXTRA=$(bg_vpat "$p")
            elif [ "$h" = nic ] && [ "$p" != - ]; then bg_ipat "$p"; RUNNER_EXTRA=$IP_EXTRA; g=("${@//@QPS@/$IP_QPS}"); fi
            sweep_run "$pre$lv${p#-}" --cfgs "$BG_SETS" --caps 1 --pbs "$BG_PBS" --set "$BG_THR" "${g[@]}" </dev/null
            RUNNER_EXTRA=""
            if [ -e "$PIPS_BG_STOPFILE" ] && [ ! -e "$OUT/bg/.noted-stop-$h" ]; then
                touch "$OUT/bg/.noted-stop-$h"
                note "the read engine was stopped in the $h half during $pre$lv${p#-}: $(head -2 "$PIPS_BG_STOPFILE" | tr '\n' ' ')"
            fi
        done
    done
    unset PIPS_BG; export PIPS_BG_LABEL=off
}

bg_phase() {
    local p=$1 qd
    case "$p" in
        n*) if [ "$DRY" = 0 ] && step_done native-done; then say "$p: the native half finished before (resumed): skipped"; return 0; fi
            if [ "$DRY" = 0 ] && [ "$BG_HELD" = 1 ]; then note "$p not run: the drives are held by alias-nvme (the vfio half started): the native half can't run in this boot"; return 0; fi
            case "$p" in nprep|nalone) if [ "$DRY" = 0 ] && [ "$BG_DEAD" = 1 ]; then note "$p not run: the engine is stopped for good"; return 0; fi ;; esac ;;
        iprep|ialone|irepl)
            if [ "$DRY" = 0 ] && [ "$BG_DEAD" = 1 ]; then note "$p not run: the engine is stopped for good"; return 0; fi ;;
    esac
    case "$p" in
        nprep)
            if [ "$DRY" = 1 ]; then echo "    bash: insmod ridcheck/pips_bg_region.ko (both drives), data check in0/in1, census (3 fio runs)"; return 0; fi
            BN_D0=$(bg_nvme_bdf "${SSD_SERIALS[0]}"); BN_D1=$(bg_nvme_bdf "${SSD_SERIALS[1]}")
            [ -n "$BN_D0" ] && [ -n "$BN_D1" ] || { note "native: a drive is not on nvme ($BN_D0/$BN_D1): native half skipped"; BN_OK=0; return 0; }
            say "native: drives $BN_D0, $BN_D1 on nvme; IOMMU $(bash "$HERE/pips-iommu.sh" mode 2>/dev/null | tail -1)"
            BN_OK=0
            bn_mod_load || { bg_env_save native; return 0; }
            say "  region: drive 0 IOVA $BN_B0, drive 1 IOVA $BN_B1 ($BN_NPAGES pages each, backing $BN_BK)"
            bg_check_read "$OUT/bg/native" native || { note "native: the data check failed: no engine in the native half"; bg_env_save native; return 0; }
            if step_done ncensus && [ -n "$BN_WIN" ]; then say "  census from before: tags $BN_WIN, MAX_OUT $BN_MO"
            else bg_census native || { bg_env_save native; return 0; }; step_mark ncensus; fi
            BN_OK=1; bg_env_save native ;;
        nalone)
            if [ "$DRY" = 1 ]; then echo "    the engine alone: x2 (MAX_OUT 1-128, INTERVAL 250-1 with pcm-iio), x1 (ws $BG_X1_WS; module reloaded per point)"; return 0; fi
            step_done nalone && { say "nalone: done before: skipped"; return 0; }
            [ "$BN_OK" = 1 ] || { note "nalone not run: no usable engine in the native half"; return 0; }
            bg_x2 native; bg_x1 native
            bn_mod_load || { BN_OK=0; note "native: the module did not load again after x1: no engine for the stress phases"; }
            bg_env_save native
            say "  region again: drive 0 IOVA $BN_B0, drive 1 $BN_B1"
            step_mark nalone ;;
        nstress) LOCKUP_SOFT=1; bg_sweeps native bn in0 "$BG_LEVELS" --single --no-asy "$BG_NBS" "4" "$RUNS"; LOCKUP_SOFT=0 ;;
        nseq)    LOCKUP_SOFT=1; BG_NEXTRA="--rw read"; bg_sweeps native bns in0 "$BG_SEQ_LEVELS" --single --no-asy "$BG_SEQ_BS" "4" "$RUNS"
                 BG_NEXTRA=""; LOCKUP_SOFT=0 ;;
        nheavy)  LOCKUP_SOFT=1; bg_sweeps native bnh in0 "$BG_HEAVY_LEVELS" --no-asy "$BG_HBS" "16" "$RUNS"; LOCKUP_SOFT=0 ;;
        ncross)  LOCKUP_SOFT=1; bg_sweeps native bnx in1 "$BG_CROSS_N_LEVELS" --single --no-asy "$BG_XBS" "4" 1; LOCKUP_SOFT=0 ;;
        ndeep)
            if [ "$DRY" = 1 ]; then echo "    bash: census under 4 x qd $(echo $BG_DEEP_QD | tr ' ' '\n' | sort -n | tail -1) (random, sequential) -> the deep window"
            elif [ "$BN_OK" = 1 ] && [ "$BG_DEAD" = 0 ]; then
                if step_done ndcensus; then say "  deep census from before: tags ${BN_WIND:-none}, MAX_OUT ${BN_MOD:-none}"
                else BN_WIND=""; BN_MOD=""; bg_census native deep || true; bg_env_save native; step_mark ndcensus; fi
            fi
            LOCKUP_SOFT=1; BG_DEEPWIN=1
            for qd in $BG_DEEP_QD; do
                BG_NEXTRA="--iodepth $qd"
                bg_sweeps native "bnq$qd" in0 "$BG_DEEP_LEVELS" --single --no-asy "$BG_DEEP_BS" "4" "$RUNS"
            done
            BG_NEXTRA=""; BG_DEEPWIN=0; LOCKUP_SOFT=0 ;;
        nend)
            if [ "$DRY" = 1 ]; then echo "    rmmod pips_bg_region"; return 0; fi
            bn_mod_unload; step_mark native-done; say "native half done: module unloaded" ;;
        vprep)
            if [ "$DRY" = 1 ]; then echo "    hold_up (bind both drives, alias-nvme --hold), guard arm, bgmap $BV_WS 1 (8 GiB), data check, census (2 alias runs)"; return 0; fi
            [ "$BG_DEAD" = 1 ] && { note "vfio half not run: the engine is stopped for good (no holder, no reboot needed)"; BV_OK=0; return 0; }
            bn_mod_unload
            if [ "$BG_HELD" = 0 ]; then
                say "vfio half: the drives go to vfio-pci and stay there until the reboot at the end"
                bash "$REPO/scripts/pips/alias/alias-vfio.sh" status > "$OUT/alias-vfio-at-start.txt" 2>&1
                hold_up || { note "vfio: the holder did not come up: vfio half skipped"; BV_OK=0; return 0; }
                BG_HELD=1
                guard arm "$OUT/guard" "$HOLD_DIR" 120 || { note "vfio: the BMC guard did not arm: vfio half skipped (the holder keeps the drives: the reboot at the end releases them)"; BV_OK=0; return 0; }
            else
                say "vfio half: the holder from before is up ($(cat "$HOLD_DIR/state"))"
            fi
            export ALIAS_HOLD=$HOLD_DIR
            grep -q 'bgmap' "$HOLD_DIR/state" || { note "vfio: the holder has no bgmap (state: $(cat "$HOLD_DIR/state")): vfio engine phases skipped"; BV_OK=0; return 0; }
            BV_OK=0
            bv_bgmap "$BV_WS" 1 || { bg_env_save vfio; return 0; }
            say "  engine region: drive 0 IOVA $BV_B0, drive 1 $BV_B1 ($BV_WS pages, backing $BV_BK)"
            bg_check_read "$OUT/bg/vfio" vfio || { note "vfio: the data check failed: no engine in the vfio half"; bg_env_save vfio; return 0; }
            if step_done vcensus && [ -n "$BV_WIN" ]; then say "  census from before: tags $BV_WIN, MAX_OUT $BV_MO"
            else bg_census vfio || { bg_env_save vfio; return 0; }; step_mark vcensus; fi
            BV_OK=1; bg_env_save vfio ;;
        valone)
            if [ "$DRY" = 1 ]; then echo "    the engine alone: drive regions flushed (hold map), x1 (ws $BG_X1_WS, region remapped per point), T8b tables, x2 deep1g, then bgmap $BV_WS 1 and x2 (hit, miss, deep2m)"; return 0; fi
            step_done valone && { say "valone: done before: skipped"; return 0; }
            [ "$BV_OK" = 1 ] || { note "valone not run: no usable engine in the vfio half"; return 0; }
            bv_flush_data
            bg_x1 vfio; bv_t8b; bv_x2_deep1g
            bv_bgmap "$BV_WS" 1 || { BV_OK=0; note "vfio: the stress region did not map again: no engine for the stress phases"; bg_env_save vfio; return 0; }
            bg_x2 vfio
            bg_env_save vfio
            step_mark valone ;;
        vstress) bg_sweeps vfio bv in0 "$BG_LEVELS" --single --no-asy "4k" "4" "$RUNS" ;;
        vcross)  bg_sweeps vfio bvx in1 "$BG_CROSS_V_LEVELS" --single --no-asy "4k" "4" 1 ;;
        iprep)
            if [ "$DRY" = 1 ]; then echo "    bash: insmod ridcheck/pips_bg_region.ko (in0's and in1's NICs), data check in0/in1, census (iperf3 30 flows, alias-rdma 32 QPs)"; return 0; fi
            bi_devices || { BN_OK=0; bg_env_save nic; return 0; }
            say "icx: in0's NIC $BN_D0, in1's NIC $BN_D1 on mlx5; IOMMU $(bash "$HERE/pips-iommu.sh" mode 2>/dev/null | tail -1)"
            BN_OK=0
            bn_mod_load || { bg_env_save nic; return 0; }
            say "  region: NIC 0 IOVA $BN_B0, NIC 1 IOVA $BN_B1 ($BN_NPAGES pages each, backing $BN_BK)"
            bg_check_read "$OUT/bg/nic" nic || { note "icx: the data check failed: no engine"; bg_env_save nic; return 0; }
            if step_done icensus && [ -n "$BN_WIN" ]; then say "  census from before: tags $BN_WIN, MAX_OUT $BN_MO"
            else bg_census nic || { bg_env_save nic; return 0; }; step_mark icensus; fi
            BN_OK=1; bg_env_save nic ;;
        ialone)
            if [ "$DRY" = 1 ]; then echo "    the engine alone: x2 (MAX_OUT 1-128, INTERVAL 250-1 with pcm-iio), x1 (ws $BG_X1_WS; module reloaded per point)"; return 0; fi
            step_done ialone && { say "ialone: done before: skipped"; return 0; }
            [ "$BN_OK" = 1 ] || { note "ialone not run: no usable engine"; return 0; }
            bg_x2 nic; bg_x1 nic
            bn_mod_load || { BN_OK=0; note "icx: the module did not load again after x1: no engine for the stress phases"; }
            bg_env_save nic; step_mark ialone ;;
        irepl)
            if [ "$DRY" = 1 ]; then echo "    the engine alone: replacement tables (one set, traced; module reloaded per table)"; return 0; fi
            step_done irepl && { say "irepl: done before: skipped"; return 0; }
            [ "$BN_OK" = 1 ] || { note "irepl not run: no usable engine"; return 0; }
            bi_repl
            bn_mod_load || { BN_OK=0; note "icx: the module did not load again after the tables: no engine for the stress phases"; }
            bg_env_save nic
            say "  region again: NIC 0 IOVA $BN_B0, NIC 1 $BN_B1"
            step_mark irepl ;;
        itcp)    bg_sweeps nic bit in0 "$BG_ILEVELS" --modes "nic0only both" "$BG_IFLOWS" uncapped "$RUNS" ;;
        irdma)   bg_sweeps nic bir in0 "$BG_ILEVELS" --modes "nic0only both" "@QPS@" uncapped "$RUNS" ;;
        icross)  bg_sweeps nic bix in1 "$BG_ICROSS_LEVELS" --modes "nic0only both" "@QPS@" uncapped 1 ;;
        iend)
            if [ "$DRY" = 1 ]; then echo "    rmmod pips_bg_region"; return 0; fi
            bn_mod_unload; step_mark nic-done; say "icx: module unloaded" ;;
    esac
}
# icx: the devices below in0's and in1's ports (as pips-rid-live.sh): BN_D0, BN_D1
bi_devices() {
    local sec n0
    pipsb bg info > "$OUT/bg/nic/bg-info.txt" 2>&1
    sec=$(bgkv bus_secondary "$OUT/bg/nic/bg-info.txt")
    [ -n "$sec" ] || { note "icx: pips bg info gives no bus_secondary: no engine"; return 1; }
    BN_D0=$(printf '0000:%02x:00.0' $(( sec + 1 ))); BN_D1=$(printf '0000:%02x:00.0' $(( sec + 2 )))
    for n0 in "$BN_D0" "$BN_D1"; do
        case "$(cat "/sys/bus/pci/devices/$n0/class" 2>/dev/null)" in
            0x02*) ;;
            *) note "icx: $n0 (below a PIPS port) is not a network function: no engine"; return 1 ;;
        esac
    done
    n0=$(basename "$(readlink -f "/sys/class/net/${SERVER_INTFS[0]}/device" 2>/dev/null)")
    [ "$n0" = "$BN_D0" ] || note "icx: NIC 0 (${SERVER_INTFS[0]} = $n0) is not in0's device $BN_D0: 'in0' in the results means $BN_D0's domain"
    return 0
}
# the drives' own regions mapped again (their IOTLB entries flushed) before the engine-alone tests
bv_flush_data() {
    local name="bgfl$STAMP-$(date +%H%M%S)" n=0
    echo "map $name 3 8 1 cyclic" > "$HOLD_DIR/cmd.tmp" && mv "$HOLD_DIR/cmd.tmp" "$HOLD_DIR/cmd"
    until [ "$(awk '{ print $2 }' "$HOLD_DIR/done" 2>/dev/null)" = "$name" ]; do
        sleep 0.5; n=$((n + 1)); [ "$n" -ge 240 ] && { note "vfio: the holder did not answer map (flush) in 120 s"; return 1; }
    done
    say "  the drives' own regions mapped again (ws 8): their IOTLB entries flushed"
}
