#!/bin/bash
# `make check`: drive pips-sim (pips.c built against the BAR0 model in
# pips_sim.c) through every command, the log decoder, and pips-fio-log.sh with
# a stand-in fio, and check the results. No hardware, no root. The model's
# state lives in a temporary folder that is deleted afterwards.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export PIPS_SIM_STATE="$T/state"
P="$HERE/pips-sim"
DEC="$HERE/pips-log-decode.py"
[ -x "$P" ] || { echo "build it first: make pips-sim"; exit 2; }
fails=0

ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
# run <want-exit> <description> <command...>
run() {
    local want="$1" d="$2" rc
    shift 2
    "$@" > "$T/out" 2>&1
    rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$d"; else bad "$d: exit $rc, expected $want"; sed 's/^/       /' "$T/out"; fi
}
has() {
    if grep -q -- "$1" "$T/out"; then ok "  has '$1'"; else bad "  lacks '$1'"; sed 's/^/       /' "$T/out"; fi
}

echo "-- registers, BRAM, window"
run 0 "info" "$P" info;                          has '"PIPS"'; has 'match'
run 0 "hwtest, every step" "$P" hwtest;          has 'hwtest: PASS'
run 0 "hwtest regfile alone" "$P" hwtest regfile; has 'restored'; has 'DESIGN_ID 0x0a02'
    has 'reserved registers 0x04-0x1c and 0x24-0x3c read 0 (0 do not'; has 'repeats reg0'
run 0 "cfg shows the design ID" "$P" cfg; has 'design_id=0x0a02'
run 0 "hwtest split" "$P" hwtest split; has 'CQ_SPLIT has recorded a BAR0 TLP'
run 1 "hwtest refuses a DDR test page inside the log region" "$P" hwtest ddr --ddr-addr 0x1000
run 0 "soak" "$P" soak 20000;                    has 'soak: PASS'
run 0 "cfg set fields" "$P" cfg set depth=8 time=0x16 mrd=1; has 'cfg=0x00011608'
run 0 "cfg set raw" "$P" cfg set raw=1;          has 'cfg=0x00000001'
run 1 "cfg set rejects a bad field" "$P" cfg set bogus=1
run 0 "axi-rd regfile" "$P" axi-rd 0xA4000000;   has '0xa4000000: 0x00000001'
run 1 "axi-rd unmapped fails" "$P" axi-rd 0xB0000000; has 'rd_err'
run 0 "wr + rd" bash -c "'$P' wr 0x808 0xCAFEF00D && '$P' rd 0x808"; has '0x0808: 0xcafef00d'
run 0 "ddr-dump" "$P" ddr-dump 0x10000000 64 "$T/ddr.bin"; has 'dumped=64'

echo "-- a recording ended by log_enable low"
export PIPS_SIM_RECORDS=1000
run 0 "log-clear" "$P" log-clear
run 0 "log-start" "$P" log-start;    has 'recording=started'
run 3 "log-wait times out while the recording is open" "$P" log-wait 50; has 'status=timeout'
run 0 "log-stop" "$P" log-stop;      has 'stop_reason=enable_low'; has 'n_records=1000'; has 'n_dropped=2'
run 0 "log-dump" "$P" log-dump "$T/a.bin"; has 'dumped=16016'
run 0 "decode" python3 "$DEC" "$T/a.bin" --csv "$T/a.csv" --json "$T/a.json"; has 'stop enable_low'
[ "$(wc -l < "$T/a.csv")" -eq 1001 ] && ok "  csv: 1000 records" || bad "  csv lines: $(wc -l < "$T/a.csv")"
run 0 "json: TLPs + dropped = 1000" python3 -c "
import json; p = json.load(open('$T/a.json'))['ports']
assert sum(v['tlp'] + v['dropped'] for v in p.values()) == 1000, p"
run 1 "log-dump refuses while a transfer is programmed" bash -c "'$P' log-start && '$P' log-dump '$T/x.bin'"
run 0 "log-stop" "$P" log-stop

echo "-- a recording that fills the region"
export PIPS_SIM_RECORDS=300000
run 0 "log-start" "$P" log-start
run 0 "log-wait" "$P" log-wait 100;  has 'stop_reason=region_full'; has 'bytes_written=4194304'
run 0 "cfg: log_enable still 1" "$P" cfg; has 'log_enable=1'
run 0 "log-dump" "$P" log-dump "$T/b.bin"
run 0 "decode" python3 "$DEC" "$T/b.bin"; has '262143 records'
run 0 "log-start clears log_enable first" "$P" log-start; has 'log_enable was 1'
run 0 "log-stop" "$P" log-stop

echo "-- log status: whole or cut"
run 0 "region full with drops" python3 "$DEC" "$T/b.bin" --region-bytes 0x400000; has 'status: FULL+DROPS'
run 0 "an early stop" python3 "$DEC" "$T/a.bin"; has 'status: CUT+DROPS'
export PIPS_SIM_RECORDS=300000 PIPS_SIM_DROP_EVERY=0
run 0 "log-start, no drops" "$P" log-start
run 0 "log-wait" "$P" log-wait 100
run 0 "log-dump" bash -c "'$P' cfg set log=0 >/dev/null && '$P' log-dump '$T/f.bin' && gzip -k '$T/f.bin'"
run 0 "decode a .gz, write the .rpt" python3 "$DEC" "$T/f.bin.gz" --region-bytes 0x400000 --rpt "$T/f.rpt"
has 'status: FULL: ran until the region filled'
grep -qx 'status: FULL' "$T/f.rpt" && grep -qx 'pips_records: 262143' "$T/f.rpt" &&
    grep -qx 'pips_full: 1' "$T/f.rpt" && ok "  rpt: status FULL, 262143 records" || bad "  rpt: $(cat "$T/f.rpt")"
run 1 "region full but the wrong size is BAD" python3 "$DEC" "$T/f.bin" --region-bytes 0x800000; has 'status: BAD'
head -c -16 "$T/f.bin" > "$T/t.bin"
run 1 "a dump missing its trailer is BAD" python3 "$DEC" "$T/t.bin"; has 'status: BAD: the last record is not a trailer'
unset PIPS_SIM_DROP_EVERY

echo "-- run-dualssd-experiment.sh: pips_record, pips_collect"
# The runner's own two functions, run against the model.
runner_pips() {   # <want status> <records> [fail]
    (
        eval "$(sed -n '/^pips_record() {/,/^}/p; /^pips_collect() {/,/^}/p' "$HERE/../run-dualssd-experiment.sh")"
        if [ "${3:-}" = fail ]; then pipsc() { return 1; }; else pipsc() { "$P" "$@"; }; fi
        sudo() { [ "$1" = -n ] && shift; "$@"; }
        HERE="$HERE/.."; setup_dir="$T/u$1"; RUN=r0; L="$setup_dir/logs/r0"
        pips_region=0x400000; pips_gzip=1; PIPS_STATUS=()
        mkdir -p "$L" "$setup_dir/reports/$RUN"
        export PIPS_SIM_RECORDS="$2" PIPS_SIM_DROP_EVERY=0
        "$P" log-clear > /dev/null
        pips_record
        pips_collect
        echo "STATUS=${PIPS_STATUS[*]}"
        "$P" cfg
    )
}
run 0 "FULL" runner_pips FULL 300000;  has 'STATUS=FULL$'; has 'log_enable=0'
[ -s "$T/uFULL/logs/r0/pips-log.bin.gz" ] && grep -qx 'status: FULL' "$T/uFULL/reports/r0/pips-log.rpt" &&
    ok "  pips-log.bin.gz and pips-log.rpt" || bad "  missing pips-log.bin.gz or rpt"
run 0 "CUT: the region did not fill in 5 s" runner_pips CUT 1000; has 'STATUS=CUT$'; has 'log_enable=0'
run 0 "FAILED: the switch does not answer" runner_pips FAILED 1000 fail; has 'STATUS=FAILED$'

echo "-- dualssd-results.py: records of several batcher settings"
mkrec() {   # <setting> <bs> <instances> <log status>
    local e="x-$1-$2-$3" d="$T/rep"
    mkdir -p "$d/$e-RUN-0" "$d/$e-RUN-0-ssd0" "$d/$e-RUN-0-ssd1"
    for i in 0 1; do printf 'IOPS: 400000\nread_Gbps: 13.1\nlat_mean_us: 150\n' > "$d/$e-RUN-0-ssd$i/fio.rpt"; done
    printf 'avg_cpu_util: 50\n' > "$d/$e-RUN-0/cpu_util.rpt"
    printf 'status: %s\npips_full: 1\npips_records: 262143\npips_dropped: 0\npips_duration_us: 4368.0\npips_in0_tlp: 65932\npips_in1_tlp: 65142\npips_out_tlp: 131069\npips_out_mwr_gbps: 53.88\n' \
        "$4" > "$d/$e-RUN-0/pips-log.rpt"
    python3 "$HERE/../dualssd-results.py" dump --reports "$d" --exp "$e" --runs 1 --ssds 0,1 \
        --out "$T/res-$1.jsonl" --meta mode=both --meta iommu=off --meta instances_per_ssd="$3" \
        --meta instances_ssd0="$3" --meta instances_ssd1="$3" --meta bs="$2" \
        --meta cpu_util_cores=36,37 --meta pips_batch="$1" --meta pips_log="$4" > /dev/null
}
for s in d1t0 d8t22; do for b in 4k 1m; do for j in 1 4; do mkrec $s $b $j FULL; done; done; done
mkrec d8t22 4k 8 FULL,CUT
run 0 "summary" python3 "$HERE/../dualssd-results.py" summary "$T"/res-*.jsonl
has '^off d1t0 '; has '^off d8t22 4k        8'; has 'PIPS TLP log per configuration'
has 'FULL,CUT .* <-- NOT ALL FULL'; has 'logs: 9 FULL, 1 CUT'
run 0 "grid" python3 "$HERE/../dualssd-results.py" grid "$T"/res-*.jsonl
has 'IOMMU off d1t0: both drives, total kIOPS'; has 'IOMMU off d8t22: both drives, total kIOPS'

echo "-- recovery"
export PIPS_SIM_RECORDS=1000
run 0 "log-start" "$P" log-start
run 0 "dma-reset under an open recording" "$P" dma-reset
run 0 "log_enable 0 while the DMA is stopped" "$P" cfg set log=0
run 0 "log-start takes the stale tail, re-arms" "$P" log-start; has 'stale bytes'
run 0 "log-stop" "$P" log-stop;      has 'n_records=1000'
run 0 "DMA into a decode error" bash -c "'$P' dma-reset >/dev/null && '$P' axi-wr 0xA4010030 1 &&
    '$P' axi-wr 0xA4010048 0x10000000 && '$P' axi-wr 0xA4010058 4096 && '$P' dma"; has 'dec_err'
run 0 "log-start resets a DMA in error" "$P" log-start; has 'has errors'
run 0 "log-stop" "$P" log-stop
run 0 "decode --scan of a region without a trailer" bash -c "
    python3 -c \"import sys; sys.stdout.buffer.write(open('$T/a.bin','rb').read()[:-16] + bytes(64))\" > '$T/s.bin' &&
    python3 '$DEC' '$T/s.bin' --scan"; has 'no trailer'

echo "-- pips-fio-log.sh with a stand-in fio"
blk=$(for b in /dev/sd? /dev/vd? /dev/nvme?n? /dev/loop0; do [ -b "$b" ] && { echo "$b"; break; }; done)
if [ -z "$blk" ]; then
    echo "skip: no block device to name"
else
    cat > "$T/fio" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo fio-stand-in; exit 0; }
out=""; rt=1
for a in "$@"; do case "$a" in --output=*) out=${a#--output=} ;; --runtime=*) rt=${a#--runtime=} ;; esac; done
sleep "$rt"
cat > "$out" <<J
{"jobs": [{"jobname": "ssd0", "job options": {"filename": "/dev/x"},
  "read": {"iops": 100000.0, "bw_bytes": 409600000,
           "clat_ns": {"mean": 300000.0, "percentile": {"99.000000": 900000}}},
  "write": {"io_bytes": 0}, "trim": {"io_bytes": 0}}]}
J
EOF
    chmod +x "$T/fio"
    export PIPS_TOOL="$P" FIO="$T/fio" PIPS_LOGS="$T/logs"
    run 0 "fio run, recording closed by log-stop" bash "$HERE/pips-fio-log.sh" --bdf 0000:00:00.0 \
        --dev "$blk" -d 3 --log-at 1 --cfg "depth=8 time=0x16" -E t1
    has 'stop_reason=enable_low'; has '100.0K IOPS'; has 'restoring the batcher config'
    [ -s "$T/logs/t1/log.bin" ] && [ -s "$T/logs/t1/log.csv" ] && ok "  log.bin and log.csv saved" || bad "  log files missing"
    run 0 "cfg restored" "$P" cfg; has 'cfg=0x00000001'
    PIPS_SIM_RECORDS=300000 run 0 "fio run, region fills" bash "$HERE/pips-fio-log.sh" --bdf 0000:00:00.0 \
        --dev "$blk" -d 2 --log-at 1 --no-csv -E t2
    has 'stop_reason=region_full'
    run 1 "an existing -E name is refused" bash "$HERE/pips-fio-log.sh" --bdf 0000:00:00.0 --dev "$blk" -d 2 -E t2
    run 1 "--rw randwrite is refused" bash "$HERE/pips-fio-log.sh" --dev "$blk" --rw randwrite
fi

echo
[ "$fails" -eq 0 ] && echo "test-sim: PASS" || echo "test-sim: $fails FAILED"
[ "$fails" -eq 0 ]
