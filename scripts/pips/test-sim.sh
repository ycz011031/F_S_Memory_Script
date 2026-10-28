#!/bin/bash
# `make check`: drive pips-sim (pips.c built against the BAR0 model in
# pips_sim.c) through every command, the log decoder and the analysis tools
# on both record formats, the runners' PIPS hooks, the results scripts,
# pips-fio-log.sh with a stand-in fio, and both PIPS sweeps with stand-in
# sweeps under them. The model is the current build (design 0x0a04) unless a
# section says otherwise (PIPS_SIM_DESIGN). No hardware, no root. The model's
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
lacks() {
    if grep -q -- "$1" "$T/out"; then bad "  has '$1'"; sed 's/^/       /' "$T/out"; else ok "  lacks '$1'"; fi
}

echo "-- registers, BRAM, window (design 0x0a04)"
run 0 "info" "$P" info;                          has '"PIPS"'; has 'match'; has 'DESIGN_ID    0x0a04 .*log format v2'
run 0 "hwtest, every step" "$P" hwtest;          has 'hwtest: PASS'
run 0 "hwtest regfile alone" "$P" hwtest regfile; has 'restored'; has 'DESIGN_ID 0x0a04'
    has 'reg1 wrote 0x00000001 read 0x00000001'; has 'log format v2; drain config register at +0x04'
    has 'reserved registers 0x08-0x1c and 0x24-0x3c read 0 (0 do not'; has 'repeats reg0'
run 0 "cfg shows the design ID, log format, drain cap" "$P" cfg
    has 'design_id=0x0a04'; has 'log_format=v2'; has '^drain=0x00000000 drain_depth_cap=0'
run 0 "hwtest split" "$P" hwtest split; has 'CQ_SPLIT has recorded a BAR0 TLP'
run 1 "hwtest refuses a DDR test page inside the log region" "$P" hwtest ddr --ddr-addr 0x1000
run 0 "soak" "$P" soak 20000;                    has 'soak: PASS'
run 0 "cfg set fields" "$P" cfg set depth=8 time=0x16 mrd=1; has 'cfg=0x00011608'
run 0 "cfg set cap=1" "$P" cfg set cap=1;        has 'drain_depth_cap=1'; has 'cfg=0x00011608'
run 0 "cfg keeps the cap" "$P" cfg;              has '^drain=0x00000001 drain_depth_cap=1'
run 0 "cfg set raw, cap=0" "$P" cfg set raw=1 cap=0; has 'cfg=0x00000001'; has 'drain_depth_cap=0'
run 1 "cfg set rejects a bad field" "$P" cfg set bogus=1
run 1 "cfg set rejects cap=2" "$P" cfg set cap=2
run 0 "axi-rd regfile" "$P" axi-rd 0xA4000000;   has '0xa4000000: 0x00000001'
run 1 "axi-rd unmapped fails" "$P" axi-rd 0xB0000000; has 'rd_err'
run 0 "wr + rd" bash -c "'$P' wr 0x808 0xCAFEF00D && '$P' rd 0x808"; has '0x0808: 0xcafef00d'
run 0 "ddr-dump" "$P" ddr-dump 0x10000000 64 "$T/ddr.bin"; has 'dumped=64'

echo "-- pips-lib.sh: setting tags, design IDs"
run 0 "pips_tag, pips_idtag, cap_of, design_of" bash -c "
    . '$HERE/pips-lib.sh'
    '$P' cfg > '$T/c.txt'
    echo \"tag=\$(pips_tag 0x00011608) tagc=\$(pips_tag 0x1608 1) id=\$(pips_idtag 0x0A04)\" \
         \"none=[\$(pips_idtag none)] cap=\$(cap_of '$T/c.txt') design=\$(design_of '$T/c.txt')\"
    pips_design_ge 0x0a04 0x0a03 && echo ge-yes; pips_design_ge 0x0a02 0x0a03 || echo ge-no
    pips_design_ge none 0x0a03 || echo none-no"
has 'tag=d8t22m1 tagc=d8t22c1 id=id0a04 none=\[\] cap=0 design=0x0a04'; has 'ge-yes'; has 'ge-no'; has 'none-no'

echo "-- a recording ended by log_enable low (v2 records)"
export PIPS_SIM_RECORDS=1000
run 0 "log-clear" "$P" log-clear
run 0 "log-start" "$P" log-start;    has 'recording=started'
run 3 "log-wait times out while the recording is open" "$P" log-wait 50; has 'status=timeout'
run 0 "log-stop" "$P" log-stop;      has 'stop_reason=enable_low'; has 'n_records=1000'; has 'n_dropped=2'
run 0 "log-dump" "$P" log-dump "$T/a-id0a04.bin"; has 'dumped=16016'
run 0 "decode, design ID from the file name" python3 "$DEC" "$T/a-id0a04.bin" --csv "$T/a.csv" --json "$T/a.json"
    has 'stop enable_low'; has 'design 0x0a04, record format v2 (design ID from: file name)'
    has 'time in the batcher'; lacks 'UNEXPECTED'
[ "$(wc -l < "$T/a.csv")" -eq 1002 ] && head -1 "$T/a.csv" | grep -q '^# design_id=0x0a04 log_format=v2' &&
    sed -n 2p "$T/a.csv" | grep -q ',wait,out_sop,in_sop,seg' &&
    ok "  csv: design line, v2 header, 1000 records" || bad "  csv: $(head -2 "$T/a.csv")"
run 0 "json: out = in0 + in1 = 1000 TLPs + dropped, waits, design" python3 -c "
import json; s = json.load(open('$T/a.json')); p = s['ports']
assert s['design_id'] == '0x0a04' and s['log_format'] == 'v2', s['design_id']
assert p['out']['tlp'] + p['out']['dropped'] == 1000, p['out']
assert p['in0']['tlp'] + p['in1']['tlp'] == p['out']['tlp'], p
assert p['out']['wait_mean'] and p['out']['wait_p99'] >= p['out']['wait_p50'] >= 4, p['out']"
cp "$T/a-id0a04.bin" "$T/a.bin"
run 0 "a v2 log with no design ID anywhere reads as v1, and says so" python3 "$DEC" "$T/a.bin"
    has 'design none, record format v1'; has 'NOTE: no out records'
run 0 "--design-id overrides" python3 "$DEC" "$T/a.bin" --design-id 0x0a04; has 'record format v2 (design ID from: --design-id)'
run 1 "log-dump refuses while a transfer is programmed" bash -c "'$P' log-start && '$P' log-dump '$T/x.bin'"
run 0 "log-stop" "$P" log-stop

echo "-- a recording that fills the region"
export PIPS_SIM_RECORDS=300000
run 0 "log-start" "$P" log-start
run 0 "log-wait" "$P" log-wait 100;  has 'stop_reason=region_full'; has 'bytes_written=4194304'
run 0 "cfg: log_enable still 1" "$P" cfg; has 'log_enable=1'
run 0 "log-dump" "$P" log-dump "$T/b-id0a04.bin"
run 0 "decode" python3 "$DEC" "$T/b-id0a04.bin"; has '262143 records'
run 0 "log-start clears log_enable first" "$P" log-start; has 'log_enable was 1'
run 0 "log-stop" "$P" log-stop

echo "-- log status: whole or cut"
run 0 "region full with drops" python3 "$DEC" "$T/b-id0a04.bin" --region-bytes 0x400000; has 'status: FULL+DROPS'
run 0 "an early stop" python3 "$DEC" "$T/a-id0a04.bin"; has 'status: CUT+DROPS'
export PIPS_SIM_RECORDS=300000 PIPS_SIM_DROP_EVERY=0
run 0 "log-start, no drops" "$P" log-start
run 0 "log-wait" "$P" log-wait 100
run 0 "log-dump" bash -c "'$P' cfg set log=0 >/dev/null && '$P' log-dump '$T/f-id0a04.bin' && gzip -k '$T/f-id0a04.bin'"
run 0 "decode a .gz, write the .rpt" python3 "$DEC" "$T/f-id0a04.bin.gz" --region-bytes 0x400000 --rpt "$T/f.rpt"
has 'status: FULL: ran until the region filled'
grep -qx 'status: FULL' "$T/f.rpt" && grep -qx 'pips_records: 262143' "$T/f.rpt" &&
    grep -qx 'pips_full: 1' "$T/f.rpt" && grep -qx 'design_id: 0x0a04' "$T/f.rpt" &&
    grep -qx 'log_format: v2' "$T/f.rpt" && grep -q '^pips_out_wait_p99: ' "$T/f.rpt" &&
    ok "  rpt: status FULL, 262143 records, design, format, waits" || bad "  rpt: $(cat "$T/f.rpt")"
run 1 "region full but the wrong size is BAD" python3 "$DEC" "$T/f-id0a04.bin" --region-bytes 0x800000; has 'status: BAD'
head -c -16 "$T/f-id0a04.bin" > "$T/t-id0a04.bin"
run 1 "a dump missing its trailer is BAD" python3 "$DEC" "$T/t-id0a04.bin"; has 'status: BAD: the last record is not a trailer'
unset PIPS_SIM_DROP_EVERY

echo "-- older builds: 0x0a02 (no drain cap, v1 records), 0x0a03 (cap, v1), none"
export PIPS_SIM_DESIGN=0x0a02 PIPS_SIM_RECORDS=1000
run 0 "0x0a02: cfg" "$P" cfg; has 'design_id=0x0a02'; has 'log_format=v1'; has '^drain=none drain_depth_cap=0'
run 1 "0x0a02: cfg set cap=1 is refused" "$P" cfg set cap=1; has 'has no drain config register'
run 0 "0x0a02: hwtest regfile" "$P" hwtest regfile; has 'reserved registers 0x04-0x1c and 0x24-0x3c read 0 (0 do not'
    lacks 'reg1'
mkdir -p "$T/old"
run 0 "0x0a02: a v1 recording, pips-cfg.txt beside it" bash -c "'$P' cfg > '$T/old/pips-cfg.txt' &&
    '$P' log-clear && '$P' log-start && '$P' log-stop && '$P' log-dump '$T/old/pips-log.bin'"
run 0 "decode: design ID from pips-cfg.txt, v1" python3 "$DEC" "$T/old/pips-log.bin" --json "$T/old.json"
    has 'design 0x0a02, record format v1 (design ID from: pips-cfg.txt)'; has 'out / (in0 + in1) TLPs'
run 0 "json: v1 ports add up to 1000" python3 -c "
import json; s = json.load(open('$T/old.json')); p = s['ports']
assert s['log_format'] == 'v1' and s['ports']['out']['wait_mean'] is None
assert sum(v['tlp'] + v['dropped'] for v in p.values()) == 1000, p"
mkdir -p "$T/old2"; cp "$T/old/pips-log.bin" "$T/old2/"
run 0 "decode: no design ID anywhere: v1, as before IDs were recorded" python3 "$DEC" "$T/old2/pips-log.bin"
    has 'design none, record format v1 (design ID from: none found'; lacks 'NOTE: no out records'
run 1 "a v1 log read as v2 is BAD (port 2 records)" python3 "$DEC" "$T/old2/pips-log.bin" --design-id 0x0a04
    has 'status: BAD: unexpected records'
export PIPS_SIM_DESIGN=0x0a03
run 0 "0x0a03: cap works, log still v1" "$P" cfg set cap=1; has 'drain_depth_cap=1'; has 'log_format=v1'
run 0 "0x0a03: hwtest regfile" "$P" hwtest regfile; has 'reg1 wrote'; has 'log format v1; drain config register at +0x04'
run 0 "0x0a03: cap back to 0" "$P" cfg set cap=0
export PIPS_SIM_DESIGN=none
run 0 "no DESIGN_ID: cfg" "$P" cfg; has 'design_id=none'; has 'log_format=v1'
run 0 "no DESIGN_ID: hwtest regfile warns" "$P" hwtest regfile; has 'no DESIGN_ID (decode error'
run 1 "no DESIGN_ID: cap refused" "$P" cfg set cap=1
unset PIPS_SIM_DESIGN

echo "-- design 0x0a06: page batcher registers (reg2, reg3) and status (0x24-0x2c)"
export PIPS_SIM_DESIGN=0x0a06
run 0 "0x0a06: cfg shows pb and thr" "$P" cfg
    has '^pb=0x00000000 page_batch_en=0 ctrl_push_off=0 grant_quantum=0'; has '^thr=0x00000000 ctrl_dw_thr_0=0'
    has 'ctrl_dw_thr 0 = 16 DW'
run 0 "0x0a06: cfg set pb, pushoff, quantum, thr" "$P" cfg set pb=1 pushoff=1 quantum=256 thr=31
    has '^pb=0x01000101 page_batch_en=1 ctrl_push_off=1 grant_quantum=256'
    has '^thr=0x001f001f ctrl_dw_thr_0=31 ctrl_dw_thr_1=31'
run 0 "0x0a06: thr0 and thr1 apart" "$P" cfg set thr0=4 thr1=16; has 'ctrl_dw_thr_0=4 ctrl_dw_thr_1=16'
run 0 "0x0a06: pips_tag_of the whole setting" bash -c ". '$HERE/pips-lib.sh'
    '$P' cfg set depth=8 time=106 cap=1 > '$T/c6.txt' && pips_tag_of '$T/c6.txt'"
    has '^d8t106c1p1o1q256w4x16$'
run 1 "0x0a06: quantum 4096 refused" "$P" cfg set quantum=4096
run 0 "0x0a06: raw2/raw3 put everything back" "$P" cfg set raw2=0 raw3=0 cap=0 raw=1
    has '^pb=0x00000000'; has '^thr=0x00000000'; has 'cfg=0x00000001'
run 0 "0x0a06: hwtest regfile" "$P" hwtest regfile
    has 'reg2 wrote 0x02aa0155 read 0x02aa0155'; has 'reg3 wrote 0x0a5a0100'; has 'status flags at +0x24'
    has 'reserved registers 0x10-0x1c and 0x30-0x3c read 0 (0 do not'
    has 'page batcher registers at +0x08/+0x0c'
run 0 "0x0a06: status with no traffic" "$P" status; has '^status=ok'; has 'stuck=0'; has 'ovf_count_0=0'
export PIPS_SIM_STAT="5,12,3,3000,40"
run 0 "0x0a06: a recording, then the status reports it" bash -c "'$P' log-clear > /dev/null &&
    '$P' log-start > /dev/null && '$P' log-stop > /dev/null && '$P' status"
    has 'stat_flags=0x00000005 ovf0=1 ovf1=0 stuck=1'; has 'ovf_count_0=12 ovf_count_1=3'
    has 'mrd_wait_max_us_0=12.00'; has 'STUCK'
run 0 "0x0a06: that read cleared it" "$P" status; has 'stuck=0'; has 'ovf_count_0=0 ovf_count_1=0'
unset PIPS_SIM_STAT
export PIPS_SIM_DESIGN=0x0a05
run 0 "0x0a05: status says none" "$P" status; has '^status=none'
run 1 "0x0a05: pb refused" "$P" cfg set pb=1; has 'has no page batcher registers'
run 0 "0x0a05: cfg lists pb=none" "$P" cfg; has '^pb=none page_batch_en=0'
unset PIPS_SIM_DESIGN

echo "-- design 0x0a07: rate caps (reg4) and refused-cycle counters (0x30-0x3c)"
export PIPS_SIM_DESIGN=0x0a07
run 0 "0x0a07: cfg shows rcap" "$P" cfg; has '^rcap=0x00000000 rate_cap_0=0 rate_cap_1=0 rate_cap_out=0'
run 0 "0x0a07: cfg set rcap (both inputs) and rcapout" "$P" cfg set rcap=100 rcapout=200
    has '^rcap=0x00c86464 rate_cap_0=100 rate_cap_1=100 rate_cap_out=200'; has 'in0 50.0, in1 50.0, out 100.0'
run 0 "0x0a07: rcap0 alone" "$P" cfg set rcap0=7; has 'rate_cap_0=7 rate_cap_1=100 rate_cap_out=200'
run 0 "0x0a07: pips_tag_of with rate caps" bash -c ". '$HERE/pips-lib.sh'
    '$P' cfg set depth=8 time=106 cap=1 pb=0 pushoff=0 quantum=0 thr=31 > '$T/c7.txt' && pips_tag_of '$T/c7.txt'"
    has '^d8t106c1w31r7x100x200$'
run 1 "0x0a07: rcap 256 refused" "$P" cfg set rcap=256
run 0 "0x0a07: raw4 puts it back" "$P" cfg set raw4=0 raw2=0 raw3=0 cap=0 raw=1; has '^rcap=0x00000000'
run 0 "0x0a07: hwtest regfile" "$P" hwtest regfile
    has 'reg4 wrote 0x00a55ac3 read 0x00a55ac3'; has 'counters at +0x30-+0x3c answer'
    has 'reserved registers 0x14-0x1c read 0 (0 do not'; has 'rate caps at +0x10'
export PIPS_SIM_BP="1000,2000,0,5"
run 0 "0x0a07: counters" "$P" counters; has '^counters=ok'; has 'bp_cycles_0=[0-9]* bp_cycles_1='
run 0 "0x0a07: status shows the counters too" "$P" status; has '^status=ok'; has '^bp_cycles_0='
run 0 "0x0a07: pips_bp_summary over wrapped samples" bash -c ". '$HERE/pips-lib.sh'
    printf 'ms\tb0\tb1\th0\th1\n0\t4000000000\t0\t0\t0\n2000\t200000000\t1000000\t0\t0\n' > '$T/bp.tsv'
    pips_bp_summary '$T/bp.tsv'"
    has '^pips_stat_bp_valid: 1'; has '^pips_stat_bp_cycles_0: 494967296$'; has '^pips_stat_bp_frac_0: 0.9899'
unset PIPS_SIM_BP
export PIPS_SIM_DESIGN=0x0a06
run 0 "0x0a06: counters says none" "$P" counters; has '^counters=none'
run 1 "0x0a06: rcap refused" "$P" cfg set rcap=10; has 'has no rate caps'
run 0 "0x0a06: cfg lists rcap=none" "$P" cfg; has '^rcap=none rate_cap_0=0'
unset PIPS_SIM_DESIGN

echo "-- analysis tools on both formats"
# A v2 sweep run folder as the runners write it, and a v1 one from before.
NEW="$T/logs/dualssd-pips-off-1-id0a04-d8t22c1/4k-j1-both-RUN-0"
OLD="$T/logs/dualssd-pips-off-1-d8t22/4k-j1-both-RUN-0"
mkdir -p "$NEW" "$OLD"
"$P" cfg set depth=8 time=22 cap=1 > "$NEW/pips-cfg.txt"; "$P" cfg set raw=1 cap=0 > /dev/null
gzip -c "$T/a-id0a04.bin" > "$NEW/pips-log-id0a04.bin.gz"
sed 's/^cfg=0x00000001 depth_threshold=1 time_threshold=0/cfg=0x00001608 depth_threshold=8 time_threshold=22/' \
    "$T/old/pips-cfg.txt" > "$OLD/pips-cfg.txt"
gzip -c "$T/old/pips-log.bin" > "$OLD/pips-log.bin.gz"
run 0 "pips-addr-pattern.py: both, found in their folders" python3 "$HERE/pips-addr-pattern.py" "$T/logs" --jsonl "$T/ap.jsonl"
    has 'id0a04-d8t22c1/4k-j1-both-RUN-0 *0a04'; has 'd8t22/4k-j1-both-RUN-0 *0a02'
run 0 "  json: design, format, v2 hold from pkt_wait" python3 -c "
import json; r = [json.loads(l) for l in open('$T/ap.jsonl')]
f = {x['design_id']: x for x in r}
assert set(f) == {'0x0a02', '0x0a04'}, list(f)
assert f['0x0a04']['log_format'] == 'v2' and f['0x0a04']['out']['unmatched'] == 0
assert f['0x0a04']['out']['hold_us_p50'] and f['0x0a04']['out']['hold_rec_p50'] is None
assert f['0x0a02']['log_format'] == 'v1'"
run 0 "pips-page-seq.py v2" python3 "$HERE/pips-page-seq.py" "$NEW/pips-log-id0a04.bin.gz" --iotlb 1x64 --csv "$T/ps.csv" --show 5
    has 'design 0x0a04, record format v2'; has 'Batching what-if'
head -1 "$T/ps.csv" | grep -q '^# design_id=0x0a04 log_format=v2' && ok "  csv design line" || bad "  csv: $(head -1 "$T/ps.csv")"
run 0 "pips-page-seq.py v1" python3 "$HERE/pips-page-seq.py" "$OLD/pips-log.bin.gz"; has 'design 0x0a02, record format v1'
run 0 "pips-mwr-sizes.py: both, labelled from folders" python3 "$HERE/pips-mwr-sizes.py" "$T/logs" --by design,cfg --csv "$T/ms.csv"
    has 'd8t22c1 *0a04 *in0'; has 'd8t22 *0a02 *in0'; has 'design 0x0a04, cfg d8t22c1'; has 'design 0x0a02, cfg d8t22'
grep -q ',0x0a04,in0,' "$T/ms.csv" && ok "  csv design column" || bad "  csv: $(head -2 "$T/ms.csv")"
run 0 "pips-mwr-sizes.py --show out, v2" python3 "$HERE/pips-mwr-sizes.py" "$NEW/pips-log-id0a04.bin.gz" --show 3 --port out
    has 'design 0x0a04, format v2'

echo "-- pips-traffic.py: payload vs ring writes on every log, synthetic NVMe and NIC traffic"
# Logs as two NVMe drives or two NICs write them (the model's records are not
# device-like): ssd = 16 x 64 DW of data, a 4 DW completion entry, an MSI per
# I/O; nic = a 4000 B packet as 15 x 64 DW + 40 DW at headroom 64, a 16 DW
# entry, an MSI and a descriptor read every 8 packets; nic-il = two packets'
# data interleaved TLP by TLP, then both entries; nic-il0 = as the NICs on icx
# write when held back: two 4032 B packets from offset 0 as 7 x 128 DW + 112 DW,
# interleaved, the previous pair's entries after 3 TLPs; ssd-pair = two I/Os' data,
# then both entries back to back. The two devices' TLPs interleave in batches.
cat > "$T/synth.py" <<'EOF'
import gzip, random, struct, sys
kind, out, fmt = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "v2"
rng, MSI = random.Random(1), 0xFEE00000
def device(src):
    base = 0x100000000 * (src + 1)
    cq = [base + 0x80000000 + 0x1000 * q for q in range(4)]
    cqi, n = [0] * 4, 0
    while True:
        q, buf = rng.randrange(4), base + 0x1000 * rng.randrange(256)
        buf2 = base + 0x1000 * rng.randrange(256, 512)
        if kind in ("ssd", "ssd-pair"):
            bufs = (buf, buf2) if kind == "ssd-pair" else (buf,)
            yield (cq[q] - 0x10000 + 64 * cqi[q] % 0x1000, 0, 0)
            for b in bufs:
                for i in range(16):
                    yield (b + 256 * i, 64, 1)
            for b in bufs:
                yield (cq[q] + 16 * cqi[q], 4, 1); cqi[q] = (cqi[q] + 1) % 256
            yield (MSI + 0x1000 * q, 1, 1)
        elif kind == "nic-il0":
            for i in range(8):
                if i == 3 and n:
                    for _ in range(2):
                        yield (cq[q] + 64 * cqi[q], 16, 1); cqi[q] = (cqi[q] + 1) % 64
                for b in (buf, buf2):
                    yield (b + 512 * i, 128 if i < 7 else 112, 1)
        else:
            bufs = (buf, buf2) if kind == "nic-il" else (buf,)
            if n % 8 == 0:
                yield (cq[q] - 0x10000 + 64 * (n // 8 % 64), 0, 0)
            for i in range(16):
                for b in bufs:
                    yield (b + 64 + 256 * i, 64 if i < 15 else 40, 1)
            for b in bufs:
                yield (cq[q] + 64 * cqi[q], 16, 1); cqi[q] = (cqi[q] + 1) % 64
            if n % 8 == 7:
                yield (MSI + 0x1000 * q, 1, 1)
        n += 1
gens, recs = [device(0), device(1)], []
while len(recs) < 20000:
    s = rng.randrange(2)
    for _ in range(rng.randrange(1, 5)):
        addr, pdw, typ = next(gens[s])
        beats = -(-(16 + 4 * pdw) // 64) if typ == 1 else 1
        if fmt == "v2":
            recs.append(struct.pack("<QBBBBHBB", addr, beats, 2, typ, pdw, 4 + rng.randrange(200), 0x80 | s, 0))
        else:
            recs.append(struct.pack("<QBBBBBBBB", addr, beats, 2, typ, pdw, 0, 0, 0x80 | s, 0))
            recs.append(struct.pack("<QBBBBBBBB", addr, beats, 2, typ, pdw, 0, 0, 0x82, 0))
recs = recs[:20000]
with gzip.open(out, "wb") as f:
    f.write(b"".join(recs) + struct.pack("<IIIBBBB", len(recs), 0, 5 * len(recs), 2, 0, 0x88, 0))
EOF
TL="$T/tlogs"
mk() {   # <kind> <run folder> <log name> [v1]
    mkdir -p "$TL/$2" && python3 "$T/synth.py" "$1" "$TL/$2/$3" "${4:-v2}"
}
mk ssd dualssd-pips-strict-2-id0a04-d8t22/4k-j8-both-RUN-0 pips-log-id0a04.bin.gz
mk ssd-pair dualssd-pips-strict-2-id0a04-d8t22c1/4k-j8-both-RUN-0 pips-log-id0a04.bin.gz
mk nic dualnic-pips-strict-1-id0a04-d8t22-uncapped-f5-both-RUN-server-0 pips-log-id0a04.bin.gz
mk nic-il dualnic-pips-strict-1-id0a04-d8t22c1-uncapped-f5-both-RUN-server-0 pips-log-id0a04.bin.gz
mk ssd dualssd-pips-off-1-d8t22/4k-j1-both-RUN-0 pips-log.bin.gz v1
printf 'design_id=0x0a02\n' > "$TL/dualssd-pips-off-1-d8t22/4k-j1-both-RUN-0/pips-cfg.txt"
mkdir -p "$TL/dualssd-pips-off-1-d8t22/4k-j2-both-RUN-0"
printf 'cut short' | gzip | head -c 12 > "$TL/dualssd-pips-off-1-d8t22/4k-j2-both-RUN-0/pips-log.bin.gz"
run 0 "every log, a line as each is done, a cut .gz skipped" python3 "$HERE/pips-traffic.py" "$TL" -j 2 \
    --csv "$T/tr.csv" --jsonl "$T/tr.jsonl"
    has '^pips-traffic: 6 log(s) under'; has '^\[[1-6]/6\] .*SKIPPED: EOFError'
    has '^\[[1-6]/6\] .*4k-j1-both-RUN-0/pips-log.bin.gz: v1 0x0a02 FULL'
    has 'pips-traffic: 5 log(s) analysed, 1 skipped'
    has '^  ssd 0x0a04 in0: ring if <= 4 DW: 100.000% .*ring sizes 4, payload 64 -> RELIABLE'
    has '^  ssd 0x0a02 in1: ring if <= 4 DW: 100.000% .* -> RELIABLE'
    has '^  nic 0x0a04 in1: ring if <= 16 DW: 100.000% .*ring sizes 16, payload 64:94%,40:6% -> RELIABLE'
    has '100.0%  64x16 -> 1$'; has '64x15 40 -> 1$'; has '64x30 40x2 -> 2$'; has '64x32 -> 2$'
    has '== kind nic  design 0x0a04  iommu strict  cfg d8t22c1  (format v2)'; has 'time in batcher, us mean/p99: payload'
[ "$(wc -l < "$T/tr.jsonl")" -eq 5 ] && head -1 "$T/tr.csv" | grep -q '^path,kind,sweep,iommu,cfg,design_id,log_format' &&
    grep -q ',nic,dualnic-pips-strict-1-id0a04-d8t22c1,strict,d8t22c1,0x0a04,v2,uncapped f5,both,FULL,in0,16,' "$T/tr.csv" &&
    ok "  csv and jsonl, labelled" || bad "  csv/jsonl: $(head -3 "$T/tr.csv")"
run 0 "--format v2 --by kind,load, one log --detail" bash -c "
    python3 '$HERE/pips-traffic.py' '$TL' --format v2 --by kind,load -j 1 &&
    python3 '$HERE/pips-traffic.py' '$TL/dualssd-pips-strict-2-id0a04-d8t22/4k-j8-both-RUN-0/pips-log-id0a04.bin.gz' --detail"
    has '^pips-traffic: 4 log(s) under'; has '== kind nic  load uncapped f5'; has '== kind ssd  load 4k j8'
    has '^      DW    writes  share  burst payload'
run 2 "--by bogus is refused" python3 "$HERE/pips-traffic.py" "$TL" --by bogus

echo "-- pips-page-seq.py on NIC logs, pips-seq-grab.sh"
NICLOG="$TL/dualnic-pips-strict-1-id0a04-d8t22-uncapped-f5-both-RUN-server-0/pips-log-id0a04.bin.gz"
run 0 "page-seq: kind nic from the path, 16 DW writes are completions" \
    python3 "$HERE/pips-page-seq.py" "$NICLOG" --json "$T/psn.jsonl"
    has 'kind nic; design 0x0a04'; lacks ' 0 I/Os'
run 0 "  json: kind nic, one I/O per packet" python3 -c "
import json; r = json.loads(open('$T/psn.jsonl').readline())
assert r['kind'] == 'nic' and 1000 < r['ios'] < 1300, (r['kind'], r['ios'])"
run 0 "  --kind ssd on the same log finds no I/Os" python3 "$HERE/pips-page-seq.py" "$NICLOG" --kind ssd
    has ' 0 I/Os'
IL0="$T/tl0/dualnic-pips-strict-1-id0a04-d1t0c1-uncapped-f5-both-RUN-server-0"
mkdir -p "$IL0" && python3 "$T/synth.py" nic-il0 "$IL0/pips-log-id0a04.bin.gz"
run 0 "  two packets at once: each open to its short last TLP, a completion between closes neither" \
    python3 "$HERE/pips-page-seq.py" "$IL0/pips-log-id0a04.bin.gz" --port in0 --show 400 --from 1000 --json "$T/il0.jsonl"
    lacks '[0-9] gap '; has ' 2/0 *$'
run 0 "  json: in0 has 2 pages open, 1 TLP per run" python3 -c "
import json; r = json.loads(open('$T/il0.jsonl').readline())['interleave']['in0']
assert r['open']['0'][3] == 2 and r['open']['0'][0] > 1.5 and r['run_mean'] < 1.2, r"

echo "-- pips-page-seq.py: arrival order and the batcher model"
# A v2 log written by the model itself: two drives whose TLPs arrive
# interleaved one by one, sent as d16t64 would (a cycle per beat, the 3-cycle
# grant gap, no link limit). Rebuilding the arrival order from gap and
# pkt_wait and running the model on it as d16t64 (default grant gap, --link
# none) must give back the logged order and waits.
cat > "$T/synthb.py" <<'EOF'
import gzip, importlib.util, random, struct, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1]); ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)
rng, MSI = random.Random(7), 0xFEE00000
BEATS, PDW = dict(data=5, cqe=1, msi=1, mrd=1), dict(data=64, cqe=4, msi=1, mrd=16)
CYC = BEATS                                    # the datapath: a cycle per 64-byte beat
def device(src):
    base, t, k = 0x10000000 * (src + 1), rng.randrange(50), 0
    while True:
        page = base + 0x1000 * rng.randrange(4096)
        yield (t, src, "mrd", base + 0x8000000 + 64 * (k % 64)); t += 3
        for i in range(16):
            yield (t, src, "data", page + 256 * i); t += 9 if src == 0 else 11
        yield (t, src, "cqe", base + 0x9000000 + 16 * (k % 256)); t += 2
        yield (t, src, "msi", MSI + 0x1000 * src); t += 40 + rng.randrange(200); k += 1
gens = [device(0), device(1)]; heads = [next(g) for g in gens]; tlps = []
while len(tlps) < 20000:
    s = 0 if heads[0][0] <= heads[1][0] else 1
    tlps.append(heads[s]); heads[s] = next(gens[s])
sent = ps.batcher([(t, s, c, BEATS[c], CYC[c]) for t, s, c, _a in tlps], 16, 64, 0, 0, None, 128, ps.GRANT_GAP)
recs, eop = [], None
for j, start, _d in sent:
    t, s, c, addr = tlps[j]
    gap = 0 if eop is None else min(255, start - eop - 1); eop = start + BEATS[c] - 1
    recs.append(struct.pack("<QBBBBHBB", addr, BEATS[c], gap, 0 if c == "mrd" else 1, PDW[c], start - t, 0x80 | s, 0))
with gzip.open(sys.argv[2], "wb") as f:
    f.write(b"".join(recs) + struct.pack("<IIIBBBB", len(recs), 0, eop + 1, 2, 0, 0x88, 0))
EOF
BL="$T/tlb/dualssd-pips-strict-3-id0a04-d16t64/4k-j8-both-RUN-0"
mkdir -p "$BL" && python3 "$T/synthb.py" "$HERE/pips-page-seq.py" "$BL/pips-log-id0a04.bin.gz"
run 0 "model on the rebuilt arrival order: self (d16t64, from the path), std, sweep (no link limit)" \
    python3 "$HERE/pips-page-seq.py" "$BL/pips-log-id0a04.bin.gz" --iotlb 1x64 --strict --model self,std,sweep \
    --link none --show 40 --from 5000 --port out,arr --json "$T/mb.jsonl"
    has '^arr: the sequence'; has '^out: the sequence'; has '^Arrival order (arr)'
    has '^ *d16t64 '; has '^ *d64t255 '; has '^ *recorded .*(d16t64, as logged on out)'
    has 'drains asked for by'; has '^ *d64t255 .* depth 0% time'
run 0 "  json: d16t64 on the arrival order gives back the logged order and waits; arrivals were interleaved" python3 -c "
import json; r = json.loads(open('$T/mb.jsonl').readline())
m = {x['setting']: x for x in r['model']}; rec = r['recorded']
assert r['setting'] == 'd16t64' and len(m) == 15, (r['setting'], list(m))
assert abs(m['d16t64']['runs']['drive'] - rec['runs']) < 1e-9, (m['d16t64']['runs'], rec)
assert abs(m['d16t64']['wait_mean_us'] - rec['wait_mean_us']) < 1e-9, (m['d16t64'], rec)
assert r['interleave']['arr']['run_mean'] < 2 < r['interleave']['out']['run_mean'], r['interleave']
assert r['windows_arr'][0]['runs']['drive'] > m['d1t0']['runs']['drive'] > m['d16t64']['runs']['drive'], m
assert r['arrival']['segments'] == 1 and r['arrival']['moved'] > 0.5, r['arrival']"
run 0 "  json: what asked for each drain (depth, time, full, read flush), counted per drain" python3 -c "
import json; r = json.loads(open('$T/mb.jsonl').readline())
m = {x['setting']: x for x in r['model']}
for x in m.values():
    assert sum(x['triggers'].values()) == x['drains'], (x['setting'], x['triggers'], x['drains'])
    assert x['triggers'] == {k: x['triggers_in'][0][k] + x['triggers_in'][1][k] for k in x['triggers']}, x
t = m['d1t0']['triggers']; assert t['depth'] > 0.9 * m['d1t0']['drains'] and t['time'] == 0, t
t = m['d16t64']['triggers']; assert t['time'] > t['depth'], t          # 16 TLPs take 135+ cycles
t = m['d64t255']['triggers']; assert t['depth'] == 0 and t['flush'] > 0, t  # 64 x 5 beats never fit
assert m['d4t255']['triggers']['depth'] > m['d4t22']['triggers']['depth'], (m['d4t255'], m['d4t22'])
assert all(x['fifo'] == 128 for x in m.values()) and r['fifo'] == 128 and r['link']['bytes_per_cycle'] is None, r['link']
assert r['grant_gap'] == 3 and r['model_cycles_per_tlp'] < 5, r['model_cycles_per_tlp']"
run 0 "  the uplink: a drive log's default is gen3x8, 9.2 cycles per 256 B TLP; sweepc1, f512 suffixes" \
    python3 "$HERE/pips-page-seq.py" "$BL/pips-log-id0a04.bin.gz" --strict --model self,sweepc1,sweepc1f512,d24t255c1f512 \
    --json "$T/ml.jsonl"
    has 'no faster than the uplink, gen3x8 (30.2 bytes per cycle: 9.19 cycles per 256 B TLP)'
    has '^ *d64t255c1f512 '; has 'FIFO 128 beats per input (design 0x0a04)'
run 0 "  json: the link slows the output and lengthens the waits; FIFO sizes per setting" python3 -c "
import json
r = json.loads(open('$T/mb.jsonl').readline()); l = json.loads(open('$T/ml.jsonl').readline())
m0 = {x['setting']: x for x in r['model']}; m1 = {x['setting']: x for x in l['model']}
assert abs(l['link']['bytes_per_cycle'] - 30.25) < 0.05 and l['link']['name'] == 'gen3x8', l['link']
assert l['model_cycles_per_tlp'] > r['model_cycles_per_tlp'] + 1, (l['model_cycles_per_tlp'], r['model_cycles_per_tlp'])
assert m1['d16t64']['wait_mean_us'] > m0['d16t64']['wait_mean_us'], (m1['d16t64'], m0['d16t64'])
assert len(m1) == 1 + 7 + 7 + 1 and m1['d8t255c1']['fifo'] == 128 and m1['d8t255c1f512']['fifo'] == 512, list(m1)
assert m1['d24t255c1f512']['cap'] == 1 and m1['d24t255c1f512']['depth'] == 24, m1['d24t255c1f512']"
run 0 "  batcher: depth 24 of 5-beat packets asks on the full trigger in 128 beats, on depth in 512" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('ps', '$HERE/pips-page-seq.py'); ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)
arr = [(5 * i, 0, 'data', 5, 9) for i in range(200)]
for fb, want in ((128, 'full'), (512, 'depth')):
    st = {}; out = ps.batcher(arr, 24, 255, 1, 0, st, fb)
    t = st['triggers'][0]; assert len(out) == 200 and max(t, key=t.get) == want, (fb, t)
assert ps.fifo_limits(128) == (109, 93) and ps.fifo_limits(512) == (493, 477)
assert ps.cycles('data', 64, 5, ps.link_bpc('gen3x8')) > 9.1
assert ps.cycles('data', 128, 9, ps.link_bpc('gen4x8')) == 9   # icx: the datapath binds
# the grant gap: depth 1 with the cap, one-TLP drains. Two backed-up inputs take turns: no gap (two NICs
# carry ~105 Gbps under d1t0c1); one input alone pays it on every drain (9 beats + 3, ~80 Gbps for one NIC)
arr = [(0, i % 2, 'data', 9, 9) for i in range(40)]
out = ps.batcher(arr, 1, 0, 1, 0, None, 128, 3)
gaps = {b[1] - a[1] for a, b in zip(out[1:], out[2:])}         # after the first grant
assert gaps == {9} and out[1][1] == 12, (gaps, out[:2])
assert len({d for _j, _s, d in out}) == 40 and [arr[j][1] for j, _s, _d in out[:4]] == [0, 1, 0, 1]
out = ps.batcher([(0, 0, 'data', 9, 9) for _ in range(20)], 1, 0, 1, 0, None, 128, 3)
assert {b[1] - a[1] for a, b in zip(out, out[1:])} == {12}, out
out = ps.batcher([(0, 0, 'data', 9, 9) for _ in range(16)], 16, 0, 0, 0, None, 512, 3)
assert [b[1] - a[1] for a, b in zip(out, out[1:])] == [12] + [9] * 14, out   # the gap at the grant only
assert ps.cycles('data', 64, 5, ps.link_bpc('gen3x8')) > 5 + 3  # bigserver: the link hides the gap
assert ps.parse_setting('d24t255c1f512') == (24, 255, 1, 0) and ps.setting_fifo('d24t255c1f512') == 512
assert ps.setting_fifo('d24t255c1') is None"
# A busy Gen3 x8 uplink: the output stalls inside packets, which neither pkt_length nor pkt_gap counts
# (pkt_wait does), so the logged output runs short of the trailer's duration. synths.py writes such a log:
# the true output holds a TLP for max(beats, its time on a 30.89 B/cycle link), the records keep the beats.
cat > "$T/synths.py" <<'EOF'
import gzip, importlib.util, random, struct, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1]); ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)
out, setting, n, pause = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
rng, MSI = random.Random(11), 0xFEE00000
BEATS, PDW = dict(data=5, cqe=1, msi=1, mrd=1), dict(data=64, cqe=4, msi=1, mrd=0)
CPB = 9.0 / 278                                # cycles per wire byte: 9 cycles per 256 B TLP
COST = {c: max(BEATS[c], ((0 if c == "mrd" else 4 * PDW[c]) + 22) * CPB) for c in BEATS}
def device(src):                               # drive 0: two pages two TLPs at a time; drive 1: four pages one at a time
    base, t, k = 0x10000000 * (src + 1), rng.randrange(50), 0
    while True:
        npg, step = (2, 2) if src == 0 else (4, 1)
        pages = [base + 0x1000 * rng.randrange(1 << 16) for _ in range(npg)]
        yield (t, src, "mrd", base + 0x8000000 + 64 * (k % 64)); t += 3
        for i in range(0, 16, step):
            for pg in pages:
                for j in range(step):
                    yield (t, src, "data", pg + 256 * (i + j)); t += COST["data"] * 2 / 0.97 * rng.uniform(0.6, 1.4)
        for _ in pages:
            yield (t, src, "cqe", base + 0x9000000 + 16 * (k % 256)); t += 2; k += 1
        yield (t, src, "msi", MSI + 0x1000 * src); t += 20
gens = [device(0), device(1)]; heads = [next(g) for g in gens]; tlps = []
while len(tlps) < n:
    s = 0 if heads[0][0] <= heads[1][0] else 1
    tlps.append(heads[s]); heads[s] = next(gens[s])
tlps = [(int(t) + pause * (k // 6000), s, c, a) for k, (t, s, c, a) in enumerate(tlps)]   # pauses: saturated gaps
d, tm, cap, m = ps.parse_setting(setting)
sent = ps.batcher([(t, s, c, BEATS[c], COST[c]) for t, s, c, _a in tlps], d, tm, cap, m, None, 128, ps.GRANT_GAP)
recs, eop = [], None
for j, start, _d in sent:
    t, s, c, addr = tlps[j]; start = int(round(start))
    gap = 0 if eop is None else max(0, min(255, start - eop - 1)); eop = start + int(round(COST[c])) - 1
    recs.append(struct.pack("<QBBBBHBB", addr, BEATS[c], gap, 0 if c == "mrd" else 1, PDW[c], max(4, start - t), 0x80 | s, 0))
with gzip.open(out, "wb") as f:
    f.write(b"".join(recs) + struct.pack("<IIIBBBB", len(recs), 0, eop + 1, 2, 0, 0x88, 0))
EOF
SL="$T/tls"
for set in d1t0c1 d4t22 d16t64c1; do
    mkdir -p "$SL/dualssd-pips-strict-4-id0a04-$set/1m-j8-both-RUN-0" &&
        python3 "$T/synths.py" "$HERE/pips-page-seq.py" "$SL/dualssd-pips-strict-4-id0a04-$set/1m-j8-both-RUN-0/pips-log-id0a04.bin.gz" $set 24000 0
done
mkdir -p "$SL/dualssd-pips-strict-4-id0a04-d16t64c1/1m-j1-both-RUN-0" &&
    python3 "$T/synths.py" "$HERE/pips-page-seq.py" "$SL/dualssd-pips-strict-4-id0a04-d16t64c1/1m-j1-both-RUN-0/pips-log-id0a04.bin.gz" d16t64c1 24000 3000
SLOG="$SL/dualssd-pips-strict-4-id0a04-d16t64c1/1m-j8-both-RUN-0/pips-log-id0a04.bin.gz"
PLOG="$SL/dualssd-pips-strict-4-id0a04-d16t64c1/1m-j1-both-RUN-0/pips-log-id0a04.bin.gz"
run 0 "stalls inside packets: --calibrate fits the link (30.89 B/cycle) on a clean full-link log" \
    python3 "$HERE/pips-page-seq.py" "$SLOG" --calibrate
    has '^calibrate: segments 1 lost 0\.[34][0-9]* fit 3[01]\.[0-9]* clean 1$'
python3 -c "
import re, sys; v = float(re.search(r'fit (\S+)', open('$T/out').read()).group(1))
sys.exit(0 if abs(v / 30.89 - 1) < 0.01 else 1)" && ok "  fit within 1% of the true link" || bad "  fit: $(cat "$T/out")"
run 0 "  ... and a log whose output idles past saturated gaps is not clean" \
    python3 "$HERE/pips-page-seq.py" "$PLOG" --calibrate
    has '^calibrate: segments [0-9]* lost .* clean 0$'
run 0 "  the model on the rebuilt arrivals gives back the logged order and waits" \
    python3 "$HERE/pips-page-seq.py" "$SLOG" --model self,d16t255c1 --json "$T/ms.jsonl"
    has 'stalls inside packets put back with the link at 30\.9 bytes per cycle'; has 'gen3x8 fitted above'
run 0 "  json: fitted link, no input reordered, the model's own setting within 2% (and its waits within 15%)" python3 -c "
import json; r = json.loads(open('$T/ms.jsonl').readline())
m = {x['setting']: x for x in r['model']}; rec = r['recorded']; a = r['arrival']
assert r['link']['fitted'] and abs(r['link']['bytes_per_cycle'] / 30.89 - 1) < 0.01, r['link']
assert a['lost'] > 0.3 and a['held'] < 0.001 and a['segments'] == 1, a
assert abs(m['d16t64c1']['runs']['drive'] / rec['runs'] - 1) < 0.02, (m['d16t64c1']['runs'], rec)
assert abs(m['d16t64c1']['wait_mean_us'] / rec['wait_mean_us'] - 1) < 0.15, (m['d16t64c1'], rec)"
run 0 "  --link-rate: the paused log keeps the measured link, its idle goes to the saturated gaps" \
    python3 "$HERE/pips-page-seq.py" "$PLOG" --model self --link-rate 30.9
    has 'link at 30\.9 bytes per cycle'; has 'more idle cycles at each saturated gap'
run 0 "pips-seq-grab.sh: a calibration pass first, the median of the clean logs passed on as --link-rate" \
    bash "$HERE/pips-seq-grab.sh" ssd --logs "$SL" --sweep dualssd-pips-strict-4-id0a04 --sets "d1t0c1 d4t22 d16t64c1" \
    --points "1m-j8-both 1m-j1-both" --model self -j 2 -o "$T/grab-cal"
    has 'calibrating the uplink on 4 logs'; has 'calibrate \[4/4\]'; has 'median fit of 3 clean logs'
grep -q '^uplink rate 3[01]\.[0-9]* bytes per cycle: the median fit of 3 clean logs' "$T/grab-cal/manifest.txt" &&
    [ "$(wc -l < "$T/grab-cal/calibrate.txt")" -eq 4 ] && grep -q '"rate_given": 3[01]\.' "$T/grab-cal/seq.jsonl" &&
    ok "  manifest, calibrate.txt, --link-rate in every log" || bad "  grab-cal: $(cat "$T/grab-cal/manifest.txt")"
run 2 "  --link with no such link is refused" \
    python3 "$HERE/pips-page-seq.py" "$BL/pips-log-id0a04.bin.gz" --model self --link gen3x9
    has 'not a link'
run 2 "  --model self without a setting in the path is refused" \
    python3 "$HERE/pips-page-seq.py" "$T/synth-nosetting.bin.gz" --model self
    has 'no setting in the'
run 0 "  a v1 log: no arrival order, no model, a note" python3 "$HERE/pips-page-seq.py" \
    "$TL/dualssd-pips-off-1-d8t22/4k-j1-both-RUN-0/pips-log.bin.gz" --model std --port out,arr --show 5
    has 'has no pkt_wait: no arrival order or model'; lacks '^arr: the sequence'; has '^out: the sequence'

run 0 "pips-seq-grab.sh nic: a log per setting and point, missing ones listed, packed" \
    bash "$HERE/pips-seq-grab.sh" nic --logs "$TL" --sets "d8t22 d8t22c1" --points "f5-both f30-both" -j 2 -o "$T/grab"
    has '2 logs (2 points), 2 missing'; has '2 of 2 logs analysed'; has '\[2/2\] done '
[ -f "$T/grab.tar.gz" ] && [ "$(wc -l < "$T/grab/seq.jsonl")" -eq 2 ] && [ -s "$T/grab/seq-d8t22c1-f5-both.txt" ] &&
    grep -q '^missing  d8t22 f30-both' "$T/grab/manifest.txt" && ok "  files and manifest" ||
    bad "  grab output: $(ls "$T/grab" 2>&1)"
run 1 "  an existing output folder is refused" bash "$HERE/pips-seq-grab.sh" nic --logs "$TL" -o "$T/grab"
grep -q '"model": \[' "$T/grab/seq.jsonl" && grep -q '^arr: the sequence' "$T/grab/seq-d8t22-f5-both.txt" &&
    ok "  model and arrival order in the grab" || bad "  grab: no model or arr listing"
mkdir -p "$TL/dualssd-pips-strict-2-id0a04-d8t22/4k-j2+16-both-RUN-0" &&
    cp "$TL/dualssd-pips-strict-2-id0a04-d8t22/4k-j8-both-RUN-0/pips-log-id0a04.bin.gz" \
       "$TL/dualssd-pips-strict-2-id0a04-d8t22/4k-j2+16-both-RUN-0/"
mkdir -p "$TL/dualssd-pips-strict-2-id0a04-d8t22/datapath-4k-j1-RUN-0"
run 0 "pips-seq-grab.sh ssd, every point: uneven co-runs in, datapath checks out" \
    bash "$HERE/pips-seq-grab.sh" ssd --logs "$TL" --sweep dualssd-pips-strict-2-id0a04 --sets "d8t22 d8t22c1" \
    --model self -o "$T/grab-all"
    has '3 logs (2 points), 1 missing'; has '3 of 3 logs analysed'
grep -q '^points: 4k-j2+16-both 4k-j8-both$' "$T/grab-all/manifest.txt" &&
    grep -q '^missing  d8t22c1 4k-j2+16-both' "$T/grab-all/manifest.txt" && ok "  points found" ||
    bad "  points: $(grep -E '^(points|missing)' "$T/grab-all/manifest.txt")"
run 0 "pips-seq-grab.sh ssd on a v1 sweep" bash "$HERE/pips-seq-grab.sh" ssd --logs "$TL" \
    --sweep dualssd-pips-off-1 --sets d8t22 --points 4k-j1-both -o "$T/grab-ssd"
    has '1 of 1 logs analysed'
grep -q 'record format v1' "$T/grab-ssd/seq-d8t22-4k-j1-both.txt" && ok "  v1 log read" || bad "  v1: $(head -3 "$T/grab-ssd/seq-d8t22-4k-j1-both.txt")"
MF="$T/G1.manifest.tsv"
NICLOG1="$TL/dualnic-pips-strict-1-id0a04-d8t22c1-uncapped-f5-both-RUN-server-0/pips-log-id0a04.bin.gz"
{
    printf '# pips sweep manifest v1\n# sweep_id=G1@h@1\n# sweep=dualnic-pips-strict-G1\n# kind=nic\n'
    printf 'sweep_id\tsetting\tpoint\trole\trun\tlog_dir\treport_dir\ttlp_log\tstatus\tdesign_id\tfinished\n'
    printf 'G1@h@1\td8t22\tuncapped-f5-both\tpoint\tr\tl\tr\t%s\tFULL\t0x0a04\tt\n' "$NICLOG"
    printf 'G1@h@1\td8t22c1\tuncapped-f5-both\tpoint\tr\tl\tr\t%s\tFULL\t0x0a04\tt\n' "$NICLOG1"
    printf 'G1@h@1\td8t22\tuncapped-f5-datapath\tdatapath\tr\tl\tr\t%s\tFULL\t0x0a04\tt\n' "$NICLOG"
    printf 'OLD@h@0\td16t64\tuncapped-f30-both\tpoint\tr\tl\tr\t%s\tFULL\t0x0a04\tt\n' "$NICLOG"
} > "$MF"
run 0 "pips-seq-grab.sh --manifest: that sweep's measured runs, nothing else" \
    bash "$HERE/pips-seq-grab.sh" --manifest "$MF" -j 2 -o "$T/grab-m"
    has 'carry another sweep ID; left out'; has '2 logs (1 points), 0 missing'; has '2 of 2 logs analysed'
grep -q '^manifest .* sweep_id G1@h@1$' "$T/grab-m/manifest.txt" &&
    grep -q -- '--model self,d8t22,d8t22c1,sweep,sweepc1,sweepc1f512 ' "$T/grab-m/manifest.txt" &&
    grep -q '^sweep dualnic-pips-strict-G1  sets: d8t22 d8t22c1$' "$T/grab-m/manifest.txt" &&
    [ -s "$T/grab-m/seq-d8t22c1-uncapped-f5-both.txt" ] && ! grep -q 'f30\|datapath\|d16t64' "$T/grab-m/manifest.txt" &&
    ok "  sweep, settings and model from the manifest" || bad "  $(cat "$T/grab-m/manifest.txt")"
# A 0x0a06 sweep (the page batcher): no batcher model, recorded order only.
sed 's/^# kind=nic$/# kind=nic\n# design_id=0x0a06/' "$MF" > "$T/G6.manifest.tsv"
run 0 "pips-seq-grab.sh --manifest of a 0x0a06 sweep: no model" \
    bash "$HERE/pips-seq-grab.sh" --manifest "$T/G6.manifest.tsv" -j 2 -o "$T/grab-6"
    has '2 of 2 logs analysed'; lacks 'calibrating the uplink'
! grep -q -- '--model' "$T/grab-6/manifest.txt" && ok "  no --model in the command" || bad "  $(grep -- 'pips-page-seq.py' "$T/grab-6/manifest.txt")"

echo "-- run-dualssd-experiment.sh / run-dualnic-experiment.sh hooks (pips-lib.sh)"
# The runners' own functions, run against the model.
runner_pips() {   # <want status> <records> [fail] [design]
    (
        . "$HERE/pips-lib.sh"
        if [ "${3:-}" = fail ]; then pipsc() { return 1; }; else pipsc() { "$P" "$@"; }; fi
        sudo() { [ "$1" = -n ] && shift; "$@"; }
        setup_dir="$T/u$1"; RUN=${RUN_NAME:-r0}; L="$setup_dir/logs/$RUN"
        pips_log=1; pips_region=0x400000; pips_gzip=1; PIPS_STATUS=()
        pips_cfg=0x00000001; pips_cap=0; pips_design=${4:-0x0a04}; pips_idt=$(pips_idtag "$pips_design")
        mkdir -p "$L" "$setup_dir/reports/$RUN"
        export PIPS_SIM_RECORDS="$2" PIPS_SIM_DROP_EVERY=0
        pips_run_cfg
        pips_record
        pips_collect
        pips_meta
        echo "STATUS=${PIPS_STATUS[*]}"
        echo "META=${PIPS_META[*]}"
        pips_report
        "$P" cfg
    )
}
run 0 "FULL" runner_pips FULL 300000;  has 'STATUS=FULL$'; has 'log_enable=0'
    has 'META=--meta pips_batch=d1t0 --meta pips_cfg=0x00000001 --meta pips_drain_cap=0 --meta pips_design_id=0x0a04 --meta pips_log=FULL'
    has 'PIPS switch *: design 0x0a04, batcher d1t0'
[ -s "$T/uFULL/logs/r0/pips-log-id0a04.bin.gz" ] && grep -qx 'status: FULL' "$T/uFULL/reports/r0/pips-log.rpt" &&
    grep -qx 'log_format: v2' "$T/uFULL/reports/r0/pips-log.rpt" && grep -q '^design_id=0x0a04' "$T/uFULL/logs/r0/pips-cfg.txt" &&
    ok "  pips-log-id0a04.bin.gz, pips-cfg.txt and pips-log.rpt" || bad "  missing pips-log-id0a04.bin.gz, pips-cfg.txt or rpt"
run 0 "CUT: the region did not fill in 5 s" runner_pips CUT 1000; has 'STATUS=CUT$'; has 'log_enable=0'
run 0 "FAILED: the switch does not answer" runner_pips FAILED 1000 fail; has 'STATUS=FAILED$'
grep -qx 'design_id: 0x0a04' "$T/uFAILED/reports/r0/pips-log.rpt" && ok "  FAILED rpt names the design" || bad "  $(cat "$T/uFAILED/reports/r0/pips-log.rpt")"
[ ! -e "$T/uFULL/logs/r0/sweep-id.txt" ] && ! grep -q 'sweep_id' "$T/uFULL/reports/r0/pips-log.rpt" &&
    ok "  outside a PIPS sweep: no sweep ID anywhere" || bad "  sweep ID outside a sweep"
SID="SW1@host@20261017-000000"
export PIPS_SWEEP_ID="$SID" PIPS_SWEEP=SW1 PIPS_SWEEP_SUB=SW1-id0a04-d1t0 PIPS_MANIFEST="$T/man.tsv"
: > "$PIPS_MANIFEST"
RUN_NAME=SW1-id0a04-d1t0/4k-j1-both-RUN-0 run 0 "inside a PIPS sweep: the sweep ID in the result" runner_pips SW 300000
    has "META=.* --meta pips_log=FULL --meta pips_sweep_id=$SID --meta pips_sweep=SW1$"
RUN_NAME=SW1-id0a04-d1t0/datapath-4k-j1-RUN-0 run 0 "  and a datapath check" runner_pips SW 1000
SL="$T/uSW/logs/SW1-id0a04-d1t0/4k-j1-both-RUN-0"
grep -qx "sweep_id=$SID" "$SL/sweep-id.txt" && grep -qx 'point=4k-j1-both' "$SL/sweep-id.txt" &&
    grep -qx 'setting=d1t0' "$SL/sweep-id.txt" && grep -qx 'sweep_setting=SW1-id0a04-d1t0' "$SL/sweep-id.txt" &&
    grep -qx "sweep_id: $SID" "$T/uSW/reports/SW1-id0a04-d1t0/4k-j1-both-RUN-0/pips-log.rpt" &&
    ok "  sweep-id.txt in the run's folder, sweep_id: in its rpt" || bad "  $(cat "$SL/sweep-id.txt")"
run 0 "  manifest: a row per run, point and role, the TLP log, its status" python3 -c "
rows = [l.rstrip('\n').split('\t') for l in open('$T/man.tsv')]
assert len(rows) == 2 and all(len(r) == 11 and r[0] == '$SID' and r[1] == 'd1t0' and r[9] == '0x0a04' for r in rows), rows
assert rows[0][2:4] == ['4k-j1-both', 'point'] and rows[0][8] == 'FULL' and rows[0][7].endswith('4k-j1-both-RUN-0/pips-log-id0a04.bin.gz'), rows[0]
assert rows[1][2:4] == ['datapath-4k-j1', 'datapath'] and rows[1][8] == 'CUT', rows[1]"
unset PIPS_SWEEP_ID PIPS_SWEEP PIPS_SWEEP_SUB PIPS_MANIFEST
export PIPS_SIM_DESIGN=0x0a02
run 0 "0x0a02 build: v1 log, named id0a02" runner_pips OLD 300000 "" 0x0a02; has 'STATUS=FULL$'
[ -s "$T/uOLD/logs/r0/pips-log-id0a02.bin.gz" ] && grep -qx 'log_format: v1' "$T/uOLD/reports/r0/pips-log.rpt" &&
    ok "  pips-log-id0a02.bin.gz, v1" || bad "  $(ls "$T/uOLD/logs/r0"; cat "$T/uOLD/reports/r0/pips-log.rpt")"
unset PIPS_SIM_DESIGN

echo "-- dualssd-results.py: records of several batcher settings and designs"
mkrec() {   # <setting> <bs> <instances> <log status> [design]
    local e="x-$1-$2-$3${5:+-$5}" d="$T/rep"
    mkdir -p "$d/$e-RUN-0" "$d/$e-RUN-0-ssd0" "$d/$e-RUN-0-ssd1"
    for i in 0 1; do printf 'IOPS: 400000\nread_Gbps: 13.1\nlat_mean_us: 150\n' > "$d/$e-RUN-0-ssd$i/fio.rpt"; done
    printf 'avg_cpu_util: 50\n' > "$d/$e-RUN-0/cpu_util.rpt"
    printf 'status: %s\npips_full: 1\npips_records: 262143\npips_dropped: 0\npips_duration_us: 4368.0\npips_in0_tlp: 65932\npips_in1_tlp: 65142\npips_out_tlp: 131069\npips_out_mwr_gbps: 53.88\n' \
        "$4" > "$d/$e-RUN-0/pips-log.rpt"
    [ -n "${5:-}" ] && printf 'design_id: %s\nlog_format: v2\npips_out_wait_mean: 250.0\npips_out_wait_p50: 200.0\npips_out_wait_p99: 500.0\n' \
        "$5" >> "$d/$e-RUN-0/pips-log.rpt"
    python3 "$HERE/../dualssd-results.py" dump --reports "$d" --exp "$e" --runs 1 --ssds 0,1 \
        --out "$T/res-$1${5:+-$5}.jsonl" --meta mode=both --meta iommu=off --meta instances_per_ssd="$3" \
        --meta instances_ssd0="$3" --meta instances_ssd1="$3" --meta bs="$2" \
        --meta cpu_util_cores=36,37 --meta pips_batch="$1" --meta pips_log="$4" \
        ${5:+--meta pips_design_id="$5"} > /dev/null
}
for s in d1t0 d8t22; do for b in 4k 1m; do for j in 1 4; do mkrec $s $b $j FULL; done; done; done
mkrec d8t22 4k 8 FULL,CUT
for s in d8t22 d8t22c1; do for j in 1 4; do mkrec $s 4k $j FULL 0x0a04; done; done
run 0 "summary" python3 "$HERE/../dualssd-results.py" summary "$T"/res-*.jsonl
has '^off d1t0 '; has '^off d8t22  *4k  *8 '; has 'PIPS TLP log per configuration'
has 'FULL,CUT .* <-- NOT ALL FULL'; has 'logs: 13 FULL, 1 CUT'
has '^PIPS design ID: 0x0a04 (4 records)'; has '^off d8t22@0a04 '; has '^off d8t22c1@0a04 '
has '1.00/2.00'
run 0 "grid" python3 "$HERE/../dualssd-results.py" grid "$T"/res-*.jsonl
has 'IOMMU off d1t0: both drives, total kIOPS'; has 'IOMMU off d8t22: both drives, total kIOPS'
has 'IOMMU off d8t22c1@0a04: both drives, total kIOPS'; has '^PIPS design ID: 0x0a04'

echo "-- dualnic-results.py: NICs behind PIPS"
mknic() {   # <setting> <flows> <design> [log status]
    local e="n-$1-$2-$3" d="$T/nrep"
    mkdir -p "$d/$e-RUN-server-0" "$d/$e-RUN-server-0-nic0" "$d/$e-RUN-server-0-nic1"
    for i in 0 1; do echo "Avg_iperf_tput: 40.000" > "$d/$e-RUN-server-0-nic$i/iperf.bw.rpt"; done
    printf 'PCIe_wr_tput: 82.0\nIOTLB_misses: 1000\n' > "$d/$e-RUN-server-0/pcie.rpt"
    meta=( --meta mode=both --meta iommu=strict --meta flows_per_nic="$2" --meta bandwidth_per_nic=uncapped )
    if [ -n "$1" ]; then
        meta+=( --meta pips_batch="$1" --meta pips_design_id="$3" )
        if [ -n "${4:-}" ]; then
            printf 'status: %s\ndesign_id: %s\nlog_format: v2\npips_records: 262143\npips_dropped: 0\npips_duration_us: 900.0\npips_in0_tlp: 131000\npips_in1_tlp: 131143\npips_out_mwr_gbps: 80.1\npips_out_wait_mean: 100.0\npips_out_wait_p99: 400.0\n' \
                "$4" "$3" > "$d/$e-RUN-server-0/pips-log.rpt"
            meta+=( --meta pips_log="$4" )
        fi
    fi
    python3 "$HERE/../dualnic-results.py" dump --reports "$d" --exp "$e" --runs 1 --nics 0,1 \
        --out "$T/nres.jsonl" "${meta[@]}" > /dev/null
}
mknic "" 5 ""                       # NICs not behind PIPS, or from before: as before
mknic d8t22 5 0x0a04 FULL
mknic d8t22c1 5 0x0a04 CUT
run 0 "summary" python3 "$HERE/../dualnic-results.py" summary "$T/nres.jsonl"
has '^PIPS design ID: 0x0a04 (2 records)'; has '^strict  *uncapped'; has '^strict d8t22@0a04 '
has '^strict d8t22c1@0a04 .*CUT .*<-- NOT ALL FULL'; has 'PIPS TLP log per configuration'; has '0.40/1.60'
has 'logs: 1 FULL, 1 CUT'

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
    export PIPS_SIM_RECORDS=1000
    run 0 "fio run, recording closed by log-stop, cap on for the run" bash "$HERE/pips-fio-log.sh" \
        --bdf 0000:00:00.0 --dev "$blk" -d 3 --log-at 1 --cfg "depth=8 time=0x16 cap=1" -E t1
    has 'stop_reason=enable_low'; has '100.0K IOPS'; has 'restoring the batcher config to 0x00000001, drain cap 0'
    has 'FPGA design ID: 0x0a04, TLP log format v2'; has 'batcher during the run: d8t22c1'
    [ -s "$T/logs/t1/log-id0a04.bin" ] && [ -s "$T/logs/t1/log.csv" ] &&
        grep -q 'design 0x0a04, record format v2' "$T/logs/t1/log-summary.txt" &&
        ok "  log-id0a04.bin and log.csv saved, decoded as v2" || bad "  log files missing: $(ls "$T/logs/t1")"
    run 0 "cfg restored" "$P" cfg; has 'cfg=0x00000001'; has 'drain_depth_cap=0'
    PIPS_SIM_RECORDS=300000 run 0 "fio run, region fills" bash "$HERE/pips-fio-log.sh" --bdf 0000:00:00.0 \
        --dev "$blk" -d 2 --log-at 1 --no-csv -E t2
    has 'stop_reason=region_full'
    run 1 "an existing -E name is refused" bash "$HERE/pips-fio-log.sh" --bdf 0000:00:00.0 --dev "$blk" -d 2 -E t2
    run 1 "--rw randwrite is refused" bash "$HERE/pips-fio-log.sh" --dev "$blk" --rw randwrite
    unset PIPS_TOOL FIO PIPS_LOGS
fi

echo "-- dualssd_pips_sweep.sh, dualnic_pips_sweep.sh with stand-in sweeps"
# A copy of the scripts they use, with stand-ins for what needs hardware: the
# PCI lookups, the drives, the IOMMU mode, sudo, and the sweeps they run per
# setting (which log their arguments and the batcher as set, and write one
# result record).
R="$T/repo"
mkdir -p "$R/scripts/pips" "$R/scripts/sosp24-experiments" "$R/utils" "$T/bin" "$T/res"
cp "$HERE/pips-lib.sh" "$R/scripts/pips/"
cp "$HERE/../dualssd-results.py" "$HERE/../dualnic-results.py" "$R/scripts/"
cp "$HERE/../sosp24-experiments/dualssd_pips_sweep.sh" "$HERE/../sosp24-experiments/dualnic_pips_sweep.sh" \
    "$R/scripts/sosp24-experiments/"
cp "$HERE/../../utils/ssd-lib.sh" "$R/utils/"
printf '\npips_find_usp() { echo 0000:97:00.0; }\npips_behind() { return 0; }\n' >> "$R/scripts/pips/pips-lib.sh"
printf '\nssd_resolve() { SSD_BDF=0000:99:00.0; SSD_DEV=/dev/null; }\n' >> "$R/utils/ssd-lib.sh"
printf 'SSD_SERIALS=(A B)\nSERVER_INTFS=(eth0 eth1)\n' > "$R/utils/setup-server.sh"
printf '#!/bin/bash\necho off\n' > "$R/utils/iommu-mode.sh"
printf '#!/bin/bash\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
for s in dualssd_sweep dualnic_flow_sweep; do
    cat > "$R/scripts/sosp24-experiments/$s.sh" <<'EOF'
#!/bin/bash
name=""; dp=1
while [ $# -gt 0 ]; do [ "$1" = -o ] && name="$2"; [ "$1" = --no-datapath ] && dp=0; shift; done
c=$("$PIPS_TOOL" cfg)
echo "$(basename "$0") $name ARGS=${DUALSSD_ARGS:-}${DUALNIC_ARGS:-} $(printf '%s\n' "$c" | grep -E '^(cfg|drain|pb|thr|rcap)=' | xargs) DP=$dp" >> "$RESULTS_DIR/calls.txt"
design=$(printf '%s\n' "$c" | sed -n 's/^design_id=//p')
# The runners' sweep hooks (pips-lib.sh) for a datapath check and one point.
. "$(dirname "$0")/../pips/pips-lib.sh"
pips_cfg=$(cfg_of <(printf '%s\n' "$c")); pips_cap=$(cap_of <(printf '%s\n' "$c")); pips_design=$design
for p in $( [ "$dp" = 1 ] && echo datapath ) point; do
    case "$(basename "$0")-$p" in
        dualssd_sweep.sh-datapath) RUN="$name/datapath-4k-j1-RUN-0" ;;
        dualssd_sweep.sh-point)    RUN="$name/4k-j1-both-RUN-0" ;;
        *-datapath)                RUN="$name-uncapped-f5-datapath-RUN-server-0" ;;
        *)                         RUN="$name-uncapped-f5-both-RUN-server-0" ;;
    esac
    L="$PIPS_REPO/utils/logs/$RUN"; mkdir -p "$L" "$PIPS_REPO/utils/reports/$RUN"
    pips_sweep_mark
    pips_manifest_add "$PIPS_REPO/utils/reports/$RUN/pips-log.rpt" "$L/pips-log-id0a04.bin.gz" FULL
done
echo "{\"iommu\": \"off\", \"pips_batch\": \"${name##*-}\", \"pips_design_id\": \"$design\", \"pips_sweep_id\": \"${PIPS_SWEEP_ID:-}\", \"mode\": \"both\", \"bs\": \"4k\", \"instances_per_ssd\": 1, \"flows_per_nic\": 5, \"bandwidth_per_nic\": \"uncapped\", \"pips_log\": \"FULL\", \"active_ssds\": [0, 1], \"mean\": {\"iops_total\": 1000.0}, \"sd\": {}, \"per_run\": []}" > "$RESULTS_DIR/$name.jsonl"
EOF
done
sweep() {   # <script> <args...>
    local s="$1"; shift
    # The last sweep's tee may still hold the PIPS run lock for a moment.
    flock /tmp/pips-run.lock true 2>/dev/null
    (cd "$R/scripts/sosp24-experiments" && PATH="$T/bin:$PATH" PIPS_TOOL="$P" RESULTS_DIR="$T/res" \
        bash "$s" "$@")
}
"$P" cfg set raw=0x00000005 cap=0 > /dev/null
run 0 "dualssd_pips_sweep.sh: 2 settings x cap off/on" sweep dualssd_pips_sweep.sh -o S1 --no-asy
    has 'settings: d1t0 d1t0c1 d8t22 d8t22c1'; has 'per setting: S1-id0a04-<setting>'
grep -q '^cfg=0x00000005 .*' "$R/utils/logs/S1/cfg-restored.txt" && grep -q 'drain_depth_cap=0' "$R/utils/logs/S1/cfg-restored.txt" &&
    ok "  restored (cfg-restored.txt)" || bad "  cfg-restored.txt: $(cat "$R/utils/logs/S1/cfg-restored.txt")"
run 0 "  calls: names with the design ID, each with its cap set" cat "$T/res/calls.txt"
    has '^dualssd_sweep.sh S1-id0a04-d1t0 ARGS=.*--pips-log 1 cfg=0x00000001 .* drain=0x00000000'
    has '^dualssd_sweep.sh S1-id0a04-d1t0c1 ARGS=.*--pips-log 1 cfg=0x00000001 .* drain=0x00000001'
    has '^dualssd_sweep.sh S1-id0a04-d8t22 ARGS=.* cfg=0x00001608 .* drain=0x00000000'
    has '^dualssd_sweep.sh S1-id0a04-d8t22c1 ARGS=.* cfg=0x00001608 .* drain=0x00000001'
[ "$(wc -l < "$T/res/calls.txt")" -eq 4 ] && ok "  4 settings run" || bad "  $(cat "$T/res/calls.txt")"
run 0 "  ~/S1.txt names the design, all four settings" cat "$T/res/S1.txt"
    has '^design_id=0x0a04'; has '^PIPS design ID: 0x0a04 (4 records)'; has '^off d8t22c1@0a04 '
run 0 "  original setting and cap back" "$P" cfg; has 'cfg=0x00000005'; has 'drain_depth_cap=0'
run 1 "  a taken name is refused" sweep dualssd_pips_sweep.sh -o S1 --no-asy
run 2 "  --caps 2 is refused" sweep dualssd_pips_sweep.sh -o S2 --caps 2
: > "$T/res/calls.txt"
run 0 "dualnic_pips_sweep.sh: same, NICs" sweep dualnic_pips_sweep.sh -o N1 --cfgs 8:22:1 --single
    has 'settings: d8t22m1 d8t22m1c1'; has 'modes nic0only nic1only both'
run 0 "  calls: flow sweep per setting, experiments named after it" cat "$T/res/calls.txt"
    has '^dualnic_flow_sweep.sh N1-id0a04-d8t22m1 ARGS=.*--pips-log 1 cfg=0x00011608 .* drain=0x00000000'
    has '^dualnic_flow_sweep.sh N1-id0a04-d8t22m1c1 ARGS=.* cfg=0x00011608 .* drain=0x00000001'
run 0 "  ~/N1.txt names the design" cat "$T/res/N1.txt"; has '^design_id=0x0a04'; has 'd8t22m1c1@0a04'
run 0 "  original setting back" "$P" cfg; has 'cfg=0x00000005'
export PIPS_SIM_DESIGN=0x0a02
: > "$T/res/calls.txt"
run 1 "0x0a02: cap on is refused before anything runs" sweep dualnic_pips_sweep.sh -o N2
    has 'no drain depth cap (needs 0x0a03 or later)'
run 0 "0x0a02: --caps 0 runs, names id0a02, no cap written" sweep dualssd_pips_sweep.sh -o S3 --caps 0 --cfgs 4:22
run 0 "  calls" cat "$T/res/calls.txt"; has '^dualssd_sweep.sh S3-id0a02-d4t22 ARGS=.* cfg=0x00001604 .* drain=none'
unset PIPS_SIM_DESIGN

: > "$T/res/calls.txt"
run 0 "dualnic_pips_sweep.sh --tag, --caps 1, --datapath-once" \
    sweep dualnic_pips_sweep.sh --tag dsweep1 --cfgs "1:0 2:22 4:50" --caps 1 --datapath-once
    has 'dual-NIC PIPS sweep dualnic-pips-off-dsweep1$'; has 'settings: d1t0c1 d2t22c1 d4t50c1 '
    has 'sweep ID: dualnic-pips-off-dsweep1@'; has 'datapath check before the first setting only'
run 0 "  calls: the datapath check before the first setting only" cat "$T/res/calls.txt"
    has 'dualnic-pips-off-dsweep1-id0a04-d1t0c1 .*DP=1$'; has 'dualnic-pips-off-dsweep1-id0a04-d2t22c1 .*DP=0$'
    has 'dualnic-pips-off-dsweep1-id0a04-d4t50c1 .*DP=0$'
M="$T/res/dualnic-pips-off-dsweep1.manifest.tsv"
run 0 "  manifest (~/<name>.manifest.tsv): header, a row per run, one sweep ID, one datapath row" python3 -c "
lines = open('$M').read().splitlines()
head = dict(l[2:].split('=', 1) for l in lines if l.startswith('# ') and '=' in l and ' ' not in l[2:].split('=', 1)[0])
rows = [l.split('\t') for l in lines if not l.startswith('#')]
assert rows[0][:4] == ['sweep_id', 'setting', 'point', 'role'] and len(rows[0]) == 11, rows[0]
sid = head['sweep_id']; data = rows[1:]
assert sid.startswith('dualnic-pips-off-dsweep1@') and head['kind'] == 'nic' and head['design_id'] == '0x0a04', head
assert {r[0] for r in data} == {sid}, data
assert [r[1] for r in data if r[3] == 'point'] == ['d1t0c1', 'd2t22c1', 'd4t50c1'], data
assert [(r[1], r[2]) for r in data if r[3] == 'datapath'] == [('d1t0c1', 'uncapped-f5-datapath')], data
assert all(r[2] == 'uncapped-f5-both' and r[5].startswith('utils/logs/dualnic-pips-off-dsweep1-id0a04-') for r in data if r[3] == 'point'), data
assert sum(1 for l in lines if l.startswith('# setting_sweep=')) == 3, lines"
SR="$R/utils/logs/dualnic-pips-off-dsweep1-id0a04-d2t22c1-uncapped-f5-both-RUN-server-0"
grep -q '^sweep_id=dualnic-pips-off-dsweep1@' "$SR/sweep-id.txt" && grep -qx 'point=uncapped-f5-both' "$SR/sweep-id.txt" &&
    grep -q '^sweep_id=dualnic-pips-off-dsweep1@' "$R/utils/logs/dualnic-pips-off-dsweep1/sweep-id.txt" &&
    grep -q '^sweep_id=dualnic-pips-off-dsweep1@' "$T/res/dualnic-pips-off-dsweep1.txt" &&
    cmp -s "$M" "$R/utils/logs/dualnic-pips-off-dsweep1/manifest.tsv" &&
    ok "  sweep-id.txt in run and sweep folders, sweep_id= in ~/<name>.txt" || bad "  $(cat "$SR/sweep-id.txt")"
run 1 "  the same --tag again is refused" sweep dualnic_pips_sweep.sh --tag dsweep1 --caps 1
run 2 "  --tag that reads like a setting is refused" sweep dualssd_pips_sweep.sh --tag d8t22
    has 'reads like a setting'
run 2 "  -o and --tag together are refused" sweep dualssd_pips_sweep.sh -o X --tag y1
: > "$T/res/calls.txt"
run 0 "dualssd_pips_sweep.sh --tag, --caps 1, --datapath-once" \
    sweep dualssd_pips_sweep.sh --tag dsweep1 --cfgs "1:0 8:106" --caps 1 --datapath-once --no-asy
run 0 "  calls" cat "$T/res/calls.txt"
    has '^dualssd_sweep.sh dualssd-pips-off-dsweep1-id0a04-d1t0c1 .* drain=0x00000001 .*DP=1$'
    has '^dualssd_sweep.sh dualssd-pips-off-dsweep1-id0a04-d8t106c1 .* cfg=0x00006a08 .* DP=0$'
awk -F'\t' '!/^#/ && $4 == "point" { print $2, $3 }' "$T/res/dualssd-pips-off-dsweep1.manifest.tsv" | tr '\n' ' ' |
    grep -qx 'd1t0c1 4k-j1-both d8t106c1 4k-j1-both ' && ok "  manifest rows: setting, point" ||
    bad "  $(cat "$T/res/dualssd-pips-off-dsweep1.manifest.tsv")"

export PIPS_SIM_DESIGN=0x0a06
"$P" cfg set raw=0x00000005 cap=0 raw2=0 raw3=0 > /dev/null
: > "$T/res/calls.txt"
run 0 "0x0a06: --pbs \"0 1\" --set, every field written" \
    sweep dualnic_pips_sweep.sh -o N6 --cfgs 8:106 --caps 1 --pbs "0 1" --set "thr=31 quantum=64"
    has 'settings: d8t106c1q64w31 d8t106c1p1q64w31'
run 0 "  calls: pb and thr as set" cat "$T/res/calls.txt"
    has '^dualnic_flow_sweep.sh N6-id0a06-d8t106c1q64w31 .* pb=0x00400000 .* thr=0x001f001f'
    has '^dualnic_flow_sweep.sh N6-id0a06-d8t106c1p1q64w31 .* pb=0x00400001 '
run 0 "  original setting, pb and thr back" "$P" cfg; has 'cfg=0x00000005'; has '^pb=0x00000000'; has '^thr=0x00000000'
run 0 "0x0a06: batch_mrd settings are skipped" sweep dualssd_pips_sweep.sh -o S6 --cfgs "8:22:1 4:22" --caps 0 --no-asy
    has 'SKIPPED: batch_mrd has no effect'
export PIPS_SIM_DESIGN=0x0a07
"$P" cfg set raw=0x00000005 cap=0 raw2=0 raw3=0 raw4=0x00000303 > /dev/null
: > "$T/res/calls.txt"
run 0 "0x0a07: rate caps written 0 unless --set, tag only when set" \
    sweep dualnic_pips_sweep.sh -o N8 --cfgs 8:106 --caps 1 --pbs 0 --set "thr=31"
    has 'settings: d8t106c1w31$'
run 0 "  calls: rcap 0" cat "$T/res/calls.txt"; has '^dualnic_flow_sweep.sh N8-id0a07-d8t106c1w31 .* rcap=0x00000000'
run 0 "  original rate caps back" "$P" cfg; has '^rcap=0x00000303'
run 0 "0x0a07: --set rcap" sweep dualnic_pips_sweep.sh -o N9 --cfgs 8:106 --caps 1 --set "rcap0=100"
    has 'settings: d8t106c1r100x0x0$'
export PIPS_SIM_DESIGN=0x0a06
run 1 "0x0a06: --set rcap is refused" sweep dualnic_pips_sweep.sh -o N10 --cfgs 8:106 --caps 1 --set "rcap=10"
    has 'has no rate caps'
export PIPS_SIM_DESIGN=0x0a05
run 1 "0x0a05: --pbs is refused" sweep dualnic_pips_sweep.sh -o N7 --pbs 1 --caps 0; has 'has no page batcher'
unset PIPS_SIM_DESIGN

echo "-- pips-timeout-pick.py: time thresholds for depths, from a sweep's results"
cat > "$T/tp.jsonl" <<'EOF'
{"exp": "x-d1t0/4k-j1-both", "bs": "4k", "pips_batch": "d1t0", "mean": {"iops_ssd0": 158000, "iops_ssd1": 211000, "pips_in0_tlp": 57000, "pips_in1_tlp": 73000, "pips_duration_us": 19000, "pips_out_tlp": 130000, "pips_out_wait_mean": 15}}
{"exp": "x-d1t0/64k-j8-both", "bs": "64k", "pips_batch": "d1t0", "mean": {"iops_ssd0": 51700, "iops_ssd1": 23900, "pips_in0_tlp": 100000, "pips_in1_tlp": 136000, "pips_duration_us": 7500, "pips_out_tlp": 236000, "pips_out_wait_mean": 390}}
EOF
run 0 "pick: a time per depth; depths the FIFO can't hold get 255" \
    python3 "$HERE/pips-timeout-pick.py" "$T/tp.jsonl" --depths "4 24" --tlps 3000 -j 2 --json "$T/tp.json"
    has '^\[ *2/2\]'; has '1 light point(s)'; has 'picked (--cfgs, with --caps 1): "4:[0-9]* 24:255"'
    has 'd24t255c1 .*depth unreachable'
run 0 "  --eval: given settings, what asks for the drains" \
    python3 "$HERE/pips-timeout-pick.py" "$T/tp.jsonl" --eval "2:22 8:106" --tlps 3000 -j 2
    has '^d2t22c1 '; has '^d8t106c1 '
run 0 "  --validate: the recorded waits against the model" \
    python3 "$HERE/pips-timeout-pick.py" "$T/tp.jsonl" --validate --tlps 3000 -j 2
    has 'pipeline latency'; has '^4k-j1-both  *d1t0 '

echo
[ "$fails" -eq 0 ] && echo "test-sim: PASS" || echo "test-sim: $fails FAILED"
[ "$fails" -eq 0 ]
