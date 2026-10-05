#!/usr/bin/env python3
"""Machine-readable results for run-dualssd-experiment.sh.

  fio-sum  sum one drive's fio JSON outputs (one per instance) into fio.rpt
  dump     read one experiment's report directories and append a single JSON
           line (config + every run + mean/sd) to a .jsonl file
  summary  print a comparison table from one or more .jsonl files

    dualssd-results.py fio-sum --out reports/X-RUN-0-ssd0/fio.rpt logs/X-RUN-0/fio-ssd0-*.json
    dualssd-results.py dump --reports DIR --exp NAME --runs 3 --ssds 0,1 \\
        --out ~/dualssd.jsonl --meta instances_per_ssd=4 --meta iommu=strict
    dualssd-results.py summary ~/dualssd-sweep-strict-*.jsonl ~/dualssd-sweep-off-*.jsonl

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


def fio_sum(a):
    """One fio process per instance, each with one job (or a group_reporting
    aggregate). IOPS and bandwidth add up; latency is IOPS-weighted."""
    iops = bw = lat_w = p99 = 0.0
    ok, bad = 0, []
    for path in a.files:
        try:
            with open(path) as f:
                txt = f.read()
            # fio may put notes ahead of the JSON in the --output file.
            doc = json.loads(txt[txt.index('{'):])
            for job in doc['jobs']:
                if job.get('error'):
                    raise ValueError(f"fio job error {job['error']}")
                rd = job['read']
                iops += rd['iops']
                bw += rd['bw_bytes']
                lat_w += rd['lat_ns']['mean'] * rd['iops']
                pct = rd.get('clat_ns', {}).get('percentile', {})
                p99 = max(p99, pct.get('99.000000', 0.0))
            ok += 1
        except (OSError, ValueError, KeyError) as e:
            bad.append(f'{os.path.basename(path)}: {e}')
    for b in bad:
        print(f'WARNING: unusable fio output {b}', file=sys.stderr)
    with open(a.out, 'w') as f:
        f.write(f'IOPS: {iops:.1f}\n')
        f.write(f'read_MBps: {bw / 1e6:.3f}\n')
        f.write(f'read_Gbps: {bw * 8 / 1e9:.3f}\n')
        f.write(f'lat_mean_us: {(lat_w / iops / 1000) if iops else 0:.2f}\n')
        f.write(f'clat_p99_us_max: {p99 / 1000:.2f}\n')
        f.write(f'instances_ok: {ok}\n')
        f.write(f'instances_failed: {len(bad)}\n')
    sys.exit(0 if ok else 1)


def one_run(reports, exp, j, ssds):
    base = os.path.join(reports, f'{exp}-RUN-{j}')
    r = {}
    iops_t, gbps_t = 0.0, 0.0
    for i in ssds:
        fio = read_kv(os.path.join(f'{base}-ssd{i}', 'fio.rpt'))
        r[f'iops_ssd{i}'] = fio.get('IOPS')
        r[f'gbps_ssd{i}'] = fio.get('read_Gbps')
        r[f'lat_us_ssd{i}'] = fio.get('lat_mean_us')
        r[f'p99_us_ssd{i}'] = fio.get('clat_p99_us_max')
        iops_t = None if (iops_t is None or fio.get('IOPS') is None) else iops_t + fio['IOPS']
        gbps_t = None if (gbps_t is None or fio.get('read_Gbps') is None) else gbps_t + fio['read_Gbps']
    r['iops_total'] = iops_t
    r['gbps_total'] = gbps_t

    # Whatever pcie.rpt holds: the key set depends on the CPU (see
    # parse_pciebw_skx in record-host-metrics.sh for Skylake's).
    pcie = read_kv(os.path.join(base, 'pcie.rpt'))
    pcie.pop('cpu_model', None)
    r.update(pcie)
    miss, wr = pcie.get('IOTLB_misses'), pcie.get('PCIe_wr_tput')
    # The comparison metrics. pcm-iio samples once a second, so counters are
    # per second: divide by IOPS for per I/O, by GB/s of DMA write for per GB.
    r['misses_per_io'] = miss / iops_t if (miss is not None and iops_t) else None
    r['misses_per_gb'] = miss / (wr / 8) if (miss is not None and wr) else None

    r['cpu_util_pct'] = read_kv(os.path.join(base, 'cpu_util.rpt')).get('avg_cpu_util')
    r.update({k: v for k, v in read_kv(os.path.join(base, 'membw.rpt')).items()
              if k.startswith('Node')})
    return r


def dump(a):
    ssds = [int(x) for x in a.ssds.split(',') if x != '']
    runs = [one_run(a.reports, a.exp, j, ssds) for j in range(a.runs)]

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
        'active_ssds': ssds,
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


def bs_bytes(bs):
    s = str(bs).strip().lower().rstrip('b')
    mult = {'k': 1 << 10, 'm': 1 << 20, 'g': 1 << 30}.get(s[-1:], 1)
    try:
        return int(float(s.rstrip('kmg')) * mult)
    except ValueError:
        return 0


def summary(a):
    recs = []
    for path in a.files:
        with open(os.path.expanduser(path)) as f:
            recs += [json.loads(l) for l in f if l.strip()]
    if not recs:
        sys.exit('no records')

    def group(r):
        return (str(r.get('iommu')), str(r.get('bs')), r.get('instances_per_ssd'))

    def key(r):
        return (str(r.get('iommu')), bs_bytes(r.get('bs')), r.get('instances_per_ssd') or 0,
                {'ssd0only': 0, 'ssd1only': 1, 'both': 2}.get(r.get('mode'), 3))

    # Single-drive misses per I/O, per IOMMU mode / block size / instances.
    base = {}
    for r in recs:
        if r.get('mode') in ('ssd0only', 'ssd1only'):
            base.setdefault(group(r), {})[r['mode']] = r['mean'].get('misses_per_io')

    hdr = f"{'IOMMU':<7} {'BS':<5} {'INST':>4} {'MODE':<9} {'IOPS_k':>15} {'GB/s':>6} " \
          f"{'PCIe_wr':>8} {'MISS/IO':>13} {'CPU_%':>11} {'CPU_us/IO':>9} {'CONTENTION':>10}"
    print(hdr)
    print('-' * len(hdr))
    for r in sorted(recs, key=key):
        m, s = r['mean'], r['sd']
        iops = m.get('iops_total')
        cont = ''
        # Without translation there are no misses to contend over.
        if r.get('mode') == 'both' and r.get('iommu') not in ('off', 'pt'):
            b = base.get(group(r), {})
            m0, m1 = b.get('ssd0only'), b.get('ssd1only')
            i0, i1 = m.get('iops_ssd0'), m.get('iops_ssd1')
            both = m.get('misses_per_io')
            # The drives are different models at different IOPS, so the
            # expectation weights each drive's own miss rate by its share of
            # the co-run's I/O instead of averaging the two baselines.
            if None not in (m0, m1, i0, i1, both) and (i0 + i1) > 0:
                expect = (m0 * i0 + m1 * i1) / (i0 + i1)
                if expect > 0:
                    cont = f'{100 * (both / expect - 1):+.1f}%'
        cpu_us = None
        ncores = len(str(r.get('cpu_util_cores', '')).split(',')) if r.get('cpu_util_cores') else 0
        if m.get('cpu_util_pct') is not None and iops and ncores:
            cpu_us = m['cpu_util_pct'] / 100 * ncores / iops * 1e6
        wr, up = m.get('PCIe_wr_tput'), r.get('uplink_gbps') or 0
        flag = '  <-- LINK BOUND' if (up and (wr or 0) > 0.85 * up) else ''
        print(f"{str(r.get('iommu')):<7} {str(r.get('bs')):<5} "
              f"{str(r.get('instances_per_ssd')):>4} {str(r.get('mode')):<9} "
              f"{fmt(iops / 1e3 if iops is not None else None, (s.get('iops_total') or 0) / 1e3, '.1f'):>15} "
              f"{fmt(m.get('gbps_total') / 8 if m.get('gbps_total') is not None else None, None, '.2f'):>6} "
              f"{fmt(wr, None, '.1f'):>8} "
              f"{fmt(m.get('misses_per_io'), s.get('misses_per_io'), '.3f'):>13} "
              f"{fmt(m.get('cpu_util_pct'), s.get('cpu_util_pct'), '.1f'):>11} "
              f"{fmt(cpu_us, None, '.2f'):>9} "
              f"{cont:>10}{flag}")
    print()
    print('  MISS/IO    = IOTLB misses per second / IOPS (both from the same run).')
    print('  CPU_us/IO  = CPU time on the fio cores per I/O; strict mode\'s cost shows here.')
    print('  CONTENTION = both MISS/IO vs the single-drive MISS/IO of each drive,')
    print('               weighted by that drive\'s share of the co-run\'s IOPS.')
    print('  IOMMU off/pt has no translation, so compare IOPS and CPU_us/IO across')
    print('  modes at the same BS/INST. LINK BOUND: PCIe write above 85% of the')
    print('  narrowest shared PCIe link, which then caps the run, not the IOMMU.')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    fs = sub.add_parser('fio-sum')
    fs.add_argument('--out', required=True)
    fs.add_argument('files', nargs='+')
    d = sub.add_parser('dump')
    d.add_argument('--reports', required=True)
    d.add_argument('--exp', required=True)
    d.add_argument('--runs', type=int, required=True)
    d.add_argument('--ssds', required=True, help='active SSD indices, e.g. 0,1')
    d.add_argument('--out', required=True)
    d.add_argument('--meta', action='append', default=[], metavar='KEY=VALUE')
    s = sub.add_parser('summary')
    s.add_argument('files', nargs='+')
    a = p.parse_args()
    {'fio-sum': fio_sum, 'dump': dump, 'summary': summary}[a.cmd](a)


if __name__ == '__main__':
    main()
