# File map

Which file does what, and which file calls, sources or reads which. Read this
instead of scanning the repo. It covers every tracked file (as of 2026-10-10,
branch `icx-dualnic`).

- Testbed state, results and how to run: [HANDOFF.md](HANDOFF.md)
  (§1–6 dual-NIC on icx, §7 dual-SSD on bigserver)
- Background on the upstream artifact and its traps: [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md)
- First-time provisioning of the icx pair: [LOCAL-SETUP.md](LOCAL-SETUP.md)

When you add, rename or rewire a script, update this file in the same commit.

Legend used below: **entry** = run by hand · **driver** = runs one experiment ·
**lib** = sourced · **called** = run by another script · **manual** = no caller,
run by hand when needed · **orphan** = no caller and superseded · **data** /
**doc** = not executable.

---

## 1. Start here

| I want to... | Run (from the repo root) | Host |
|---|---|---|
| Dual-SSD: sweep fio instances per drive | `scripts/sosp24-experiments/dualssd_sweep.sh` | bigserver |
| Dual-SSD: sweep block size | `scripts/sosp24-experiments/dualssd_bs_sweep.sh` | bigserver |
| Dual-SSD: block size × instances | `scripts/sosp24-experiments/dualssd_cross_sweep.sh` | bigserver |
| Dual-SSD: uneven co-runs (one drive LOW, the other HIGH instances) | `--asy` on either sweep above, or `run-dualssd-experiment.sh -J n0,n1` | bigserver |
| Dual-SSD: one configuration | `scripts/run-dualssd-experiment.sh` | bigserver |
| Dual-SSD: find the pcm-iio row, check VT-d counters | `sudo bash utils/discover-ssd-pcie.sh` | bigserver |
| Dual-SSD: tables from results | `python3 scripts/dualssd-results.py summary\|grid ~/<sweep>.jsonl` | any |
| Dual-NIC: NIC0 alone, NIC1 alone, both | `scripts/sosp24-experiments/dualnic_exp.sh` | icx |
| Dual-NIC: sweep flows / offered load | `dualnic_flow_sweep.sh` / `dualnic_load_sweep.sh` (same folder) | icx |
| Dual-NIC: one configuration | `scripts/run-dualnic-experiment.sh` | icx |
| Dual-NIC: map NIC → pcm-iio row | `sudo bash utils/discover-pcie-topology.sh` | icx |
| Dual-NIC: tables from results | `python3 scripts/dualnic-results.py summary ~/<sweep>.jsonl` | any |
| Which IOMMU mode a device got | `bash utils/iommu-mode.sh <intf\|nvme dev\|BDF>` | any |
| Reproduce a SOSP'24 figure | `scripts/sosp24-experiments/{flows_exp,ringbuffer_exp,latency_fig7,no_hcc_fig8,hcc_fig8}.sh` | receiver |
| Just move packets, no PCM | `scripts/local/run-traffic.sh` (check first: `preflight.sh`) | icx |
| Survey a machine | `bash scripts/collect-setup-info.sh` | any |

Per-host config lives in `utils/setup-server.sh`, which is **git-ignored**.
Create it from `utils/setup-server.sh.example` (upstream / icx) or
`utils/setup-server.sh.bigserver.example` (bigserver).

---

## 2. Call graphs

`─` calls, `·` sources. Paths are relative to the repo root.

### 2.1 Dual-SSD (bigserver, Skylake-SP)

```
scripts/sosp24-experiments/dualssd_cross_sweep.sh   exec, SWEEP_PREFIX=dualssd-xsweep
scripts/sosp24-experiments/dualssd_bs_sweep.sh      exec, SWEEP_PREFIX=dualssd-bssweep
  │  both only remap arguments, then exec:
  ▼
scripts/sosp24-experiments/dualssd_sweep.sh
 · utils/ssd-lib.sh               ssd_resolve, relaunch_in_tmux (--tmux)
 · utils/setup-server.sh          SSD_SERIALS, SSD_CORES, SSD_PCIE_PATTERN, PCM_*
 ─ utils/iommu-mode.sh <BDF>      puts strict/off/... in the sweep name
 ─ scripts/run-dualssd-experiment.sh       datapath check, then once per point
 ─ scripts/dualssd-results.py summary      → ~/<sweep>.txt
 ─ scripts/dualssd-results.py grid         → ~/<sweep>.txt, only with several
                                             block sizes AND instance counts

scripts/run-dualssd-experiment.sh            one configuration × --runs
 · utils/setup-server.sh, utils/ssd-lib.sh
 ─ utils/iommu-mode.sh <BDF>
 ─ fio (system binary), J instances per drive, always --readonly
 ─ utils/record-host-metrics.sh --pcie 1 --membw 0|1 --pattern "$SSD_PCIE_PATTERN"   (cwd utils/)
 │    ─ sar            → utils/cpu_util.py           → cpu_util.rpt
 │    ─ pcm-iio        reads utils/opCode-6-85.txt from cwd → pcie.csv
 │                     → parse_pciebw_skx (CPU model 85)    → pcie.rpt
 │    ─ pcm-memory     → membw.log → utils/parse_membw.py   → membw.rpt
 │    writes windows.txt (start/end of each measurement window)
 ─ scripts/dualssd-results.py fio-sum --windows   → reports/<exp>-RUN-<j>-ssd<i>/fio.rpt
 ─ scripts/dualssd-results.py dump                → ~/<sweep>.jsonl (or --results)

utils/discover-ssd-pcie.sh                   once per host or after hardware changes
 · utils/setup-server.sh (if present), utils/ssd-lib.sh
 ─ utils/iommu-mode.sh, fio --readonly, pcm-iio with opCode-6-<family>-<model>.txt
 ─ scripts/dualssd-results.py fio-sum
```

Mentioned only in error messages, not called: `run-dualssd-experiment.sh`
names `discover-ssd-pcie.sh` and `setup-server.sh.bigserver.example`;
`record-host-metrics.sh` names `discover-ssd-pcie.sh` and
`discover-pcie-topology.sh`.

### 2.2 Dual-NIC (icx receiver, client over ssh)

```
scripts/sosp24-experiments/dualnic_exp.sh          3 points: NIC0, NIC1, both
scripts/sosp24-experiments/dualnic_load_sweep.sh   offered-load sweep
scripts/sosp24-experiments/dualnic_flow_sweep.sh   flow-count sweep
  │  (flow sweep also: ─ utils/iommu-mode.sh, ─ scripts/dualnic-results.py summary → ~/<sweep>.txt)
  ▼
scripts/run-dualnic-experiment.sh            runs on icx; drives the client over ssh
 · utils/setup-server.sh
 ─ utils/iommu-mode.sh <intf>
 ─ LOCAL  utils/setup-envir.sh               SSH  utils/setup-envir.sh
 ─ LOCAL  utils/tcp/run-netapp-tput.sh -m server  (iperf3 -s)
 ─ SSH    utils/tcp/run-netapp-tput.sh -m client  (iperf3 -c)
 ─ LOCAL  utils/record-host-metrics.sh       pcm-iio reads utils/opCode-6-106.txt from cwd
 ─ scripts/dualnic-results.py dump           → ~/<exp>-<N>.jsonl (or --results)

utils/discover-pcie-topology.sh              NIC → root port → pcm-iio row (PCIE_PATTERN)
 · utils/setup-server.sh (if present)
```

### 2.3 Upstream SOSP'24 figures (receiver drives sender over ssh)

Full trace with what each step does: [KNOWLEDGE-MAP.md §2.4–2.5](KNOWLEDGE-MAP.md#24-control-flow).

```
flows_exp.sh, ringbuffer_exp.sh, no_hcc_fig8.sh ─ run-dctcp-tput-experiment.sh
flows_exp_client.sh                             ─ run-dctcp-tput-experiment-client.sh
hcc_fig8.sh                                     ─ run-dctcp-tput-experiment-hcc.sh ─ utils/set_mba_levels.sh
  each of the three run-dctcp-tput-experiment*.sh:
    ─ utils/setup-envir.sh, utils/tcp/run-netapp-tput.sh, utils/record-host-metrics.sh
    ─ scripts/collect-tput-stats.py              → reports/<exp>/tput_metrics.dat
  every throughput wrapper (these and the pips_* ones below) then
    ─ scripts/report-tput-metrics.py             → stdout

latency_fig7.sh ─ run-dctcp-latency-experiment.sh
                    ─ utils/setup-envir.sh, utils/tcp/run-netapp-tput.sh
                    ─ utils/tcp/run-netapp-lat.sh ─ utils/print_netperf_lat_stats.py
                    ─ scripts/collect-lat-stats.py
                ─ scripts/report-lat-metrics.py

pips_corun.sh, pips_corun_mtu.sh, pips_corun_ring_buffer.sh ─ run-ssd-nic-experiment.sh
pips_corun_randread_client.sh                ─ run-ssd-randread-nic-client-experiment.sh
  both run-ssd-*.sh: same as run-dctcp-tput-experiment.sh, plus
    ─ utils/fio/run-ssdapp.sh, which fills utils/fio/jobfiles/bs_rw_logging.fio

IOVA trace counting: flows_exp.sh, flows_exp_client.sh, pips_corun.sh,
pips_corun_mtu.sh, pips_corun_randread_client.sh ─ sosp24-experiments/count_invalidation.py

utils/record-host-metrics.sh, depending on its flags:
  ─ utils/cpu_util.py (--cpu-util)   ─ utils/print_retx_rate.py (--retx)
  ─ utils/parse_tcplog.py (--tcplog) ─ utils/collect_iio_occ.c, compiled on first use (--iio, Skylake only)
  ─ pcm-iio (--pcie) ─ pcm-memory (--membw) ─ utils/parse_membw.py (--membw) ─ perf (-f)
```

Called but missing from the repo: `sosp24-experiments/clean_logs.sh` and
`/home/benny/restart.sh` ([KNOWLEDGE-MAP.md §4.3](KNOWLEDGE-MAP.md)).

### 2.4 Minimal traffic path (`scripts/local/`)

```
scripts/local/preflight.sh   · _common.sh · config.sh       read-only checks
scripts/local/run-traffic.sh · _common.sh · config.sh
                             ─ SSH scripts/local/_remote-client.sh · _common.sh
```

---

## 3. Shared pieces and who uses them

| File | What it holds | Used by |
|---|---|---|
| `utils/setup-server.sh` (git-ignored) | Per-host config: paths, PCM, interfaces/IPs, client ssh, `SSD_*` | Sourced by nearly every runner and wrapper, `record-host-metrics.sh`, `setup-envir.sh`, `run-netapp-tput.sh`, `run-ssdapp.sh`, both `discover-*.sh` |
| `utils/setup-server.sh.example` | Template for icx | Copied by hand |
| `utils/setup-server.sh.bigserver.example` | Template for bigserver (drive serials, cores, pcm-iio row) | Copied by hand |
| `utils/ssd-lib.sh` | `ssd_resolve`, `iommu_unit`, `relaunch_in_tmux`, `pci_chain`, `bdf_link`, `link_gbps`, `shared_link_gbps`, `csv_col` | `run-dualssd-experiment.sh`, `dualssd_sweep.sh`, `discover-ssd-pcie.sh` |
| `utils/record-host-metrics.sh` | The measurement harness: `sar`, pcm-iio, pcm-memory, netstat, tcplog, IIO occupancy, perf | Every driver: `run-dual{nic,ssd}-experiment.sh`, `run-dctcp-tput-experiment*.sh`, `run-ssd-*.sh` |
| `utils/iommu-mode.sh` | Prints off / pt / strict / lazy / on for an interface, block device or BDF | `run-dual{nic,ssd}-experiment.sh`, `dualnic_flow_sweep.sh`, `dualssd_sweep.sh`, `discover-ssd-pcie.sh` |
| `utils/opCode-6-85.txt` | pcm-iio events, Skylake / Cascade Lake (model 85): paper's VT-d set | pcm-iio, run from `utils/` on bigserver |
| `utils/opCode-6-106.txt` | pcm-iio events, Ice Lake-SP (model 106) | pcm-iio, run from `utils/` on icx |
| `scripts/dualssd-results.py` | `fio-sum`, `dump`, `summary` (plus every PCM value), `grid` | `run-dualssd-experiment.sh`, `dualssd_sweep.sh`, `discover-ssd-pcie.sh` |
| `scripts/dualnic-results.py` | `dump`, `summary` | `run-dualnic-experiment.sh`, `dualnic_flow_sweep.sh` |
| `utils/setup-envir.sh` | MTU, ring, socket buffers, ECN, DDIO, prefetch, PFC | All NIC drivers, locally and over ssh |
| `utils/tcp/run-netapp-tput.sh` | Starts iperf3 servers or clients | All NIC drivers |

**pcm-iio reads `opCode-6-<family>-<model>.txt` from its current directory**,
which is why every caller `cd`s into `utils/` first. Run elsewhere, it silently
falls back to default events and every column shifts.

---

## 4. Every file

### Top level

| File | Role |
|---|---|
| `README.md` | doc: upstream artifact README (kernel build, paper figures) |
| `HANDOFF.md` | doc: testbeds, how to run, results so far, traps, next steps |
| `KNOWLEDGE-MAP.md` | doc: upstream structure, data flow, findings ledger |
| `LOCAL-SETUP.md` | doc: provisioning worksheet for the icx pair |
| `FILE-MAP.md` | doc: this file |
| `fands.patch` | data: the F&S kernel patch |
| `Fast & Safe IO Memory Protection.pdf` | doc: the paper |
| `.gitignore` | the Linux kernel's ignore file plus repo entries; ignores `.*`, `utils/setup-server.sh`, `utils/logs/`, `utils/reports/`, `/dualnic/`, `/dualssd/` |
| `.gitattributes` | pins LF line endings |
| `LICENSE` | upstream license |

### `scripts/`

| File | Role |
|---|---|
| `run-dualssd-experiment.sh` | driver: dual-SSD, one configuration (§2.1) |
| `run-dualnic-experiment.sh` | driver: dual-NIC, one configuration (§2.2) |
| `dualssd-results.py` | called: fio summing, JSONL records, summary and grid tables |
| `dualnic-results.py` | called: JSONL records, summary table |
| `run-dctcp-tput-experiment.sh` | driver: upstream throughput |
| `run-dctcp-tput-experiment-client.sh` | driver: upstream throughput, client-side variant |
| `run-dctcp-tput-experiment-hcc.sh` | driver: upstream throughput with hostCC |
| `run-dctcp-latency-experiment.sh` | driver: upstream latency |
| `run-ssd-nic-experiment.sh` | driver: upstream SSD + NIC co-run |
| `run-ssd-randread-nic-client-experiment.sh` | driver: upstream SSD randread + NIC client co-run |
| `collect-tput-stats.py` | called: `.rpt` files → `tput_metrics.dat` |
| `collect-lat-stats.py` | called: `.rpt` files → `lat_metrics.dat` |
| `report-tput-metrics.py` | called: `tput_metrics.dat` → stdout, misses per page |
| `report-lat-metrics.py` | called: `lat_metrics.dat` → stdout |
| `collect-rdma-tput-stats.py` | orphan |
| `collect-setup-info.sh` | entry: read-only machine survey |

### `scripts/sosp24-experiments/`

| File | Role |
|---|---|
| `dualssd_sweep.sh` | entry: instance sweep; the engine behind the two below |
| `dualssd_bs_sweep.sh` | entry: block-size sweep (wrapper) |
| `dualssd_cross_sweep.sh` | entry: block size × instances (wrapper) |
| `dualnic_exp.sh` | entry: three-point dual-NIC comparison |
| `dualnic_flow_sweep.sh` | entry: dual-NIC flow-count sweep |
| `dualnic_load_sweep.sh` | entry: dual-NIC offered-load sweep |
| `flows_exp.sh` | entry: paper Fig 2 / 5 |
| `flows_exp_client.sh` | entry: Fig 2 / 5, client-side driver |
| `ringbuffer_exp.sh` | entry: Fig 3 / 6 / 9 |
| `latency_fig7.sh` | entry: Fig 7 |
| `no_hcc_fig8.sh` | entry: Fig 8 without hostCC |
| `hcc_fig8.sh` | entry: Fig 8 with hostCC |
| `pips_corun.sh`, `pips_corun_mtu.sh`, `pips_corun_ring_buffer.sh` | entry: SSD + NIC co-run variants |
| `pips_corun_randread_client.sh` | entry: SSD randread + NIC client co-run |
| `count_invalidation.py` | called: counts IOTLB invalidations in an ftrace IOVA log |
| `plot.py`, `plot-pips.py` | manual: matplotlib plots from the reports |
| `README.md` | doc: upstream experiment notes |

### `scripts/local/`

| File | Role |
|---|---|
| `config.sh` | lib: six required values for the minimal path |
| `_common.sh` | lib: `load_config`, `rsh`, `pick_cores`, output helpers |
| `preflight.sh` | entry: read-only checks |
| `run-traffic.sh` | entry: N iperf3 flows, aggregate result |
| `_remote-client.sh` | called over ssh by `run-traffic.sh` |
| `README.md` | doc |

### `utils/`

| File | Role |
|---|---|
| `record-host-metrics.sh` | called: measurement harness (§3) |
| `ssd-lib.sh` | lib: dual-SSD helpers (§3) |
| `iommu-mode.sh` | called/entry: IOMMU mode of a device |
| `discover-ssd-pcie.sh` | entry: SSD → pcm-iio row, VT-d counter check; logs to `utils/logs/discover-ssd-pcie-<date>-<time>/` |
| `discover-pcie-topology.sh` | entry: NIC → pcm-iio row |
| `setup-envir.sh` | called: network and host tuning |
| `setup-envir-qizhe.sh` | orphan: near-copy of `setup-envir.sh` |
| `setup-host.sh`, `setup-bare-metal.sh` | manual: older host setup variants, no caller |
| `setup-server.sh.example`, `setup-server.sh.bigserver.example` | data: config templates (§3) |
| `cpu_util.py` | called: `sar` log → average busy % (12- and 24-hour formats) |
| `parse_membw.py` | called: `pcm-memory` log → per-socket and system MB/s (`NODE n` and `SKT n` formats) |
| `print_retx_rate.py` | called: netstat before/after → retransmit % |
| `print_netperf_lat_stats.py` | called: netperf log → percentiles |
| `parse_tcplog.py` | called: ftrace tcp_probe → CSV |
| `collect_iio_occ.c` | called: IIO occupancy via MSRs, Skylake only; compiled by the harness |
| `set_mba_levels.sh` | called: Intel MBA throttle on (hostCC) |
| `reset_mba_levels.sh` | manual: MBA throttle off |
| `opCode-6-85.txt`, `opCode-6-106.txt` | data: pcm-iio event sets in use (§3) |
| `opCode-85.txt`, `opCode-106.txt`, `opCode-134.txt` | data: upstream's sets under PCM's older file names; not referenced by any script |
| `fio/run-ssdapp.sh` | called: fio for the upstream SSD co-runs (read-only) |
| `fio/jobfiles/bs_rw_logging.fio` | data: fio job template for `run-ssdapp.sh` (`readonly=1`) |
| `tcp/run-netapp-tput.sh` | called: iperf3 servers or clients |
| `tcp/run-netapp-lat.sh` | called: netserver or netperf |
| `tcp/netperf-logging.diff` | data: netperf patch for p99.9 / p99.99 |
| `tcp/README.md`, `README.md` | doc |

---

## 5. Where output lands

| Path | Written by | In git |
|---|---|---|
| `utils/logs/<exp>-RUN-<j>/` | `record-host-metrics.sh` and the drivers: raw `pcie.csv`, `pcm-iio.out`, `membw.log`, `cpu_util.log`, `windows.txt`, fio JSON and per-second IOPS logs | no |
| `utils/reports/<exp>-RUN-<j>[-ssd<i>]/` | parsed `pcie.rpt`, `membw.rpt`, `cpu_util.rpt`, `fio.rpt`, `iperf.bw.rpt`, `retx.rpt` | no |
| `utils/logs/<sweep>/`, `utils/reports/<sweep>/` | sweeps group their runs here (`-E <sweep>/<config>`), plus `sweep.log`, `datapath.jsonl` and, for the dual-SSD sweeps, `failed.txt` | no |
| `utils/logs/<exp>.console.log` | `run-dualssd-experiment.sh`: its full console output | no |
| `~/<sweep>.jsonl`, `~/<sweep>.txt` | `*-results.py dump` / the sweeps' summary step, on the host that ran them | no |
| `/dualssd/`, `/dualnic/` | copies of `~/*.jsonl` / `.txt` brought back for analysis | no (ignored) |
| `/tmp/dualssd-experiment.lock` | `run-dualssd-experiment.sh`: one run at a time | no |

Sweep names never repeat: `<prefix>-<iommu>-<N>` with the first unused `N`
(prefixes `dualssd-sweep`, `dualssd-bssweep`, `dualssd-xsweep`,
`dualnic-flowsweep`). A run whose `-E` name already has output is refused.

---

## 6. Before editing a script

- Each script's header comment is its help text: `-h` prints it with
  `sed -n '2,<N>p'`. If you add lines to a header, update `<N>` (the line
  before `set -u`).
- New scripts need the executable bit in git: `git update-index --chmod=+x <file>`.
- The `.gitignore` ignores every dotfile (`.*`), so a new dotfile needs `git add -f`.
- fio must stay read-only (`--readonly`, `readonly=1`). Drive 0 on bigserver
  holds a filesystem with data, the host is shared, and its other NVMe drives
  (an md RAID) must never be touched (HANDOFF §7).
