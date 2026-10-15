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
| Dual-SSD through PIPS: the cross sweep + uneven co-runs once per batcher depth/time, TLP log checked in every run | `scripts/sosp24-experiments/dualssd_pips_sweep.sh --cfgs "1:0 8:22"` | bigserver |
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
| PIPS switch: bring-up (enumeration, BAR0, regfile, DMA, DDR, empty log) | `sudo bash scripts/pips/pips-bringup.sh` | PIPS host |
| PIPS switch: one fio run with the TLP log collected from FPGA DDR | `sudo bash scripts/pips/pips-fio-log.sh` | PIPS host |
| PIPS switch: one register / test point / log by hand | `sudo scripts/pips/pips <command>` ([scripts/pips/README.md](scripts/pips/README.md)) | PIPS host |
| PIPS switch: same over JTAG | `source scripts/pips/pips-xsct.tcl` in XSCT | XSCT host |
| PIPS tools: test without hardware | `make -C scripts/pips check` | any Linux |

Per-host config lives in `utils/setup-server.sh`, which is **git-ignored**.
Create it from `utils/setup-server.sh.example` (upstream / icx) or
`utils/setup-server.sh.bigserver.example` (bigserver).

---

## 2. Call graphs

`─` calls, `·` sources. Paths are relative to the repo root.

### 2.1 Dual-SSD (bigserver, Skylake-SP)

```
scripts/sosp24-experiments/dualssd_pips_sweep.sh    once per PIPS batcher setting (--cfgs):
 · scripts/pips/pips-lib.sh       pips_build, pips_find_usp, pips_lock, pips_tag, cfg_of
 ─ scripts/pips/pips cfg set      depth/time/batch_mrd through BAR0; restored at the end
 ─ dualssd_sweep.sh -o <NAME>-<setting> --asy, DUALSSD_ARGS += --pips-log 1
 ─ scripts/dualssd-results.py summary|grid  all settings → ~/<NAME>.txt
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
 with --pips-log 1, per run (· scripts/pips/pips-lib.sh):
 ─ make -C scripts/pips; sudo scripts/pips/pips cfg, log-clear, log-start, log-wait|log-stop, log-dump
 ─ scripts/pips/pips-log-decode.py --rpt          → reports/<exp>-RUN-<j>/pips-log.rpt (status)

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

### 2.5 PIPS switch bring-up (`scripts/pips/`)

Test points and the order to run them: [scripts/pips/README.md](scripts/pips/README.md).

```
scripts/pips/pips-bringup.sh                 enumeration, then the test points
 · scripts/pips/pips-lib.sh       pips_build, pips_find_usp, pips_below, lspci_brief, pips_outdir, pips_lock
 ─ make → scripts/pips/pips       built from pips.c + pips_regs.h on first use
 ─ pips info / cfg / dma / hwtest / log-dump / soak
 ─ scripts/pips/pips-log-decode.py           the smoke recording
 ─ utils/iommu-mode.sh <BDF>                 devices behind the switch

scripts/pips/pips-fio-log.sh                 one fio run with a TLP log
 · scripts/pips/pips-lib.sh       also pips_nvme_below, blk_bdf
 ─ pips info / cfg / dma, log-clear, log-start, log-wait | log-stop, log-dump
 ─ fio (system binary, --readonly)
 ─ scripts/pips/pips-log-decode.py           → log-summary.txt/.json, log.csv
 ─ utils/iommu-mode.sh <dev>

scripts/pips/Makefile  check ─ pips-sim (pips.c + pips_sim.c) ─ scripts/pips/test-sim.sh
                                 ─ pips-log-decode.py, pips-fio-log.sh with a stand-in fio
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
| `scripts/dualssd-results.py` | `fio-sum`, `dump`, `summary` (plus every PCM value, and the PIPS log table), `grid`. Records with a PIPS batcher setting (`pips_batch`) group as `<iommu> <setting>` | `run-dualssd-experiment.sh`, `dualssd_sweep.sh`, `dualssd_pips_sweep.sh`, `discover-ssd-pcie.sh` |
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
| `dualssd_pips_sweep.sh` | entry: the cross sweep with `--asy`, once per PIPS batcher setting, with the switch's TLP log in every run |
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

### `scripts/pips/`

| File | Role |
|---|---|
| `pips-bringup.sh` | entry: enumeration, links, `pips hwtest`, smoke recording, optional soak |
| `pips-fio-log.sh` | entry: one read-only fio run on the NVMe behind PIPS, with the TLP log |
| `pips-lib.sh` | lib: tool build, device discovery below the switch, lspci summary, output folder, run lock, batcher setting names (`pips_tag`). Also sourced by `run-dualssd-experiment.sh` and `dualssd_pips_sweep.sh` |
| `pips.c` | called/entry: the BAR0 tool (`pips`): registers, window, regfile, DMA, log, DDR dumps, `hwtest`, `soak` |
| `pips_regs.h` | data: register map, verbatim from the FPGA repo's `sw_handoff/` |
| `pips-log-decode.py` | called/entry: TLP log (`.bin` or `.gz`) → whole-or-cut status, per-port summary, CSV, JSON, `.rpt` |
| `pips-addr-pattern.py` | manual: TLP logs or sweep log folders → address width, page spread, IOVA reuse, out-stream runs and hold, LRU reuse distance and predicted IOTLB misses; one table line and one JSON line per log. Imports `pips-log-decode.py`'s loader |
| `pips-page-seq.py` | manual: one TLP log → page access sequence run by run, per-drive interleaving, batching what-if (windows regrouped by drive / page), optional set-associative IOTLB simulation, CSV of every TLP. Imports `pips-addr-pattern.py` (`tlp_events`) |
| `pips-mwr-sizes.py` | manual: TLP logs or sweep log folders → per-drive map of MWr payload sizes (DW), with size-free checks of the "≤ 4 DW = completion entry" rule (mixed pages, interrupt after, bytes per entry); summed per sweep / IOMMU / setting / block size; long CSV; `--show` size sequence. Imports `pips-addr-pattern.py` |
| `pips-xsct.tcl` | manual: config register, DMA and log over JTAG (XSCT) |
| `pips_sim.c` | data: BAR0 model for `make check`; never on a testbed |
| `test-sim.sh` | called: by `make check` |
| `Makefile` | builds `pips`; `check` builds `pips-sim` and runs `test-sim.sh` |
| `README.md` | doc: test points, order, expected values |
| `PIO-MANUAL.md` | doc: everything about the PIO, BAR0, regfile, log DMA and TLP log, collected from the FPGA and AXI4-switch repos plus the hardware runs |

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
| `/dualssd/`, `/dualnic/` | copies of `~/*.jsonl` / `.txt` brought back for analysis; `dualssd/` keeps one folder per batch (`1006/`, `1010/`; sweep names repeat across batches) and `dualssd-xsweeps-report.html`, the local copy of the cross-sweep report (HANDOFF §7) | no (ignored) |
| `/tmp/dualssd-experiment.lock` | `run-dualssd-experiment.sh`: one run at a time | no |
| `utils/logs/pips-bringup-<date>-<time>/`, `utils/logs/pips-fio-<date>-<time>/` (or `-o` / `-E` name) | `pips-bringup.sh`, `pips-fio-log.sh`: lspci, dmesg, register readouts, `hwtest.txt`, fio JSON, `log.bin` + its decode | no |
| `/tmp/pips-run.lock`, `/tmp/pips-bar0.lock` | the PIPS scripts and `dualssd_pips_sweep.sh` (one at a time) and the `pips` tool (one BAR0 user at a time) | no |
| `utils/logs/<sweep>/<config>-RUN-<j>/pips-log.bin.gz`, `pips-log-summary.txt/.json`, `pips-cfg.txt`; `utils/reports/<sweep>/<config>-RUN-<j>/pips-log.rpt` | `run-dualssd-experiment.sh --pips-log 1`: each run's TLP log from FPGA DDR, its decode, and its status (FULL, CUT, +DROPS, NO_TRAILER, BAD, FAILED) | no |
| `~/<NAME>.txt`, `~/<NAME>-<setting>.{jsonl,txt}`, `utils/logs/<NAME>/pips-sweep.log` | `dualssd_pips_sweep.sh`: every setting side by side with the log check; one cross sweep per setting | no |
| `scripts/pips/pips`, `scripts/pips/pips-sim` | `make` in `scripts/pips/` | no (ignored) |

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
