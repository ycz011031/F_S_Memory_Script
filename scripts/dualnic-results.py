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

NICs behind the PIPS switch: records carry pips_batch (the batcher setting,
e.g. d8t22c1) and pips_design_id (the FPGA build, e.g. 0x0a04), and with
--pips-log 1 each run's TLP log numbers (pips_*) and status (pips_log).
Records with a different setting or build are different points: the IOMMU
column reads e.g. 'off d8t22c1@0a04'. Records without them (NICs not behind
PIPS, or from before) read as before.
"""
import argparse
import collections
import datetime
import json
import os
import platform
import re
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
        # Pause, discard, buffer and error counter deltas over the window, both
        # ends of NIC i's link (srv_ = this host, cli_ = the client): nicstats_report.
        r.update({f'nic{i}_{k}': v for k, v in
                  read_kv(os.path.join(base, f'nicstats-nic{i}.rpt')).items()})
    # TCP retransmits on the client over the window, all flows (nstat).
    rx = read_kv(os.path.join(base, 'retx.rpt'))
    if 'Retx_percent' in rx:
        r['retx_pct'] = rx['Retx_percent']
        r['retx_segs'] = rx.get('Retx_segs')
    # The PIPS TLP log's numbers (--pips-log 1), pips_*: full or not, records,
    # drops, per-port TLPs, MWr Gbps and time in the batcher. Its text status
    # goes in 'pips_log'.
    r.update(read_kv(os.path.join(base, 'pips-log.rpt')))
    return r


def dump(a):
    nics = [int(x) for x in a.nics.split(',') if x != '']
    runs = [one_run(a.reports, a.exp, j, nics) for j in range(a.runs)]

    # nicstats files list only the counters that moved: a run without one had 0.
    keys = list(dict.fromkeys(k for r in runs for k in r))
    for r in runs:
        for k in keys:
            if k not in r and re.match(r'nic\d_(srv|cli)_', k):
                r[k] = 0.0
    mean, sd = {}, {}
    for k in keys:
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


def design_short(r):
    """The PIPS FPGA design ID a record was measured on, '0a04', or ''."""
    d = str(r.get('pips_design_id') or '').lower()
    return d[2:] if re.fullmatch(r'0x[0-9a-f]{4}', d) else ''


def tag(r):
    """The IOMMU mode, plus the PIPS batcher setting and design ID when the
    record has them, e.g. 'off d8t22c1@0a04': different points never mix."""
    b = r.get('pips_batch')
    if not b:
        return str(r.get('iommu'))
    d = design_short(r)
    return f"{r.get('iommu')} {b}" + (f"@{d}" if d else '')


def designs_line(recs):
    """'PIPS design ID: 0x0a04 (12 records)' for the records that have one, or ''."""
    c = collections.Counter(f'0x{design_short(r)}' for r in recs if design_short(r))
    if not c:
        return ''
    return 'PIPS design ID: ' + ', '.join(f'{d} ({n} records)' for d, n in sorted(c.items()))


def pips_table(recs, key, tw):
    """Each configuration's PIPS TLP log (--pips-log 1): whether every run's
    recording is whole, and what it saw per input."""
    rs = [r for r in recs if r.get('pips_log') is not None]
    if not rs:
        return
    sw = max([13] + [len(str(r['pips_log'])) for r in rs])
    hdr = (f"{'IOMMU':<{tw}} {'RATE':<9} {'FLOWS':>5} {'MODE':<9} {'LOG, per run':<{sw}} "
           f"{'RECORDS':>8} {'DROP':>5} {'SPAN_us':>8} {'in0_TLP':>8} {'in1_TLP':>8} "
           f"{'out_MWr_Gbps':>12} {'WAIT_us':>11}")
    print()
    print('PIPS TLP log per configuration (numbers: means over runs)')
    print(hdr)
    print('-' * len(hdr))
    counts = collections.Counter()
    for r in sorted(rs, key=key):
        m = r['mean']
        st = str(r['pips_log']) or 'none'
        counts.update(st.split(','))
        flag = '' if set(st.split(',')) == {'FULL'} else '  <-- NOT ALL FULL'
        w, p = m.get('pips_out_wait_mean'), m.get('pips_out_wait_p99')
        wait = '-' if w is None or p is None else f'{w / 250:.2f}/{p / 250:.2f}'
        print(f"{tag(r):<{tw}} {str(r.get('bandwidth_per_nic')):<9} "
              f"{str(r.get('flows_per_nic')):>5} {str(r.get('mode')):<9} {st:<{sw}} "
              f"{fmt(m.get('pips_records'), None, '.0f'):>8} "
              f"{fmt(m.get('pips_dropped'), None, '.0f'):>5} "
              f"{fmt(m.get('pips_duration_us'), None, '.0f'):>8} "
              f"{fmt(m.get('pips_in0_tlp'), None, '.0f'):>8} "
              f"{fmt(m.get('pips_in1_tlp'), None, '.0f'):>8} "
              f"{fmt(m.get('pips_out_mwr_gbps'), None, '.2f'):>12} {wait:>11}{flag}")
    print()
    print('  logs: ' + ', '.join(f'{n} {s}' for s, n in counts.most_common()))
    print('  FULL = it ran until the log region filled; CUT = ended first (5 s);')
    print('  +DROPS = TLP records lost to logger FIFO overflow; NO_TRAILER, BAD,')
    print('  FAILED = no usable log. in0 = from downstream port one (b348), in1 = from')
    print('  downstream port zero (b148). WAIT_us = mean/p99 time a TLP spent in the')
    print('  batcher (logs of design 0x0a04 on; - before).')


def flows_key(v):
    """Sort key for flows_per_nic: 5, or '5x30' for an uneven co-run (NIC 0 x NIC 1)."""
    parts = [int(x) for x in re.findall(r'\d+', str(v or 0))] or [0]
    return (sum(parts) / len(parts), str(v))


def nic_tput(m):
    """'N0/N1' Gbps of a record's mean, '-' if neither NIC has one."""
    v = [m.get(f'tput_nic{i}_gbps') for i in (0, 1)]
    if v == [None, None]:
        return '-'
    return '/'.join('-' if x is None else f'{x:.1f}' for x in v)


def status_table(recs, key, tw):
    """The page batcher's status over each run (design 0x0a06 on): overflow spills,
    the watchdog's stuck bit, the longest MRd wait. Means over runs."""
    rs = [r for r in recs if r['mean'].get('pips_stat_valid')]
    if not rs:
        return
    hdr = (f"{'IOMMU':<{tw}} {'RATE':<9} {'FLOWS':>5} {'MODE':<9} {'OVF0':>6} {'OVF1':>6} "
           f"{'STUCK':>5} {'MRD_WAIT_us in0/in1':>20} {'RETX_%':>7} {'PAUSE srv/cli':>14}")
    print()
    print('PIPS page batcher status per configuration (design 0x0a06 on; means over runs)')
    print(hdr)
    print('-' * len(hdr))
    for r in sorted(rs, key=key):
        m = r['mean']
        pause_s = sum(v or 0 for k, v in m.items() if k.startswith('nic') and '_srv_' in k and 'pause' in k)
        pause_c = sum(v or 0 for k, v in m.items() if k.startswith('nic') and '_cli_' in k and 'pause' in k)
        w = f"{fmt(m.get('pips_stat_mrd_wait_max_us_0'), None, '.2f')}/" \
            f"{fmt(m.get('pips_stat_mrd_wait_max_us_1'), None, '.2f')}"
        flag = '  <-- STUCK' if (m.get('pips_stat_stuck') or 0) > 0 else ''
        print(f"{tag(r):<{tw}} {str(r.get('bandwidth_per_nic')):<9} "
              f"{str(r.get('flows_per_nic')):>5} {str(r.get('mode')):<9} "
              f"{fmt(m.get('pips_stat_ovf_count_0'), None, '.0f'):>6} "
              f"{fmt(m.get('pips_stat_ovf_count_1'), None, '.0f'):>6} "
              f"{fmt(m.get('pips_stat_stuck'), None, '.0f'):>5} {w:>20} "
              f"{fmt(m.get('retx_pct'), None, '.3f'):>7} {f'{pause_s:.0f}/{pause_c:.0f}':>14}{flag}")
    print()
    print('  OVF0/1 = times input 0/1 spilled to its overflow (per-page mode: no free page')
    print('  segment); STUCK = the watchdog forced a drain (should be 0); MRD_WAIT = the')
    print('  longest time a read waited at the switch (crash safety: the device\'s completion')
    print('  timeout is 50 us at the least). RETX_% = client TCP retransmits; PAUSE = pause')
    print('  counter increments over the window, this host / the client, both NICs.')


def summary(a):
    recs = []
    for path in a.files:
        with open(os.path.expanduser(path)) as f:
            recs += [json.loads(l) for l in f if l.strip()]
    if not recs:
        sys.exit('no records')
    if designs_line(recs):
        print(designs_line(recs))
        print()

    def key(r):
        return (str(r.get('bandwidth_per_nic')), flows_key(r.get('flows_per_nic')),
                {'nic0only': 0, 'nic1only': 1, 'both': 2}.get(r.get('mode'), 3),
                tag(r))

    # contention = both / mean(nic0only, nic1only) - 1, per IOMMU mode (and
    # PIPS setting and build), rate, flows
    base = {}
    for r in recs:
        if r.get('mode') in ('nic0only', 'nic1only'):
            g = (tag(r), r.get('bandwidth_per_nic'), r.get('flows_per_nic'))
            base.setdefault(g, []).append(r['mean'].get('misses_per_gbps'))

    tw = max([7] + [len(tag(r)) for r in recs])
    hdr = f"{'IOMMU':<{tw}} {'RATE':<9} {'FLOWS':>5} {'MODE':<9} {'TPUT_Gbps':>16} {'NIC0/NIC1':>11} " \
          f"{'PCIe_wr':>8} {'MISS_PER_GBPS':>20} {'CPU_%':>12} {'CONTENTION':>10}"
    print(hdr)
    print('-' * len(hdr))
    for r in sorted(recs, key=key):
        m, s = r['mean'], r['sd']
        cont = ''
        # Without translation there are no misses to contend over; the ratio
        # of two near-zero counts would read as a large, meaningless swing.
        if r.get('mode') == 'both' and r.get('iommu') not in ('off', 'pt'):
            b = base.get((tag(r), r.get('bandwidth_per_nic'), r.get('flows_per_nic')), [])
            both = m.get('misses_per_gbps')
            if len(b) >= 2 and None not in b and both and sum(b) > 0:
                cont = f'{100 * (both / (sum(b) / len(b)) - 1):+.1f}%'
        wr = m.get('PCIe_wr_tput')
        flag = '  <-- LINK BOUND' if (wr or 0) > 100 else ''
        print(f"{tag(r):<{tw}} {str(r.get('bandwidth_per_nic')):<9} "
              f"{str(r.get('flows_per_nic')):>5} {str(r.get('mode')):<9} "
              f"{fmt(m.get('tput_total_gbps'), s.get('tput_total_gbps'), '.2f'):>16} "
              f"{nic_tput(m):>11} "
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
    print('  FLOWS AxB = an uneven co-run: A flows on NIC 0, B on NIC 1. RATE hw<R> = the')
    print('  client NIC paced each port to R in hardware (iperf3 uncapped).')
    if any(r.get('pips_batch') for r in recs):
        print('  IOMMU <mode> d<D>t<T>[m1][c1][p1][o1][q<N>][w<N>][@<id>] = NICs behind PIPS with')
        print('  batcher depth D, time T (m1: batch_mrd on; c1: drain depth cap on; p1: per-page')
        print('  batching; o1: ctrl_push off; q<N>: grant quantum N beats; w<N>: completion')
        print('  threshold N DW) on FPGA design 0x<id>.')
    pips_table(recs, key, tw)
    status_table(recs, key, tw)


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
