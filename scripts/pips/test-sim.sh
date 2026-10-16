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
# data interleaved TLP by TLP, then both entries; ssd-pair = two I/Os' data,
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
run 0 "pips-seq-grab.sh nic: a log per setting and point, missing ones listed, packed" \
    bash "$HERE/pips-seq-grab.sh" nic --logs "$TL" --sets "d8t22 d8t22c1" --points "f5-both f30-both" -j 2 -o "$T/grab"
    has '2 logs, 2 missing'; has '2 of 2 logs analysed'
[ -f "$T/grab.tar.gz" ] && [ "$(wc -l < "$T/grab/seq.jsonl")" -eq 2 ] && [ -s "$T/grab/seq-d8t22c1-f5-both.txt" ] &&
    grep -q '^missing  d8t22 f30-both' "$T/grab/manifest.txt" && ok "  files and manifest" ||
    bad "  grab output: $(ls "$T/grab" 2>&1)"
run 1 "  an existing output folder is refused" bash "$HERE/pips-seq-grab.sh" nic --logs "$TL" -o "$T/grab"
run 0 "pips-seq-grab.sh ssd on a v1 sweep" bash "$HERE/pips-seq-grab.sh" ssd --logs "$TL" \
    --sweep dualssd-pips-off-1 --sets d8t22 --points 4k-j1-both -o "$T/grab-ssd"
    has '1 of 1 logs analysed'
grep -q 'record format v1' "$T/grab-ssd/seq-d8t22-4k-j1-both.txt" && ok "  v1 log read" || bad "  v1: $(head -3 "$T/grab-ssd/seq-d8t22-4k-j1-both.txt")"

echo "-- run-dualssd-experiment.sh / run-dualnic-experiment.sh hooks (pips-lib.sh)"
# The runners' own functions, run against the model.
runner_pips() {   # <want status> <records> [fail] [design]
    (
        . "$HERE/pips-lib.sh"
        if [ "${3:-}" = fail ]; then pipsc() { return 1; }; else pipsc() { "$P" "$@"; }; fi
        sudo() { [ "$1" = -n ] && shift; "$@"; }
        setup_dir="$T/u$1"; RUN=r0; L="$setup_dir/logs/r0"
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
name=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && name="$2"; shift; done
c=$("$PIPS_TOOL" cfg)
echo "$(basename "$0") $name ARGS=${DUALSSD_ARGS:-}${DUALNIC_ARGS:-} $(printf '%s\n' "$c" | grep -E '^(cfg|drain)=' | xargs)" >> "$RESULTS_DIR/calls.txt"
design=$(printf '%s\n' "$c" | sed -n 's/^design_id=//p')
echo "{\"iommu\": \"off\", \"pips_batch\": \"${name##*-}\", \"pips_design_id\": \"$design\", \"mode\": \"both\", \"bs\": \"4k\", \"instances_per_ssd\": 1, \"flows_per_nic\": 5, \"bandwidth_per_nic\": \"uncapped\", \"pips_log\": \"FULL\", \"active_ssds\": [0, 1], \"mean\": {\"iops_total\": 1000.0}, \"sd\": {}, \"per_run\": []}" > "$RESULTS_DIR/$name.jsonl"
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

echo
[ "$fails" -eq 0 ] && echo "test-sim: PASS" || echo "test-sim: $fails FAILED"
[ "$fails" -eq 0 ]
