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
run 0 "hwtest regfile alone" "$P" hwtest regfile; has 'restored'
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
