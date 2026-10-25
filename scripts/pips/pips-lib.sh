# Helpers shared by pips-bringup.sh, pips-fio-log.sh, the dual-SSD and
# dual-NIC runners and their PIPS sweeps. Sourced, not run. Safe under `set -u`.

PIPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPS_REPO=$(cd "$PIPS_DIR/../.." && pwd)
PIPS="${PIPS_TOOL:-$PIPS_DIR/pips}"     # PIPS_TOOL: use another binary (e.g. pips-sim)

die() { echo "ERROR: $*" >&2; exit 1; }

# Build the pips tool if it is missing or older than its sources.
pips_build() {
    [ -n "${PIPS_TOOL:-}" ] && return 0
    if [ ! -x "$PIPS" ] || [ "$PIPS_DIR/pips.c" -nt "$PIPS" ] || [ "$PIPS_DIR/pips_regs.h" -nt "$PIPS" ]; then
        echo "building $PIPS"
        make -s -C "$PIPS_DIR" pips || return 1
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$PIPS"
    fi
    return 0
}

# BDF of the PIPS upstream port (10ee:b048). Fails if there is none or several.
pips_find_usp() {
    local d found=()
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10ee ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = 0xb048 ] && found+=( "$(basename "$d")" )
    done
    if [ ${#found[@]} -eq 1 ]; then echo "${found[0]}"; return 0; fi
    if [ ${#found[@]} -eq 0 ]; then
        echo "ERROR: no PIPS upstream port (10ee:b048). FPGA not programmed, or not rescanned:" >&2
        echo "  echo 1 | sudo tee /sys/bus/pci/rescan;  lspci -nn -d 10ee:" >&2
    else
        echo "ERROR: several PIPS upstream ports (${found[*]}): pick one with --bdf" >&2
    fi
    return 1
}

# Every PCI function below the upstream port, in BDF order (ports before devices).
pips_below() {
    local d
    for d in /sys/bus/pci/devices/*; do
        case "$(readlink -f "$d")" in */"$1"/*) basename "$d" ;; esac
    done | sort
}

# /dev/nvmeXnY namespaces whose controller sits below the upstream port.
# Under native NVMe multipath the disk hangs off nvme-subsystem; follow a path.
pips_nvme_below() {
    local b n p m
    for b in /sys/class/block/nvme*n*; do
        [ -e "$b" ] || continue
        n=$(basename "$b")
        [[ $n =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        p=$(readlink -f "$b")
        case "$p" in
            */nvme-subsystem/*) for m in "$b/multipath/"*; do p=$(readlink -f "$m"); break; done ;;
        esac
        case "$p" in */"$1"/*) echo "/dev/$n" ;; esac
    done
}

# PCI function a block device's controller is, e.g. 0000:99:00.0 for nvme0n1.
blk_bdf() {
    local n p m
    n=$(basename "$1")
    p=$(readlink -f "/sys/class/block/$n" 2>/dev/null)
    case "$p" in
        */nvme-subsystem/*) for m in "/sys/class/block/$n/multipath/"*; do p=$(readlink -f "$m"); break; done ;;
    esac
    printf '%s' "$p" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1
}

# One line from `lspci -vv` of a function: link (and its capability), MPS/MRRS
# in use, and error bits that are set. Needs root for the capabilities.
#
# A link trains to the lower of its two ends, so it is DEGRADED only when it
# is below what both ends can do: a Gen4 switch port on a Gen3 root port, or
# an x8 port with an x4 drive, is normal. Error bits are sticky: set at any
# time since boot or since software last cleared them, not necessarily now.
lspci_brief() {
    local partner pcap=""
    partner=$(link_partner "$1")
    [ -n "$partner" ] && pcap=$(lspci -vv -s "$partner" 2>/dev/null | awk "$LSPCI_LINK_AWK"'
        /LnkCap:/ { print grab($0); exit }')
    lspci -vv -s "$1" 2>/dev/null | awk -v pcap="$pcap" "$LSPCI_LINK_AWK"'
        function num(s) { gsub(/[^0-9.]/, "", s); return s + 0 }
        /LnkCap:/ { cap = grab($0) }
        /LnkSta:/ { sta = grab($0) }
        /^[ \t]+MaxPayload [0-9]+ bytes, MaxReadReq/ { mps = $2; mrrs = $5 }
        /DevSta:|UESta:|CESta:/ { tag = $1; for (i = 2; i <= NF; i++)
            if ($i ~ /\+$/ && $i !~ /^(AuxPwr|TransPend)/) err = err " " tag $i }
        END {
            if (sta == "") printf "link ?"
            else {
                split(sta, a, " "); split(cap, c, " "); ms = num(c[1]); mw = num(c[2])
                if (pcap != "") { split(pcap, p, " ")
                    if (num(p[1]) < ms) ms = num(p[1]); if (num(p[2]) < mw) mw = num(p[2]) }
                printf "link %s", sta
                if (num(a[1]) < ms || num(a[2]) < mw)
                    printf " DEGRADED: both ends can do %gGT/s x%d", ms, mw
                else if (sta != cap)
                    printf " (this end can do %s%s)", cap, pcap != "" ? ", the other end cannot" : ""
            }
            printf "  MPS %s MRRS %s", mps == "" ? "?" : mps, mrrs == "" ? "?" : mrrs
            printf "  error bits (sticky):%s\n", err == "" ? " none" : err
        }'
}
LSPCI_LINK_AWK='
    function grab(line,   i, n, f, s, w) { n = split(line, f, /[ \t,]+/)
        for (i = 1; i < n; i++) { if (f[i] == "Speed") s = f[i+1]; if (f[i] == "Width") w = f[i+1] }
        return s " " w }'

# The function at the other end of a function's link: below a root or
# downstream port, the device on its secondary bus; above anything else, the
# port it hangs off. Empty if there is none or lspci cannot tell (not root).
link_partner() {
    local d
    case "$(lspci -vv -s "$1" 2>/dev/null | grep -oE 'Express \(v[0-9]\) [A-Za-z ]+' | head -1)" in
        *"Root Port"*|*"Downstream Port"*)
            for d in /sys/bus/pci/devices/"$1"/????:??:??.0; do
                [ -e "$d" ] && { basename "$d"; return 0; }
            done ;;
        *)
            d=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")")
            [[ $d =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] && echo "$d" ;;
    esac
    return 0
}

# Batcher setting from `pips cfg`: cfg_of <file> -> 0x..., cap_of <file> ->
# drain_depth_cap (0 when the build has no drain register), pips_tag <cfg>
# [cap] -> d<depth>t<time>, plus m1 with batch_mrd and c1 with the drain cap
# (names results and sweeps; no c1 = whole-FIFO drains, as every build before
# design 0x0a03 did).
cfg_of() { sed -n 's/^cfg=\(0x[0-9a-f]*\).*/\1/p' "$1"; }
cap_of() { local c; c=$(sed -n 's/.*drain_depth_cap=\([01]\).*/\1/p' "$1" | head -1); echo "${c:-0}"; }
# The page batcher fields (design 0x0a06 on; 0 0 0 0 0 before): pb_of <file> ->
# "<page_batch_en> <ctrl_push_off> <grant_quantum> <ctrl_dw_thr_0> <ctrl_dw_thr_1>".
pb_of() {
    awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] } }
         END { printf "%d %d %d %d %d\n", v["page_batch_en"], v["ctrl_push_off"], v["grant_quantum"],
               v["ctrl_dw_thr_0"], v["ctrl_dw_thr_1"] }' "$1"
}
# pips_tag <cfg> [cap] [pb pushoff quantum thr0 thr1]: d<depth>t<time>, then m1
# (batch_mrd), c1 (drain cap), p1 (page_batch_en), o1 (ctrl_push_off), q<N>
# (grant_quantum, beats), w<N> (both completion thresholds N DW; w<a>x<b> when
# they differ; none when both are 0 = 16 DW). Fields at their power-on value add
# nothing, so every tag of an older build reads as before.
pips_tag() {
    local v=$(( $1 )) c="${2:-0}" p="${3:-0}" o="${4:-0}" q="${5:-0}" t0="${6:-0}" t1="${7:-0}" w=""
    if [ "$t0" != 0 ] || [ "$t1" != 0 ]; then
        if [ "$t0" = "$t1" ]; then w="w$t0"; else w="w${t0}x${t1}"; fi
    fi
    printf 'd%dt%d%s%s%s%s%s%s\n' $(( v & 0xFF )) $(( (v >> 8) & 0xFF )) \
        "$( (( (v >> 16) & 1 )) && echo m1)" "$( [ "$c" = 1 ] && echo c1)" \
        "$( [ "$p" = 1 ] && echo p1)" "$( [ "$o" = 1 ] && echo o1)" \
        "$( [ "$q" != 0 ] && echo "q$q")" "$w"
}
# The whole setting a `pips cfg` readout file describes.
pips_tag_of() { pips_tag "$(cfg_of "$1")" "$(cap_of "$1")" $(pb_of "$1"); }

# The FPGA build, from `pips cfg`: design_of <file> -> 0x0a04, or none (a build
# from before the DESIGN_ID register). pips_idtag <design> -> id0a04, the tag
# every artifact name carries; nothing for none or unknown, which keeps the
# names of before design IDs were recorded. The log decoders read the ID back
# from these names (pips-log-decode.py --help, "Design ID").
design_of() { sed -n 's/^design_id=//p' "$1" | head -1; }
pips_idtag() {
    case "${1:-}" in
        0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) printf 'id%s\n' "$(echo "${1#0x}" | tr 'A-F' 'a-f')" ;;
        *) echo "" ;;
    esac
}
# pips_design_ge <design> <min>: true if the build is <min> or later (0x0a03 = drain cap).
pips_design_ge() {
    case "${1:-}" in 0x[0-9a-fA-F]*) [ $(( $1 )) -ge $(( $2 )) ] ;; *) return 1 ;; esac
}

# pips_behind <usp> <bdf>...: true if any of the PCI functions sits below the
# PIPS upstream port, i.e. its traffic goes through the switch.
pips_behind() {
    local u="$1" b; shift
    for b in "$@"; do
        case "$(readlink -f "/sys/bus/pci/devices/$b" 2>/dev/null)" in */"$u"/*) return 0 ;; esac
    done
    return 1
}

# Kernel log lines that report a PCIe, IOMMU or NVMe problem. Not the boot-time
# "_OSC: platform does not support [... AER ... DPC]" or "nvme ...: Shutdown
# timeout set to 10 seconds" lines.
PIPS_KERNEL_ERR_RE='AER: |DPC: |DMAR: \[DMA|DMAR:.*[Ff]ault|pciehp.*(Link Down|Card not present)|nvme.*(timeout, |controller is down|[Rr]eset(ting)? controller|I/O error|failed|Removing)'

# BAR0 of a function as the kernel holds it: prints "<start> <bytes>" (hex
# start, decimal size), start 0 when the BAR is not assigned.
bar0_of() {
    local s e
    read -r s e _ < "/sys/bus/pci/devices/$1/resource" 2>/dev/null || return 1
    [ $((e)) -gt 0 ] || return 1
    printf '%s %d\n' "$s" $(( e - s + 1 ))
}

# Make utils/logs/<name>/ (or $PIPS_LOGS/<name>/) for this run and print its
# path. With "unique", a taken name gets -2, -3, ...; otherwise it is refused.
pips_outdir() {
    local name="$1" mode="${2:-}" owner="${SUDO_USER:-$(id -un)}" logs out base k=1
    logs="${PIPS_LOGS:-$PIPS_REPO/utils/logs}"
    if [ ! -d "$logs" ]; then
        mkdir -p "$logs" && chown "$owner": "$logs"
    fi
    out="$logs/$name"
    if [ -e "$out" ]; then
        [ "$mode" = unique ] || { echo "ERROR: $out already exists; pick another name" >&2; return 1; }
        base="$out"; while [ -e "$out" ]; do k=$((k + 1)); out="$base-$k"; done
    fi
    mkdir -p "$out" && echo "$out"
}

# ------------------------------------------------------------------ runner hooks
# Shared by run-dualssd-experiment.sh and run-dualnic-experiment.sh: the
# switch's build and batcher setting go with every result whose devices are
# behind it, and --pips-log 1 records its TLP log in every run. The runner
# sets pips_log (0 or 1) and, per run, RUN, L (the run's log folder) and
# setup_dir (utils/); preflight collects problems in PROBLEMS. pips_identify
# sets pips_here (an active device is behind PIPS), pips_cfg, pips_cap,
# pips_design, pips_idt (id0a04) and pips_region; PIPS_STATUS collects each
# run's log status. The runner's pips calls run as root without a prompt.
pipsc() { sudo -n "$PIPS" "$@"; }
pips_here=0; pips_cfg=""; pips_cap=0; pips_pb="0 0 0 0 0"; pips_design=""; pips_idt=""; pips_region=""; PIPS_STATUS=()
pips_gzip="${PIPS_LOG_GZIP:-1}"
pips_setting() { pips_tag "$pips_cfg" "$pips_cap" $pips_pb; }
# The page batcher's status registers exist (design 0x0a06 on).
pips_has_status() { pips_design_ge "${pips_design:-}" 0x0a06; }

# pips_identify <what> <bdf>...: in preflight. Reads the switch's build and
# batcher setting when one of the devices (<what>: "drive", "NIC") is behind
# it, or when --pips-log 1 asks for its log. A problem is fatal (PROBLEMS)
# only with --pips-log 1; otherwise the results go untagged, with a warning.
pips_identify() {
    local what="$1" usp out msg=""
    shift
    usp=$(pips_find_usp 2>/dev/null) && pips_behind "$usp" "$@" && pips_here=1
    [ "$pips_log" = 1 ] || [ "$pips_here" = 1 ] || return 0
    if ! pips_build >/dev/null 2>&1; then
        msg="cannot build $PIPS (make -C scripts/pips pips)"
    elif ! out=$(pipsc cfg 2>&1); then
        msg="the PIPS switch does not answer:
$(printf '%s\n' "$out" | tail -2 | sed 's/^/      /')
    Bring it up first: sudo bash scripts/pips/pips-bringup.sh"
    else
        pips_cfg=$(cfg_of <(printf '%s\n' "$out"))
        pips_cap=$(cap_of <(printf '%s\n' "$out"))
        pips_pb=$(pb_of <(printf '%s\n' "$out"))
        pips_design=$(design_of <(printf '%s\n' "$out"))
        pips_idt=$(pips_idtag "$pips_design")
        pips_region=$(pipsc info 2>/dev/null | awk '$1 == "LOG_BYTES" {print $2}')
        echo "   PIPS: ${usp:-?}, design ${pips_design:-?}, batcher $(pips_setting) ($pips_cfg)," \
             "log region ${pips_region:-?} bytes$( [ "$pips_here" = 1 ] || echo "; NO active $what is behind it")"
        [ -n "$pips_cfg" ] || msg="could not read the batcher setting (pips cfg)"
        [ "$pips_log" = 1 ] && [ -z "$pips_region" ] && msg="pips info shows no LOG_BYTES"
    fi
    [ -n "$msg" ] || return 0
    if [ "$pips_log" = 1 ]; then
        PROBLEMS+=("--pips-log: $msg")
    else
        echo "   WARNING: a ${what} is behind PIPS, but its design ID and setting cannot be read:" \
             "$msg" | head -3
        pips_cfg=""
    fi
}

# Sweep identity (SWEEP-LOGS.md). A PIPS sweep exports PIPS_SWEEP_ID (unique:
# <name>@<host>@<start time>), PIPS_SWEEP (its name), PIPS_SWEEP_SUB (the
# current setting's sweep, <name>-id<XXXX>-<setting>) and PIPS_MANIFEST (its
# manifest.tsv). Then each run's folder gets sweep-id.txt, its .rpt a
# sweep_id: line, each result pips_sweep_id, and the manifest a row per run.
# Runs outside a PIPS sweep have none of these.
pips_setting_known() { if [ -n "$pips_cfg" ]; then pips_setting; else echo unknown; fi; }
pips_point() {   # the run's point: $RUN without the setting's sweep name and -RUN-<j>
    local p="${RUN%-RUN-*}"
    [ -n "${PIPS_SWEEP_SUB:-}" ] && p="${p#"$PIPS_SWEEP_SUB"}"
    p="${p#/}"; echo "${p#-}"
}
pips_sweep_mark() {
    [ -n "${PIPS_SWEEP_ID:-}" ] || return 0
    printf 'sweep_id=%s\nsweep=%s\nsweep_setting=%s\nsetting=%s\npoint=%s\nrun=%s\nstarted=%s\n' \
        "$PIPS_SWEEP_ID" "${PIPS_SWEEP:-}" "${PIPS_SWEEP_SUB:-}" "$(pips_setting_known)" "$(pips_point)" "$RUN" \
        "$(date '+%F %T')" > "$L/sweep-id.txt"
}
pips_manifest_add() {   # <report file> <TLP log or ""> <status>
    local rel_l rel_r role=point
    [ -n "${PIPS_SWEEP_ID:-}" ] && [ -n "${PIPS_MANIFEST:-}" ] || return 0
    rel_l="${L#"$PIPS_REPO"/}"; rel_r="${1%/*}"; rel_r="${rel_r#"$PIPS_REPO"/}"
    case "$(pips_point)" in *datapath*) role=datapath ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PIPS_SWEEP_ID" "$(pips_setting_known)" "$(pips_point)" \
        "$role" "$RUN" "$rel_l" "$rel_r" "${2:+${2#"$PIPS_REPO"/}}" "$3" "${pips_design:-none}" \
        "$(date '+%F %T')" >> "$PIPS_MANIFEST"
}

# pips_sweep_begin <kind ssd|nic> <name> <logdir> <results dir> <design> <sub>...:
# in a PIPS sweep, before its first run. <sub> are the per-setting sweep names
# (<name>-id<XXXX>-<setting>). Exports the identity above, writes
# <logdir>/sweep-id.txt and starts <logdir>/manifest.tsv: "#" lines, then a
# header row, then one row per run as it ends (pips_manifest_add).
pips_sweep_begin() {
    local kind="$1" name="$2" logdir="$3" dir="$4" design="$5" s
    shift 5
    export PIPS_SWEEP="$name"
    export PIPS_SWEEP_ID="$name@$(hostname -s)@$(date +%Y%m%d-%H%M%S)"
    export PIPS_MANIFEST="$logdir/manifest.tsv"
    export PIPS_SWEEP_SUB=""
    {
        echo "# pips sweep manifest v1: one row per run of this sweep (scripts/pips/SWEEP-LOGS.md)"
        echo "# sweep_id=$PIPS_SWEEP_ID"
        echo "# sweep=$name"
        echo "# kind=$kind"
        echo "# host=$(hostname)"
        echo "# design_id=${design:-none}"
        echo "# started=$(date '+%F %T')"
        echo "# repo_revision=$(git -C "$PIPS_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        for s in "$@"; do echo "# setting_sweep=$s results=$dir/$s.jsonl"; done
        printf 'sweep_id\tsetting\tpoint\trole\trun\tlog_dir\treport_dir\ttlp_log\tstatus\tdesign_id\tfinished\n'
    } > "$PIPS_MANIFEST"
    printf 'sweep_id=%s\nsweep=%s\nkind=%s\nhost=%s\ndesign_id=%s\nstarted=%s\nmanifest=%s\n' \
        "$PIPS_SWEEP_ID" "$name" "$kind" "$(hostname)" "${design:-none}" "$(date '+%F %T')" \
        "$PIPS_MANIFEST" > "$logdir/sweep-id.txt"
}

# pips_sweep_save <results dir>: the manifest so far, also as
# <results dir>/<name>.manifest.tsv (after each setting, and at the end).
pips_sweep_save() {
    [ -n "${PIPS_MANIFEST:-}" ] && [ -s "$PIPS_MANIFEST" ] || return 0
    cp "$PIPS_MANIFEST" "$1/$PIPS_SWEEP.manifest.tsv" 2>/dev/null
}

# pips_run_cfg: at the start of each run, before the load. The run's folder
# keeps the `pips cfg` readout it ran with (pips-cfg.txt: setting, drain cap,
# design ID, log format) and, inside a PIPS sweep, sweep-id.txt; with
# --pips-log 1 the log region is zeroed, so leftovers never pass for data.
pips_run_cfg() {
    local now
    PIPS_RUN_T0=$(date +%s)            # for pips_lockups_collect
    pips_sweep_mark
    if [ -n "$pips_cfg" ]; then
        pipsc cfg > "$L/pips-cfg.txt" 2>&1
        now=$(cfg_of "$L/pips-cfg.txt")
        [ -n "$now" ] && [ "$(pips_tag_of "$L/pips-cfg.txt")" != "$(pips_setting)" ] && \
            echo "WARNING: the PIPS batcher setting changed during the experiment:" \
                 "$(pips_setting) at the start, $(pips_tag_of "$L/pips-cfg.txt") now" >&2
    fi
    # The status registers clear on read: this read opens the run's period.
    if [ "$pips_log" = 1 ] && pips_has_status; then
        pipsc status > "$L/pips-status-before.txt" 2>&1 ||
            echo "WARNING: PIPS status read failed: $(tail -1 "$L/pips-status-before.txt")" >&2
    fi
    if [ "$pips_log" = 1 ]; then
        pipsc log-clear > "$L/pips-log-clear.txt" 2>&1 || \
            echo "WARNING: PIPS log-clear failed: $(tail -1 "$L/pips-log-clear.txt")" >&2
    fi
    return 0
}

# One recording, while the load is in steady state and no window is open.
pips_record() {
    local f="$L/pips-log-record.txt" t0
    t0=$(date +%s%3N)
    { pipsc log-start && pipsc log-wait 5000; } > "$f" 2>&1
    grep -q '^status=timeout' "$f" && pipsc log-stop 2000 >> "$f" 2>&1
    pipsc cfg set log=0 >> "$f" 2>&1        # a region-full stop leaves log_enable at 1
    echo "   PIPS log recorded in $(( $(date +%s%3N) - t0 )) ms:" \
         "$(grep -E '^(stop_reason|n_records|n_dropped|duration_us)=' "$f" | xargs)"
}

# After the measurement windows: dump, decode, compress. Never fails the run.
# The dump is named with the design ID (pips-log-id0a04.bin.gz), which picks
# its record format; the decode and the .rpt name it too.
pips_collect() {
    local f="$L/pips-log-record.txt" bin="$L/pips-log${pips_idt:+-$pips_idt}.bin"
    local rpt="$setup_dir/reports/$RUN/pips-log.rpt"
    local scan=()
    if grep -q '^stop_reason=' "$f" 2>/dev/null; then
        pipsc log-dump "$bin" > "$L/pips-log-dump.txt" 2>&1
    elif [ -n "$pips_region" ]; then
        # The recording never closed: the whole region as it is, read without a trailer.
        pipsc log-dump "$bin" "$pips_region" > "$L/pips-log-dump.txt" 2>&1
        scan=( --scan )
    fi
    if [ -s "$bin" ]; then
        sudo -n chown "$(id -un)": "$bin"
        python3 "$PIPS_DIR/pips-log-decode.py" "$bin" ${scan[@]+"${scan[@]}"} \
            --design-id "${pips_design:-none}" --region-bytes "${pips_region:-0}" --rpt "$rpt" \
            --json "$L/pips-log-summary.json" > "$L/pips-log-summary.txt" 2>&1
        [ "$pips_gzip" = 1 ] && gzip -f "$bin"
    fi
    [ -s "$rpt" ] || printf 'status: FAILED\ndesign_id: %s\n' "${pips_design:-none}" > "$rpt"
    [ -n "${PIPS_SWEEP_ID:-}" ] && printf 'sweep_id: %s\n' "$PIPS_SWEEP_ID" >> "$rpt"
    pips_status_collect "$rpt"
    pips_lockups_collect "$rpt"
    PIPS_STATUS+=( "$(awk '/^status:/{print $2; exit}' "$rpt")" )
    local got=""
    for got in "$bin.gz" "$bin"; do [ -s "$got" ] && break; got=""; done
    pips_manifest_add "$rpt" "$got" "${PIPS_STATUS[-1]}"
    echo "   PIPS log: $(awk '/^status:/{print $2; exit}' "$rpt")," \
         "$(awk '/^pips_records:/{r=$2} /^pips_dropped:/{d=$2} END{printf "%s records, %s dropped", r, d}' "$rpt")" \
         "(logs: pips-log-*.txt)"
}

# pips_status_collect <rpt>: the page batcher's status over this run (design
# 0x0a06 on), read once after the window: since pips_run_cfg's read, so the
# whole run, setup included. Saved as pips-status.txt and added to the .rpt as
# numbers (they reach the JSONL record as pips_stat_*): overflow flags and
# counts per input, the watchdog's stuck bit, the longest MRd wait (cycles of
# 4 ns, and us). A stuck bit is printed as a warning: it should never be set.
pips_status_collect() {
    local rpt="$1" f="$L/pips-status.txt"
    pips_has_status || return 0
    if ! pipsc status > "$f" 2>&1 || ! grep -q '^status=ok' "$f"; then
        echo "WARNING: PIPS status read failed: $(tail -1 "$f")" >&2
        echo "pips_stat_valid: 0" >> "$rpt"
        return 0
    fi
    awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[2] != "") v[kv[1]] = kv[2] } }
         END {
             print "pips_stat_valid: 1"
             print "pips_stat_ovf0: " v["ovf0"];  print "pips_stat_ovf1: " v["ovf1"]
             print "pips_stat_stuck: " v["stuck"]
             print "pips_stat_ovf_count_0: " v["ovf_count_0"]; print "pips_stat_ovf_count_1: " v["ovf_count_1"]
             print "pips_stat_mrd_wait_max_0: " v["mrd_wait_max_0"]; print "pips_stat_mrd_wait_max_1: " v["mrd_wait_max_1"]
             print "pips_stat_mrd_wait_max_us_0: " v["mrd_wait_max_us_0"]
             print "pips_stat_mrd_wait_max_us_1: " v["mrd_wait_max_us_1"]
         }' "$f" >> "$rpt"
    if grep -q 'stuck=1' "$f"; then
        echo "!!!!!!!! WARNING: PIPS page batcher STUCK bit set in this run: its watchdog found the" >&2
        echo "!!!!!!!! output idle with data held and forced a drain ($f)" >&2
    fi
    echo "   PIPS status: $(grep -E '^(stat_flags|ovf_count|mrd_wait_max_us)' "$f" | xargs)"
}

# pips_lockups_collect <rpt>: kernel soft lockups since this run began
# (pips_run_cfg), as kernel_soft_lockups: in the .rpt (and so the record), with
# a warning. A run with any is not clean data: on bigserver they came from
# strict-mode IOTLB invalidations piling onto one interrupt CPU (HANDOFF §8
# "0x0A06 campaign"), and they stall pcm-iio and sar as well.
pips_lockups_collect() {
    local n
    [ -n "${PIPS_RUN_T0:-}" ] || return 0
    n=$(sudo -n journalctl -k --since "@$PIPS_RUN_T0" 2>/dev/null | grep -c 'soft lockup')
    echo "kernel_soft_lockups: ${n:-0}" >> "$1"
    if [ "${n:-0}" -gt 0 ]; then
        echo "!!!!!!!! WARNING: $n kernel soft lockup(s) during this run (journalctl -k): its numbers are not clean" >&2
    fi
}

# pips_meta: PIPS_META = the --meta arguments for the results dump.
# pips_batch and pips_design_id keep records of different batcher settings and
# FPGA builds apart in the summaries; pips_log is each run's log status,
# comma-separated.
pips_meta() {
    PIPS_META=()
    if [ -n "$pips_cfg" ]; then
        PIPS_META+=( --meta pips_batch="$(pips_setting)" --meta pips_cfg="$pips_cfg"
                     --meta pips_drain_cap="$pips_cap" --meta pips_design_id="${pips_design:-unknown}" )
        if pips_has_status; then
            local p o q t0 t1
            read -r p o q t0 t1 <<< "$pips_pb"
            PIPS_META+=( --meta pips_page_batch="$p" --meta pips_ctrl_push_off="$o"
                         --meta pips_grant_quantum="$q" --meta pips_ctrl_dw_thr_0="$t0"
                         --meta pips_ctrl_dw_thr_1="$t1" )
        fi
    fi
    [ "$pips_log" = 1 ] && PIPS_META+=( --meta pips_log="$(IFS=,; echo "${PIPS_STATUS[*]}")" )
    [ -n "${PIPS_SWEEP_ID:-}" ] && PIPS_META+=( --meta pips_sweep_id="$PIPS_SWEEP_ID"
                                                --meta pips_sweep="${PIPS_SWEEP:-}" )
    return 0
}

# pips_report: the result's PIPS lines.
pips_report() {
    [ -n "$pips_cfg" ] && printf '  %-25s : design %s, batcher %s\n' "PIPS switch" \
        "${pips_design:-?}" "$(pips_setting)"
    [ "$pips_log" = 1 ] && printf '  %-25s : %s\n' "PIPS log, per run" "${PIPS_STATUS[*]:-none}"
    return 0
}

# One PIPS run at a time: they share the log DMA, log_enable and WIN_BASE.
# Opened read-only, created only if missing: with fs.protected_regular even
# root may not O_CREAT-open another user's file in /tmp.
pips_lock() {
    local f=/tmp/pips-run.lock
    [ -e "$f" ] || { : > "$f" && chmod 666 "$f"; } 2>/dev/null
    exec 8< "$f" || return 1
    flock -n 8 && return 0
    echo "ERROR: another PIPS script is running (/tmp/pips-run.lock):" >&2
    pgrep -af 'pips-(bringu[p]|fio-lo[g])|dual(ssd|nic)_pips_swee[p]' >&2
    return 1
}
