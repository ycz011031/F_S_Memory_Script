#!/bin/bash
# One fio run on the NVMe drive(s) behind PIPS, with the switch's TLP log
# recorded during it and collected from FPGA DDR through BAR0, plus the
# switch's registers, links and kernel log before and after. fio is
# read-only: --readonly, and --rw read or randread only.
#
#   sudo bash scripts/pips/pips-fio-log.sh [options]
#
#   --dev /dev/nvmeXnY   drive to load; repeat for several (default: every
#                        NVMe namespace behind PIPS, all in the one fio run)
#   --bs 4k --rw randread --iodepth 32 --numjobs 4      fio, per drive
#   -d 20                fio runtime, seconds
#   --log-at 5           start the recording this many seconds into the run
#   --log-for 0          end it after this many seconds; 0 = when the region
#                        fills or fio ends. Under load the 4 MiB region
#                        (262143 TLPs) fills within milliseconds.
#   --cfg "K=V ..."      batcher config for the run, `pips cfg set` fields,
#                        e.g. "depth=8 time=0x16 mrd=1"; restored afterwards
#   --no-log             fio and the readouts only
#   --no-clear           keep the old log region contents (default: zero it)
#   --no-csv             skip log.csv (one line per record, ~15 MB when full)
#   --bdf BDF            PIPS upstream port (default: the only 10ee:b048)
#   -E NAME              folder under utils/logs/ (default pips-fio-<date>-<time>)
#
# Output, never overwritten, in utils/logs/<NAME>/:
#   run.log                        this output
#   fio.json fio.err fio-summary.txt   fio, and IOPS / GB/s / latency per drive
#   info-before.txt info-after.txt     pips info (counters, CQ_SPLIT, PIO_STATUS)
#   cfg-before.txt cfg-after.txt dma-before.txt dma-after.txt
#   lspci-before.txt lspci-after.txt   lspci -vv of the PIPS functions (links, AER)
#   dmesg.txt                      kernel log lines printed during the run
#   log-start.txt log-stop.txt     the recording: arming, DMA status, trailer
#   log.bin                        the recording, as the DMA wrote it to DDR
#   log-summary.txt log-summary.json log.csv   its decode (pips-log-decode.py)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pips-lib.sh"

DEVS=(); BS=4k; RW=randread; QD=32; NJ=4; RUNTIME=20; LOG_AT=5; LOG_FOR=0
CFG=""; DO_LOG=1; CLEAR=1; CSV=1; BDF=""; NAME=""
FIO="${FIO:-fio}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEVS+=( "$2" ); shift 2 ;;
        --bs) BS="$2"; shift 2 ;;
        --rw) RW="$2"; shift 2 ;;
        --iodepth) QD="$2"; shift 2 ;;
        --numjobs) NJ="$2"; shift 2 ;;
        -d) RUNTIME="$2"; shift 2 ;;
        --log-at) LOG_AT="$2"; shift 2 ;;
        --log-for) LOG_FOR="$2"; shift 2 ;;
        --cfg) CFG="$2"; shift 2 ;;
        --no-log) DO_LOG=0; shift ;;
        --no-clear) CLEAR=0; shift ;;
        --no-csv) CSV=0; shift ;;
        --bdf) BDF="$2"; shift 2 ;;
        -E) NAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (-h for help)" >&2; exit 2 ;;
    esac
done
case "$RW" in read|randread) ;; *) die "--rw must be read or randread: fio stays read-only" ;; esac
for v in QD NJ RUNTIME LOG_AT LOG_FOR; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number (got '${!v}')"
done
[ "$DO_LOG" = 0 ] || [ "$LOG_AT" -lt "$RUNTIME" ] || die "--log-at ($LOG_AT) must be less than -d ($RUNTIME)"
command -v "$FIO" >/dev/null || die "fio not found"
[ "$(id -u)" -eq 0 ] || echo "WARNING: not root: BAR0 access, lspci capabilities and dmesg need sudo"

pips_lock || exit 1
pips_build || die "cannot build $PIPS"
if [ -z "$BDF" ]; then BDF=$(pips_find_usp) || exit 1; fi
case "$BDF" in ????:??:??.?) ;; *) BDF="0000:$BDF" ;; esac
if [ ${#DEVS[@]} -eq 0 ]; then
    mapfile -t DEVS < <(pips_nvme_below "$BDF")
    [ ${#DEVS[@]} -gt 0 ] || die "no NVMe namespace behind PIPS ($BDF); name a drive with --dev"
fi
for d in "${DEVS[@]}"; do [ -b "$d" ] || die "$d is not a block device"; done

if [ -n "$NAME" ]; then OUT=$(pips_outdir "$NAME") || exit 1
else OUT=$(pips_outdir "pips-fio-$(date +%Y%m%d-%H%M%S)" unique) || exit 1; fi
OWNER="${SUDO_USER:-$(id -un)}"
exec > >(tee "$OUT/run.log") 2>&1
echo "saving to $OUT/"

P() { "$PIPS" -s "$BDF" "$@"; }
FIO_PID=""; RECORDING=0; CFG_SET=0; CFG0=""
cleanup() {
    [ -n "$FIO_PID" ] && kill -INT "$FIO_PID" 2>/dev/null
    if [ "$RECORDING" = 1 ]; then
        echo "stopping the recording"; P log-stop 2000 >/dev/null 2>&1; RECORDING=0
    fi
    if [ "$CFG_SET" = 1 ] && [ -n "$CFG0" ]; then
        echo "restoring the batcher config to $CFG0"; P cfg set raw="$CFG0" >/dev/null && CFG_SET=0
    fi
    chown -R "$OWNER": "$OUT" 2>/dev/null
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM
section() { echo; echo "== $*"; }
ms() { date +%s%3N; }

# ---------------------------------------------------------------------------
section "1. Setup"
echo "  PIPS upstream port $BDF; kernel $(uname -r); $("$FIO" --version)"
echo "  fio: ${#DEVS[@]} drive(s) x $NJ jobs x iodepth $QD, $RW $BS, ${RUNTIME} s, read-only"
NODES=()
for d in "${DEVS[@]}"; do
    b=$(blk_bdf "$d"); n=$(basename "$d")
    case "$(readlink -f "/sys/bus/pci/devices/$b" 2>/dev/null)" in
        */"$BDF"/*) where="behind PIPS" ;;
        *) where="NOT behind PIPS: its TLPs will not be in the log" ;;
    esac
    node=$(cat "/sys/bus/pci/devices/$b/numa_node" 2>/dev/null); NODES+=( "${node:--1}" )
    echo "  $d  ${b:-?}  $(cat "/sys/class/block/$n/device/model" 2>/dev/null | xargs)" \
         " IOMMU $(bash "$PIPS_REPO/utils/iommu-mode.sh" "$d" 2>/dev/null)  NUMA ${node:-?}  $where"
    [ -n "$b" ] && echo "      $(lspci_brief "$b")"
done
P info > "$OUT/info-before.txt" 2>&1 || { cat "$OUT/info-before.txt"; die "pips info failed: run pips-bringup.sh first"; }
P cfg > "$OUT/cfg-before.txt" 2>&1 || die "cannot read the batcher config: $(cat "$OUT/cfg-before.txt")"
P dma > "$OUT/dma-before.txt" 2>&1
CFG0=$(sed -n 's/^cfg=\(0x[0-9a-f]*\).*/\1/p' "$OUT/cfg-before.txt")
echo "  batcher config before: $(grep '^cfg=' "$OUT/cfg-before.txt")"
for b in $BDF $(pips_below "$BDF"); do echo "### $b"; lspci -vv -s "$b" 2>&1; done > "$OUT/lspci-before.txt"
DMESG0=$(dmesg 2>/dev/null | wc -l)

if [ -n "$CFG" ]; then
    # shellcheck disable=SC2086   # one argument per field
    P cfg set $CFG > "$OUT/cfg-run.txt" 2>&1 || die "pips cfg set $CFG: $(cat "$OUT/cfg-run.txt")"
    CFG_SET=1
    echo "  batcher config for the run: $(grep '^cfg=' "$OUT/cfg-run.txt")"
fi
if [ "$DO_LOG" = 1 ] && [ "$CLEAR" = 1 ]; then
    P log-clear 2>&1 | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "log-clear failed"
fi

# ---------------------------------------------------------------------------
section "2. fio"
ARGS=( --readonly --direct=1 --ioengine=libaio --rw="$RW" --bs="$BS" --iodepth="$QD"
       --numjobs="$NJ" --thread --time_based --runtime="$RUNTIME" --randrepeat=0
       --norandommap --output-format=json --output="$OUT/fio.json" )
for i in "${!DEVS[@]}"; do
    ARGS+=( --name="ssd$i" --filename="${DEVS[$i]}" )
    node=${NODES[$i]}
    [ "$node" -ge 0 ] 2>/dev/null && [ -r "/sys/devices/system/node/node$node/cpulist" ] &&
        ARGS+=( --cpus_allowed="$(cat "/sys/devices/system/node/node$node/cpulist")" )
done
echo "  $FIO ${ARGS[*]}" > "$OUT/fio.cmd"
T0=$(ms)
"$FIO" "${ARGS[@]}" > "$OUT/fio.err" 2>&1 &
FIO_PID=$!
echo "  fio started (pid $FIO_PID)"

LOG_RC=""
if [ "$DO_LOG" = 1 ]; then
    sleep "$LOG_AT"
    kill -0 "$FIO_PID" 2>/dev/null || { cat "$OUT/fio.err"; die "fio ended before the recording"; }
    { echo "# t=$(( $(ms) - T0 )) ms into fio"; P log-start 2>&1; } > "$OUT/log-start.txt"
    sed 's/^/  /' "$OUT/log-start.txt"
    grep -q '^recording=started' "$OUT/log-start.txt" || die "log-start failed"
    RECORDING=1
    if [ "$LOG_FOR" -gt 0 ]; then
        sleep "$LOG_FOR"
        { echo "# t=$(( $(ms) - T0 )) ms: log-stop"; P log-stop 5000 2>&1; } > "$OUT/log-stop.txt"
    else
        left=$(( (RUNTIME - LOG_AT + 2) * 1000 ))
        { echo "# t=$(( $(ms) - T0 )) ms: log-wait (up to $left ms for the region to fill)"
          P log-wait "$left" 2>&1; echo "# rc=$?"; } > "$OUT/log-stop.txt"
        if grep -q '^status=timeout' "$OUT/log-stop.txt"; then
            { echo "# t=$(( $(ms) - T0 )) ms: region not full when fio ended: log-stop"
              P log-stop 5000 2>&1; } >> "$OUT/log-stop.txt"
        fi
    fi
    grep -q '^stop_reason=' "$OUT/log-stop.txt" && LOG_RC=0 || LOG_RC=1
    if [ "$LOG_RC" = 0 ]; then
        P cfg set log=0 > /dev/null 2>&1     # a region-full stop leaves log_enable at 1
        RECORDING=0
    fi
    sed 's/^/  /' "$OUT/log-stop.txt"
fi
wait "$FIO_PID"; FIO_RC=$?; FIO_PID=""
echo "  fio done, status $FIO_RC"
[ "$FIO_RC" -eq 0 ] || sed 's/^/    /' "$OUT/fio.err"

# ---------------------------------------------------------------------------
section "3. Collect"
if [ "$DO_LOG" = 1 ]; then
    if [ "$LOG_RC" = 0 ]; then
        P log-dump "$OUT/log.bin" 2>&1 | sed 's/^/  /'
        DEC=( "$OUT/log.bin" )
    else
        echo "  the DMA did not finish: dumping the whole region for a post-mortem (--scan decode)"
        bytes=$(awk '$1 == "LOG_BYTES" {print $2}' "$OUT/info-before.txt")
        P log-dump "$OUT/log-region.bin" "${bytes:-0x400000}" 2>&1 | sed 's/^/  /'
        DEC=( "$OUT/log-region.bin" --scan )
    fi
    [ "$CSV" = 1 ] && DEC+=( --csv "$OUT/log.csv" )
    python3 "$HERE/pips-log-decode.py" "${DEC[@]}" --json "$OUT/log-summary.json" \
        > "$OUT/log-summary.txt" 2>&1
    echo "  decode: log-summary.txt$([ "$CSV" = 1 ] && echo ", log.csv"), log-summary.json"
fi
P info > "$OUT/info-after.txt" 2>&1
P cfg > "$OUT/cfg-after.txt" 2>&1
P dma > "$OUT/dma-after.txt" 2>&1
for b in $BDF $(pips_below "$BDF"); do echo "### $b"; lspci -vv -s "$b" 2>&1; done > "$OUT/lspci-after.txt"
dmesg 2>/dev/null | tail -n +$((DMESG0 + 1)) > "$OUT/dmesg.txt"

python3 - "$OUT/fio.json" > "$OUT/fio-summary.txt" 2>&1 <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
per = {}
for j in d["jobs"]:
    r, w = j["read"], j["write"]
    if w.get("io_bytes", 0) or j.get("trim", {}).get("io_bytes", 0):
        sys.exit("FATAL: fio reports bytes written or trimmed")
    a = per.setdefault(j["jobname"], dict(dev=j.get("job options", {}).get("filename", "?"),
                                          iops=0.0, bw=0, lat=0.0, p99=0, n=0))
    a["iops"] += r["iops"]; a["bw"] += r["bw_bytes"]; a["n"] += 1
    a["lat"] += r["clat_ns"]["mean"] * r["iops"]
    a["p99"] = max(a["p99"], r["clat_ns"].get("percentile", {}).get("99.000000", 0))
tot = dict(iops=0.0, bw=0)
for name, a in sorted(per.items()):
    lat = a["lat"] / a["iops"] / 1e3 if a["iops"] else 0
    print(f"{name} {a['dev']}: {a['iops'] / 1e3:.1f}K IOPS  {a['bw'] / 1e9:.3f} GB/s  "
          f"clat mean {lat:.0f} us, p99 {a['p99'] / 1e3:.0f} us (worst job)  {a['n']} jobs")
    tot["iops"] += a["iops"]; tot["bw"] += a["bw"]
if len(per) > 1:
    print(f"total: {tot['iops'] / 1e3:.1f}K IOPS  {tot['bw'] / 1e9:.3f} GB/s")
EOF

# ---------------------------------------------------------------------------
section "Summary"
echo "  fio:"; sed 's/^/    /' "$OUT/fio-summary.txt"
if [ "$DO_LOG" = 1 ]; then
    echo "  log:"
    grep -E '^(bytes_written|n_records|n_dropped|duration_us|stop_reason)=' "$OUT/log-stop.txt" \
        | xargs | sed 's/^/    /'
    sed -n '/^port /,/^$/p' "$OUT/log-summary.txt" | sed 's/^/    /'
    grep -q UNEXPECTED "$OUT/log-summary.txt" && grep UNEXPECTED "$OUT/log-summary.txt" | sed 's/^/    /'
fi
echo "  switch registers, before -> after:"
for r in CQ_SPLIT MWR_COUNT MRD_COUNT PIO_STATUS WIN_STATUS; do
    printf '    %-10s %s  ->  %s\n' "$r" \
        "$(awk -v r="$r" '$1 == r { $1 = ""; print substr($0, 2) }' "$OUT/info-before.txt")" \
        "$(awk -v r="$r" '$1 == r { $1 = ""; print substr($0, 2) }' "$OUT/info-after.txt")"
done
echo "  kernel log: $(wc -l < "$OUT/dmesg.txt") new lines$(grep -qE "$PIPS_KERNEL_ERR_RE" "$OUT/dmesg.txt" && echo ', PCIe/IOMMU/NVMe errors among them: see dmesg.txt')"
diff <(grep -E 'LnkSta:|UESta:|CESta:|DevSta:' "$OUT/lspci-before.txt") \
     <(grep -E 'LnkSta:|UESta:|CESta:|DevSta:' "$OUT/lspci-after.txt") > /dev/null ||
    echo "  link or error status changed during the run: diff lspci-before.txt lspci-after.txt"
echo "  logs: $OUT/"
[ "$FIO_RC" -eq 0 ] && [ "${LOG_RC:-0}" = 0 ]
