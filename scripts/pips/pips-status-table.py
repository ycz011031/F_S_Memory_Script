#!/usr/bin/env python3
"""The page batcher's status per run of PIPS sweeps (design 0x0a06 on), by
manifest: what `pips status` read after each run's measurement window, which
covers that run from its setup (pips_run_cfg's read opened the period).

    python3 scripts/pips/pips-status-table.py ~/<sweep>.manifest.tsv ... [--tsv OUT]

Per run, from <log_dir>/pips-status.txt (paths in the manifest are relative to
the repo): the overflow flags and spill counts of in0/in1, the watchdog's stuck
bit, the longest MRd wait per input (us), and from design 0x0a07 (pips-bp.tsv,
pips-lib.sh pips_bp_start) the share of the run's cycles each input was refused
with a beat waiting (any reason; "cap" the rate cap's part). Prints one line per run, flagged where
something is set, then per sweep and setting the worst of each. --tsv writes
the per-run rows. Runs without the file (older designs, failed reads) are
counted, not listed. SWEEP-LOGS.md: read a sweep only through its manifest.
"""
import argparse
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
FIELDS = ("ovf0", "ovf1", "stuck", "ovf_count_0", "ovf_count_1", "mrd_wait_max_us_0", "mrd_wait_max_us_1")
BP_FIELDS = ("bp_frac_0", "bp_frac_1", "cap_hold_frac_0", "cap_hold_frac_1", "bp_max_gap_s")
CLK_HZ = 250e6
WRAP = 1 << 32
# A device's completion timeout is 50 us at the least (PCIe default range 50 us - 50 ms).
WAIT_WARN_US = 25.0


def read_status(path):
    """key=value pairs of a `pips status` readout, or None if it is not a good one."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    kv = {}
    for tok in text.split():
        k, eq, v = tok.partition("=")
        if eq:
            kv[k] = v
    if kv.get("status") != "ok":
        return None
    out = {}
    for k in FIELDS:
        try:
            out[k] = float(kv[k])
        except (KeyError, ValueError):
            out[k] = None
    return out


def read_bp(path):
    """Refused and rate-cap-held cycles per input as a share of the sampled span, from
    pips-bp.tsv (ms, then four free-running 32-bit counters; differences wrap), or
    Nones. A gap over 17 s between samples may hide a wrap: those runs get no share."""
    none = dict.fromkeys(BP_FIELDS)
    try:
        with open(path) as fh:
            rows = [l.split("\t") for l in fh.read().splitlines()[1:] if l.strip()]
        rows = [[float(x) for x in r[:5]] for r in rows if len(r) >= 5]
    except (OSError, ValueError):
        return none
    if len(rows) < 2:
        return none
    sums, gap = [0.0] * 4, 0.0
    for a, b in zip(rows, rows[1:]):
        gap = max(gap, (b[0] - a[0]) / 1000)
        for k in range(4):
            sums[k] += (b[k + 1] - a[k + 1]) % WRAP
    cyc = (rows[-1][0] - rows[0][0]) / 1000 * CLK_HZ
    if cyc <= 0 or gap >= 17:
        return dict(none, bp_max_gap_s=gap)
    return dict(bp_frac_0=sums[0] / cyc, bp_frac_1=sums[1] / cyc, cap_hold_frac_0=sums[2] / cyc,
                cap_hold_frac_1=sums[3] / cyc, bp_max_gap_s=gap)


def manifest_rows(path):
    rows, sweep = [], None
    with open(path) as f:
        hdr = None
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# sweep="):
                sweep = line.split("=", 1)[1]
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if hdr is None:
                hdr = cols
                continue
            rows.append(dict(zip(hdr, cols)))
    return sweep or os.path.basename(path), rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifests", nargs="+")
    ap.add_argument("--tsv", help="write the per-run rows here")
    ap.add_argument("--repo", default=REPO, help="where the manifest's relative paths start (default: this repo)")
    a = ap.parse_args()

    runs, missing = [], collections.Counter()
    for m in a.manifests:
        sweep, rows = manifest_rows(m)
        for r in rows:
            d = r.get("log_dir", "")
            d = d if os.path.isabs(d) else os.path.join(a.repo, d)
            st = read_status(os.path.join(d, "pips-status.txt"))
            if st is None:
                missing[sweep] += 1
                continue
            runs.append(dict(sweep=sweep, setting=r.get("setting"), point=r.get("point"),
                             role=r.get("role"), run=r.get("run"), **st,
                             **read_bp(os.path.join(d, "pips-bp.tsv"))))
    if not runs:
        print("no runs with a page batcher status (pips-status.txt); designs before 0x0a06 have none")
        for s, n in missing.items():
            print(f"  {s}: {n} runs without one")
        return 0

    def f(v, spec):
        return "-" if v is None else format(v, spec)

    def pct(v):
        return "-" if v is None else f"{100 * v:.1f}"

    sw = max(len(r["setting"] or "") for r in runs)
    pw = max(len(r["point"] or "") for r in runs)
    bp = any(r["bp_frac_0"] is not None for r in runs)
    print(f"{'setting':<{sw}}  {'point':<{pw}}  ovf0 ovf1 stuck  spills in0/in1  MRd wait max us in0/in1"
          + ("  refused % in0/in1 (cap)" if bp else ""))
    flagged = 0
    for r in runs:
        flag = []
        if r["stuck"]:
            flag.append("STUCK")
        if (r["ovf_count_0"] or 0) + (r["ovf_count_1"] or 0) > 0:
            flag.append("OVERFLOW")
        if max(r["mrd_wait_max_us_0"] or 0, r["mrd_wait_max_us_1"] or 0) > WAIT_WARN_US:
            flag.append(f"WAIT>{WAIT_WARN_US:g}us")
        flagged += bool(flag)
        print(f"{r['setting'] or '':<{sw}}  {r['point'] or '':<{pw}}  {f(r['ovf0'], '4.0f')} {f(r['ovf1'], '4.0f')} "
              f"{f(r['stuck'], '5.0f')}  {f(r['ovf_count_0'], '6.0f')}/{f(r['ovf_count_1'], '<6.0f')}  "
              f"{f(r['mrd_wait_max_us_0'], '8.2f')}/{f(r['mrd_wait_max_us_1'], '<8.2f')}"
              + (f"  {pct(r['bp_frac_0'])}/{pct(r['bp_frac_1'])}"
                 + (f" ({pct(r['cap_hold_frac_0'])}/{pct(r['cap_hold_frac_1'])})"
                    if (r['cap_hold_frac_0'] or 0) + (r['cap_hold_frac_1'] or 0) > 0 else "") if bp else "")
              + f"{'  <-- ' + ', '.join(flag) if flag else ''}")
    print()
    print("worst per sweep and setting:")
    g = collections.defaultdict(list)
    for r in runs:
        g[(r["sweep"], r["setting"])].append(r)
    for (s, st), rs in sorted(g.items()):
        print(f"  {s} {st}: {len(rs)} runs, stuck {sum(1 for r in rs if r['stuck'])}, "
              f"spills max {max((r['ovf_count_0'] or 0) for r in rs):.0f}/{max((r['ovf_count_1'] or 0) for r in rs):.0f}, "
              f"MRd wait max {max((r['mrd_wait_max_us_0'] or 0) for r in rs):.2f}/"
              f"{max((r['mrd_wait_max_us_1'] or 0) for r in rs):.2f} us"
              + (f", refused max {pct(max((r['bp_frac_0'] or 0) for r in rs))}/"
                 f"{pct(max((r['bp_frac_1'] or 0) for r in rs))} %" if bp else ""))
    print()
    print(f"{len(runs)} runs, {flagged} flagged; " +
          (", ".join(f"{s}: {n} without a status" for s, n in missing.items()) or "every run has a status"))
    print(f"  STUCK: the batcher's watchdog forced a drain (should never happen). OVERFLOW: an input")
    print(f"  ran out of page segments and stopped batching until its overflow drained. WAIT > "
          f"{WAIT_WARN_US:g} us: half the shortest completion timeout a device may use.")
    if bp:
        print("  refused %: cycles an input had a beat waiting and was not taken (FIFO full, lock, barrier or")
        print("  rate cap), over the run from its setup; (cap): the rate cap's part, shown when set.")
    if a.tsv:
        with open(a.tsv, "w") as out:
            keys = ("sweep", "setting", "point", "role", "run") + FIELDS + BP_FIELDS
            out.write("\t".join(keys) + "\n")
            for r in runs:
                out.write("\t".join("" if r[k] is None else str(r[k]) for k in keys) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
