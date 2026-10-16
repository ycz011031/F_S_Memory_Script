#!/usr/bin/env python3
"""Traffic and payload-length patterns in every PIPS TLP log: can the switch
tell a device's payload writes from its control writes by size alone?

    pips-traffic.py                                  every log under utils/logs
    pips-traffic.py utils/logs/dualnic-pips-strict-1-id0a04-*    logs or folders
    ... --format v2                                  only logs of design 0x0a04 on
    ... --match '4k-j*'                              only run folders matching this glob
    ... --by kind,design,iommu,cfg,load              what the end tables are summed over
                                                     (default kind,design,iommu,cfg)
    ... --csv sizes.csv --jsonl traffic.jsonl        every log's numbers
    ... -j 8                                         logs decoded in parallel (default 4)
    pips-traffic.py LOG --detail                     one log's size table and motifs

It reads every pips-log[-id<XXXX>].bin(.gz) (the sweeps' runs) and
log[-id<XXXX>].bin (pips-fio-log.sh) under the folders given, in either record
format (pips-log-decode.py picks it by design ID), and prints a line as each
log is done. Python 3, standard library only.

Doorbells are not in the log. They are host-to-device writes, and the logger
sees only what the devices send toward the host (PIO-MANUAL.md §8.1). What
the log shows of the same exchange are the devices' control writes: NVMe
completion entries, NIC completion entries or descriptor write-backs, and
MSI-X interrupts. This tool asks whether those can be told from payload.

Every write a device sends (MWr, per input in0/in1) is classed two ways:

  by address  msi:  to 0xFEE0_0000-0xFEEF_FFFF.
              Every other write by how its 4 KiB page is written over the
              log. A visit to a page is a group of the device's writes to it
              with at most 8 of its other writes between them.
              ring:    a ring of fixed-size entries (completion queue,
                       descriptor write-back ring): the page has at least 3
                       visits, at least 75% of them start where the previous
                       one ended (the ring marches on), at most 2 KiB per
                       visit on average, all sizes multiples of the smallest
                       (at most 4x) and every offset aligned to it;
              payload: otherwise, if its visits average at least two
                       writes: buffers filled in bursts of MPS-sized pieces;
              unclear: anything else, e.g. pages of single-write payloads.
              (Per size it also reports "burst": the share of writes
              address-contiguous with one at most 4 writes away. Entries
              written back to back are bursts too, so it is shown, not used.)
  by size     its payload_dw.

The size rule is the threshold T that best splits ring from payload with
"ring if payload_dw <= T". Its accuracy is the share of ring + payload writes
on which size and address agree; unclear writes are left out and counted.
Verdict: RELIABLE at >= 99.9% with at least 100 writes of each, MOSTLY at
>= 99%, NO below.

Length pattern. A device's ring writes with no payload between them form a
group (entries posted back to back), and the payload writes it sent before a
group form one transaction (one I/O for NVMe, one or a few packets for a NIC).
The motif is their sizes in order, run-length coded, then the ring writes in
the group: "64x16 -> 1" = sixteen 64 DW writes (4 KiB at MPS 256 B), then one
entry; "64x15 40 -> 1" = 15 x 256 B + 160 B (a 4000 B packet), one entry;
"?" marks unclear writes. Reported: the commonest motifs and their share of
groups, payload bytes per ring write, interrupts per ring write, memory reads
(descriptor and command fetches) per ring write.

Timing, v2 logs only: the time each class spent in the batcher (pkt_wait),
mean and p99 in us: does batching hold back control writes?

Each log is labelled from its folders: kind (ssd/nic), sweep, IOMMU mode,
batcher setting (with c1 for the drain cap) and design ID from the run's
pips-cfg.txt or else the sweep's name, and the load (block size and fio
instances, or rate and flows) and mode from the run's name.
"""
import argparse
import collections
import csv
import fnmatch
import importlib.util
import json
import math
import multiprocessing
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_log_decode",
                                               os.path.join(HERE, "pips-log-decode.py"))
dec = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dec)

DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "utils", "logs"))
MSI_LO, MSI_HI = 0xFEE00000, 0xFEF00000
BURST_WINDOW = 4                 # writes either side that may hold the contiguous neighbour
VISIT_GAP = 8                    # other writes allowed between two writes of one page visit
RING_VISITS = 3                  # a ring page: at least this many visits,
RING_CONT = 0.75                 #   this share of them starting where the last one ended,
RING_VISIT_BYTES = 2048          #   and at most this many bytes per visit on average
CLASSES = ("payload", "ring", "unclear")
WAIT_CLASSES = ("payload", "ring", "unclear", "msi", "mrd")
SRC = ("in0", "in1")
LOG_NAME = re.compile(r"^(?:pips-)?log(?:-id[0-9a-fA-F]{4})?\.bin(?:\.gz)?$")
SWEEP_RE = re.compile(r"(?P<sweep>dual(?P<kind>ssd|nic)-pips-(?P<iommu>[^/]+?)-\d+"
                      r"(?:-id(?P<design>[0-9a-fA-F]{4}))?-(?P<cfg>d\d+t\d+(?:m1)?(?:c1)?))(?=[-/]|$)")
SSD_RUN_RE = re.compile(r"^(?P<dp>datapath-)?(?P<bs>\d+[kmgKMG]?)-j(?P<j>[\d+]+)(?:-(?P<mode>[a-z0-9]+))?"
                        r"-RUN-\d+$")
NIC_RUN_RE = re.compile(r"-(?P<rate>uncapped|\d+g)-f(?P<flows>\d+)-(?P<mode>nic0only|nic1only|both|datapath)"
                        r"-RUN-server-\d+$")
GROUP_KEYS = ("kind", "design", "iommu", "cfg", "load", "mode", "sweep", "run", "all")
REL, MOSTLY = 0.999, 0.99


# ------------------------------------------------------------------ finding and labelling logs
def find_logs(paths, pattern):
    for a in paths:
        if os.path.isdir(a):
            for root, dirs, files in os.walk(a):
                dirs.sort()
                for f in sorted(files):
                    if LOG_NAME.match(f):
                        if not pattern or fnmatch.fnmatch(os.path.basename(root), pattern):
                            yield os.path.join(root, f)
        elif os.path.exists(a):
            yield a
        else:
            print(f"pips-traffic: {a}: no such file or folder", file=sys.stderr)


def first_match(path, regex):
    try:
        with open(path) as f:
            for line in f:
                m = regex.match(line)
                if m:
                    return m
    except OSError:
        pass
    return None


def labels(path):
    """kind, sweep, iommu, cfg, design, load, mode and run of a log, from its folders."""
    run_dir = os.path.dirname(os.path.abspath(path))
    run = os.path.basename(run_dir)
    m = dict(kind="?", sweep="?", iommu="?", cfg="?", design="?", load="?", mode="?", run=run)
    s = SWEEP_RE.search(run_dir.replace(os.sep, "/"))
    if s:
        m.update(kind=s["kind"], sweep=s["sweep"], iommu=s["iommu"], cfg=s["cfg"])
        if s["design"]:
            m["design"] = "0x" + s["design"].lower()
    elif "RUN-server" in run:
        m["kind"] = "nic"
    elif run.startswith("pips-fio") or "dualssd" in run_dir:
        m["kind"] = "ssd"
    io = first_match(os.path.join(os.path.dirname(run_dir), "sweep.log"),
                     re.compile(r"^######## IOMMU: (\S+)"))
    if io:
        m["iommu"] = io[1]
    for name in ("pips-cfg.txt", "cfg-run.txt", "cfg-before.txt"):
        pc = os.path.join(run_dir, name)
        cf = first_match(pc, re.compile(r"^cfg=(0x[0-9a-fA-F]+)"))
        if cf:
            v = int(cf[1], 16)
            cap = first_match(pc, re.compile(r".*drain_depth_cap=([01])"))
            m["cfg"] = (f"d{v & 0xFF}t{(v >> 8) & 0xFF}" + ("m1" if (v >> 16) & 1 else "")
                        + ("c1" if cap and cap[1] == "1" else ""))
            break
    r = SSD_RUN_RE.match(run)
    if r:
        m.update(load=f"{r['bs']} j{r['j']}", mode="datapath" if r["dp"] else (r["mode"] or "?"))
    r = NIC_RUN_RE.search(run)
    if r:
        m.update(load=f"{r['rate']} f{r['flows']}", mode=r["mode"])
    return m


# ------------------------------------------------------------------ one device's stream
def pct_counter(c, p):
    """p-th percentile of a Counter {value: count}."""
    n = sum(c.values())
    if not n:
        return None
    want, seen = p / 100 * n, 0
    for v in sorted(c):
        seen += c[v]
        if seen >= want:
            return v
    return max(c)


def rle(tokens, max_runs=6):
    runs = []
    for t in tokens:
        if runs and runs[-1][0] == t:
            runs[-1][1] += 1
        else:
            runs.append([t, 1])
    s = " ".join(f"{t}x{n}" if n > 1 else str(t) for t, n in runs[:max_runs])
    return s + (f" +{len(runs) - max_runs} runs" if len(runs) > max_runs else "") if s else "(none)"


def analyse_source(stream):
    """stream: one device's records in log order, (addr, length, type, payload_dw, kind, wait)."""
    st = dict(mwr=0, msi=0, mrd=0, other=0, drops=0)
    writes = []                                    # (addr, pdw, wait, is_msi), every MWr in order
    waits = {c: collections.Counter() for c in WAIT_CLASSES}
    for addr, _length, typ, pdw, kind, wait in stream:
        if kind == dec.KIND_DROP:
            st["drops"] += 1
            continue
        t = typ & 0xF
        if t == 1:
            msi = MSI_LO <= addr < MSI_HI
            writes.append((addr, pdw, wait, msi))
            st["mwr"] += 1
            st["msi"] += msi
            if msi and wait is not None and wait != dec.WAIT_SAT:
                waits["msi"][wait] += 1
        elif t == 0:
            st["mrd"] += 1
            if wait is not None and wait != dec.WAIT_SAT:
                waits["mrd"][wait] += 1
        else:
            st["other"] += 1

    data = [k for k, w in enumerate(writes) if not w[3]]      # non-MSI writes, by index into writes
    burst = [False] * len(data)
    ends = {}                                                 # end address -> position in data
    for i, k in enumerate(data):
        addr, pdw = writes[k][0], writes[k][1]
        j = ends.get(addr)
        if j is not None and i - j <= BURST_WINDOW:
            burst[i] = burst[j] = True
        ends[addr + 4 * pdw] = i

    # Per 4 KiB page: its visits (writes to it with at most VISIT_GAP other writes
    # between them), how many of them start where the previous one ended, bytes.
    pages = {}          # page -> [writes, sizes, gcd of offsets, visits, continued, bytes, last, end]
    for i, k in enumerate(data):
        addr, pdw = writes[k][0], writes[k][1]
        off, nb = addr & 0xFFF, 4 * pdw
        p = pages.get(addr >> 12)
        if p is None:
            p = pages[addr >> 12] = [0, set(), 0, 1, 0, 0, i, off + nb]
        elif i - p[6] > VISIT_GAP:
            p[3] += 1
            p[4] += off == p[7] % 4096
            p[7] = off + nb
        else:
            p[7] = max(p[7], off + nb)
        p[0] += 1
        p[1].add(pdw)
        p[2] = math.gcd(p[2], off)
        p[5] += nb
        p[6] = i
    pclass = {}
    for pg, (n, sizes, g, visits, cont, nbytes, _last, _end) in pages.items():
        m = min(sizes)
        ring = (visits >= RING_VISITS and cont >= RING_CONT * (visits - 1)
                and nbytes / visits <= RING_VISIT_BYTES and m > 0 and max(sizes) <= 4 * m
                and all(s % m == 0 for s in sizes) and g % (4 * m) == 0)
        pclass[pg] = "ring" if ring else "payload" if n >= 2 * visits else "unclear"
    st["pages"] = dict(collections.Counter(pclass.values()))

    sizes = {}
    size_pages = collections.defaultdict(set)
    motifs = collections.Counter()                 # "payload motif -> entries" per completion group
    ring_bytes = collections.Counter()             # payload bytes per ring write, weighted by entries
    cur, cur_bytes, group = [], 0, None            # group: [motif, payload bytes, ring writes]

    def close(g):
        if g:
            motifs[f"{g[0]} -> {g[2]}"] += 1
            ring_bytes[round(g[1] / g[2])] += g[2]

    pos = {k: i for i, k in enumerate(data)}
    for k, (addr, pdw, wait, msi) in enumerate(writes):
        if msi:
            continue
        i = pos[k]
        c = pclass[addr >> 12]
        s = sizes.get(pdw)
        if s is None:
            s = sizes[pdw] = dict(n=0, burst=0, payload=0, ring=0, unclear=0, next_msi=0, aligned=0)
        s["n"] += 1
        s["burst"] += burst[i]
        s[c] += 1
        s["next_msi"] += k + 1 < len(writes) and writes[k + 1][3]
        s["aligned"] += pdw > 0 and (addr & 0xFFF) % (4 * pdw) == 0
        size_pages[pdw].add(addr >> 12)
        if wait is not None and wait != dec.WAIT_SAT:
            waits[c][wait] += 1
        if c == "ring":
            if group is not None and not cur:          # back to back with the last entry
                group[2] += 1
            else:
                close(group)
                group = [rle(cur), cur_bytes, 1]
            cur, cur_bytes = [], 0
        elif c == "payload":
            cur.append(pdw)
            cur_bytes += 4 * pdw
        else:
            cur.append(f"?{pdw}")
    close(group)
    for pdw, ps in size_pages.items():
        sizes[pdw]["pages"] = len(ps)
    st.update(sizes=sizes, motifs=motifs, ring_bytes=ring_bytes, waits=waits)
    return st


def analyse(job):
    """One log -> its labels and per-device results, or an error. Runs in a worker."""
    path, design = job
    t0 = time.time()
    try:
        fi = dec.detect(path, design)
        recs, trailer, _pads, _nbytes, problem = dec.load(path, False, fi["format"])
    except SystemExit as e:                                   # pips-log-decode's fail()
        return dict(path=path, error=str(e), secs=time.time() - t0)
    except Exception as e:                                    # e.g. a .gz cut short
        return dict(path=path, error=f"{type(e).__name__}: {e}", secs=time.time() - t0)
    v2 = fi["format"] == "v2"
    streams = ([], [])
    for addr, length, _gap, typ, pdw, _tag, _at, info, wait in recs:
        kind, port = (info >> 2) & 3, info & 3
        if port > 1 or kind not in (dec.KIND_TLP, dec.KIND_DROP):
            continue                                          # v1: out records repeat the inputs
        streams[port].append((addr, length, typ, pdw, kind, wait))
    if problem:
        status = "BAD"
    elif not trailer:
        status = "NO_TRAILER"
    else:
        status = ("FULL" if trailer["stop_reason"] == "region_full" else "CUT") + \
                 ("+DROPS" if trailer["n_dropped"] else "")
    lab = labels(path)
    if fi["design_id"] is not None or lab["design"] == "?":
        lab["design"] = fi["design"]
    return dict(path=path, labels=lab, format=fi["format"], design_source=fi["source"],
                status=status, records=len(recs), v2=v2, secs=time.time() - t0,
                src={SRC[p]: analyse_source(streams[p]) for p in (0, 1)})


# ------------------------------------------------------------------ the size rule
def size_rule(sizes):
    """Best "ring if payload_dw <= T" over {pdw: counts}: (T, accuracy, errors, ring, payload, unclear)."""
    ring = sum(s["ring"] for s in sizes.values())
    pay = sum(s["payload"] for s in sizes.values())
    unclear = sum(s["unclear"] for s in sizes.values())
    if not ring or not pay:
        return None, None, 0, ring, pay, unclear
    best = None
    ring_le, pay_le = 0, 0
    for t in sorted(sizes):
        ring_le += sizes[t]["ring"]
        pay_le += sizes[t]["payload"]
        err = (ring - ring_le) + pay_le
        if best is None or err < best[1]:
            best = (t, err)
    t, err = best
    return t, 1 - err / (ring + pay), err, ring, pay, unclear


def verdict(acc, ring, pay):
    if acc is None:
        return "n/a"
    if acc >= REL and ring >= 100 and pay >= 100:
        return "RELIABLE"
    return "MOSTLY" if acc >= MOSTLY else "NO"


def class_sizes(sizes, cls, k=3):
    """The sizes most of whose writes are cls, commonest first, as '4' or '64:93%'."""
    tot = sum(s[cls] for s in sizes.values())
    top = sorted(((s[cls], pdw) for pdw, s in sizes.items() if s[cls] * 2 > s["n"]), reverse=True)[:k]
    return ",".join(f"{pdw}" + (f":{100 * n / tot:.0f}%" if len(top) > 1 else "") for n, pdw in top) or "-"


def wait_us(c, p=None):
    if not c or not sum(c.values()):
        return None
    if p is None:
        v = sum(k * n for k, n in c.items()) / sum(c.values())
    else:
        v = pct_counter(c, p)
    return v / dec.CLOCK_HZ * 1e6


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


# ------------------------------------------------------------------ merging and printing
def new_acc():
    return dict(logs=0, mwr=0, msi=0, mrd=0, other=0, drops=0, pages=collections.Counter(),
                sizes={}, motifs=collections.Counter(), ring_bytes=collections.Counter(),
                waits={c: collections.Counter() for c in WAIT_CLASSES})


def merge(acc, st):
    acc["logs"] += 1
    for k in ("mwr", "msi", "mrd", "other", "drops"):
        acc[k] += st[k]
    acc["pages"].update(st["pages"])
    for pdw, s in st["sizes"].items():
        t = acc["sizes"].setdefault(pdw, dict.fromkeys(s, 0))
        for k, v in s.items():
            t[k] = t.get(k, 0) + v
    acc["motifs"].update(st["motifs"])
    acc["ring_bytes"].update(st["ring_bytes"])
    for c in WAIT_CLASSES:
        acc["waits"][c].update(st["waits"][c])


def src_line(st):
    """One device's short result: rule, accuracy, the ring and payload sizes."""
    if not st["mwr"]:
        return "no writes"
    t, acc, _err, ring, pay, unclear = size_rule(st["sizes"])
    n = sum(s["n"] for s in st["sizes"].values())
    if t is None:
        return (f"no {'ring' if not ring else 'payload'} writes ({st['mwr']} MWr, "
                f"{100 * unclear / n if n else 0:.0f}% unclear)")
    return (f"<={t}DW {100 * acc:.2f}% ring {class_sizes(st['sizes'], 'ring')} "
            f"payload {class_sizes(st['sizes'], 'payload')}"
            + (f" unclear {100 * unclear / n:.0f}%" if unclear * 100 >= n else ""))


def summary_stats(st):
    t, acc, err, ring, pay, unclear = size_rule(st["sizes"])
    rw = ring or 0
    ng = sum(st["motifs"].values())
    top = st["motifs"].most_common(1)
    return dict(rule_dw=t, accuracy=acc, errors=err, ring=ring, payload=pay, unclear=unclear,
                verdict=verdict(acc, ring, pay),
                ring_sizes=class_sizes(st["sizes"], "ring"), payload_sizes=class_sizes(st["sizes"], "payload"),
                msi_per_ring=st["msi"] / rw if rw else None, mrd_per_ring=st["mrd"] / rw if rw else None,
                bytes_per_ring_p50=pct_counter(st["ring_bytes"], 50),
                bytes_per_ring_mean=(sum(k * n for k, n in st["ring_bytes"].items()) /
                                     sum(st["ring_bytes"].values())) if st["ring_bytes"] else None,
                ring_groups=ng, top_motif=top[0][0] if top else None,
                top_motif_share=top[0][1] / ng if top and ng else None,
                wait_us={c: dict(mean=wait_us(st["waits"][c]), p99=wait_us(st["waits"][c], 99))
                         for c in WAIT_CLASSES})


def print_sizes(st, indent="    ", k=10):
    tot = sum(s["n"] for s in st["sizes"].values()) or 1
    print(f"{indent}{'DW':>4} {'writes':>9} {'share':>6} {'burst':>6} {'payload':>7} {'ring':>6} "
          f"{'unclear':>7} {'>msi':>6} {'aligned':>7} {'pages':>7}")
    for pdw, s in sorted(st["sizes"].items(), key=lambda kv: -kv[1]["n"])[:k]:
        n = s["n"]
        print(f"{indent}{pdw:>4} {n:9d} {100 * n / tot:5.1f}% {100 * s['burst'] / n:5.1f}% "
              f"{100 * s['payload'] / n:6.1f}% {100 * s['ring'] / n:5.1f}% {100 * s['unclear'] / n:6.1f}% "
              f"{100 * s['next_msi'] / n:5.1f}% {100 * s['aligned'] / n:6.1f}% {s.get('pages', 0):7d}")
    if len(st["sizes"]) > k:
        print(f"{indent}... {len(st['sizes']) - k} more sizes")


def print_motifs(st, indent="    ", k=5):
    ng = sum(st["motifs"].values())
    if not ng:
        return
    print(f"{indent}payload before each group of ring writes (motif -> ring writes in the group; "
          f"share of {ng} groups):")
    for m, n in st["motifs"].most_common(k):
        print(f"{indent}  {100 * n / ng:5.1f}%  {m}")


def print_group(title, accs, v2):
    print(f"\n== {title}")
    for src in SRC:
        st = accs.get(src)
        if not st or not st["mwr"]:
            continue
        sm = summary_stats(st)
        w = sm["wait_us"]
        print(f"  {src}: {st['logs']} logs, {st['mwr']} MWr ({st['msi']} MSI), {st['mrd']} MRd; "
              f"pages payload/ring/unclear {st['pages'].get('payload', 0)}/{st['pages'].get('ring', 0)}/"
              f"{st['pages'].get('unclear', 0)}")
        print(f"    size rule: ring if <= {fmt(sm['rule_dw'], 'd')} DW, agrees on "
              f"{fmt(sm['accuracy'] and 100 * sm['accuracy'], '.3f')}% ({sm['errors']} of "
              f"{sm['ring'] + sm['payload']} disagree; {sm['unclear']} unclear)  -> {sm['verdict']}")
        print(f"    ring sizes {sm['ring_sizes']}, payload sizes {sm['payload_sizes']}; per ring write: "
              f"{fmt(sm['bytes_per_ring_p50'], 'd')} B payload (p50; mean {fmt(sm['bytes_per_ring_mean'], '.0f')}), "
              f"{fmt(sm['msi_per_ring'], '.3f')} MSI, {fmt(sm['mrd_per_ring'], '.3f')} MRd")
        if v2:
            print("    time in batcher, us mean/p99: " + ", ".join(
                f"{c} {fmt(w[c]['mean'], '.2f')}/{fmt(w[c]['p99'], '.2f')}" for c in WAIT_CLASSES
                if w[c]["mean"] is not None))
        print_sizes(st, k=8)
        print_motifs(st, k=3)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", help=f"logs, or folders searched for them (default {DEFAULT_ROOT})")
    ap.add_argument("--match", help="only run folders whose name matches this glob")
    ap.add_argument("--format", choices=("v1", "v2"), help="only logs in this record format")
    ap.add_argument("--design-id", metavar="ID",
                    help="design ID of the build that wrote every log (0x0a04, or none); "
                         "default: found per log (pips-log-decode.py --help)")
    ap.add_argument("--by", default="kind,design,iommu,cfg",
                    help=f"sum the end tables per these, comma-separated: {', '.join(GROUP_KEYS)}")
    ap.add_argument("--csv", help="write one row per log, device and size to this CSV")
    ap.add_argument("--jsonl", help="write one JSON object per log to this file")
    ap.add_argument("--detail", action="store_true", help="also print every log's size table and motifs")
    ap.add_argument("-j", "--jobs", type=int, default=min(4, os.cpu_count() or 1),
                    help="logs decoded in parallel (default 4; 1 = in this process)")
    a = ap.parse_args()
    by = a.by.split(",")
    bad = [k for k in by if k not in GROUP_KEYS]
    if bad:
        ap.error(f"--by: unknown {', '.join(bad)}; choose from {', '.join(GROUP_KEYS)}")

    paths = a.paths or [DEFAULT_ROOT]
    logs = list(find_logs(paths, a.match))
    if a.format:
        logs = [p for p in logs if dec.detect(p, a.design_id)["format"] == a.format]
    if not logs:
        sys.exit(f"pips-traffic: no logs found under {' '.join(paths)}"
                 + (f" in format {a.format}" if a.format else ""))
    print(f"pips-traffic: {len(logs)} log(s) under {' '.join(paths)}, {max(1, a.jobs)} at a time",
          flush=True)

    groups = collections.OrderedDict()             # group key -> {src: acc}, and its formats
    gformats = collections.defaultdict(set)
    kinds = collections.OrderedDict()              # (kind, design) -> {src: acc}
    csvf = open(a.csv, "w", newline="") if a.csv else None
    cw = csv.writer(csvf) if csvf else None
    if cw:
        cw.writerow(("path", "kind", "sweep", "iommu", "cfg", "design_id", "log_format", "load", "mode",
                     "status", "device", "payload_dw", "writes", "burst", "payload", "ring", "unclear",
                     "next_msi", "aligned", "pages"))
    jl = open(a.jsonl, "w") if a.jsonl else None
    n_ok, n_bad, t0 = 0, 0, time.time()
    jobs = [(p, a.design_id) for p in logs]
    pool = multiprocessing.Pool(a.jobs) if a.jobs > 1 else None
    results = pool.imap_unordered(analyse, jobs) if pool else map(analyse, jobs)
    for k, r in enumerate(results, 1):
        where = os.path.relpath(r["path"])
        where = where if len(where) <= 90 else "..." + where[-87:]
        if "error" in r:
            n_bad += 1
            print(f"[{k:>{len(str(len(logs)))}}/{len(logs)}] {r['secs']:5.1f}s {where}: SKIPPED: {r['error']}",
                  flush=True)
            continue
        n_ok += 1
        lab = r["labels"]
        print(f"[{k:>{len(str(len(logs)))}}/{len(logs)}] {r['secs']:5.1f}s {where}: {r['format']} "
              f"{lab['design']} {r['status']} {r['records']} rec | "
              + " | ".join(f"{s}: {src_line(r['src'][s])}" for s in SRC), flush=True)
        if a.detail:
            for s in SRC:
                st = r["src"][s]
                if st["mwr"]:
                    print(f"  {s}: {st['mwr']} MWr ({st['msi']} MSI), {st['mrd']} MRd, {st['drops']} dropped")
                    print_sizes(st)
                    print_motifs(st)
        g = tuple("all" if key == "all" else lab[key] for key in by)
        for s in SRC:
            merge(groups.setdefault(g, {}).setdefault(s, new_acc()), r["src"][s])
            merge(kinds.setdefault((lab["kind"], lab["design"]), {}).setdefault(s, new_acc()), r["src"][s])
        gformats[g].add(r["format"])
        if cw:
            for s in SRC:
                for pdw, x in sorted(r["src"][s]["sizes"].items()):
                    cw.writerow((r["path"], lab["kind"], lab["sweep"], lab["iommu"], lab["cfg"], lab["design"],
                                 r["format"], lab["load"], lab["mode"], r["status"], s, pdw, x["n"], x["burst"],
                                 x["payload"], x["ring"], x["unclear"], x["next_msi"], x["aligned"],
                                 x.get("pages", 0)))
        if jl:
            jl.write(json.dumps(dict(
                path=r["path"], labels=lab, log_format=r["format"], design_source=r["design_source"],
                status=r["status"], records=r["records"],
                devices={s: dict(summary_stats(r["src"][s]),
                                 **{k2: r["src"][s][k2] for k2 in ("mwr", "msi", "mrd", "other", "drops", "pages")},
                                 sizes={str(p): v for p, v in r["src"][s]["sizes"].items()},
                                 motifs=dict(r["src"][s]["motifs"].most_common(10)))
                         for s in SRC})) + "\n")
    if pool:
        pool.close()
        pool.join()
    if csvf:
        csvf.close()
    if jl:
        jl.close()
    print(f"\npips-traffic: {n_ok} log(s) analysed, {n_bad} skipped, {time.time() - t0:.0f} s", flush=True)
    if not n_ok:
        return 1

    print("\nDoorbells are host-to-device writes and are not in the log. 'ring' = writes to pages written"
          "\nas a ring of fixed-size entries, a few per visit (completion entries, descriptor write-backs);"
          "\n'payload' = pages filled in multi-write bursts. The size rule is checked against that"
          "\naddress behaviour (--help).")
    for g, accs in groups.items():
        print_group("  ".join(f"{k} {v}" for k, v in zip(by, g)) + f"  (format {','.join(sorted(gformats[g]))})",
                    accs, "v2" in gformats[g])

    print("\n== verdict per kind and design (every log of it)")
    for (kind, design), accs in kinds.items():
        for s in SRC:
            st = accs.get(s)
            if not st or not st["mwr"]:
                continue
            sm = summary_stats(st)
            worst = [summary_stats(gacc[s])["accuracy"] for g, gacc in groups.items()
                     if s in gacc and gacc[s]["mwr"] and dict(zip(by, g)).get("kind", kind) == kind
                     and dict(zip(by, g)).get("design", design) == design]
            worst = [w for w in worst if w is not None]
            print(f"  {kind} {design} {s}: ring if <= {fmt(sm['rule_dw'], 'd')} DW: "
                  f"{fmt(sm['accuracy'] and 100 * sm['accuracy'], '.3f')}% of {sm['ring'] + sm['payload']} writes"
                  + (f" (worst group {100 * min(worst):.3f}%)" if len(worst) > 1 else "")
                  + f"; ring sizes {sm['ring_sizes']}, payload {sm['payload_sizes']} -> {sm['verdict']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
