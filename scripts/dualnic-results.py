#!/usr/bin/env python3
"""Machine-readable results for run-dualnic-experiment.sh.

  dump     read one experiment's report directories and append a single JSON
           line (config + every run + mean/sd) to a .jsonl file
  summary  print a comparison table from one or more .jsonl files

    dualnic-results.py dump --reports DIR --exp NAME --runs 3 --nics 0,1 \\
        --out ~/dualnic-results.jsonl --meta flows_per_nic=8 --meta iommu=strict
    dualnic-results.py summary ~/dualnic-flowsweep-strict-*.jsonl \\
                               ~/dualnic-flowsweep-off-*.jsonl

The .rpt files stay the source of truth; this only collects them, so a run
whose reports are missing shows up as null rather than as zero.
"""
import argparse
import datetime
import json
import os
import platform
import socket
import statistics
import sys

# pcie.rpt also carries legacy aliases with wrong names (L1_Miss etc., see
# HANDOFF.md "Traps"). Only the correct names go into the JSON.
PCIE_KEYS = ('PCIe_wr_tput', 'PCIe_rd_tput', 'IOTLB_lookups', 'IOTLB_misses',
             'IOTLB_hits_derived', 'CTXT_cache_hits', 'PWC_512G_hits',
             'PWC_1G_hits', 'PWC_2M_hits', 'PWC_4K_hits', 'IOMMU_mem_access')


def read_kv(path):
    """'key: number' lines -> {key: float}. Non-numeric values are skipped."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if ':' not in line:
                    continue
                k, v = line.split(':', 1)
                tok = v.split()
                if not tok:
                    continue
                try:
                    out[k.strip()] = float(tok[0])
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def parse_meta(pairs):
    meta = {}
    for p in pairs:
        k, _, v = p.partition('=')
        for cast in (int, float):
            try:
                v = cast(v)
                break
            except ValueError:
                pass
        meta[k] = v
    return meta


def one_run(reports, exp, j, nics):
    base = os.path.join(reports, f'{exp}-RUN-server-{j}')
    r = {}
    total = 0.0
    for i in nics:
        t = read_kv(os.path.join(f'{base}-nic{i}', 'iperf.bw.rpt')).get('Avg_iperf_tput')
        r[f'tput_nic{i}_gbps'] = t
        total = None if (t is None or total is None) else total + t
    r['tput_total_gbps'] = total

    pcie = read_kv(os.path.join(base, 'pcie.rpt'))
    r.update({k: pcie.get(k) for k in PCIE_KEYS})
    wr, miss = pcie.get('PCIe_wr_tput'), pcie.get('IOTLB_misses')
    # The cross-run comparison metric: raw misses scale with bytes moved.
    r['misses_per_gbps'] = miss / wr if (wr and miss is not None) else None

    r['cpu_util_pct'] = read_kv(os.path.join(base, 'cpu_util.rpt')).get('avg_cpu_util')
    r.update({k: v for k, v in read_kv(os.path.join(base, 'membw.rpt')).items()
              if k.startswith('Node')})
    for i in nics:
        rx = read_kv(os.path.join(base, f'retx-nic{i}.rpt'))
        if 'Retx_percent' in rx:
            r[f'retx_nic{i}_pct'] = rx['Retx_percent']
    return r


def dump(a):
    nics = [int(x) for x in a.nics.split(',') if x != '']
    runs = [one_run(a.reports, a.exp, j, nics) for j in range(a.runs)]

    mean, sd = {}, {}
    for k in runs[0]:
        vals = [r.get(k) for r in runs]
        if any(v is None for v in vals):
            mean[k] = sd[k] = None
            continue
        mean[k] = statistics.mean(vals)
        sd[k] = statistics.stdev(vals) if len(vals) > 1 else 0.0

    try:
        cmdline = open('/proc/cmdline').read().strip()
    except OSError:
        cmdline = None
    rec = {
        'timestamp': datetime.datetime.now().isoformat(timespec='seconds'),
        'host': socket.gethostname(),
        'kernel': platform.release(),
        'cmdline': cmdline,
        'exp': a.exp,
        'active_nics': nics,
    }
    rec.update(parse_meta(a.meta))
    rec.update({'runs': a.runs, 'mean': mean, 'sd': sd, 'per_run': runs})

    out = os.path.expanduser(a.out)
    with open(out, 'a') as f:
        f.write(json.dumps(rec) + '\n')
    print(f'  results appended to {out}')


def fmt(m, s, spec):
    if m is None:
        return 'n/a'
    return format(m, spec) if not s else f'{format(m, spec)}+/-{format(s, spec)}'


def summary(a):
    recs = []
    for path in a.files:
        with open(os.path.expanduser(path)) as f:
            recs += [json.loads(l) for l in f if l.strip()]
    if not recs:
        sys.exit('no records')

    def key(r):
        return (str(r.get('bandwidth_per_nic')), r.get('flows_per_nic') or 0,
                {'nic0only': 0, 'nic1only': 1, 'both': 2}.get(r.get('mode'), 3),
                str(r.get('iommu')))

    # contention = both / mean(nic0only, nic1only) - 1, per IOMMU mode, rate, flows
    base = {}
    for r in recs:
        if r.get('mode') in ('nic0only', 'nic1only'):
            g = (r.get('iommu'), r.get('bandwidth_per_nic'), r.get('flows_per_nic'))
            base.setdefault(g, []).append(r['mean'].get('misses_per_gbps'))

    hdr = f"{'IOMMU':<7} {'RATE':<9} {'FLOWS':>5} {'MODE':<9} {'TPUT_Gbps':>16} " \
          f"{'PCIe_wr':>8} {'MISS_PER_GBPS':>20} {'CPU_%':>12} {'CONTENTION':>10}"
    print(hdr)
    print('-' * len(hdr))
    for r in sorted(recs, key=key):
        m, s = r['mean'], r['sd']
        cont = ''
        # Without translation there are no misses to contend over; the ratio
        # of two near-zero counts would read as a large, meaningless swing.
        if r.get('mode') == 'both' and r.get('iommu') not in ('off', 'pt'):
            b = base.get((r.get('iommu'), r.get('bandwidth_per_nic'), r.get('flows_per_nic')), [])
            both = m.get('misses_per_gbps')
            if len(b) >= 2 and None not in b and both and sum(b) > 0:
                cont = f'{100 * (both / (sum(b) / len(b)) - 1):+.1f}%'
        wr = m.get('PCIe_wr_tput')
        flag = '  <-- LINK BOUND' if (wr or 0) > 100 else ''
        print(f"{str(r.get('iommu')):<7} {str(r.get('bandwidth_per_nic')):<9} "
              f"{str(r.get('flows_per_nic')):>5} {str(r.get('mode')):<9} "
              f"{fmt(m.get('tput_total_gbps'), s.get('tput_total_gbps'), '.2f'):>16} "
              f"{fmt(wr, None, '.1f'):>8} "
              f"{fmt(m.get('misses_per_gbps'), s.get('misses_per_gbps'), '.0f'):>20} "
              f"{fmt(m.get('cpu_util_pct'), s.get('cpu_util_pct'), '.1f'):>12} "
              f"{cont:>10}{flag}")
    print()
    print('  CONTENTION = both / mean(nic0only, nic1only) - 1 on MISS_PER_GBPS.')
    print('  IOMMU off/pt has no translation, so its miss columns read 0 and')
    print('  the on/off comparison is TPUT and CPU_% at the same RATE/FLOWS.')
    print('  Ignore LINK BOUND rows for IOMMU conclusions: there the ~126 Gbps')
    print('  shared uplink, not the IOMMU, is the constraint.')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('dump')
    d.add_argument('--reports', required=True)
    d.add_argument('--exp', required=True)
    d.add_argument('--runs', type=int, required=True)
    d.add_argument('--nics', required=True, help='active NIC indices, e.g. 0,1')
    d.add_argument('--out', required=True)
    d.add_argument('--meta', action='append', default=[], metavar='KEY=VALUE')
    s = sub.add_parser('summary')
    s.add_argument('files', nargs='+')
    a = p.parse_args()
    dump(a) if a.cmd == 'dump' else summary(a)


if __name__ == '__main__':
    main()
