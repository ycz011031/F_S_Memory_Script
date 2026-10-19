#!/usr/bin/env python3
"""Pick the batcher's time_threshold for each depth, so that the depth trigger
asks for a good share of the drains instead of the timeout, from a PIPS
sweep's results (no TLP logs needed).

    pips-timeout-pick.py ~/dualssd-pips-strict-1-id0a04-d1t0.jsonl
    pips-timeout-pick.py ~/dualnic-pips-strict-1-id0a04-d1t0.jsonl --kind nic
    pips-timeout-pick.py JSONL --depths "2 4 8 16" --target 0.5 --json pick.json
    pips-timeout-pick.py JSONL... --validate        # the arrival model against the recorded waits

Each JSONL record is one load point (fio IOPS per drive and block size, or
each NIC's write rate, and the TLPs each input sent during the TLP log). For
every point it builds an arrival stream per input and runs the batcher of
pips-page-seq.py (axi4_mwr_batch.v: depth, time and full triggers, reads
flushing their input, drains alternating, cap) on it for each candidate
setting dDtTc1, counting which trigger asked for each drain.

Arrivals, per input (synthetic; the logs' own arrival order is
pips-page-seq.py --model on a d1t0 log):
  drive  I/Os at the fio rate (Poisson); each sends block/256 data TLPs of
         256 B (5 beats) back to back, one every --gap cycles (Gen4 x4:
         280 wire bytes per TLP, ~9 cycles of 4 ns), then its completion
         entry and an interrupt (1 beat each); 0.8 reads per I/O at random
         (pass-through: each flushes its input's FIFO). TLPs beyond those
         (drive 1's host-buffer writes) go in as 144 B writes inside the burst.
  nic    packets of 8 TLPs (7 x 512 B, 9 beats, + 448 B, 8 beats) one every
         --gap cycles, each packet at least 81 cycles after the last (100 GbE
         wire time of 4032 B) plus an exponential gap for the measured rate;
         a 64 B completion (2 beats) after each, 0.1 more at random, and
         reads for the rest of the TLP count.
The output takes 9 cycles per 256 B (drive uplink Gen3 x8) or 512 B (NIC,
the 512-bit datapath) TLP and 1-2 per small one; contention between the two
inputs and FIFO backpressure come out of the model.

The choice, per depth D: the smallest T (0-255 cycles) at which the depth
trigger asks for at least --target of the drains at the median light point
(the points whose output is below --light of the uplink: where T decides;
on a full uplink the FIFO backlog meets any depth the FIFO can hold). If no T
gets there, 255. A FIFO holds 109 beats and its full trigger fires above 93,
so a depth above 93 / (beats per data TLP) can't trigger: about 18 for 256 B
TLPs and 10 for 512 B ones. Those depths get T = 255 and are marked.
--fifo 512 models design 0x0A05's FIFOs instead (493 / 477 beats: 95 and 53
TLPs); the settings are then named dDtTc1f512.

--validate runs the settings each record was recorded with (pips_batch, with
the FIFO size of its pips_design_id) and compares the modelled mean wait (plus the pipeline latency, the light-load
d1t0 wait) with the log's pips_out_wait_mean.
Python 3, standard library only; a line per point as it finishes.
"""
import argparse
import concurrent.futures as cf
import importlib.util
import json
import math
import os
import random
import re
import statistics
import sys
import time as _time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_page_seq", os.path.join(HERE, "pips-page-seq.py"))
seq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seq)

CLOCK_MHZ = 250
FULL_BEATS = seq.FULL_BEATS
KIND = {
    # beats and output cycles per class; data_beats is the beats of a full data TLP
    "ssd": dict(data=(5, 9), extra=(3, 5), cqe=(1, 2), msi=(1, 1), read=(1, 1), gap=9.2, uplink_tlps=27.8e6),
    "nic": dict(data=(9, 9), tail=(8, 8), cqe=(2, 2), msi=(1, 1), read=(1, 1), gap=9.0, uplink_tlps=31e6),
}
DEPTHS = (1, 2, 4, 8, 16, 24, 36, 64)


def reachable(kind, depth, fifo=seq.FIFO_DEFAULT):
    """Whether a FIFO of `fifo` beats of full data TLPs reaches `depth` packets
    before its full trigger (FULL_BEATS at the default 128)."""
    return depth * KIND[kind]["data"][0] <= seq.fifo_limits(fifo)[1]


def fifo_suffix(fifo):
    """'' for the 0x0A04 FIFO, else 'f<beats>' to append to a setting name."""
    return "" if fifo == seq.FIFO_DEFAULT else f"f{fifo}"


def load_points(paths, kind):
    pts = []
    for p in paths:
        with open(p) as f:
            for line in f:
                r = json.loads(line)
                m = r.get("mean", {})
                dur = m.get("pips_duration_us")
                if not dur:
                    continue
                exp = r.get("exp", "")
                name = exp.split("/")[-1] if kind == "ssd" else re.sub(r"^.*?-(?:uncapped|\d+g)-", "", exp)
                ins = []
                for c in (0, 1):
                    tlps = m.get(f"pips_in{c}_tlp", 0) / dur * 1e6       # TLPs per second
                    if kind == "ssd":
                        iops = m.get(f"iops_ssd{c}", 0)
                        bs = r.get("bs", "4k")
                        nbytes = int(bs[:-1]) * (1024 if bs[-1] == "k" else 1048576)
                        ins.append(dict(rate=iops, tlps=tlps, data=nbytes // 256))
                    else:
                        wr = m.get(f"pips_in{c}_mwr_gbps", 0) * 1e9 / 8
                        ins.append(dict(rate=wr / (4032 + 64 * 1.1), tlps=tlps))
                fifo = seq.FIFO_BY_DESIGN.get(str(r.get("pips_design_id", "")).lower(), seq.FIFO_DEFAULT)
                pts.append(dict(name=name, setting=r.get("pips_batch"), fifo=fifo, path=p, ins=ins,
                                out_tlps=m.get("pips_out_tlp", 0) / dur * 1e6,
                                wait=m.get("pips_out_wait_mean"), src=os.path.basename(p)))
    return pts


def arrivals(pt, kind, n_target, gap, seed):
    """Synthetic arrival stream for one point: (t_in, src, cls, beats, cycles), sorted."""
    rng = random.Random(seed)
    K = KIND[kind]
    tot = sum(i["tlps"] for i in pt["ins"])
    if tot <= 0:
        return []
    span = n_target / tot * CLOCK_MHZ * 1e6                       # cycles to simulate
    arr = []
    for c, inp in enumerate(pt["ins"]):
        if inp["rate"] <= 0 or inp["tlps"] <= 0:
            continue
        per_cycle = inp["rate"] / (CLOCK_MHZ * 1e6)                # I/Os or packets per cycle
        t, free = 0.0, 0.0
        if kind == "ssd":
            extra = max(0.0, inp["tlps"] / inp["rate"] - inp["data"] - 2.8)
            while True:
                t += rng.expovariate(per_cycle)
                if t > span:
                    break
                s = max(t, free)
                n = inp["data"]
                k_extra = int(extra) + (rng.random() < extra - int(extra))
                kinds = ["data"] * n + ["extra"] * k_extra
                if k_extra:
                    rng.shuffle(kinds)
                    kinds.remove("data"); kinds.insert(0, "data")
                for cls in kinds:
                    b, cy = K[cls]
                    arr.append((s, c, "data", b, cy))
                    s += gap if cls == "data" else gap * 0.6
                arr.append((s, c, "cqe") + K["cqe"]); s += 1.3
                if rng.random() < 0.98:
                    arr.append((s, c, "msi") + K["msi"]); s += 1.0
                free = s
            nread = int(0.8 * inp["rate"] * span / (CLOCK_MHZ * 1e6))
        else:
            mean_gap = 1 / per_cycle
            wire = 81.0
            extra_cqe = 0.1
            while True:
                t += wire + (rng.expovariate(1 / (mean_gap - wire)) if mean_gap > wire + 1 else 0.0)
                if t > span:
                    break
                s = max(t, free)
                for k in range(8):
                    b, cy = K["data"] if k < 7 else K["tail"]
                    arr.append((s, c, "data", b, cy))
                    s += gap
                arr.append((s, c, "cqe") + K["cqe"]); s += 2
                if rng.random() < extra_cqe:
                    arr.append((s, c, "cqe") + K["cqe"]); s += 2
                free = s
            pkts = inp["rate"] * span / (CLOCK_MHZ * 1e6)
            nread = int(max(0.0, inp["tlps"] / inp["rate"] - 9.1) * pkts) if inp["rate"] else 0
        for _ in range(nread):
            arr.append((rng.uniform(0, span), c, "read") + K["read"])
    arr.sort(key=lambda a: a[0])
    return arr


def run_setting(arr, name):
    d, t, cap, mrd = seq.parse_setting(name)
    st = {}
    sent = seq.batcher(arr, d, t, cap, mrd, st, seq.setting_fifo(name) or seq.FIFO_DEFAULT)
    waits = [s - arr[j][0] for j, s, _d in sent]
    trig = {k: st["triggers"][0][k] + st["triggers"][1][k] for k in seq.TRIGGERS}
    drains = sum(trig.values())
    batched = sum(1 for _j, _s, dn in sent if dn >= 0)
    return dict(setting=name, triggers=trig, drains=drains,
                tlps_per_drain=batched / drains if drains else None,
                wait_mean=statistics.fmean(waits) if waits else None,
                trig_p50={k: seq.pct(v, 50) for k, v in st["trig_cycles"].items()})


def work(job):
    pt, kind, names, n_target, gap, seed = job
    t0 = _time.time()
    arr = arrivals(pt, kind, n_target, gap, seed)
    res = [run_setting(arr, nm) for nm in names] if arr else []
    return pt, res, _time.time() - t0


PER_PACKET = (2, 4, 6, 8, 9, 10, 11, 12, 14, 16, 20, 24, 32)


def candidates(depth):
    """Time thresholds to try for one depth: D times a few cycles per packet
    (back to back at link rate a data TLP takes about 9), and 255."""
    return sorted({min(255, depth * k) for k in PER_PACKET} | {255})


def share(r, k="depth"):
    return r["triggers"][k] / r["drains"] if r["drains"] else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("jsonl", nargs="+", help="sweep results (~/<sweep>-<setting>.jsonl), one record per point")
    ap.add_argument("--kind", choices=("ssd", "nic"), help="default: nic if a path contains 'dualnic'")
    ap.add_argument("--depths", default=" ".join(map(str, DEPTHS)), help="depths to pick a time for")
    ap.add_argument("--target", type=float, default=0.5,
                    help="share of drains the depth trigger should ask for at the median light point (0.5)")
    ap.add_argument("--light", type=float, default=0.85,
                    help="a light point's output TLP rate is below this share of the uplink's (0.85)")
    ap.add_argument("--gap", type=float, help="cycles between back-to-back data TLPs of one input "
                                              "(default 9.2 drives, 9 NICs)")
    ap.add_argument("--tlps", type=int, default=40000, help="TLPs simulated per point (40000)")
    ap.add_argument("--points", help="regex: only points whose name matches")
    ap.add_argument("--validate", action="store_true",
                    help="model each record's own setting and compare the wait with the log's")
    ap.add_argument("--eval", metavar="CFGS",
                    help='only these settings, as the sweeps\' --cfgs ("2:22 4:50"), with the cap on: '
                         "what asks for the drains at light and full points")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2, help="points at a time")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--json", help="write the per-point, per-setting results here")
    ap.add_argument("--fifo", type=int, default=seq.FIFO_DEFAULT,
                    help=f"batching FIFO in beats ({seq.FIFO_DEFAULT}; 512 for design 0x0A05)")
    a = ap.parse_args()
    fx = fifo_suffix(a.fifo)
    kind = a.kind or ("nic" if any("dualnic" in p for p in a.jsonl) else "ssd")
    gap = a.gap or KIND[kind]["gap"]
    pts = load_points(a.jsonl, kind)
    if a.points:
        pts = [p for p in pts if re.search(a.points, p["name"])]
    if not a.validate:                       # one record per point: the first file that has it
        seen, uniq = set(), []
        for p in pts:
            if p["name"] not in seen:
                seen.add(p["name"]); uniq.append(p)
        pts = uniq
    if not pts:
        sys.exit("pips-timeout-pick: no records with a TLP log summary (pips_duration_us)")
    depths = [int(x) for x in a.depths.split()]
    uplink = KIND[kind]["uplink_tlps"]
    evals = []
    if a.eval:
        for c in a.eval.split():
            d, t = (int(x) for x in c.split(":")[:2])
            evals.append(f"d{d}t{t}c1{fx}")
    if a.validate:
        jobs = [(p, kind, [p["setting"] + fifo_suffix(p["fifo"]), "d1t0" + fifo_suffix(p["fifo"])],
                 a.tlps, gap, a.seed) for p in pts if p["setting"]]
    elif evals:
        jobs = [(p, kind, evals, a.tlps, gap, a.seed) for p in pts]
    else:
        names = sorted({f"d{d}t{t}c1{fx}" for d in depths for t in (candidates(d) if d > 1 else (0,))},
                       key=lambda s: seq.parse_setting(s)[:2])
        jobs = [(p, kind, names, a.tlps, gap, a.seed) for p in pts]
    print(f"pips-timeout-pick: {len(jobs)} point(s), kind {kind}, {a.tlps} TLPs each, "
          f"data TLPs {gap:g} cycles apart, {len(jobs[0][2])} setting(s) per point, {a.j} at a time", flush=True)
    out, t0 = [], _time.time()
    with cf.ProcessPoolExecutor(max_workers=a.j) as ex:
        for k, (pt, res, dt) in enumerate(ex.map(work, jobs), 1):
            out.append((pt, res))
            print(f"[{k:3d}/{len(jobs)}] {dt:5.1f}s  {pt['src']}  {pt['name']}", flush=True)
    print(f"done in {_time.time() - t0:.0f} s")

    if a.validate:
        print("\nRecorded against modelled mean wait, cycles (modelled + the d1t0 pipeline latency)")
        lat = [pt["wait"] - r[1]["wait_mean"] for pt, r in out
               if pt["setting"] == "d1t0" and pt["out_tlps"] < 0.3 * uplink and r]
        p0 = statistics.median(lat) if lat else 0.0
        print(f"pipeline latency (light d1t0 points, recorded - modelled): {p0:.1f} cycles")
        print(f"{'point':18} {'setting':9} {'out %':>6} {'recorded':>9} {'model':>7} {'ratio':>6}  drains asked for by (model)")
        errs = {}
        for pt, r in sorted(out, key=lambda x: (x[0]["name"], x[0]["setting"])):
            if not r:
                continue
            m = r[0]["wait_mean"] + p0
            ratio = m / pt["wait"] if pt["wait"] else None
            light = pt["out_tlps"] < a.light * uplink
            if ratio and light:
                errs.setdefault(pt["setting"], []).append(ratio)
            trig = " ".join(f"{k} {100 * share(r[0], k):.0f}%" for k in seq.TRIGGERS)
            print(f"{pt['name']:18} {pt['setting']:9} {100 * pt['out_tlps'] / uplink:6.0f} {pt['wait']:9.1f} "
                  f"{m:7.1f} {ratio:6.2f}  {trig}")
        print("\nlight points, model / recorded mean wait: median (range) per setting")
        for s, v in sorted(errs.items(), key=lambda kv: seq.parse_setting(kv[0])[:3]):
            print(f"  {s:9} {statistics.median(v):5.2f} ({min(v):.2f}-{max(v):.2f}), {len(v)} points")
        return 0

    light = [(pt, {r["setting"]: r for r in res}) for pt, res in out if pt["out_tlps"] < a.light * uplink]
    full = [(pt, {r["setting"]: r for r in res}) for pt, res in out if pt["out_tlps"] >= a.light * uplink]
    print(f"\n{len(light)} light point(s) (output below {100 * a.light:.0f}% of the uplink), {len(full)} full")
    if evals:
        def med(group, nm, k):
            v = [share(rs[nm], k) for _p, rs in group]
            return f"{100 * statistics.median(v):3.0f}%" if v else "   -"
        rows = []
        print(f"\n{'setting':10} {'T ns':>5}  light points (median): depth  time  full flush  TLPs/drain  wait"
              f"   full points: depth  time  full flush")
        for nm in evals:
            d, t, _c, _m = seq.parse_setting(nm)
            tpd = [rs[nm]["tlps_per_drain"] for _p, rs in light if rs[nm]["tlps_per_drain"]]
            wl = [rs[nm]["wait_mean"] for _p, rs in light if rs[nm]["wait_mean"] is not None]
            print(f"{nm:10} {4 * t:5d}  {'':22}" + " ".join(med(light, nm, k) for k in seq.TRIGGERS)
                  + f"  {statistics.median(tpd) if tpd else 0:10.1f}  {statistics.median(wl) * 4 if wl else 0:4.0f} ns"
                  + f"  {'':12}" + " ".join(med(full, nm, k) for k in seq.TRIGGERS)
                  + ("" if reachable(kind, d, a.fifo) else "   depth unreachable"))
            rows.append(dict(setting=nm, depth=d, time=t, reachable=reachable(kind, d, a.fifo),
                             light={k: statistics.median([share(rs[nm], k) for _p, rs in light]) if light else None
                                    for k in seq.TRIGGERS},
                             full={k: statistics.median([share(rs[nm], k) for _p, rs in full]) if full else None
                                   for k in seq.TRIGGERS},
                             tlps_per_drain_light=statistics.median(tpd) if tpd else None,
                             wait_light_ns=statistics.median(wl) * 4 if wl else None))
        if a.json:
            with open(a.json, "w") as f:
                json.dump(dict(kind=kind, gap=gap, light=a.light, tlps=a.tlps, fifo=a.fifo, eval=rows,
                               points=[dict(name=pt["name"], src=pt["src"], out_share=pt["out_tlps"] / uplink,
                                            results=res) for pt, res in out]), f)
            print(f"results: {a.json}")
        return 0
    picks = []
    for d in depths:
        ts = candidates(d) if d > 1 else [0]
        rows = []
        for t in ts:
            nm = f"d{d}t{t}c1{fx}"
            dl = [share(rs[nm]) for _p, rs in light] or [0.0]
            tl = [share(rs[nm], "time") for _p, rs in light] or [0.0]
            df = [share(rs[nm]) for _p, rs in full] or [0.0]
            wl = [rs[nm]["wait_mean"] for _p, rs in light if rs[nm]["wait_mean"] is not None] or [0.0]
            rows.append(dict(t=t, setting=nm, depth_light_p50=statistics.median(dl), depth_light_min=min(dl),
                             depth_light_max=max(dl), time_light_p50=statistics.median(tl),
                             depth_full_p50=statistics.median(df), wait_light_p50=statistics.median(wl)))
        ok = reachable(kind, d, a.fifo)
        if d == 1:
            pick = rows[0]
        elif ok:
            pick = next((r for r in rows if r["depth_light_p50"] >= a.target), rows[-1])
        else:
            pick = rows[-1]
        picks.append(dict(depth=d, reachable=ok, pick=pick, rows=rows))
        print(f"\ndepth {d}{'' if ok else '  (above what the FIFO holds before its full trigger: depth never asks)'}")
        print(f"  {'T':>4} {'ns':>5}   light points: depth p50 (min-max)  time p50  wait p50   full points: depth p50")
        for r in rows:
            mark = "  <- pick" if r is pick else ""
            print(f"  {r['t']:4d} {4 * r['t']:5d}   {100 * r['depth_light_p50']:9.0f}% "
                  f"({100 * r['depth_light_min']:3.0f}-{100 * r['depth_light_max']:3.0f}%)  "
                  f"{100 * r['time_light_p50']:7.0f}%  {r['wait_light_p50'] / CLOCK_MHZ * 1000:6.0f} ns"
                  f"   {100 * r['depth_full_p50']:9.0f}%{mark}")
    cfgs = " ".join(f"{p['depth']}:{p['pick']['t']}" for p in picks)
    print(f"\npicked (--cfgs, with --caps 1): \"{cfgs}\"")
    for p in picks:
        r = p["pick"]
        print(f"  {r['setting']:10} T {r['t']:3d} cycles = {4 * r['t']:4d} ns: depth asks for "
              f"{100 * r['depth_light_p50']:.0f}% of drains at the median light point, "
              f"{100 * r['depth_full_p50']:.0f}% on a full uplink" + ("" if p["reachable"] else "; depth unreachable"))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(dict(kind=kind, gap=gap, target=a.target, light=a.light, tlps=a.tlps, fifo=a.fifo, cfgs=cfgs, picks=picks,
                           points=[dict(name=pt["name"], src=pt["src"], out_share=pt["out_tlps"] / uplink,
                                        results=res) for pt, res in out]), f)
        print(f"results: {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
