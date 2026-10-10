"""pcm-memory text output (membw.log) -> membw.rpt, one 'key: value' per line.

    python3 parse_membw.py logs/<exp>/membw.log > reports/<exp>/membw.rpt

Per socket, the mean over every sample of read, write and total memory
bandwidth (MB/s), as Node<N>_rd_bw / _wr_bw / _total_bw; then the system
totals (System_rd_bw / _wr_bw / _total_bw) and how many samples were averaged
(membw_samples).

Older PCM labels the per-socket lines "NODE 0 Mem Read (MB/s)", current PCM
"SKT  0 Mem Read (MB/s)"; both parse, however many sockets share a line
(-columns). The per-channel lines stay in membw.log only.
"""
import re
import sys

SOCKET = [   # (suffix, pattern); group 1 = socket, group 2 = MB/s
    ('rd_bw', re.compile(r'(?:NODE|SKT)\s*(\d+)\s+Mem Read\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
    ('wr_bw', re.compile(r'(?:NODE|SKT)\s*(\d+)\s+Mem Write\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
    ('total_bw', re.compile(r'(?:NODE|SKT)\s*(\d+)\s+Memory\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
]
# "System Read Throughput", not "System DRAM/PMM Read Throughput": the total.
SYSTEM = [
    ('System_rd_bw', re.compile(r'System Read Throughput\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
    ('System_wr_bw', re.compile(r'System Write Throughput\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
    ('System_total_bw', re.compile(r'System Memory Throughput\s*\(MB/s\)\s*:\s*(-?[\d.]+)')),
]

vals = {}
lines = []
try:
    with open(sys.argv[1], errors='replace') as f:
        for line in f:
            lines.append(line.rstrip())
            for suffix, pat in SOCKET:
                for sock, v in pat.findall(line):
                    vals.setdefault((int(sock), suffix), []).append(float(v))
            for key, pat in SYSTEM:
                m = pat.search(line)
                if m:
                    vals.setdefault(key, []).append(float(m.group(1)))
except OSError as e:
    print(f'WARNING: cannot read pcm-memory output: {e}', file=sys.stderr)

sockets = sorted({k[0] for k in vals if isinstance(k, tuple)})
for s in sockets:
    for suffix, _ in SOCKET:
        v = vals.get((s, suffix))
        if v:
            print(f'Node{s}_{suffix}: {sum(v) / len(v):.3f}')
for key, _ in SYSTEM:
    v = vals.get(key)
    if v:
        print(f'{key}: {sum(v) / len(v):.3f}')
n = max((len(v) for v in vals.values()), default=0)
print(f'membw_samples: {n}')

if n == 0:
    shown = [l for l in lines if l.strip()][:8]
    print('WARNING: no memory bandwidth samples in the pcm-memory output; '
          'membw.rpt has none.' + (' Its first lines:' if shown else ' It is empty.'),
          file=sys.stderr)
    for l in shown:
        print(f'    {l}', file=sys.stderr)
