#!/usr/bin/env python3
"""Address and burst pattern of PIPS TLP logs: the stream the IOMMU translates.

    pips-addr-pattern.py LOG [LOG ...]                  one table line per log
    pips-addr-pattern.py utils/logs/dualssd-pips-strict-1-d8t22 ...
                                                        every pips-log.bin(.gz) under
                                                        these folders
    ... --jsonl addr-pattern.jsonl                      also one JSON object per log
    ... --match '4k-j*-both'                            only run folders matching this

LOG is a dump as `pips log-dump` wrote it, e.g. a sweep run's pips-log.bin.gz.
It is read with pips-log-decode.py's loader. Python 3, standard library only.

Classes. Each TLP from a drive is one of: data (MWr, more than 16 bytes), cqe
(MWr of at most 16 bytes: an NVMe completion entry), msi (MWr to
0xFEE0_0000-0xFEEF_FFFF), mrd (memory read: command fetch, PRP list, or the
990 EVO Plus's host memory buffer), other.

Per log:
  width     share of the drives' memory requests at or above 4 GiB (64-bit
            address, 4-DW header). With the IOMMU on, Linux gives IOVAs below
            4 GiB; with it off these are physical addresses.
  pages     distinct 4 KiB pages, 2 MiB and 1 GiB regions of each drive's data
            writes. 2 MiB is what one leaf page table covers, 1 GiB one page
            directory: the levels of the page walk.
  visits    a visit is a drive's data writes to one 4 KiB page for one I/O; it
            starts at the TLP with page offset 0 (buffers are 4 KiB aligned
            under O_DIRECT). TLPs per visit, and the share of visits to a page
            the log saw before (an IOVA or buffer handed out again).
  ios       NVMe completion entries per drive: one per I/O completed.
  out       each out TLP is matched to its in0/in1 record. Per channel the
            batcher keeps order (memory reads in their own FIFO), so the match
            is the oldest pending TLP of that channel and class. Then: runs of
            one drive's TLPs on out, and the records logged between a TLP's in
            and out records ("hold"), in µs at the log's average record rate.
  reuse     LRU stack distance on out, per translated TLP (msi left out): how
            many other (drive, 4 KiB page) pairs were touched since this pair's
            last touch. A fully associative LRU IOTLB of E entries hits iff
            the distance is below E. "cold" is a first touch in the log.
  predicted misses per I/O for IOTLB sizes E, two ways: "lru" = cold + every
            distance >= E; "strict" = every new visit (strict mode invalidates
            the page at unmap, so a page's next I/O always misses) + the rest
            at distance >= E. Compare with pcm-iio's misses per I/O.

A log is a snapshot of a few ms (262,143 records under load), so the first
touches of pages already in use before it started count as cold.
"""
import argparse
import collections
import fnmatch
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_log_decode",
                                               os.path.join(HERE, "pips-log-decode.py"))
dec = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dec)

MSI_LO, MSI_HI = 0xFEE00000, 0xFEF00000
BUCKETS = (0, 1, 4, 16, 64, 256, 1024, 4096)          # lower bounds; then "cold"
IOTLB_SIZES = (16, 32, 64, 128, 256, 512, 1024)
CH = ("in0", "in1")


def classify(typ, addr, pdw):
    t = typ & 0xF
    if t == 0:
        return "mrd"
    if t == 1:
        if MSI_LO <= addr < MSI_HI:
            return "msi"
        return "cqe" if pdw <= 4 else "data"
    return "other"


def bucket(d):
    """Index into BUCKETS for a stack distance; len(BUCKETS) means cold."""
    if d is None:
        return len(BUCKETS)
    for i in range(len(BUCKETS) - 1, -1, -1):
        if d >= BUCKETS[i]:
            return i
    return 0


def bucket_names():
    names = []
    for i, lo in enumerate(BUCKETS):
        hi = BUCKETS[i + 1] - 1 if i + 1 < len(BUCKETS) else None
        names.append(str(lo) if hi == lo else f"{lo}-{hi}" if hi is not None else f">={lo}")
    return names + ["cold"]


class StackDistance:
    """LRU stack distance in O(log n) per access: a Fenwick tree over access
    times holds a 1 at each key's most recent access."""

    def __init__(self, n):
        self.n, self.tree, self.last, self.t = n, [0] * (n + 1), {}, 0

    def _add(self, i, v):
        while i <= self.n:
            self.tree[i] += v
            i += i & -i

    def _sum(self, i):
        s = 0
        while i > 0:
            s += self.tree[i]
            i -= i & -i
        return s

    def access(self, key):
        self.t += 1
        prev = self.last.get(key)
        d = None
        if prev is not None:
            d = self._sum(self.t - 1) - self._sum(prev)
            self._add(prev, -1)
        self._add(self.t, 1)
        self.last[key] = self.t
        return d


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(p / 100 * len(s)))]


def tlp_events(recs):
    """Every TLP record in log order as (index, port, class, addr, payload_dw,
    drive, drive's record index). For in0/in1 the drive is the port. For out it
    is the channel whose oldest pending TLP of the same class (memory reads have
    their own FIFO) has the same address, type, size and tag; None when no
    channel matches, e.g. a TLP sent before the log started. Also returns
    counts: drops per port, matched, ambiguous, unmatched, lost."""
    pending = [{"w": collections.deque(), "r": collections.deque()} for _ in CH]
    in_holes = [0, 0]
    out_holes = 0
    st = dict(drops=[0, 0, 0], matched=0, ambiguous=0, unmatched=0, lost=0)
    events = []
    for i, (addr, length, _gap, typ, pdw, tag, _at, info, _r) in enumerate(recs):
        kind, port = (info >> 2) & 3, info & 3
        if kind == dec.KIND_DROP:
            st["drops"][port] += 1
            if port < 2:
                in_holes[port] += 1
            elif port == 2:
                out_holes += 1
            continue
        if kind != dec.KIND_TLP or port > 2:
            continue
        c = classify(typ, addr, pdw)
        q = "r" if c == "mrd" else "w"
        key = (addr, typ & 0xF, pdw, length, tag)
        if port < 2:
            pending[port][q].append(key + (i,))
            events.append((i, port, c, addr, pdw, port, i))
            continue
        src, src_i = None, None
        heads = [ch for ch in (0, 1) if pending[ch][q] and pending[ch][q][0][:5] == key]
        if heads:
            if len(heads) == 2:
                st["ambiguous"] += 1
                heads.sort(key=lambda ch: pending[ch][q][0][5])
            src = heads[0]
            src_i = pending[src][q].popleft()[5]
            st["matched"] += 1
        else:
            # an out record was dropped: its TLP is still at the head
            for ch in (0, 1):
                dq = pending[ch][q]
                for j in range(1, min(out_holes, len(dq) - 1) + 1):
                    if dq[j][:5] == key:
                        for _ in range(j):
                            dq.popleft()
                        out_holes -= j
                        st["lost"] += j
                        src, src_i = ch, dq.popleft()[5]
                        st["matched"] += 1
                        break
                if src is not None:
                    break
            if src is None:
                holes = [ch for ch in (0, 1) if in_holes[ch]]
                if len(holes) == 1:                    # its in record was dropped
                    src = holes[0]
                    in_holes[src] -= 1
                else:
                    st["unmatched"] += 1
        events.append((i, 2, c, addr, pdw, src, src_i))
    return events, st


def analyse(path):
    recs, trailer, _pads, _nbytes, problem = dec.load(path, False)
    n = len(recs)
    dur_us = trailer["duration_cycles"] / dec.CLOCK_HZ * 1e6 if trailer else None
    us_per_rec = dur_us / n if dur_us and n else None

    cls = [collections.Counter() for _ in CH]
    hi64 = [0, 0]
    mem = [0, 0]
    pages = [set() for _ in CH]
    reg2m = [collections.Counter() for _ in CH]
    reg1g = [set() for _ in CH]
    payload = [0, 0]
    visits = [0, 0]
    revisits = [0, 0]
    seen_page = [set() for _ in CH]
    mrd_reg2m = [collections.Counter() for _ in CH]

    holds = []
    runs, run_src, run_len = [], None, 0
    page_runs, prun_key, prun_len = [], None, 0
    sd = StackDistance(n)
    dist = {c: collections.Counter() for c in ("data_new", "data_cont", "cqe", "mrd", "other")}
    visit_open = [None, None]          # page of the drive's current visit, on out
    out_ios = 0                        # completion entries on out: I/Os the out stream covers

    events, ms = tlp_events(recs)
    for i, port, c, addr, pdw, src, src_i in events:
        if port < 2:                                   # a drive's request
            p = port
            cls[p][c] += 1
            if c != "msi" and c != "other":
                mem[p] += 1
                hi64[p] += addr >= 1 << 32
            if c == "data":
                pg = addr >> 12
                pages[p].add(pg)
                reg2m[p][addr >> 21] += 1
                reg1g[p].add(addr >> 30)
                payload[p] += 4 * pdw
                if addr & 0xFFF == 0:
                    visits[p] += 1
                    revisits[p] += pg in seen_page[p]
                    seen_page[p].add(pg)
            elif c == "mrd":
                mrd_reg2m[p][addr >> 21] += 1
            continue

        if src_i is not None:
            holds.append(i - src_i)
        if src is not None and src == run_src:
            run_len += 1
        else:
            if run_len:
                runs.append(run_len)
            run_src, run_len = src, 1 if src is not None else 0

        if c == "msi" or src is None:
            continue
        pkey = (src, addr >> 12)
        if pkey == prun_key:
            prun_len += 1
        else:
            if prun_len:
                page_runs.append(prun_len)
            prun_key, prun_len = pkey, 1
        d = sd.access(pkey)
        if c == "data":
            new = addr & 0xFFF == 0 or visit_open[src] != addr >> 12
            visit_open[src] = addr >> 12
            cat = "data_new" if new else "data_cont"
        else:
            cat = c if c in dist else "other"
        dist[cat][d] += 1                              # d is None for a first touch
        out_ios += c == "cqe"

    if run_len:
        runs.append(run_len)
    if prun_len:
        page_runs.append(prun_len)

    ios = [cls[p]["cqe"] for p in (0, 1)]
    hist = {cat: [0] * (len(BUCKETS) + 1) for cat in dist}
    for cat, cnt in dist.items():
        for d, k in cnt.items():
            hist[cat][bucket(d)] += k
    pred = {}
    for e in IOTLB_SIZES:
        def misses(cat):
            return sum(k for d, k in dist[cat].items() if d is None or d >= e)
        rest = sum(misses(cat) for cat in dist if cat != "data_new")
        pred[e] = dict(lru=(rest + misses("data_new")) / out_ios if out_ios else None,
                       strict=(rest + sum(dist["data_new"].values())) / out_ios if out_ios else None)

    def top_regions(counter, k=4):
        tot = sum(counter.values())
        return [[f"0x{r << 21:x}", round(cnt / tot, 4)] for r, cnt in counter.most_common(k)] if tot else []

    weighted_run = sum(r * r for r in runs) / sum(runs) if runs else None
    out = dict(
        path=path, status=problem or ("FULL" if trailer and trailer["stop_reason"] == "region_full"
                                      else "CUT" if trailer else "NO_TRAILER"),
        records=n, duration_us=dur_us, drops=ms["drops"],
        drives={CH[p]: dict(
            classes=dict(cls[p]), ios=ios[p],
            tlp_per_io=sum(cls[p].values()) / ios[p] if ios[p] else None,
            width64=hi64[p] / mem[p] if mem[p] else None,
            data_pages=len(pages[p]), data_2m=len(reg2m[p]), data_1g=len(reg1g[p]),
            data_bytes_per_tlp=payload[p] / cls[p]["data"] if cls[p]["data"] else None,
            visits=visits[p], data_tlp_per_visit=cls[p]["data"] / visits[p] if visits[p] else None,
            revisit=revisits[p] / visits[p] if visits[p] else None,
            data_top_2m=top_regions(reg2m[p]), mrd_top_2m=top_regions(mrd_reg2m[p]))
            for p in (0, 1)},
        out=dict(matched=ms["matched"], ambiguous=ms["ambiguous"], unmatched=ms["unmatched"], lost=ms["lost"],
                 run_mean=sum(runs) / len(runs) if runs else None, run_weighted=weighted_run,
                 run_p50=pct(runs, 50), run_p99=pct(runs, 99), run_max=max(runs) if runs else None,
                 page_run_mean=sum(page_runs) / len(page_runs) if page_runs else None,
                 hold_rec_p50=pct(holds, 50), hold_rec_p99=pct(holds, 99),
                 hold_us_p50=pct(holds, 50) * us_per_rec if holds and us_per_rec else None,
                 hold_us_p99=pct(holds, 99) * us_per_rec if holds and us_per_rec else None),
        reuse=dict(buckets=bucket_names(), **hist),
        predicted_miss_per_io={str(e): v for e, v in pred.items()})
    return out


def find_logs(args, pattern):
    for a in args:
        if os.path.isdir(a):
            for root, dirs, files in os.walk(a):
                dirs.sort()
                for f in sorted(files):
                    if f in ("pips-log.bin", "pips-log.bin.gz"):
                        run = os.path.basename(root)
                        if not pattern or fnmatch.fnmatch(run, pattern):
                            yield os.path.join(root, f)
        else:
            yield a


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+", help="logs, or folders searched for pips-log.bin(.gz)")
    ap.add_argument("--match", help="only run folders whose name matches this glob")
    ap.add_argument("--jsonl", help="append one JSON object per log to this file")
    a = ap.parse_args()

    jl = open(a.jsonl, "a") if a.jsonl else None
    print(f"{'run':52} {'IOs d0/d1':>11} {'TLP/IO':>11} {'64b%':>5} {'pages d0/d1':>13} "
          f"{'2M':>7} {'reuse%':>9} {'out run':>8} {'hold us p50/p99':>16} "
          f"{'pred miss/IO strict E=64/256':>29}")
    for path in find_logs(a.paths, a.match):
        try:
            r = analyse(path)
        except SystemExit as e:                       # pips-log-decode's fail()
            print(f"{path}: {e}", file=sys.stderr)
            continue
        d0, d1 = r["drives"]["in0"], r["drives"]["in1"]
        o, pm = r["out"], r["predicted_miss_per_io"]
        w = [x["width64"] for x in (d0, d1) if x["width64"] is not None]
        name = os.path.relpath(os.path.dirname(path)) if os.path.dirname(path) else path
        print(f"{name[-52:]:52} {d0['ios']:5d}/{d1['ios']:<5d} "
              f"{fmt(d0['tlp_per_io'], '5.1f')}/{fmt(d1['tlp_per_io'], '<5.1f')} "
              f"{fmt(100 * sum(w) / len(w) if w else None, '5.1f')} "
              f"{d0['data_pages']:6d}/{d1['data_pages']:<6d} {d0['data_2m']:3d}/{d1['data_2m']:<3d} "
              f"{fmt(100 * d0['revisit'] if d0['revisit'] is not None else None, '4.0f')}/"
              f"{fmt(100 * d1['revisit'] if d1['revisit'] is not None else None, '<4.0f')} "
              f"{fmt(o['run_weighted'], '8.1f')} "
              f"{fmt(o['hold_us_p50'], '7.2f')}/{fmt(o['hold_us_p99'], '<8.2f')} "
              f"{fmt(pm['64']['strict'], '14.2f')}/{fmt(pm['256']['strict'], '<14.2f')}")
        if o["unmatched"] > 100 or o["lost"]:
            print(f"  note: {o['unmatched']} out TLPs unmatched, {o['lost']} lost", file=sys.stderr)
        if jl:
            jl.write(json.dumps(r) + "\n")
    if jl:
        jl.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
