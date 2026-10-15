#!/usr/bin/env python3
"""Payload sizes of the drives' memory writes in PIPS TLP logs, and whether a
completion entry can be told from read data by its size alone.

    pips-mwr-sizes.py LOG [LOG ...]                   one line per drive per log,
                                                      then the size map per sweep
    pips-mwr-sizes.py utils/logs/dualssd-pips-off-1-d1t0 utils/logs/dualssd-pips-strict-1-d1t0
                                                      every pips-log.bin(.gz) under
                                                      these folders
    ... --match '4k-j*-both*'                         only run folders matching this
    ... --by iommu,bs                                 what the size maps are summed
                                                      over: iommu, cfg, bs, sweep
                                                      (default) or all
    ... --detail                                      also every log's own size map
    ... --csv sizes.csv                               one row per log, drive and size
    pips-mwr-sizes.py LOG --show 60 [--port in1] [--from REC]
                                                      the sizes in log order,
                                                      run-length coded

LOG is a dump as `pips log-dump` wrote it, e.g. a sweep run's pips-log.bin.gz,
read with pips-log-decode.py's loader. Python 3, standard library only.

What there is to tell apart. The log holds what the drives send up, so no
doorbells: those are host-to-device writes. Per read I/O a drive writes the
data (in Max Payload Size pieces: 64 DW at MPS 256 B), one completion entry
(16 B = 4 DW, into its completion queue) and, unless interrupts are coalesced,
one interrupt (an MSI-X write to 0xFEE0_0000-0xFEEF_FFFF). The 990 EVO Plus
also writes its host memory buffer. pips-addr-pattern.py and pips-page-seq.py
call every MWr of at most 4 DW outside the MSI range a completion entry;
--cqe-max moves that limit here. Every check below but B/CQE and MSI/CQE works
without the size.

Size map, per drive (in0, in1), one line per payload size. Class: data = the
drive's most common size over the limit, odd = any other size over it, cqe =
at or under it (cqe? if not 4 DW), msi = to the MSI range.
  beats ok  pkt_length is the beats that payload takes (16 B descriptor +
            payload, 64 B a beat): payload_dw and the TLP's length agree
  16B al    address 16-byte aligned (a completion entry always is)
  off 0     at page offset 0: starts a 4 KiB page
  end       ends at the page end
  pages     distinct 4 KiB pages written (per log; the mean when summed)
  mixed     written to a page that also takes writes from the other side of
            the limit. A completion queue page takes only entries and a data
            buffer only data, so mixing means the size rule files some writes
            wrongly; e.g. a drive that posts two entries in one 8 DW TLP
  >msi      directly followed, on the same port, by an interrupt: true of a
            completion entry unless interrupts are coalesced

Per drive and log:
  CQE       writes at or under the limit (outside the MSI range)
  B/CQE     data bytes (writes over the limit) per completion entry, against
            the block size bs. Above it: extra large writes (host memory
            buffer) or entries the rule misses; below it: small writes that are
            not entries. A log is a few ms, so I/Os cut by its ends blur this
            at large block sizes; trust it at 4k-16k
  MSI/CQE   interrupts per completion entry
  odd       non-MSI writes neither 4 DW nor the main data size
  mixed     writes on pages that take both sides of the limit

Each log is labelled from its folders, utils/logs/<sweep>/<config>-RUN-<j>/:
the IOMMU mode from the sweep's sweep.log, the batcher setting from the run's
pips-cfg.txt (what the run read before it started), the block size from the
config name. Unknown fields print as ?.
"""
import argparse
import collections
import csv
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pips_addr_pattern",
                                               os.path.join(HERE, "pips-addr-pattern.py"))
ap_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ap_mod)
dec = ap_mod.dec

PORTS = ("in0", "in1", "out")
CQE_DW = 4                                       # an NVMe completion entry: 16 bytes
FEAT = ("n", "beats_ok", "a16", "off0", "end", "mixed", "next_msi", "pages", "logs")
GROUP_KEYS = ("iommu", "cfg", "bs", "sweep", "all")
SWEEP_RE = re.compile(r"^dualssd-pips-(?P<iommu>.+)-\d+-(?P<cfg>d\d+t\d+(?:m1)?)$")
CONFIG_RE = re.compile(r"^(?:datapath-)?(?P<bs>\d+[kmg]?)-j[\d+]+(?:-\w+?)?-RUN-\d+$", re.I)


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def beats(pdw):
    """512-bit beats of an MWr with pdw payload DWORDs: 16 B descriptor + payload."""
    return -(-(16 + 4 * pdw) // 64)


def cfg_tag(v):
    """The batcher setting as pips-lib.sh's pips_tag writes it: d<depth>t<time>[m1]."""
    return f"d{v & 0xFF}t{(v >> 8) & 0xFF}" + ("m1" if (v >> 16) & 1 else "")


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


def meta(path):
    """Sweep, run, IOMMU mode, batcher setting and block size of a log, from its folders."""
    run_dir = os.path.dirname(os.path.abspath(path))
    sweep_dir = os.path.dirname(run_dir)
    m = dict(sweep=os.path.basename(sweep_dir), run=os.path.basename(run_dir),
             iommu="?", cfg="?", bs="?")
    s = SWEEP_RE.match(m["sweep"])
    if s:
        m.update(iommu=s["iommu"], cfg=s["cfg"])
    # What the sweep and the run recorded wins over the folder name.
    io = first_match(os.path.join(sweep_dir, "sweep.log"), re.compile(r"^######## IOMMU: (\S+)"))
    if io:
        m["iommu"] = io[1]
    cf = first_match(os.path.join(run_dir, "pips-cfg.txt"), re.compile(r"^cfg=(0x[0-9a-fA-F]+)"))
    if cf:
        m["cfg"] = cfg_tag(int(cf[1], 16))
    c = CONFIG_RE.match(m["run"])
    if c:
        m["bs"] = c["bs"]
    return m


def new_bin():
    return dict.fromkeys(FEAT, 0)


def analyse(path, cqe_max):
    """Per port, the MWr size bins: {(msi, payload_dw): {feature: count}}, and
    per bin the top 2 MiB region and its share."""
    recs, trailer, _pads, _nbytes, problem = dec.load(path, False)
    bins = [collections.defaultdict(new_bin) for _ in PORTS]
    pages = [collections.defaultdict(collections.Counter) for _ in PORTS]
    regions = [collections.defaultdict(collections.Counter) for _ in PORTS]
    side = [(set(), set()) for _ in PORTS]            # pages written at/under, over the limit
    last = [None] * len(PORTS)                         # the bin of each port's previous MWr
    drops = [0] * len(PORTS)
    for addr, length, _gap, typ, pdw, _tag, _at, info, _r in recs:
        kind, port = (info >> 2) & 3, info & 3
        if port > 2:
            continue
        if kind == dec.KIND_DROP:
            drops[port] += 1
            last[port] = None                          # a hole: the next TLP is unknown
            continue
        if kind != dec.KIND_TLP or typ & 0xF != 1:
            continue
        msi = ap_mod.MSI_LO <= addr < ap_mod.MSI_HI
        key = (msi, pdw)
        b = bins[port][key]
        off = addr & 0xFFF
        b["n"] += 1
        b["beats_ok"] += length == beats(pdw)
        b["a16"] += addr & 0xF == 0
        b["off0"] += off == 0
        b["end"] += off + 4 * pdw == 0x1000
        if msi and last[port] is not None and not last[port][0]:
            bins[port][last[port]]["next_msi"] += 1
        last[port] = key
        if not msi:
            pages[port][key][addr >> 12] += 1
            regions[port][key][addr >> 21] += 1
            side[port][pdw > cqe_max].add(addr >> 12)
    top = [{} for _ in PORTS]
    for p in range(len(PORTS)):
        for key, pc in pages[p].items():
            other = side[p][key[1] <= cqe_max]
            bins[p][key]["mixed"] = sum(n for pg, n in pc.items() if pg in other)
            bins[p][key]["pages"] = len(pc)
            reg, n = regions[p][key].most_common(1)[0]
            top[p][key] = (reg << 21, n / bins[p][key]["n"])
        for b in bins[p].values():
            b["logs"] = 1
    if problem:
        status = problem
    elif not trailer:
        status = "NO_TRAILER"
    else:
        status = "FULL" if trailer["stop_reason"] == "region_full" else "CUT"
        status += "+DROPS" if trailer["n_dropped"] else ""
    return dict(path=path, status=status, records=len(recs), drops=drops,
                bins=[dict(b) for b in bins], top=top)


def summary(bins, cqe_max):
    """One drive's totals from its size bins (one log's or summed)."""
    small = sum(b["n"] for (msi, dw), b in bins.items() if not msi and dw <= cqe_max)
    big = {dw: b for (msi, dw), b in bins.items() if not msi and dw > cqe_max}
    main = max(big, key=lambda dw: big[dw]["n"]) if big else None
    data_bytes = sum(4 * dw * b["n"] for dw, b in big.items())
    msi = sum(b["n"] for (m, _dw), b in bins.items() if m)
    return dict(
        mwr=sum(b["n"] for b in bins.values()), cqe=small, msi=msi, main=main,
        data_bytes=data_bytes,
        b_per_cqe=data_bytes / small if small else None,
        msi_per_cqe=msi / small if small else None,
        cqe_next_msi=sum(b["next_msi"] for (m, dw), b in bins.items() if not m and dw <= cqe_max),
        odd=sum(b["n"] for (m, dw), b in bins.items() if not m and dw not in (CQE_DW, main)),
        mixed=sum(b["mixed"] for (m, _dw), b in bins.items() if not m))


def label(key, main, cqe_max):
    msi, dw = key
    if msi:
        return "msi"
    if dw <= cqe_max:
        return "cqe" if dw == CQE_DW else "cqe?"
    return "data" if dw == main else "odd"


def order(bins):
    """Non-MSI sizes largest first, then the interrupts."""
    return sorted(bins, key=lambda k: (k[0], -k[1]))


def size_list(bins, k=5):
    top = sorted(bins.items(), key=lambda kv: -kv[1]["n"])[:k]
    s = " ".join(f"{dw}{'i' if msi else ''}:{b['n']}" for (msi, dw), b in top)
    return s + (" .." if len(bins) > k else "")


def pc(n, d):
    return 100 * n / d if d else None


def print_map(bins3, cqe_max, top=None):
    """The size map of in0 and in1, then out against their sum."""
    for p in (0, 1):
        bins = bins3[p]
        if not bins:
            continue
        s = summary(bins, cqe_max)
        print(f"  {PORTS[p]} ({dec.PORT_DESC[PORTS[p]]}): {s['mwr']} MWr, CQE {s['cqe']}, "
              f"B/CQE {fmt(s['b_per_cqe'], '.0f')}, MSI/CQE {fmt(s['msi_per_cqe'], '.3f')}, "
              f"odd {s['odd']}, mixed {s['mixed']}")
        print(f"    {'DW':>4} {'class':5} {'count':>9} {'share':>6} {'beats ok':>8} {'16B al':>6} "
              f"{'off 0':>6} {'end':>6} {'pages':>7} {'mixed':>6} {'>msi':>6}"
              + (f"  {'top 2 MiB region':>18}" if top else ""))
        for key in order(bins):
            b = bins[key]
            n = b["n"]
            dw = "255+" if key[1] == 255 else str(key[1])
            line = (f"    {dw:>4} {label(key, s['main'], cqe_max):5} {n:9d} {fmt(pc(n, s['mwr']), '5.1f')}% "
                    f"{fmt(pc(b['beats_ok'], n), '7.1f')}% {fmt(pc(b['a16'], n), '5.1f')}% "
                    f"{fmt(pc(b['off0'], n), '5.1f')}% {fmt(pc(b['end'], n), '5.1f')}% ")
            if key[0]:
                line += f"{'':>7} {'':>6} {'':>6}"
            else:
                line += (f"{b['pages'] / b['logs']:7.0f} {fmt(pc(b['mixed'], n), '5.1f')}% "
                         f"{fmt(pc(b['next_msi'], n), '5.1f')}%")
            if top and key in top[p]:
                reg, share = top[p][key]
                line += f"  0x{reg:012x} {100 * share:3.0f}%"
            print(line)
    ins = collections.Counter()
    for p in (0, 1):
        for key, b in bins3[p].items():
            ins[key] += b["n"]
    out = collections.Counter({key: b["n"] for key, b in bins3[2].items()})
    diff = {k: out[k] - ins[k] for k in set(ins) | set(out) if out[k] != ins[k]}
    if not diff:
        print("  out by size: the same as in0 + in1")
    else:
        worst = sorted(diff.items(), key=lambda kv: -abs(kv[1]))[:4]
        print("  out by size minus in0 + in1: "
              + ", ".join(f"{dw} DW{' msi' if msi else ''} {d:+d}" for (msi, dw), d in worst)
              + "  (TLPs in flight at the log's ends, dropped records; more = the batcher "
                "changed sizes)")


def add_bins(into, bins3):
    for p in range(len(PORTS)):
        for key, b in bins3[p].items():
            t = into[p].setdefault(key, new_bin())
            for f in FEAT:
                t[f] += b[f]


def show(path, port, start, count):
    """The MWr sizes of one port in log order, run-length coded per 4 KiB page."""
    recs, _trailer, _pads, _nbytes, _problem = dec.load(path, False)
    want = PORTS.index(port)
    toks = []                                       # [first record, token, page, repeat]
    for i in range(start, len(recs)):
        addr, _length, _gap, typ, pdw, _tag, _at, info, _r = recs[i]
        kind, p = (info >> 2) & 3, info & 3
        if p != want or kind not in (dec.KIND_TLP, dec.KIND_DROP):
            continue
        page = None
        if kind == dec.KIND_DROP:
            tok = "drop"
        elif typ & 0xF == 0:
            tok = "rd"
        elif typ & 0xF == 1:
            msi = ap_mod.MSI_LO <= addr < ap_mod.MSI_HI
            tok = f"{pdw}i" if msi else str(pdw)
            page = None if msi else addr >> 12
        else:
            tok = dec.TYPES[typ & 0xF]
        if toks and toks[-1][1] == tok and toks[-1][2] == page:
            toks[-1][3] += 1
            continue
        if len(toks) == count:
            break
        toks.append([i, tok, page, 1])
    print(f"{path}, {port} from record {start}: payload DW per MWr; xN = N in a row to one 4 KiB page; "
          f"i = interrupt (MSI range); rd = memory read")
    for j in range(0, len(toks), 12):
        row = toks[j:j + 12]
        print(f"{row[0][0]:8d}  " + " ".join(t[1] + (f"x{t[3]}" if t[3] > 1 else "") for t in row))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+", help="logs, or folders searched for pips-log.bin(.gz)")
    ap.add_argument("--match", help="only run folders whose name matches this glob")
    ap.add_argument("--cqe-max", type=int, default=4, metavar="DW",
                    help="the size rule: non-MSI writes of at most this many DW are completion "
                         "entries (default 4, as pips-addr-pattern.py)")
    ap.add_argument("--by", default="sweep",
                    help=f"sum the size maps per these, comma-separated: {', '.join(GROUP_KEYS)} "
                         "(default sweep)")
    ap.add_argument("--detail", action="store_true", help="also print every log's own size map")
    ap.add_argument("--csv", help="write one row per log, port and size to this CSV")
    ap.add_argument("--show", type=int, metavar="N", help="one log: print N runs of its size sequence")
    ap.add_argument("--port", choices=PORTS, default="in0", help="port for --show (default in0)")
    ap.add_argument("--from", dest="start", type=int, default=0, metavar="REC",
                    help="start --show at this record index")
    a = ap.parse_args()
    by = a.by.split(",")
    bad = [k for k in by if k not in GROUP_KEYS]
    if bad:
        ap.error(f"--by: unknown {', '.join(bad)}; choose from {', '.join(GROUP_KEYS)}")

    logs = list(ap_mod.find_logs(a.paths, a.match))
    if not logs:
        sys.exit("pips-mwr-sizes: no logs found")
    if a.show:
        if len(logs) != 1:
            sys.exit(f"pips-mwr-sizes: --show takes one log, found {len(logs)}")
        show(logs[0], a.port, a.start, a.show)
        return 0

    groups = collections.OrderedDict()             # group -> [bins per port, logs]
    rows = []
    print(f"size rule: a non-MSI MWr of at most {a.cqe_max} DW is a completion entry")
    print(f"{'run':30} {'IOMMU':>6} {'cfg':>7} {'drive':>5} {'MWr':>7} {'sizes DW:count (i = interrupt)':40} "
          f"{'CQE':>6} {'B/CQE':>7} {'bs':>5} {'MSI/CQE':>7} {'>msi':>5} {'odd':>5} {'mixed':>5}")
    sweep = None
    for path in logs:
        try:
            r = analyse(path, a.cqe_max)
        except SystemExit as e:                     # pips-log-decode's fail()
            print(f"{path}: {e}", file=sys.stderr)
            continue
        m = meta(path)
        if m["sweep"] != sweep:
            sweep = m["sweep"]
            print(f"== {os.path.dirname(os.path.dirname(path)) or sweep}")
        for p in (0, 1):
            s = summary(r["bins"][p], a.cqe_max)
            print(f"{(m['run'] if p == 0 else '')[-30:]:30} {m['iommu']:>6} {m['cfg']:>7} {PORTS[p]:>5} "
                  f"{s['mwr']:7d} {size_list(r['bins'][p]):40} {s['cqe']:6d} "
                  f"{fmt(s['b_per_cqe'], '7.0f')} {m['bs']:>5} {fmt(s['msi_per_cqe'], '7.3f')} "
                  f"{fmt(pc(s['cqe_next_msi'], s['cqe']), '4.0f')}% "
                  f"{s['odd']:5d} {s['mixed']:5d}")
        if r["status"] != "FULL" or any(r["drops"]):
            print(f"  note: log {r['status']}, drops in0/in1/out {'/'.join(map(str, r['drops']))}")
        if a.detail:
            print_map(r["bins"], a.cqe_max, r["top"])
            print()
        g = tuple("all" if k == "all" else m[k] for k in by)
        grp = groups.setdefault(g, [[{} for _ in PORTS], 0])
        add_bins(grp[0], r["bins"])
        grp[1] += 1
        for p in range(len(PORTS)):
            main = summary(r["bins"][p], a.cqe_max)["main"]
            for key in order(r["bins"][p]):
                b = r["bins"][p][key]
                reg = r["top"][p].get(key)
                rows.append((m["sweep"], m["run"], m["iommu"], m["cfg"], m["bs"], PORTS[p], key[1],
                             int(key[0]), label(key, main, a.cqe_max), b["n"], b["beats_ok"], b["a16"],
                             b["off0"], b["end"], b["pages"], b["mixed"], b["next_msi"],
                             f"0x{reg[0]:x}" if reg else "", f"{reg[1]:.4f}" if reg else ""))

    for g, (bins3, n) in groups.items():
        print(f"\nsize map summed over {n} log(s): "
              + ", ".join("all" if k == "all" else f"{k} {v}" for k, v in zip(by, g)))
        print_map(bins3, a.cqe_max)

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(("sweep", "run", "iommu", "cfg", "bs", "port", "payload_dw", "msi", "class", "count",
                        "beats_ok", "align16", "off0", "page_end", "pages", "mixed", "next_msi",
                        "top_2m", "top_2m_share"))
            w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
