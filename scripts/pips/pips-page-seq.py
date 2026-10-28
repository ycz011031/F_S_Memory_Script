#!/usr/bin/env python3
"""The order in which the drives' TLPs ask the IOMMU for pages, from a PIPS
TLP log, and how much regrouping (batching) could shorten it.

    pips-page-seq.py LOG                          interleaving + batching what-if
    pips-page-seq.py LOG --show 300 [--from REC] [--port out|in0|in1]
                                                  the sequence itself, one line per run
    pips-page-seq.py LOG --csv seq.csv            every TLP: record, port, drive, class,
                                                  page, offset, run, visit, open pages
    pips-page-seq.py LOG --iotlb 1x64,16x4,64x1 [--strict]
                                                  also simulated IOTLB misses per policy
    ... --json results.jsonl                      also append everything as one JSON line

LOG is one pips-log.bin(.gz) (pips-log-id<XXXX>.bin.gz from design 0x0a02 on).
--kind nic reads a NIC log (default: nic when the path has "dualnic" in it):
writes of up to 16 DW (the NIC's 64-byte completions) count as completions
instead of 4 DW (NVMe), and a packet's buffer visit ends at its last TLP, the
first one shorter than the NIC's largest, since a 4000-byte packet never fills
its 4 KiB page. "drive" below then means NIC, and an I/O is a completion write
(received packets, plus the sends' completions: about 1.1 per packet).
Out TLPs are matched to their drive as in pips-addr-pattern.py; in a v2 log
(design 0x0a04 on) every record names its drive, and the in0/in1 streams are
each drive's TLPs in the order they left. --design-id overrides the design ID
found for the log (pips-log-decode.py --help). Python 3, standard library only.

Terms. A run is consecutive TLPs to the same (drive, 4 KiB page) on one
stream; every run boundary is a translation of a different page. A visit is
one I/O's writes to one page: it starts at page offset 0 and is complete once
4 KiB has been written. A drive's open pages are its visits started and not
yet complete: how many pages it writes at once.

Interleaving, per drive (in0, in1: what each drive sends) and on out (what the
IOMMU sees): TLPs per run, share of visits written in a single run, and open
pages.

Batching what-if, on out's translated TLPs (interrupts left out). The stream is
cut into windows of W consecutive TLPs and each window is regrouped:
  drive   each drive's TLPs together, in the drive's own order. What a
          per-drive batcher can do; PCIe ordering holds.
  page    as drive, and within a drive the data writes between two of its
          completion entries, interrupts or reads grouped by page. Needs
          relaxed ordering for the data writes; a completion entry never
          passes its data.
  ideal   everything in the window grouped by (drive, page), ignoring
          ordering: the bound.
Reported per W: the extra wait a window costs (mean and worst, at the log's
TLP rate), distinct pages per window, and runs per I/O under each policy.
I/Os are completion entries on out.

--iotlb SxW,... simulates IOTLBs of S sets x W ways (LRU in each set, set =
page number mod S, entries tagged by drive) on each regrouped stream. The real
geometry is not published; compare S x W with 1 x (S*W) for conflict misses at
equal size. --strict counts every new visit as a miss, because strict mode
invalidates a page's entry when its I/O completes.

Arrival order (v2 logs). Each record's gap and pkt_wait rebuild when the TLP
entered the batcher (in_sop = out_sop - pkt_wait), so the out TLPs sorted by
it are the order the two inputs handed them over: stream "arr" (--port arr,
interleaving, and a windowed what-if from it). That is the order batching
starts from; out is what the setting made of it. Two corrections make it
hold on a busy uplink. (1) A stall inside a packet on the output is in
neither pkt_length nor pkt_gap, while pkt_wait counts it, so the output's
times are rebuilt with those stalls put back: each packet holds the output
for its beats or the link's time for it, whichever is longer (the model's own
rule), with the link's rate fitted so the rebuilt output ends at the
trailer's duration (a full Gen3 x8 drive log loses about a third of its time
otherwise). The fitted link is no slower than --link-rate (the uplink's rate
measured on clean logs: --calibrate, which pips-seq-grab.sh runs first); time
still missing then is idle past saturated gaps. (2) The batcher never
reorders one input's TLPs (a FIFO, and a read waits for it to empty), so each
input's arrivals keep their output order. The model then charges the fitted
link rate, so arrivals and output run on one clock.

--model runs the batcher of axi4_mwr_batch.v on the arrival order, for the
log's own setting (self: checks the model against the log), the 0x0A04
settings (std), a depth sweep at time 255 with the drain cap off (sweep) or
on (sweepc1), the 10-17 depth sweep's settings (deep: depths 1-64, cap on,
times from pips-timeout-pick.py) or any dDtT[m1][c1][fBEATS]. Per
input a FIFO of writes asks for the output at DEPTH packets, after TIME
cycles non-empty, or when nearly full; a grant sends what the FIFO holds then
(with c1, at most DEPTH) as one run; the inputs alternate; a read waits until
its input's writes are out and then goes first. A TLP holds the output one
cycle per 64-byte beat (the 512-bit datapath; what back-to-back pairs within
a drain take in every log), plus a grant gap of 3 cycles whenever the output
takes a new drain from the input it just served, or a pass-through packet
(--grant-gap: one NIC alone under d1t0c1, every drain one TLP, takes 12
cycles per 512 B TLP instead of 9; two NICs alternating under d1t0c1 carry
~105 Gbps, so a grant to the other input hides it), but no
less than the uplink takes to carry it (--link; a Gen3 x8 uplink is slower
than the datapath). --progress prints each stage to stderr.
Reported: page switches per I/O as sent, with each drain regrouped by page
(with and without ordering), simulated misses, the time in the switch, TLPs
per drain, and what asked for each drain: depth (also when a drain's
leftovers already held DEPTH packets), time, full (a FIFO stops taking beats
at FIFO_DEPTH - 19 and asks 16 beats before that: 109 / 93 of 128 beats up to
0x0A04, 493 / 477 of 512 on 0x0A05, so a depth of more than 93 or 477 / beats
per TLP never asks) or a read's flush. The FIFO size comes from the log's
design ID (--fifo overrides it); a setting named ...fBEATS runs with that
size instead, e.g. sweepc1f512 is the cap-on sweep with 0x0A05's FIFO on any
log.
"""
import argparse
import collections
import time as time_mod
import csv
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_addr_pattern",
                                               os.path.join(HERE, "pips-addr-pattern.py"))
ap_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ap_mod)
dec = ap_mod.dec

WINDOWS = (1, 2, 4, 8, 16, 32, 64, 128, 256, 512)
POLICIES = ("drive", "page", "ideal")
PORTS = ("in0", "in1", "out", "arr")
ARR = 3                                    # port index of the arrival-order stream (v2 logs)
WAIT_SAT = 65535
# The 0x0A04 sweeps' settings, and a depth sweep at the longest time limit the
# 8-bit field allows, cap off and on, for --model std / sweep / sweepc1.
STD_SETS = ("d1t0", "d1t0c1", "d4t22", "d4t22c1", "d8t22", "d8t22c1", "d16t64", "d16t64c1")
SWEEP_DEPTHS = (1, 2, 4, 8, 16, 32, 64)
SWEEP_SETS = tuple(f"d{d}t255" for d in SWEEP_DEPTHS)
SWEEPC1_SETS = tuple(f"d{d}t255c1" for d in SWEEP_DEPTHS)
# The 10-17 depth sweep (HANDOFF §8): cap on, each time just past what D
# back-to-back TLPs take to arrive (pips-timeout-pick.py), 255 past the FIFO.
DEEP_SETS = ("d1t0c1", "d2t22c1", "d4t50c1", "d8t106c1", "d16t218c1", "d24t255c1", "d36t255c1", "d64t255c1")
GROUPS = {"std": STD_SETS, "sweep": SWEEP_SETS, "sweepc1": SWEEPC1_SETS, "deep": DEEP_SETS}
GROUP_RE = re.compile(r"^(std|sweep|sweepc1|deep)(f\d+)?$")
SET_RE = re.compile(r"^d(\d+)t(\d+)(m1)?(c1)?(?:f(\d+))?$")
PB_FIELDS = re.compile(r"(?:p1)?(?:o1)?(?:q\d+)?(?:w\d+(?:x\d+)?)?(?:r\d+x\d+x\d+)?$")
SET_IN_PATH = re.compile(r"-(d\d+t\d+(?:m1)?(?:c1)?(?:p1)?(?:o1)?(?:q\d+)?(?:w\d+(?:x\d+)?)?(?:r\d+x\d+x\d+)?)(?=[/-]|$)")
# axi4_mwr_batch.v at its build parameters: FIFO_DEPTH beats of 64 B per input,
# MAX_PKT_BEATS 16, so prog_full stops the input at FIFO_DEPTH - 19 beats and
# the full trigger fires once fewer than 16 beats of that are left. FIFO_DEPTH
# is the RTL default of 128 up to 0x0A04 (109 / 93 beats); 0x0A05 builds it
# with 512 (493 / 477; pips.tcl, FPGA commit 64193c6).
MAX_PKT_BEATS = 16
FIFO_DEFAULT = 128
# 0x0A06 (page batcher) run with page_batch_en 0 is one in-order FIFO per input
# over the whole data array, 1536 rows; its full trigger differs (free rows
# below the largest packet seen), so the model is an approximation there, and
# per-page mode (p1) it cannot model at all: pips-seq-grab.sh runs no model
# on 0x0A06 sweeps.
FIFO_BY_DESIGN = {"0x0a05": 512, "0x0a06": 1536, "0x0a07": 1536}


def fifo_limits(fifo):
    """(beats at which prog_full stops an input, fill above which it asks for a drain)."""
    admit = fifo - MAX_PKT_BEATS - 3
    return admit, admit - MAX_PKT_BEATS


ADMIT_BEATS, FULL_BEATS = fifo_limits(FIFO_DEFAULT)
# The uplink. The batcher hands the PCIe IP a 64-byte beat per cycle, faster
# than a Gen3 x8 link carries them: on a busy link the output runs back to back
# until the IP's buffer is full and then stalls, so the pairs service() measures
# are the fast ones. The model takes no less than the link's time per TLP:
# payload + 22 bytes (3DW header 12, sequence number 2, LCRC 4, framing 4) at
# LINK_EFF of the raw rate after 128b/130b coding. LINK_EFF covers DLLPs and SKP
# sets and is measured: bigserver's full-link drive logs (Gen3 x8) take 9.2
# cycles per 256 B TLP. icx's PIPS uplink is Gen4 x8, which the 512-bit
# datapath, not the link, limits.
LINK_GTS = {"gen3": 8.0, "gen4": 16.0, "gen5": 32.0}
LINK_DEFAULT = {"ssd": "gen3x8", "nic": "gen4x8"}
LINK_EFF = 0.96
TLP_OVERHEAD = 22
# Cycles the output loses when it takes a new drain from the input it just
# served (or a pass-through packet): the master FSM re-arbitrates at the packet
# boundary. One NIC alone under d1t0c1 (every drain one TLP) sends a 512 B TLP
# every 12 cycles instead of 9 (about 80 Gbps). A grant to the other input
# costs nothing measurable: two NICs alternating under d1t0c1 carry ~105 Gbps,
# which 12 cycles per TLP (85 Gbps at most) can't; charging it there made the
# 10-19 grab's NIC model back up (HANDOFF section 8, item 11).
GRANT_GAP = 3


# Stalls inside a packet on the output (arrival()): a packet's last beat goes
# in once the link is no more than TX_BUF_BYTES behind. 0, the model's rule
# (a TLP holds the output for the longer of its beats and its link time): with
# a buffer the rebuild and the model disagree on the link they fit, and a
# model a few percent slower than the arrivals never drains its queue. With
# --calibrate the fitted link may be as slow as LINK_EFF_MIN of the raw rate;
# otherwise no slower than --link-rate, or LINK_EFF of the raw rate.
TX_BUF_BYTES = 0
LINK_EFF_MIN = 0.80
# Logs --calibrate counts as clean: one segment (no saturated gap, so all the
# missing time is stalls) and at least this share of the time lost (a full link)
CAL_LOST_MIN = 0.10


def link_bpc(name, eff=LINK_EFF):
    """Bytes per 4 ns cycle a link carries ('gen3x8'), None for 'none' (no link limit)."""
    if name is None or name.lower() == "none":
        return None
    m = re.match(r"^(gen[345])x(1|2|4|8|16)$", name.lower())
    if not m:
        raise ValueError(f"not a link: {name} (gen3x8, gen4x16, ... or none)")
    return LINK_GTS[m.group(1)] * 1e9 * int(m.group(2)) * 128 / 130 / 8 / dec.CLOCK_HZ * eff


def wire_bytes(is_read, pdw):
    """Bytes a TLP takes on the link: payload (none for a read) + TLP_OVERHEAD."""
    return (0 if is_read else 4 * pdw) + TLP_OVERHEAD


def out_times(pk, c, buf=TX_BUF_BYTES, extra=0.0):
    """Output (sop, eop) per packet with the stalls inside packets put back.
    pk: (length, gap, wire bytes, saturated gap) in output order; c: link cycles
    per wire byte (0: no stalls, the times as logged); extra: idle cycles added
    to each saturated gap. A packet's last beat goes in once the link is no more
    than `buf` bytes behind."""
    res, eop, link = [], None, 0.0
    for length, gap, wire, sat in pk:
        sop = 0.0 if eop is None else eop + 1 + gap + (extra if sat else 0.0)
        link = max(link, sop) + wire * c
        eop = max(sop + length, link - buf * c) - 1
        res.append((sop, eop))
    return res


def fit_stalls(pk, duration, slowest_bpc, buf=TX_BUF_BYTES):
    """(c, extra, span as logged): the link rate c (cycles per wire byte, 0 if
    the log lost no time) that makes out_times() end at `duration` cycles,
    no slower than slowest_bpc; time still missing at that bound goes to the
    saturated gaps as `extra` each."""
    span0 = out_times(pk, 0.0)[-1][1] + 1 if pk else 0
    if not pk or not duration or not slowest_bpc or duration <= span0 * 1.002:
        return 0.0, 0.0, span0
    end = lambda c: out_times(pk, c, buf)[-1][1] + 1
    lo, hi = 0.0, 1 / slowest_bpc
    if end(hi) <= duration:
        nsat = sum(1 for x in pk if x[3])
        return hi, ((duration - end(hi)) / nsat if nsat else 0.0), span0
    for _ in range(30):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if end(mid) < duration else (lo, mid)
    return hi, 0.0, span0


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(p / 100 * len(s)))]


def mean(vals):
    return sum(vals) / len(vals) if vals else None


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def annotate(events, kind="ssd"):
    """Per port: the TLP sequence with run numbers, visit state and open pages.
    Rows: (rec, port, drive, cls, addr, pdw, run, visit, open_d0, open_d1).
    kind nic: a TLP shorter than the device's largest so far is a packet's last."""
    rows = []
    state = {}
    for port in range(len(PORTS)):
        st = state[port] = dict(prev=None, run=-1, next_off={}, seen=set(), open=[set(), set()], mps=[0, 0])
    for i, port, c, addr, pdw, src, _src_i, _w in events:
        st = state[port]
        page = addr >> 12
        key = (src, page) if c != "msi" else (src, "msi")
        if key != st["prev"]:
            st["run"] += 1
            st["prev"] = key
        visit = ""
        if c == "data" and src is not None:
            off, nbytes = addr & 0xFFF, 4 * pdw
            k = (src, page)
            if off == 0:
                visit = "reuse" if k in st["seen"] else "new"
                st["seen"].add(k)
                st["open"][src].add(page)
            elif st["next_off"].get(k) != off:
                visit = "gap"                      # not where this page's last write ended
            st["mps"][src] = max(st["mps"][src], pdw)
            if off + nbytes >= 4096 or (kind == "nic" and pdw < st["mps"][src]):
                st["open"][src].discard(page)
                st["next_off"].pop(k, None)
            else:
                st["next_off"][k] = off + nbytes
        rows.append((i, PORTS[port], src, c, addr, pdw, st["run"], visit,
                     len(st["open"][0]), len(st["open"][1])))
    return rows


def interleave(rows):
    """Per stream: TLPs per run (data only), share of visits in one run, open pages."""
    out = {}
    for name in PORTS:
        rs = [r for r in rows if r[1] == name and r[3] == "data" and r[2] is not None]
        if name == "arr" and not rs:
            continue                                   # v1 log: no arrival order
        runs = collections.Counter(r[6] for r in rs)
        run_len = list(runs.values())
        # a visit is single-run if all its TLPs share one run number
        vis_runs, vis_cur = [], {}
        for r in rs:
            k = (r[2], r[4] >> 12)
            if r[4] & 0xFFF == 0:
                if k in vis_cur:
                    vis_runs.append(vis_cur[k])
                vis_cur[k] = {r[6]}
            elif k in vis_cur:
                vis_cur[k].add(r[6])
        vis_runs += list(vis_cur.values())
        single = sum(1 for v in vis_runs if len(v) == 1)
        opens = {d: [r[8 + d] for r in rs if r[2] == d] for d in (0, 1)}
        out[name] = dict(tlps=len(rs), run_mean=mean(run_len), run_p50=pct(run_len, 50),
                         visits=len(vis_runs), single_run=single / len(vis_runs) if vis_runs else None,
                         runs_per_visit=mean([len(v) for v in vis_runs]),
                         open={d: (mean(v), pct(v, 50), pct(v, 99), max(v) if v else None)
                               for d, v in opens.items()})
    return out


def regroup(items, w, policy):
    """items: (drive, page, cls) in out order. Cut into windows of w; regroup each."""
    if w == 1:
        return items
    res = []
    for s in range(0, len(items), w):
        win = items[s:s + w]
        by = {}
        for it in win:
            by.setdefault(it[0], []).append(it)
        for seq in by.values():
            if policy == "drive":
                res.extend(seq)
                continue
            groups = {}
            for it in seq:
                if policy == "page" and it[2] != "data":
                    for g in groups.values():          # flush: nothing passes a barrier
                        res.extend(g)
                    groups = {}
                    res.append(it)
                else:
                    groups.setdefault(it[1], []).append(it)
            for g in groups.values():
                res.extend(g)
    return res


def count_runs(seq):
    n, prev = 0, None
    for it in seq:
        k = (it[0], it[1])
        if k != prev:
            n += 1
            prev = k
    return n


def simulate(seq, sets, ways, strict, new_flags):
    """Misses of a set-associative LRU IOTLB. new_flags[j]: seq[j] starts a visit."""
    tlb = [collections.OrderedDict() for _ in range(sets)]
    miss = 0
    for it, new in zip(seq, new_flags):
        k = (it[0], it[1])
        s = tlb[it[1] % sets]
        if strict and new:
            s.pop(k, None)                             # invalidated at the last unmap
        if k in s:
            s.move_to_end(k)
            continue
        miss += 1
        s[k] = True
        if len(s) > ways:
            s.popitem(last=False)
    return miss


def regroup_flags(items, w, policy):
    """regroup() on (item, index) pairs, to carry each item's own flags along."""
    tagged = [it + (j,) for j, it in enumerate(items)]
    return regroup(tagged, w, policy)


def whatif(events, dur_us, geoms, strict, on=2):
    """Windows of W TLPs of stream `on` (2 = out, ARR = arrival order), each regrouped."""
    items = [(src, addr >> 12, c) for _i, port, c, addr, pdw, src, _s, _w in events
             if port == on and src is not None and c != "msi"]
    new = [c == "data" and (addr & 0xFFF) == 0 for _i, port, c, addr, pdw, src, _s, _w in events
           if port == on and src is not None and c != "msi"]
    n_out = sum(1 for e in events if e[1] == on)
    ios = sum(1 for it in items if it[2] == "cqe")
    us_per_tlp = dur_us / n_out if dur_us and n_out else None
    rows = []
    for w in WINDOWS:
        wins = [len({(it[0], it[1]) for it in items[s:s + w]}) for s in range(0, len(items), w)]
        row = dict(w=w, wait_mean=(w - 1) / 2 * us_per_tlp if us_per_tlp else None,
                   wait_max=(w - 1) * us_per_tlp if us_per_tlp else None,
                   pages_mean=mean(wins), pages_p99=pct(wins, 99), runs={}, miss={})
        for pol in POLICIES:
            seq = regroup_flags(items, w, pol)
            row["runs"][pol] = count_runs(seq) / ios if ios else None
            for g in geoms:
                flags = [new[it[3]] for it in seq]
                row["miss"][(pol, g)] = simulate(seq, g[0], g[1], strict, flags) / ios if ios else None
            if w == 1:
                for p2 in POLICIES[1:]:
                    row["runs"][p2] = row["runs"][pol]
                    for g in geoms:
                        row["miss"][(p2, g)] = row["miss"][(pol, g)]
                break
        rows.append(row)
    return dict(items=len(items), ios=ios, us_per_tlp=us_per_tlp, rows=rows)


def arrival(recs, events, duration=None, slowest_bpc=None):
    """v2: rebuild when each TLP entered the batcher, as pips-log-decode.py does
    (telemetry_dma_format.md §4.3): out_sop = previous out EOP + 1 + gap, and
    in_sop = out_sop - pkt_wait. Returns the out events again as stream ARR, in
    order of (segment, in_sop): the order the two inputs handed the TLPs over.
    A segment ends at a saturated gap (255) or a dropped record, after which
    times are lower bounds; no TLP waits that long here, so the order holds.
    With the trailer's duration and the slowest the uplink can be, the stalls
    inside packets, which neither field counts but pkt_wait does, are put back
    (fit_stalls()); without them a TLP's in_sop is early by the stalls of the
    packets that left during its wait, and one input's TLPs swap places. Each
    input then keeps its output order (the batcher never reorders an input).
    Also returns per record index (out_sop, in_sop, beats, segment, out_sop as
    logged) and counts, with the fitted link (bytes per cycle, None if the log
    lost no time)."""
    idx, pk, ports, waits, segs = [], [], [], [], []
    seg, wsat, first = 0, 0, True
    for i, (_addr, length, gap, typ, pdw, _tag, _at, info, wait) in enumerate(recs):
        kind, port = (info >> 2) & 3, info & 3
        if port > 1:
            continue
        if kind == dec.KIND_DROP:
            seg += 1
            continue
        if kind != dec.KIND_TLP:
            continue
        sat = not first and gap == 255
        seg += sat
        first = False
        wsat += wait == WAIT_SAT
        idx.append(i)
        pk.append((length, gap, wire_bytes((typ & 0xF) == 0, pdw), sat))
        ports.append(port)
        waits.append(wait)
        segs.append(seg)
    c, extra, span0 = fit_stalls(pk, duration, slowest_bpc)
    logged = out_times(pk, 0.0)
    times = out_times(pk, c, TX_BUF_BYTES, extra) if c else logged
    tl, last, held = {}, [None, None], 0
    for k, i in enumerate(idx):
        in_sop = times[k][0] - waits[k]
        p = ports[k]
        if last[p] is not None and in_sop < last[p]:
            in_sop, held = last[p], held + 1          # an input's TLPs arrive in their output order
        last[p] = in_sop
        tl[i] = (times[k][0], in_sop, pk[k][0], segs[k], logged[k][0])
    out = [e for e in events if e[1] == 2 and e[0] in tl]
    order = sorted(range(len(out)), key=lambda k: (tl[out[k][0]][3], tl[out[k][0]][1], k))
    arr = [(e[0], ARR) + e[2:] for e in (out[k] for k in order)]
    moved = sum(1 for pos, k in enumerate(order) if pos != k)
    return arr, tl, dict(tlps=len(out), segments=seg + 1, wait_saturated=wsat,
                         moved=moved / len(out) if out else None,
                         span_logged_cycles=span0, duration_cycles=duration,
                         lost=(1 - span0 / duration) if duration else None,
                         link_fit=(1 / c) if c else None, tx_buf=TX_BUF_BYTES if c else None,
                         idle_extra=extra, held=held / len(out) if out else None)


def parse_setting(name):
    """'d16t64c1' -> (depth 16, time 64, cap 1, batch_mrd 0). A trailing fBEATS
    (FIFO size) is allowed and left to setting_fifo()."""
    m = SET_RE.match(name)
    if not m:
        raise ValueError(f"not a batcher setting: {name} (dDEPTHtTIME[m1][c1][fBEATS])")
    if m.group(5) and fifo_limits(int(m.group(5)))[1] < MAX_PKT_BEATS:
        raise ValueError(f"{name}: a FIFO of {m.group(5)} beats can't hold a {MAX_PKT_BEATS}-beat packet")
    return int(m.group(1)), int(m.group(2)), int(bool(m.group(4))), int(bool(m.group(3)))


def setting_fifo(name):
    """The FIFO size in beats a setting names ('d24t255c1f512' -> 512), or None."""
    m = SET_RE.match(name)
    return int(m.group(5)) if m and m.group(5) else None


BATCHED = ("data", "cqe", "msi")             # memory writes: they wait in the batching FIFOs


def service(out_items):
    """Cycles a TLP keeps the output busy, link or credit stalls included: per
    (class, payload DW), the median over this log of out_sop(next) - out_sop(this)
    for back-to-back pairs of one drain, that is consecutive written TLPs from
    the same input where the second had entered before that input's run on
    the output began (so it was in the same grant and nothing held it).
    out_items: (src, cls, pdw, out_sop, in_sop, beats) in out order. Returns
    (table, cycles per beat for kinds with too few pairs)."""
    samples = collections.defaultdict(list)
    per_beat = []
    run_start = None
    for k, a in enumerate(out_items):
        if k == 0 or out_items[k - 1][0] != a[0]:
            run_start = a[3]
        if k + 1 == len(out_items):
            break
        b = out_items[k + 1]
        if a[0] == b[0] and a[1] in BATCHED and b[1] in BATCHED and b[4] <= run_start:
            d = b[3] - a[3]
            samples[(a[1], a[2])].append(d)
            per_beat.append(d / max(a[5], 1))
    table = {k: pct(v, 50) for k, v in samples.items() if len(v) >= 20}
    one_beat = [v for (c, _p), v in table.items() if c in ("cqe", "msi")]
    if one_beat:
        table[("one-beat", 0)] = min(one_beat)
    return table, (pct(per_beat, 50) if per_beat else 1.0)


def cycles(cls, pdw, beats, bpc=None):
    """Output cycles of one TLP within a drain: one per 64-byte beat on the
    512-bit datapath (back-to-back pairs of one drain take exactly that in
    every log, service()), and with bpc (link bytes per cycle) at least the
    link's time for it (a read carries no payload). batcher() adds the grant
    gap."""
    v = beats
    if bpc:
        v = max(v, ((0 if cls == "mrd" else 4 * pdw) + TLP_OVERHEAD) / bpc)
    return v


TRIGGERS = ("depth", "time", "full", "flush")


def batcher(arr, depth, time, cap, mrd_batched, stats=None, fifo_beats=FIFO_DEFAULT, grant_gap=0):
    """The batcher of axi4_mwr_batch.v on TLPs in arrival order. arr: (t_in,
    src, cls, beats, cycles) per TLP. Per input a FIFO of `fifo_beats` beats that
    takes writes (reads too with batch_mrd) and asks for the output once it
    holds `depth` packets, has been non-empty for `time` cycles (restarted
    when a drain ends), or has fewer than 16 of its admit beats left (fifo_beats -
    19: 109 of 128). A grant sends the packets in the FIFO at that moment
    (with the cap: at most `depth`), as one run; when both inputs ask, they
    alternate. A read (pass-through) enters only once its input's FIFO is
    empty, which flushes that FIFO and holds back the input behind it, and
    then goes out ahead of the next batched packet. An input stops taking
    packets at its admit limit. A TLP holds the output its `cycles`; the
    first TLP of a drain from the input served last, and a pass-through
    packet, at least its beats + `grant_gap`. Returns the TLPs in output order as (arr index, start cycle,
    drain number).
    stats, a dict, gets per drain what asked for it: "depth" (the FIFO held
    DEPTH packets; also when a drain's leftovers already did), "full",
    "time", or "flush" (a read behind the writes), counted per input in
    stats["triggers"][input][reason], and the cycles from the batch's start
    (FIFO non-empty, or the last drain's end) to the trigger in
    stats["trig_cycles"][reason]."""
    n = len(arr)
    admit_beats, full_beats = fifo_limits(fifo_beats)
    trig_depth = max(depth, 1)
    take_cap = trig_depth if cap else None
    inq = [collections.deque(), collections.deque()]  # arrived, not admitted (blocked)
    fifo = [collections.deque(), collections.deque()]
    fill = [0, 0]
    tmr = [None, None]                                 # timer start: FIFO non-empty / drain end
    latch = [False, False]
    why = [None, None]                                 # what latched the request, and when
    snap = [0, 0]                                      # packets left in the granted drain; -1: flush
    if stats is not None:
        stats["triggers"] = [{k: 0 for k in TRIGGERS} for _ in (0, 1)]
        stats["trig_cycles"] = {k: [] for k in TRIGGERS}
    f2 = collections.deque()
    owner, rr_last, drain_no = None, 1, 0
    nxt, t, out = 0, 0, []
    prev_d, prev_src = None, None                      # drain (-1 pass-through) and input of the TLP last sent

    def occ(j, d):
        """Cycles TLP j holds the output; a new drain from the same input, or a
        pass-through packet, costs the grant gap."""
        nonlocal prev_d, prev_src
        x = arr[j][4]
        if grant_gap and (d < 0 or (d != prev_d and (prev_src is None or arr[j][1] == prev_src))):
            x = max(x, arr[j][3] + grant_gap)
        prev_d, prev_src = d, arr[j][1]
        return x

    def passes(j):
        return arr[j][2] not in BATCHED and not mrd_batched

    def admit(c, now):
        q = inq[c]
        while q:
            j = q[0]
            if passes(j):
                if fifo[c]:
                    return                             # ordering barrier: flush first
                f2.append(j)
            else:
                if fill[c] >= admit_beats:
                    return                             # prog_full
                if not fifo[c]:
                    tmr[c] = max(now, arr[j][0])
                fifo[c].append(j)
                fill[c] += arr[j][3]
            q.popleft()

    def arrive(upto):
        nonlocal nxt
        while nxt < n and arr[nxt][0] <= upto:
            c = arr[nxt][1]
            inq[c].append(nxt)
            if len(inq[c]) == 1:
                admit(c, arr[nxt][0])
            nxt += 1

    def asks(c, now):
        if not fifo[c]:
            return False
        if inq[c] and passes(inq[c][0]):
            return True                                # flush request
        if not latch[c]:
            r = ("depth" if len(fifo[c]) >= trig_depth else "full" if fill[c] > full_beats
                 else "time" if now - tmr[c] >= time else None)
            if r:
                latch[c], why[c] = True, (r, now - tmr[c])
        return latch[c]

    def serve(c, now):
        nonlocal owner
        j = fifo[c].popleft()
        fill[c] -= arr[j][3]
        out.append((j, now, drain_no))
        end = now + occ(j, drain_no)
        if snap[c] > 0:
            snap[c] -= 1
        if not fifo[c]:
            snap[c], latch[c], tmr[c], owner = 0, False, None, None
        elif snap[c] == 0:                             # drain done: leftovers start a new batch
            latch[c], tmr[c], owner = False, end, None
        if inq[c]:
            admit(c, end)                              # room again, or the barrier cleared
        return end

    while len(out) < n:
        arrive(t)
        if f2:
            j = f2.popleft()
            out.append((j, t, -1))
            t += occ(j, -1)
            continue
        a = [asks(0, t), asks(1, t)]
        if owner is not None and a[owner] and (snap[owner] != 0):
            t = serve(owner, t)
            continue
        c = (0 if rr_last == 1 else 1) if a[0] and a[1] else 1 if a[1] else 0 if a[0] else None
        if c is None:
            ev = [arr[nxt][0]] if nxt < n else []
            ev += [tmr[k] + time for k in (0, 1) if fifo[k] and not latch[k]]
            if not ev:
                break                                  # only blocked input left (cannot happen)
            t = max(t + 1, min(ev))
            continue
        owner, rr_last = c, c
        drain_no += 1
        flush = bool(inq[c]) and passes(inq[c][0])
        if stats is not None:
            r, dt = why[c] if latch[c] else ("flush", t - tmr[c])
            stats["triggers"][c][r] += 1
            stats["trig_cycles"][r].append(dt)
        k = len(fifo[c])
        snap[c] = -1 if flush else (min(k, take_cap) if take_cap else k)
        t = serve(c, t)
    return out


def model(events, tl, names, geoms, strict, kind, bpc=None, fifo=FIFO_DEFAULT, grant_gap=GRANT_GAP,
          progress=None):
    """Each named batcher setting run on the arrival order (batcher()); page
    switches per I/O as it would send them, and with each drain regrouped by
    page (with barriers, and without: the bound), simulated IOTLB misses of
    the first geometry, and the time each TLP would spend in the switch.
    bpc: the uplink's bytes per cycle (cycles()); fifo: the FIFO size in beats
    for settings that don't name one; grant_gap: batcher(). progress(msg), if
    given, hears of each setting. Also returns the mean output cycles per TLP
    the model charges within a drain."""
    arr_ev = [e for e in events if e[1] == ARR and e[5] is not None]
    arr, prev = [], None
    for e in arr_ev:
        _out_sop, in_sop, beats, _seg, _logged = tl[e[0]]
        prev = in_sop if prev is None else max(in_sop, prev)   # past a saturated gap times are bounds
        arr.append((prev, e[5], e[2], beats, cycles(e[2], e[4], beats, bpc)))
    t0 = arr[0][0] if arr else 0
    arr = [(a[0] - t0,) + a[1:] for a in arr]
    res = []
    for k, name in enumerate(names, 1):
        depth, time, cap, mrd = parse_setting(name)
        fb = setting_fifo(name) or fifo
        st = {}
        if progress:
            progress(f"model {k}/{len(names)} {name}")
        sent = batcher(arr, depth, time, cap, mrd, st, fb, grant_gap)
        items, flags, groups, waits = [], [], [], []
        for j, start, d in sent:
            _i, _p, c, addr, _pdw, src, _s, _w = arr_ev[j]
            waits.append(start - arr[j][0])
            if c == "msi":
                continue
            it = (src, addr >> 12, c)
            items.append(it)
            flags.append(c == "data" and (addr & 0xFFF) == 0)
            if groups and groups[-1][0] == d and d >= 0:
                groups[-1][1].append(it)
            else:
                groups.append((d, [it]))
        ios = sum(1 for it in items if it[2] == "cqe")
        runs = {"drive": count_runs(items) / ios if ios else None}
        for pol in POLICIES[1:]:
            seq = []
            for _d, g in groups:
                seq.extend(regroup(g, len(g), pol))
            runs[pol] = count_runs(seq) / ios if ios else None
        miss = (simulate(items, geoms[0][0], geoms[0][1], strict, flags) / ios) if geoms and ios else None
        us = 1e6 / dec.CLOCK_HZ
        res.append(dict(setting=name, depth=depth, time=time, cap=cap, batch_mrd=mrd, fifo=fb, runs=runs,
                        miss=miss, miss_geom=f"{geoms[0][0]}x{geoms[0][1]}" if geoms else None,
                        wait_mean_us=mean(waits) * us if waits else None,
                        wait_p99_us=pct(waits, 99) * us if waits else None,
                        drains=len({d for _j, _s, d in sent if d >= 0}),
                        batched=sum(1 for _j, _s, d in sent if d >= 0),
                        triggers={k: st["triggers"][0][k] + st["triggers"][1][k] for k in TRIGGERS},
                        triggers_in=st["triggers"],
                        trig_p50={k: pct(v, 50) for k, v in st["trig_cycles"].items()}))
    return res, (mean([a[4] for a in arr]) if arr else None)


def trig_share(m):
    """'depth 62% time 30% full 0% flush 8%' from a model() result."""
    tot = sum(m["triggers"].values())
    return " ".join(f"{k} {100 * v / tot:.0f}%" for k, v in m["triggers"].items()) if tot else "-"


def show(rows, port, start, count):
    print(f"\n{port}: the sequence, one line per run (data offsets in hex; visit: new = offset 0 of a page "
          f"not seen before, reuse = offset 0 of a page seen before, gap = not where its last write ended)")
    print(f"{'run':>7} {'record':>7} {'drive':>5} {'class':5} {'page':>12} {'offsets':>11} {'TLPs':>5} "
          f"{'visit':6} {'open d0/d1':>10}")
    cur, shown = None, 0
    seq = [r for r in rows if r[1] == port]
    first = next((k for k, r in enumerate(seq) if r[0] >= start), len(seq))
    for r in seq[first:]:                    # arr is not in record order: start, then list on
        if cur is None or r[6] != cur[6]:
            if cur is not None:
                _line(cur, last, n)
                shown += 1
                if shown >= count:
                    return
            cur, n = r, 0
        n += 1
        last = r
    if cur is not None and shown < count:
        _line(cur, last, n)


def _line(first, last, n):
    rec, _port, src, c, addr, _pdw, run, visit, o0, o1 = first
    drive = "-" if src is None else f"d{src}"
    if c == "msi":
        page, offs = "interrupt", ""
    else:
        page = f"0x{addr >> 12:x}"
        offs = f"{addr & 0xFFF:03x}" + (f"-{last[4] & 0xFFF:03x}" if n > 1 else "")
    print(f"{run:7d} {rec:7d} {drive:>5} {c:5} {page:>12} {offs:>11} {n:5d} {visit:6} {o0:4d}/{o1:<4d}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", help="one pips-log[-id<XXXX>].bin or .bin.gz")
    ap.add_argument("--show", type=int, metavar="N", help="print N runs of the sequence")
    ap.add_argument("--from", dest="start", type=int, default=0, metavar="REC",
                    help="start --show at this record index")
    ap.add_argument("--port", default="out",
                    help="stream(s) for --show, comma-separated: out, arr (v2: the order the TLPs "
                         "entered the switch), in0, in1 (default out)")
    ap.add_argument("--model", metavar="LIST",
                    help="v2: run the batcher model on the arrival order for these settings, "
                         "comma-separated: self (the log's own, from its path or --setting), std "
                         f"({' '.join(STD_SETS)}), sweep ({' '.join(SWEEP_SETS)}), sweepc1 (the same "
                         f"with the cap on), deep ({' '.join(DEEP_SETS)}), or dDtT[m1][c1][fBEATS]; a "
                         "group followed by fBEATS (sweepc1f512) runs each of its settings with a FIFO "
                         "of that many beats")
    ap.add_argument("--link", metavar="genGxW",
                    help="the uplink the model's output can't outrun: gen3x8, gen4x8, ... or none (the "
                         "datapath rate measured from the log only). Default: "
                         + ", ".join(f"{k} {v}" for k, v in LINK_DEFAULT.items()))
    ap.add_argument("--link-rate", type=float, metavar="BPC",
                    help="the uplink's measured rate in bytes per cycle (TLP_OVERHEAD included; "
                         "from --calibrate on clean logs): the slowest the per-log fit may make the link, "
                         "and the model's rate on a log that lost no time. Default: "
                         f"{LINK_EFF} of the raw rate")
    ap.add_argument("--calibrate", action="store_true",
                    help="only fit the uplink's rate to this log (stalls inside packets, from the "
                         "trailer's duration) and print it: 'calibrate: segments S lost L fit BPC clean 0|1'")
    ap.add_argument("--grant-gap", type=int, default=GRANT_GAP, metavar="CYCLES",
                    help=f"cycles the model's output loses at each new drain from the input it just served "
                         f"(default {GRANT_GAP}, from one-NIC d1t0c1 logs)")
    ap.add_argument("--progress", action="store_true",
                    help="print each stage to stderr as it starts (liveness for long runs)")
    ap.add_argument("--fifo", type=int, metavar="BEATS",
                    help="batching FIFO size for the model, in 64-byte beats (default: from the design "
                         f"ID: {FIFO_DEFAULT}, 0x0a05 512)")
    ap.add_argument("--setting", metavar="dDtT[c1]",
                    help="the log's own batcher setting for --model self (default: from the path)")
    ap.add_argument("--csv", help="write every TLP to this CSV")
    ap.add_argument("--iotlb", help="IOTLB geometries to simulate, SETSxWAYS[,...], e.g. 1x64,16x4")
    ap.add_argument("--json", help="append the results to this file as one JSON line")
    ap.add_argument("--strict", action="store_true",
                    help="IOTLB: a page's new visit always misses (strict mode invalidates at unmap)")
    ap.add_argument("--kind", choices=("ssd", "nic"),
                    help="device kind (default: nic if the path contains 'dualnic', else ssd)")
    ap.add_argument("--design-id", metavar="ID",
                    help="design ID of the build that wrote the log (0x0a04, or none); default: "
                         "found from its name or folder (pips-log-decode.py --help)")
    a = ap.parse_args(argv)
    t_start = time_mod.time()

    def progress(msg):
        if a.progress:
            print(f"pips-page-seq: +{time_mod.time() - t_start:.0f}s {msg}", file=sys.stderr, flush=True)
    geoms = []
    if a.iotlb:
        for g in a.iotlb.split(","):
            s, w = g.lower().split("x")
            geoms.append((int(s), int(w)))
    show_ports = a.port.split(",")
    for p in show_ports:
        if p not in PORTS:
            ap.error(f"--port {p}: one of {', '.join(PORTS)}")
    own = a.setting
    if own is None:
        m = SET_IN_PATH.search(os.path.abspath(a.log).replace("\\", "/"))
        own = m.group(1) if m else None
    # "self" on a page batcher log (0x0A06 on): with page_batch_en 0 the model's
    # setting is the log's without the page batcher's fields (o1 q<N> w<N> r...),
    # which the in-order model has no notion of; with p1 there is none.
    own_model = own
    if own is not None and PB_FIELDS.search(own):
        own_model = None if "p1" in own else PB_FIELDS.sub("", own)
    names = []
    for x in (a.model.split(",") if a.model else []):
        g = GROUP_RE.match(x)
        if x == "self" and own is None:
            ap.error("--model self: no setting in the log's path; give --setting")
        if x == "self" and own_model is None:
            print(f"pips-page-seq: --model self left out: {own} is per-page batching (p1), "
                  "which the model does not describe", file=sys.stderr)
            continue
        add = (tuple(s + (g.group(2) or "") for s in GROUPS[g.group(1)]) if g
               else (own_model,) if x == "self" else (x,))
        for nm in add:
            try:
                parse_setting(nm)
            except ValueError as err:
                ap.error(f"--model: {err}")
            if nm not in names:
                names.append(nm)

    kind = a.kind or ("nic" if "dualnic" in os.path.abspath(a.log) else "ssd")
    link = a.link or LINK_DEFAULT[kind]
    try:
        bpc = link_bpc(link)
    except ValueError as err:
        ap.error(f"--link: {err}")
    progress(f"decoding {a.log}")
    fi = dec.detect(a.log, a.design_id)
    fifo = a.fifo or FIFO_BY_DESIGN.get(str(fi["design"]).lower(), FIFO_DEFAULT)
    if fifo_limits(fifo)[1] < MAX_PKT_BEATS:
        ap.error(f"--fifo {fifo}: too small for a {MAX_PKT_BEATS}-beat packet")
    recs, trailer, _pads, _nbytes, problem = dec.load(a.log, False, fi["format"])
    dur_us = trailer["duration_cycles"] / dec.CLOCK_HZ * 1e6 if trailer else None
    events, ms = ap_mod.tlp_events(recs, fi["format"], 16 if kind == "nic" else 4)
    tl, ainfo = None, None
    raw = link_bpc(link, 1.0)
    slowest = None if not raw else raw * LINK_EFF_MIN if a.calibrate else (a.link_rate or raw * LINK_EFF)
    if a.calibrate and fi["format"] != "v2":
        print(f"calibrate: {fi['format']} log, no pkt_wait")
        return 1
    if fi["format"] == "v2":
        progress("rebuilding the arrival order (stalls inside packets put back)")
        arr_events, tl, ainfo = arrival(recs, events, trailer and trailer["duration_cycles"], slowest)
        events = events + arr_events
        if a.calibrate:
            lf, lost = ainfo["link_fit"], ainfo["lost"]
            clean = int(bool(lf) and ainfo["segments"] == 1 and (lost or 0) >= CAL_LOST_MIN
                        and lf > raw * LINK_EFF_MIN * 1.001)
            print(f"calibrate: segments {ainfo['segments']} lost {fmt(lost, '.4f')} fit {fmt(lf, '.3f')} clean {clean}")
            if a.json:
                with open(a.json, "a") as f:
                    f.write(json.dumps(dict(path=a.log, kind=kind, link=link, calibrate=dict(ainfo, clean=clean))) + "\n")
            return 0
        if ainfo["link_fit"] and bpc:
            bpc = ainfo["link_fit"]                  # arrivals and the model on one clock
        elif a.link_rate and bpc:
            bpc = a.link_rate
    elif names or "arr" in show_ports:
        print(f"pips-page-seq: {fi['format']} log has no pkt_wait: no arrival order or model", file=sys.stderr)
        names = []
    progress(f"{len(recs)} records decoded; following the pages")
    rows = annotate(events, kind)
    print(f"log {a.log}: {len(recs)} records, {fmt(dur_us, '.0f')} us"
          + (f" ({problem})" if problem else "")
          + f"; out matched {ms['matched']}, unmatched {ms['unmatched']}, ambiguous {ms['ambiguous']}")
    print(f"  kind {kind}; design {fi['design']}, record format {fi['format']} (design ID from: {fi['source']})"
          + ("; in0/in1 = each drive's TLPs in the order they left" if fi["format"] == "v2" else ""))

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            wr = csv.writer(f)
            wr.writerow((f"# design_id={fi['design']} log_format={fi['format']}",))
            wr.writerow(("record", "port", "drive", "class", "page", "offset", "payload_bytes", "run",
                         "visit", "open_d0", "open_d1"))
            for r in rows:
                wr.writerow((r[0], r[1], "" if r[2] is None else r[2], r[3],
                             "" if r[3] == "msi" else f"0x{r[4] >> 12:x}", f"0x{r[4] & 0xFFF:x}",
                             4 * r[5], r[6], r[7], r[8], r[9]))

    il = interleave(rows)
    print("\nInterleaving of data writes (in0, in1: as each drive sends them; out: as the IOMMU sees them"
          + ("; arr: as they entered the switch" if "arr" in il else "") + ")")
    print(f"{'stream':6} {'data TLPs':>9} {'TLPs/run':>8} {'p50':>4} {'visits':>7} {'one run':>7} "
          f"{'runs/visit':>10} {'open pages d0 mean/p50/p99/max':>31} {'d1':>16}")
    for name, x in il.items():
        o = [x["open"][d] for d in (0, 1)]
        of = ["/".join(fmt(v, ".1f") if j == 0 else fmt(v, "d") for j, v in enumerate(t)) for t in o]
        print(f"{name:6} {x['tlps']:9d} {fmt(x['run_mean'], '8.2f')} {fmt(x['run_p50'], '4d')} "
              f"{x['visits']:7d} {fmt(100 * x['single_run'] if x['single_run'] is not None else None, '6.1f')}% "
              f"{fmt(x['runs_per_visit'], '10.2f')} {of[0]:>31} {of[1]:>16}")

    progress("what-if on out" + (" with the IOTLB simulation" if geoms else ""))
    wi = whatif(events, dur_us, geoms, a.strict)
    print(f"\nBatching what-if on out: {wi['items']} translated TLPs, {wi['ios']} I/Os, "
          f"{fmt(wi['us_per_tlp'] and 1000 * wi['us_per_tlp'], '.1f')} ns per TLP")
    print(f"{'W':>4} {'wait us mean/max':>17} {'pages/window mean/p99':>22} "
          f"{'runs per I/O: logged':>21} {'drive':>7} {'page':>7} {'ideal':>7}")
    logged = wi["rows"][0]["runs"]["drive"]
    for r in wi["rows"]:
        print(f"{r['w']:4d} {fmt(r['wait_mean'], '8.2f')}/{fmt(r['wait_max'], '<8.2f')} "
              f"{fmt(r['pages_mean'], '14.1f')}/{fmt(r['pages_p99'], '<7d')} {fmt(logged, '21.2f')} "
              f"{fmt(r['runs']['drive'], '7.2f')} {fmt(r['runs']['page'], '7.2f')} {fmt(r['runs']['ideal'], '7.2f')}")
    if geoms:
        print(f"\nSimulated IOTLB misses per I/O ({'strict: new visits always miss' if a.strict else 'no invalidation'})")
        head = "".join(f"{f'{s}x{w} ' + pol:>14}" for s, w in geoms for pol in POLICIES)
        print(f"{'W':>4} {head}")
        for r in wi["rows"]:
            print(f"{r['w']:4d} " + "".join(f"{fmt(r['miss'][(pol, g)], '14.3f')}" for g in geoms for pol in POLICIES))

    wa, svc, per_beat, mod, recorded, mod_cyc = None, {}, None, [], None, None
    if tl is not None:
        print(f"\nArrival order (arr): each TLP's output start minus its pkt_wait. {ainfo['tlps']} TLPs, "
              f"{ainfo['segments']} segment(s), {ainfo['wait_saturated']} saturated waits; "
              f"{fmt(ainfo['moved'] and 100 * ainfo['moved'], '.1f')}% left in another position than they arrived")
        lf = ainfo["link_fit"]
        print(f"  The output as logged spans {fmt(ainfo['lost'] is not None and 100 * (1 - ainfo['lost']), '.1f')}% "
              f"of the recording; "
              + (f"stalls inside packets put back with the link at {lf:.1f} bytes per cycle "
                 f"({(256 + TLP_OVERHEAD) / lf:.2f} cycles per 256 B TLP, {100 * lf / link_bpc(link, 1.0):.1f}% "
                 f"of {link}'s raw rate; transmit buffer {ainfo['tx_buf']} B)"
                 + (f", {ainfo['idle_extra']:.0f} more idle cycles at each saturated gap" if ainfo['idle_extra'] else "")
                 if lf else "no stalls put back")
              + f"; {fmt(ainfo['held'] and 100 * ainfo['held'], '.2f')}% of TLPs held to their input's output order")
        progress("what-if on the arrival order")
        wa = whatif(events, dur_us, [], a.strict, ARR)
        print(f"Batching what-if on arr (windows of the arrival order): {wa['ios']} I/Os")
        print(f"{'W':>4} {'runs per I/O: as arrived':>25} {'drive':>7} {'page':>7} {'ideal':>7}")
        for r in wa["rows"]:
            print(f"{r['w']:4d} {fmt(wa['rows'][0]['runs']['drive'], '25.2f')} {fmt(r['runs']['drive'], '7.2f')} "
                  f"{fmt(r['runs']['page'], '7.2f')} {fmt(r['runs']['ideal'], '7.2f')}")
        out_items = [(e[5], e[2], e[4], tl[e[0]][4], tl[e[0]][4] - (tl[e[0]][0] - tl[e[0]][1]), tl[e[0]][2])
                     for e in events if e[1] == 2 and e[0] in tl and e[5] is not None]
        svc, per_beat = service(out_items)
        waits = [e[7] for e in events if e[1] == 2 and e[7] is not None and e[7] != WAIT_SAT]
        recorded = dict(setting=own, runs=wi["rows"][0]["runs"]["drive"],
                        miss=wi["rows"][0]["miss"][("drive", geoms[0])] if geoms else None,
                        wait_mean_us=mean(waits) * 1e6 / dec.CLOCK_HZ if waits else None)
        if names:
            mod, mod_cyc = model(events, tl, names, geoms, a.strict, kind, bpc, fifo, a.grant_gap, progress)
            print(f"\nBatcher model on the arrival order (axi4_mwr_batch.v: depth/time/full triggers, drains of "
                  f"the packets present at the grant, cap, inputs alternating, reads after their input's writes). "
                  f"Output cycles per TLP when queued, from this log: "
                  + ", ".join(f"{c} {p} DW {v}" for (c, p), v in sorted(svc.items(), key=lambda kv: str(kv[0])))
                  + f"; else {per_beat:.2f} per beat. The model takes 1 cycle per 64-byte beat, "
                  + f"+{a.grant_gap} per new drain from the same input")
            print(f"  ... and no faster than the uplink, {link}"
                  + (" fitted above" if ainfo["link_fit"] and bpc == ainfo["link_fit"] else "")
                  + (f" ({bpc:.1f} bytes per cycle: {(256 + TLP_OVERHEAD) / bpc:.2f} cycles per 256 B TLP)" if bpc else "")
                  + f": {fmt(mod_cyc, '.2f')} cycles per TLP on average; the log's output took "
                  + f"{fmt(wi['us_per_tlp'] and wi['us_per_tlp'] * dec.CLOCK_HZ / 1e6, '.2f')}. "
                  + f"FIFO {fifo} beats per input (design {fi['design']}"
                  + (", --fifo" if a.fifo else "") + f"), unless a setting names its own (fBEATS)")
            print(f"{'setting':>13} {'runs per I/O: as sent':>22} {'by page':>8} {'bound':>7} "
                  f"{'misses/I/O':>11} {'wait us mean/p99':>17} {'TLPs/drain':>10}  drains asked for by")
            for m_ in mod:
                print(f"{m_['setting']:>13} {fmt(m_['runs']['drive'], '22.2f')} {fmt(m_['runs']['page'], '8.2f')} "
                      f"{fmt(m_['runs']['ideal'], '7.2f')} {fmt(m_['miss'], '11.3f')} "
                      f"{fmt(m_['wait_mean_us'], '8.2f')}/{fmt(m_['wait_p99_us'], '<8.2f')} "
                      f"{fmt(m_['batched'] / m_['drains'] if m_['drains'] else None, '10.1f')}  {trig_share(m_)}")
            print(f"{'recorded':>13} {fmt(recorded['runs'], '22.2f')} {'':>8} {'':>7} {fmt(recorded['miss'], '11.3f')} "
                  f"{fmt(recorded['wait_mean_us'], '8.2f')}   ({own or 'setting unknown'}, as logged on out)")

    if a.json:
        rec = dict(path=a.log, kind=kind, design_id=fi["design"], log_format=fi["format"],
                   strict=a.strict, matched=ms["matched"], unmatched=ms["unmatched"],
                   interleave={k: dict(v, open={str(d): o for d, o in v["open"].items()}) for k, v in il.items()},
                   ios=wi["ios"], us_per_tlp=wi["us_per_tlp"],
                   windows=[dict(w=r["w"], wait_mean=r["wait_mean"], pages_mean=r["pages_mean"],
                                 pages_p99=r["pages_p99"], runs=r["runs"],
                                 miss={f"{g[0]}x{g[1]}": {pol: r["miss"][(pol, g)] for pol in POLICIES}
                                       for g in geoms}) for r in wi["rows"]])
        if wa is not None:
            rec.update(setting=own, arrival=ainfo, recorded=recorded,
                       windows_arr=[dict(w=r["w"], wait_mean=r["wait_mean"], pages_mean=r["pages_mean"],
                                         pages_p99=r["pages_p99"], runs=r["runs"]) for r in wa["rows"]],
                       service={f"{c}/{p}": v for (c, p), v in svc.items()}, service_per_beat=per_beat,
                       link=dict(name=link, bytes_per_cycle=bpc, eff=LINK_EFF, overhead=TLP_OVERHEAD,
                                 fitted=bool(ainfo["link_fit"]) and bpc == ainfo["link_fit"],
                                 rate_given=a.link_rate),
                       fifo=fifo, grant_gap=a.grant_gap, model_cycles_per_tlp=mod_cyc, model=mod)
        with open(a.json, "a") as f:
            f.write(json.dumps(rec) + "\n")

    progress("done")
    if a.show:
        for p in show_ports:
            if p == "arr" and tl is None:
                continue
            show(rows, p, a.start, a.show)
    return 0


if __name__ == "__main__":
    sys.exit(main())
