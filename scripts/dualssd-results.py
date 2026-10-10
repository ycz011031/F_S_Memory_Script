#!/usr/bin/env python3
"""Machine-readable results for run-dualssd-experiment.sh.

  fio-sum  sum one drive's fio JSON outputs (one per instance) into fio.rpt
  dump     read one experiment's report directories and append a single JSON
           line (config + every run + mean/sd) to a .jsonl file
  summary  print a comparison table from one or more .jsonl files, then every
           pcm-iio and pcm-memory value
  grid     the same records as block size x instances tables (cross sweeps)

    dualssd-results.py fio-sum --out reports/X-RUN-0-ssd0/fio.rpt logs/X-RUN-0/fio-ssd0-*.json
    dualssd-results.py dump --reports DIR --exp NAME --runs 3 --ssds 0,1 \\
        --out ~/dualssd.jsonl --meta instances_per_ssd=4 --meta iommu=strict
    dualssd-results.py summary ~/dualssd-sweep-strict-*.jsonl ~/dualssd-sweep-off-*.jsonl

The .rpt files stay the source of truth; this only collects them, so a run
whose reports are missing shows up as null rather than as zero.
"""
import argparse
import datetime
import glob
import json
import os
import platform
import re
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


def read_windows(path):
    """windows.txt from record-host-metrics.sh -> {name: (start_ms, end_ms)}
    for cpu / pcie / membw, plus 'all' spanning every window."""
    marks = {}
    with open(path) as f:
        for line in f:
            tok = line.split()
            if len(tok) == 2 and tok[1].isdigit():
                marks[tok[0]] = int(tok[1])
    spans = {}
    for name in ('cpu', 'pcie', 'membw'):
        if f'{name}_start' in marks and f'{name}_end' in marks:
            spans[name] = (marks[f'{name}_start'], marks[f'{name}_end'])
    if spans:
        spans['all'] = (min(s for s, _ in spans.values()), max(e for _, e in spans.values()))
    return spans


def read_iops_log(path):
    """fio --write_iops_log with log_avg_msec=1000 and log_unix_epoch=1:
    'epoch_ms, iops, ddir, bs, offset[, prio]' per line. Each sample is the
    mean over the second ending at its timestamp. fio logs nothing during
    ramp_time (checked with fio 3.43)."""
    pts = []
    with open(path) as f:
        for line in f:
            tok = line.split(',')
            try:
                pts.append((int(tok[0]), float(tok[1])))
            except (ValueError, IndexError):
                pass
    return sorted(pts)


SLACK_MS = 500   # timer jitter between fio's samples and the window marks


def window_mean(pts, a, b):
    """Mean of the samples whose one-second interval lies inside [a, b]."""
    vals = [v for t, v in pts if t - 1000 >= a - SLACK_MS and t <= b + SLACK_MS]
    return sum(vals) / len(vals) if vals else None


def coverage_gap(pts, a, b):
    """'' if the samples cover [a, b] without a hole, else what is missing."""
    if not pts:
        return 'no samples logged'
    ts = [t for t, _ in pts]
    if ts[0] - 1000 > a + SLACK_MS:
        return f'first sample starts {(ts[0] - 1000 - a) / 1000:.1f} s after the window opened'
    # The runner stops fio right after the window, so the last full second
    # logged ends at most ~1 s before the window closes.
    if ts[-1] < b - 1000 - SLACK_MS:
        return f'samples stop {(b - ts[-1]) / 1000:.1f} s before the window closed'
    hole = max((t2 - t1 for t1, t2 in zip(ts, ts[1:]) if t2 >= a and t1 <= b), default=0)
    if hole > 2000:
        return f'a {hole / 1000:.1f} s hole in the samples'
    return ''


def fio_sum(a):
    """One fio process per instance, each with one job (or a group_reporting
    aggregate). IOPS and bandwidth add up; latency is IOPS-weighted.

    With --windows, IOPS come from each instance's per-second log averaged
    over exactly the measurement windows, and every instance must have logged
    through all of them. fio's own summary covers from the end of ramp_time
    to the stop, a little wider; it is kept as fio_IOPS_postramp."""
    spans = read_windows(a.windows) if a.windows else {}
    iops_run = bw_run = lat_w = p99 = 0.0
    win = {w: 0.0 for w in spans}
    ok, bad, uncovered = 0, [], []
    runtime_min, bytes_per_io, stalled = None, None, 0
    for path in a.files:
        name = os.path.basename(path)
        try:
            with open(path) as f:
                txt = f.read()
            # fio may put notes ahead of the JSON in the --output file.
            doc = json.loads(txt[txt.index('{'):])
            for job in doc['jobs']:
                if job.get('error'):
                    raise ValueError(f"fio job error {job['error']}")
                # Every fio here runs --readonly. If one ever reports bytes
                # written or trimmed, something bypassed that: stop loudly.
                for d in ('write', 'trim'):
                    if job.get(d, {}).get('io_bytes', 0):
                        sys.exit(f'FATAL: {path}: fio reports {job[d]["io_bytes"]} bytes '
                                 f'of {d} on a drive that must only be read.')
                rd = job['read']
                iops_run += rd['iops']
                bw_run += rd['bw_bytes']
                lat_w += rd['lat_ns']['mean'] * rd['iops']
                pct = rd.get('clat_ns', {}).get('percentile', {})
                p99 = max(p99, pct.get('99.000000', 0.0))
                if rd.get('total_ios'):
                    bytes_per_io = rd['io_bytes'] / rd['total_ios']
                rt = rd.get('runtime', 0) / 1000
                runtime_min = rt if runtime_min is None else min(runtime_min, rt)
                # fio's own clock: job_start is when it began measuring, i.e.
                # after ramp_time; job_start + runtime is when it stopped.
                if spans and 'job_start' in job:
                    a0, b0 = spans['all']
                    if job['job_start'] > a0 + SLACK_MS:
                        uncovered.append(f'{name}: fio began measuring '
                                         f'{(job["job_start"] - a0) / 1000:.1f} s after the window opened')
                    if job['job_start'] + rd.get('runtime', 0) < b0 - 1000 - SLACK_MS:
                        uncovered.append(f'{name}: fio stopped measuring '
                                         f'{(b0 - job["job_start"] - rd["runtime"]) / 1000:.1f} s '
                                         f'before the window closed')
            if spans:
                logs = sorted(glob.glob(path[:-len('.json')] + '_iops.*.log'))
                if not logs:
                    uncovered.append(f'{name}: no per-second log')
                    win = {w: None for w in win}
                else:
                    pts = read_iops_log(logs[0])
                    gap = coverage_gap(pts, *spans['all'])
                    if gap:
                        uncovered.append(f'{name}: {gap}')
                    for w, (s, e) in spans.items():
                        m = window_mean(pts, s, e)
                        win[w] = None if (m is None or win[w] is None) else win[w] + m
                    stalled += sum(1 for t, v in pts
                                   if v == 0 and spans['all'][0] < t <= spans['all'][1] + 1000)
            ok += 1
        except (OSError, ValueError, KeyError) as e:
            bad.append(f'{name}: {e}')
    for b in bad:
        print(f'ERROR: unusable fio output {b}', file=sys.stderr)
    for u in uncovered:
        print(f'ERROR: did not cover the measurement window: {u}', file=sys.stderr)

    iops = win.get('all') if spans else iops_run
    if bytes_per_io and iops is not None:
        bw = iops * bytes_per_io
    else:
        bw = bw_run if not spans else None
    with open(a.out, 'w') as f:
        if iops is not None:
            f.write(f'IOPS: {iops:.1f}\n')
        if bw is not None:
            f.write(f'read_MBps: {bw / 1e6:.3f}\n')
            f.write(f'read_Gbps: {bw * 8 / 1e9:.3f}\n')
        if bytes_per_io:
            f.write(f'bytes_per_io: {bytes_per_io:.0f}\n')
        for w in ('cpu', 'pcie', 'membw'):
            if win.get(w) is not None:
                f.write(f'IOPS_{w}_window: {win[w]:.1f}\n')
        f.write(f'fio_IOPS_postramp: {iops_run:.1f}\n')
        if runtime_min is not None:
            f.write(f'fio_runtime_s_min: {runtime_min:.1f}\n')
        if spans:
            f.write(f'window_s: {(spans["all"][1] - spans["all"][0]) / 1000:.1f}\n')
            f.write(f'window_covered: {0 if (uncovered or bad) else 1}\n')
            f.write(f'stalled_seconds: {stalled}\n')
        f.write(f'lat_mean_us: {(lat_w / iops_run / 1000) if iops_run else 0:.2f}\n')
        f.write(f'clat_p99_us_max: {p99 / 1000:.2f}\n')
        f.write(f'instances_ok: {ok}\n')
        f.write(f'instances_failed: {len(bad)}\n')
    if not ok:
        sys.exit(1)
    sys.exit(3 if (spans and (uncovered or bad)) else 0)


def one_run(reports, exp, j, ssds):
    base = os.path.join(reports, f'{exp}-RUN-{j}')
    r = {}
    iops_t, gbps_t = 0.0, 0.0
    # IOPS over each measurement window alone, so per-I/O ratios divide
    # counters by the IOPS of the same seconds. Older reports lack them.
    iops_w = {'cpu': 0.0, 'pcie': 0.0}
    covered = None
    for i in ssds:
        fio = read_kv(os.path.join(f'{base}-ssd{i}', 'fio.rpt'))
        r[f'iops_ssd{i}'] = fio.get('IOPS')
        r[f'gbps_ssd{i}'] = fio.get('read_Gbps')
        r[f'lat_us_ssd{i}'] = fio.get('lat_mean_us')
        r[f'p99_us_ssd{i}'] = fio.get('clat_p99_us_max')
        r[f'fio_iops_postramp_ssd{i}'] = fio.get('fio_IOPS_postramp')
        iops_t = None if (iops_t is None or fio.get('IOPS') is None) else iops_t + fio['IOPS']
        gbps_t = None if (gbps_t is None or fio.get('read_Gbps') is None) else gbps_t + fio['read_Gbps']
        for w in iops_w:
            v = fio.get(f'IOPS_{w}_window')
            iops_w[w] = None if (iops_w[w] is None or v is None) else iops_w[w] + v
        if 'window_covered' in fio:
            covered = min(fio['window_covered'], 1.0 if covered is None else covered)
    r['iops_total'] = iops_t
    r['gbps_total'] = gbps_t
    r['iops_cpu_window'] = iops_w['cpu']
    r['iops_pcie_window'] = iops_w['pcie']
    r['window_covered'] = covered

    # Whatever pcie.rpt holds: the key set depends on the CPU (see
    # parse_pciebw_skx in record-host-metrics.sh for Skylake's).
    pcie = read_kv(os.path.join(base, 'pcie.rpt'))
    pcie.pop('cpu_model', None)
    r.update(pcie)
    miss, wr = pcie.get('IOTLB_misses'), pcie.get('PCIe_wr_tput')
    # The comparison metrics. pcm-iio samples once a second, so counters are
    # per second: divide by IOPS for per I/O, by GB/s of DMA write for per GB.
    # Use the IOPS of the pcm-iio window itself when the report has it.
    iops_pcie = r['iops_pcie_window'] or iops_t
    r['misses_per_io'] = miss / iops_pcie if (miss is not None and iops_pcie) else None
    r['misses_per_gb'] = miss / (wr / 8) if (miss is not None and wr) else None

    r['cpu_util_pct'] = read_kv(os.path.join(base, 'cpu_util.rpt')).get('avg_cpu_util')
    # Everything pcm-memory gave: per-socket and system read / write / total
    # MB/s and the sample count (utils/parse_membw.py).
    r.update(read_kv(os.path.join(base, 'membw.rpt')))
    return r


def dump(a):
    ssds = [int(x) for x in a.ssds.split(',') if x != '']
    runs = [one_run(a.reports, a.exp, j, ssds) for j in range(a.runs)]
    # Which keys came from each PCM tool, in report order, so the summary can
    # print every PCM value without a fixed list (the set depends on the CPU).
    base0 = os.path.join(a.reports, f'{a.exp}-RUN-0')
    pcm = {'pcm-iio': [k for k in read_kv(os.path.join(base0, 'pcie.rpt')) if k != 'cpu_model'],
           'pcm-memory': list(read_kv(os.path.join(base0, 'membw.rpt')))}

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
    rec.update({'pcm_keys': pcm, 'runs': a.runs, 'mean': mean, 'sd': sd, 'per_run': runs})

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


def load(files):
    recs = []
    for path in files:
        with open(os.path.expanduser(path)) as f:
            recs += [json.loads(l) for l in f if l.strip()]
    if not recs:
        sys.exit('no records')
    return recs


def group(r):
    """One measurement point: IOMMU mode, block size, instances per drive
    ("n0+n1" for a co-run whose drives had different counts)."""
    return (str(r.get('iommu')), str(r.get('bs')), r.get('instances_per_ssd'))


def n_of(r, i):
    """Instances drive i ran in record r (older records: instances_per_ssd)."""
    return r.get(f'instances_ssd{i}', r.get('instances_per_ssd'))


def is_asym(r):
    return r.get('mode') == 'both' and n_of(r, 0) != n_of(r, 1)


def point(r, i):
    """The single-drive point that matches drive i's share of record r."""
    return (str(r.get('iommu')), str(r.get('bs')), n_of(r, i))


def alone_iops(recs):
    """Each single-drive run's IOPS: {point: {'ssd0only': iops, ...}}."""
    base = {}
    for r in recs:
        if r.get('mode') in ('ssd0only', 'ssd1only'):
            base.setdefault(group(r), {})[r['mode']] = r['mean'].get('iops_total')
    return base


def kept(r, alone):
    """Each drive's IOPS in a co-run as % of its IOPS alone at the same block
    size and its own instance count, {drive: pct}, for the drives that have a
    single-drive run there. alone: alone_iops() of all records."""
    out = {}
    for i in (0, 1):
        a = alone.get(point(r, i), {}).get(f'ssd{i}only')
        c = r['mean'].get(f'iops_ssd{i}')
        if a and c is not None:
            out[i] = 100 * c / a
    return out


def cpu_us_per_io(r):
    """CPU time on the fio cores per I/O, from the CPU window, or None."""
    m = r['mean']
    ncores = len(str(r.get('cpu_util_cores', '')).split(',')) if r.get('cpu_util_cores') else 0
    iops_cpu = m.get('iops_cpu_window') or m.get('iops_total')   # same seconds as the CPU sample
    if m.get('cpu_util_pct') is not None and iops_cpu and ncores:
        return m['cpu_util_pct'] / 100 * ncores / iops_cpu * 1e6
    return None


def miss_per_4k(r):
    """IOTLB misses per 4 KiB of data read: comparable across block sizes."""
    mpio = r['mean'].get('misses_per_io')
    if mpio is not None and bs_bytes(r.get('bs')):
        return mpio / (bs_bytes(r.get('bs')) / 4096)
    return None


def link_bound(r):
    wr, up = r['mean'].get('PCIe_wr_tput'), r.get('uplink_gbps') or 0
    return bool(up and (wr or 0) > 0.85 * up)


def sort_key(r):
    """IOMMU, block size; even runs by instances, then uneven co-runs by
    (low, high) count, the drive-0-low orientation first."""
    def num(v):
        return v if isinstance(v, (int, float)) else 0
    a, b = num(n_of(r, 0)), num(n_of(r, 1))
    return (str(r.get('iommu')), bs_bytes(r.get('bs')), a != b, min(a, b), max(a, b), a > b,
            {'ssd0only': 0, 'ssd1only': 1, 'both': 2}.get(r.get('mode'), 3))


# pcm-iio keys of Skylake records written before dump stored 'pcm_keys'.
OLD_PCIE_KEYS = ['PCIe_wr_tput', 'PCIe_rd_tput', 'IOTLB_hits', 'IOTLB_misses',
                 'CTXT_Miss', 'L1_Miss', 'L2_Miss', 'L3_Miss', 'Mem_Read']


def pcm_keys(recs, tool):
    """Every key any record took from one PCM tool's report, in report order."""
    out = []
    for r in recs:
        ks = (r.get('pcm_keys') or {}).get(tool)
        if ks is None:
            ks = OLD_PCIE_KEYS if tool == 'pcm-iio' else \
                [k for k in r['mean'] if k.startswith(('Node', 'System'))]
        out += [k for k in ks if k in r['mean'] and k not in out]
    return out


def pcm_tables(recs):
    """Every pcm-iio and pcm-memory value, one row per configuration."""
    def label(k):
        m = re.match(r'(?:Node(\d+)|System)_(\w+)_bw$', k)
        if m:
            return (f'N{m.group(1)}' if m.group(1) else 'Sys') + '_' + m.group(2)
        return 'n' if k.endswith('_samples') else k.replace('PCIe_ob_', 'OB_').replace('_tput', '')

    def cell(k, v):
        if v is None:
            return 'n/a'
        if k.endswith('_samples'):
            return f'{v:.0f}'
        if k.endswith('_tput'):
            return f'{v:.3f}'                  # Gbps
        if k.endswith('_bw'):
            return f'{v:.0f}'                  # MB/s
        return f'{v / 1e6:.3f}'                # events/s -> M/s

    legends = {
        'pcm-iio': ['  pcm-iio, the shared stack: PCIe_wr / PCIe_rd = device DMA writes into /',
                    '  reads from memory, OB_rd / OB_wr = CPU MMIO to the devices (doorbells),',
                    '  in Gbps; every other column is VT-d events, millions per second;',
                    '  n = one-second samples averaged.'],
        'pcm-memory': ['  pcm-memory: MB/s per socket (N<socket>) and system-wide (Sys);',
                       '  n = samples averaged.'],
    }
    for tool in ('pcm-iio', 'pcm-memory'):
        ks = pcm_keys(recs, tool)
        print()
        if not ks:
            print(f'  {tool}: no values in these records' +
                  (' (--membw 0, or recorded before 2026-10-10)' if tool == 'pcm-memory' else ''))
            continue
        cols = [(k, label(k)) for k in ks]
        rows = [[cell(k, r['mean'].get(k)) for k, _ in cols] for r in sorted(recs, key=sort_key)]
        ws = [max([len(l)] + [len(row[c]) for row in rows]) for c, (_, l) in enumerate(cols)]
        hdr = f"{'IOMMU':<7} {'BS':<5} {'INST':>5} {'MODE':<9}" + \
              ''.join(f' {l:>{w}}' for (_, l), w in zip(cols, ws))
        print(f'{tool}, means over runs (sd of each in the .jsonl)')
        print(hdr)
        print('-' * len(hdr))
        for r, row in zip(sorted(recs, key=sort_key), rows):
            print(f"{str(r.get('iommu')):<7} {str(r.get('bs')):<5} "
                  f"{str(r.get('instances_per_ssd')):>5} {str(r.get('mode')):<9}" +
                  ''.join(f' {c:>{w}}' for c, w in zip(row, ws)))
        print()
        print('\n'.join(legends[tool]))


def asym_table(recs):
    """Uneven co-runs (dualssd_sweep.sh --asy): both orientations of each
    LOW+HIGH pair side by side, with the even co-runs at LOW and at HIGH."""
    co = {}
    for r in recs:
        if r.get('mode') == 'both':
            co[(str(r.get('iommu')), str(r.get('bs')), n_of(r, 0), n_of(r, 1))] = r
    pairs = sorted({(k[0], k[1], min(k[2], k[3]), max(k[2], k[3])) for k in co if k[2] != k[3]},
                   key=lambda p: (p[0], bs_bytes(p[1]), p[2], p[3]))
    if not pairs:
        return

    def ki(r, i):
        v = r['mean'].get(f'iops_ssd{i}') if r else None
        return None if v is None else v / 1e3

    def two(a, b):
        return '-' if None in (a, b) else f'{a:.1f}/{b:.1f}'

    def pct(a, b):
        return '-' if None in (a, b) or not b else f'{100 * a / b:.0f}%'

    rows = []
    for io, bs, lo, hi in pairs:
        a = co.get((io, bs, lo, hi))        # drive 0 LOW, drive 1 HIGH
        b = co.get((io, bs, hi, lo))        # drive 1 LOW, drive 0 HIGH
        sl, sh = co.get((io, bs, lo, lo)), co.get((io, bs, hi, hi))
        rows.append([io, bs, f'{lo}+{hi}',
                     two(ki(a, 0), ki(a, 1)), pct(ki(a, 0), ki(sl, 0)),
                     two(ki(b, 1), ki(b, 0)), pct(ki(b, 1), ki(sl, 1)),
                     two(ki(sl, 0), ki(sl, 1)), two(ki(sh, 0), ki(sh, 1))])
    hdr = ['IOMMU', 'BS', 'LOW+HIGH', 'd0 LOW: low/high', 'vsLOW',
           'd1 LOW: low/high', 'vsLOW', 'both LOW: d0/d1', 'both HIGH: d0/d1']
    ws = [max([len(h)] + [len(row[c]) for row in rows]) for c, h in enumerate(hdr)]

    def line(cells):
        return '  '.join(f'{v:<{w}}' if c < 3 else f'{v:>{w}}'
                         for c, (v, w) in enumerate(zip(cells, ws)))
    print()
    print('uneven co-runs, kIOPS (dualssd_sweep.sh --asy)')
    print(line(hdr))
    print('-' * len(line(hdr)))
    for row in rows:
        print(line(row))
    print()
    print('  d0 LOW    = drive 0 ran LOW instances and drive 1 HIGH: kIOPS of the LOW')
    print('              drive / the HIGH drive. d1 LOW = the same with the drives swapped;')
    print('              the two agree unless the drives or their slots differ.')
    print('  vsLOW     = the LOW drive\'s IOPS as % of its own IOPS when both drives ran')
    print('              LOW: what a heavier neighbour costs it.')
    print('  both LOW, both HIGH = the even co-runs at either count, drive 0 / drive 1.')


def summary(a):
    recs = load(a.files)
    key = sort_key

    # Single-drive misses per I/O and IOPS, per IOMMU mode / block size / instances.
    base = {}
    for r in recs:
        if r.get('mode') in ('ssd0only', 'ssd1only'):
            base.setdefault(group(r), {})[r['mode']] = r['mean'].get('misses_per_io')
    alone = alone_iops(recs)

    hdr = f"{'IOMMU':<7} {'BS':<5} {'INST':>5} {'MODE':<9} {'IOPS_k':>15} {'GB/s':>6} " \
          f"{'LAT_us':>7} {'PCIe_wr':>8} {'MISS/IO':>13} {'MISS/4K':>8} {'CPU_%':>11} " \
          f"{'CPU_us/IO':>9} {'CONTENTION':>10} {'KEPT%':>11}"
    print(hdr)
    print('-' * len(hdr))
    for r in sorted(recs, key=key):
        m, s = r['mean'], r['sd']
        iops = m.get('iops_total')
        cont = ''
        # Without translation there are no misses to contend over.
        if r.get('mode') == 'both' and r.get('iommu') not in ('off', 'pt'):
            m0 = base.get(point(r, 0), {}).get('ssd0only')
            m1 = base.get(point(r, 1), {}).get('ssd1only')
            i0, i1 = m.get('iops_ssd0'), m.get('iops_ssd1')
            both = m.get('misses_per_io')
            # The drives are different models at different IOPS, so the
            # expectation weights each drive's own miss rate by its share of
            # the co-run's I/O instead of averaging the two baselines.
            if None not in (m0, m1, i0, i1, both) and (i0 + i1) > 0:
                expect = (m0 * i0 + m1 * i1) / (i0 + i1)
                if expect > 0:
                    cont = f'{100 * (both / expect - 1):+.1f}%'
        # Unlike CONTENTION this needs only one drive's single run, and it
        # means something with the IOMMU off too.
        kept_s = ''
        if r.get('mode') == 'both':
            kept_s = ' '.join(f's{i}:{v:.0f}' for i, v in kept(r, alone).items())
        cpu_us = cpu_us_per_io(r)
        miss4k = miss_per_4k(r)
        # Mean fio latency, IOPS-weighted across the active drives.
        lat = None
        pairs = [(m.get(f'lat_us_ssd{i}'), m.get(f'iops_ssd{i}')) for i in r.get('active_ssds', [])]
        if pairs and all(l is not None and n for l, n in pairs):
            lat = sum(l * n for l, n in pairs) / sum(n for _, n in pairs)
        wr = m.get('PCIe_wr_tput')
        flag = '  <-- LINK BOUND' if link_bound(r) else ''
        if any(run.get('window_covered') == 0 for run in r.get('per_run', [])):
            flag += '  <-- fio DID NOT COVER THE WINDOW'
        print(f"{str(r.get('iommu')):<7} {str(r.get('bs')):<5} "
              f"{str(r.get('instances_per_ssd')):>5} {str(r.get('mode')):<9} "
              f"{fmt(iops / 1e3 if iops is not None else None, (s.get('iops_total') or 0) / 1e3, '.1f'):>15} "
              f"{fmt(m.get('gbps_total') / 8 if m.get('gbps_total') is not None else None, None, '.2f'):>6} "
              f"{fmt(lat, None, '.0f'):>7} "
              f"{fmt(wr, None, '.1f'):>8} "
              f"{fmt(m.get('misses_per_io'), s.get('misses_per_io'), '.3f'):>13} "
              f"{fmt(miss4k, None, '.3f'):>8} "
              f"{fmt(m.get('cpu_util_pct'), s.get('cpu_util_pct'), '.1f'):>11} "
              f"{fmt(cpu_us, None, '.2f'):>9} "
              f"{cont:>10} {kept_s:>11}{flag}")
    print()
    print('  IOPS, GB/s = fio, averaged over the measurement windows only (no warm-up).')
    print('  LAT_us     = mean fio completion latency per I/O, IOPS-weighted across drives.')
    print('  MISS/IO    = IOTLB misses per second / IOPS of the same pcm-iio window.')
    print('  MISS/4K    = MISS/IO per 4 KiB read: compares block sizes.')
    print('  CPU_us/IO  = CPU time on the fio cores per I/O, from the same CPU window;')
    print('               strict mode\'s cost shows here.')
    print('  CONTENTION = both MISS/IO vs the single-drive MISS/IO of each drive,')
    print('               weighted by that drive\'s share of the co-run\'s IOPS. Needs the')
    print('               single-drive runs (dualssd_sweep.sh --single).')
    print('  KEPT%      = each drive\'s IOPS in the co-run as % of its IOPS alone at the')
    print('               same BS/INST (s0 = drive 0); needs that drive\'s single run.')
    print('  INST n0+n1 = an uneven co-run: n0 instances on drive 0, n1 on drive 1, cores')
    print('               split in proportion. CONTENTION and KEPT% then compare each')
    print('               drive with its own single-drive run at its own count.')
    print('  IOMMU off/pt has no translation, so compare IOPS and CPU_us/IO across')
    print('  modes at the same BS/INST. LINK BOUND: PCIe write above 85% of the')
    print('  narrowest shared PCIe link, which then caps the run, not the IOMMU.')
    asym_table(recs)
    pcm_tables(recs)


def grid(a):
    """Block size x instances tables, one per IOMMU mode and metric."""
    recs = load(a.files)
    alone = alone_iops(recs)
    # A point measured twice (say, a re-run) shows its last record.
    pts = {group(r) + (r.get('mode'),): r for r in recs if not is_asym(r)}

    def k(v):
        return f'{v / 1e3:.1f}'

    def cells_both(r):
        m = r['mean']
        return m.get('iops_ssd0'), m.get('iops_ssd1')

    for iommu in sorted({p[0] for p in pts}):
        here = [p for p in pts if p[0] == iommu]
        bss = sorted({p[1] for p in here}, key=bs_bytes)
        js = sorted({p[2] for p in here if p[2] is not None})
        modes = {p[3] for p in here}
        # (title, mode, cell function returning a string or None)
        tables = []
        if 'both' in modes:
            tables += [
                ('both drives, total kIOPS  (* = LINK BOUND)', 'both',
                 lambda r: None if r['mean'].get('iops_total') is None else
                 k(r['mean']['iops_total']) + ('*' if link_bound(r) else '')),
                ('both drives, kIOPS of drive 0 / drive 1', 'both',
                 lambda r: None if None in cells_both(r) else
                 '/'.join(k(v) for v in cells_both(r))),
                ('both drives, GB/s', 'both',
                 lambda r: None if r['mean'].get('gbps_total') is None else
                 f"{r['mean']['gbps_total'] / 8:.2f}"),
                ('both drives, CPU us per I/O', 'both',
                 lambda r: None if cpu_us_per_io(r) is None else f'{cpu_us_per_io(r):.2f}'),
            ]
            if iommu not in ('off', 'pt'):
                tables.append(('both drives, IOTLB misses per 4 KiB read', 'both',
                               lambda r: None if miss_per_4k(r) is None else f'{miss_per_4k(r):.3f}'))
        for i in (0, 1):
            if f'ssd{i}only' not in modes:
                continue
            tables.append((f'drive {i} alone, kIOPS  (* = LINK BOUND)', f'ssd{i}only',
                           lambda r: None if r['mean'].get('iops_total') is None else
                           k(r['mean']['iops_total']) + ('*' if link_bound(r) else '')))
            if 'both' in modes:
                tables.append((f'drive {i} in the co-run, % of its IOPS alone', 'both',
                               lambda r, i=i: (lambda v: None if v is None else f'{v:.0f}%')(
                                   kept(r, alone).get(i))))

        for title, mode, cell in tables:
            rows = []
            for b in bss:
                row = []
                for j in js:
                    r = pts.get((iommu, b, j, mode))
                    row.append((cell(r) if r else None) or '-')
                rows.append(row)
            w = max([len(c) for row in rows for c in row] + [len(str(j)) for j in js] + [4])
            print(f'IOMMU {iommu}: {title}')
            print(f"  {'BS':<5}" + ''.join(f'  {str(j):>{w}}' for j in js) + '   <- instances per drive')
            for b, row in zip(bss, rows):
                print(f'  {b:<5}' + ''.join(f'  {c:>{w}}' for c in row))
            print()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    fs = sub.add_parser('fio-sum')
    fs.add_argument('--out', required=True)
    fs.add_argument('--windows', help="record-host-metrics.sh's windows.txt: average each "
                    "instance's <json>_iops.*.log over those windows and require full coverage")
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
    g = sub.add_parser('grid')
    g.add_argument('files', nargs='+')
    a = p.parse_args()
    {'fio-sum': fio_sum, 'dump': dump, 'summary': summary, 'grid': grid}[a.cmd](a)


if __name__ == '__main__':
    main()
