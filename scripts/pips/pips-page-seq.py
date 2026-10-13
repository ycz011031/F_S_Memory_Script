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

LOG is one pips-log.bin(.gz). Out TLPs are matched to their drive as in
pips-addr-pattern.py. Python 3, standard library only.

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
"""
import argparse
import collections
import csv
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_addr_pattern",
                                               os.path.join(HERE, "pips-addr-pattern.py"))
ap_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ap_mod)
dec = ap_mod.dec

WINDOWS = (1, 2, 4, 8, 16, 32, 64, 128, 256, 512)
POLICIES = ("drive", "page", "ideal")
PORTS = ("in0", "in1", "out")


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(p / 100 * len(s)))]


def mean(vals):
    return sum(vals) / len(vals) if vals else None


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def annotate(events):
    """Per port: the TLP sequence with run numbers, visit state and open pages.
    Rows: (rec, port, drive, cls, addr, pdw, run, visit, open_d0, open_d1)."""
    rows = []
    state = {}
    for port in range(3):
        st = state[port] = dict(prev=None, run=-1, next_off={}, seen=set(), open=[set(), set()])
    for i, port, c, addr, pdw, src, _src_i in events:
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
            if off + nbytes >= 4096:
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


def whatif(events, dur_us, geoms, strict):
    items = [(src, addr >> 12, c) for _i, port, c, addr, pdw, src, _s in events
             if port == 2 and src is not None and c != "msi"]
    new = [c == "data" and (addr & 0xFFF) == 0 for _i, port, c, addr, pdw, src, _s in events
           if port == 2 and src is not None and c != "msi"]
    n_out = sum(1 for e in events if e[1] == 2)
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


def show(rows, port, start, count):
    print(f"\n{port}: the sequence, one line per run (data offsets in hex; visit: new = offset 0 of a page "
          f"not seen before, reuse = offset 0 of a page seen before, gap = not where its last write ended)")
    print(f"{'run':>7} {'record':>7} {'drive':>5} {'class':5} {'page':>12} {'offsets':>11} {'TLPs':>5} "
          f"{'visit':6} {'open d0/d1':>10}")
    cur, shown = None, 0
    for r in rows:
        if r[1] != port or r[0] < start:
            continue
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", help="one pips-log.bin or .bin.gz")
    ap.add_argument("--show", type=int, metavar="N", help="print N runs of the sequence")
    ap.add_argument("--from", dest="start", type=int, default=0, metavar="REC",
                    help="start --show at this record index")
    ap.add_argument("--port", choices=PORTS, default="out", help="stream for --show (default out)")
    ap.add_argument("--csv", help="write every TLP to this CSV")
    ap.add_argument("--iotlb", help="IOTLB geometries to simulate, SETSxWAYS[,...], e.g. 1x64,16x4")
    ap.add_argument("--json", help="append the results to this file as one JSON line")
    ap.add_argument("--strict", action="store_true",
                    help="IOTLB: a page's new visit always misses (strict mode invalidates at unmap)")
    a = ap.parse_args()
    geoms = []
    if a.iotlb:
        for g in a.iotlb.split(","):
            s, w = g.lower().split("x")
            geoms.append((int(s), int(w)))

    recs, trailer, _pads, _nbytes, problem = dec.load(a.log, False)
    dur_us = trailer["duration_cycles"] / dec.CLOCK_HZ * 1e6 if trailer else None
    events, ms = ap_mod.tlp_events(recs)
    rows = annotate(events)
    print(f"log {a.log}: {len(recs)} records, {fmt(dur_us, '.0f')} us"
          + (f" ({problem})" if problem else "")
          + f"; out matched {ms['matched']}, unmatched {ms['unmatched']}, ambiguous {ms['ambiguous']}")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            wr = csv.writer(f)
            wr.writerow(("record", "port", "drive", "class", "page", "offset", "payload_bytes", "run",
                         "visit", "open_d0", "open_d1"))
            for r in rows:
                wr.writerow((r[0], r[1], "" if r[2] is None else r[2], r[3],
                             "" if r[3] == "msi" else f"0x{r[4] >> 12:x}", f"0x{r[4] & 0xFFF:x}",
                             4 * r[5], r[6], r[7], r[8], r[9]))

    il = interleave(rows)
    print("\nInterleaving of data writes (in0, in1: as each drive sends them; out: as the IOMMU sees them)")
    print(f"{'stream':6} {'data TLPs':>9} {'TLPs/run':>8} {'p50':>4} {'visits':>7} {'one run':>7} "
          f"{'runs/visit':>10} {'open pages d0 mean/p50/p99/max':>31} {'d1':>16}")
    for name, x in il.items():
        o = [x["open"][d] for d in (0, 1)]
        of = ["/".join(fmt(v, ".1f") if j == 0 else fmt(v, "d") for j, v in enumerate(t)) for t in o]
        print(f"{name:6} {x['tlps']:9d} {fmt(x['run_mean'], '8.2f')} {fmt(x['run_p50'], '4d')} "
              f"{x['visits']:7d} {fmt(100 * x['single_run'] if x['single_run'] is not None else None, '6.1f')}% "
              f"{fmt(x['runs_per_visit'], '10.2f')} {of[0]:>31} {of[1]:>16}")

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

    if a.json:
        rec = dict(path=a.log, strict=a.strict, matched=ms["matched"], unmatched=ms["unmatched"],
                   interleave={k: dict(v, open={str(d): o for d, o in v["open"].items()}) for k, v in il.items()},
                   ios=wi["ios"], us_per_tlp=wi["us_per_tlp"],
                   windows=[dict(w=r["w"], wait_mean=r["wait_mean"], pages_mean=r["pages_mean"],
                                 pages_p99=r["pages_p99"], runs=r["runs"],
                                 miss={f"{g[0]}x{g[1]}": {pol: r["miss"][(pol, g)] for pol in POLICIES}
                                       for g in geoms}) for r in wi["rows"]])
        with open(a.json, "a") as f:
            f.write(json.dumps(rec) + "\n")

    if a.show:
        show(rows, a.port, a.start, a.show)
    return 0


if __name__ == "__main__":
    sys.exit(main())
