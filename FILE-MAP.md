# File map

Which file does what, and which file calls, sources or reads which. Read this
instead of scanning the repo. It covers every tracked file (as of 2026-10-19,
branch `icx-dualnic`), and in §7 the git-ignored analysis tree (`dualssd/`,
`dualnic/`, the report generators) on the machine where results are analysed.

- Testbed state, results and how to run: [HANDOFF.md](HANDOFF.md)
  (§1–6 dual-NIC on icx, §7 dual-SSD on bigserver)
- Background on the upstream artifact and its traps: [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md)
- First-time provisioning of the icx pair: [LOCAL-SETUP.md](LOCAL-SETUP.md)
- PIPS tools, design IDs, the batcher model: [scripts/pips/README.md](scripts/pips/README.md);
  reading one sweep's logs: [scripts/pips/SWEEP-LOGS.md](scripts/pips/SWEEP-LOGS.md);
  the switch itself: [scripts/pips/PIO-MANUAL.md](scripts/pips/PIO-MANUAL.md)

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
| Dual-SSD through PIPS: the cross sweep + uneven co-runs once per batcher depth/time, drain cap off and on, TLP log checked in every run | `scripts/sosp24-experiments/dualssd_pips_sweep.sh --cfgs "1:0 8:22"` | bigserver |
| Dual-SSD: uneven co-runs (one drive LOW, the other HIGH instances) | `--asy` on either sweep above, or `run-dualssd-experiment.sh -J n0,n1` | bigserver |
| Dual-SSD: one configuration | `scripts/run-dualssd-experiment.sh` | bigserver |
| Dual-SSD: find the pcm-iio row, check VT-d counters | `sudo bash utils/discover-ssd-pcie.sh` | bigserver |
| Dual-SSD: tables from results | `python3 scripts/dualssd-results.py summary\|grid ~/<sweep>.jsonl` | any |
| Dual-NIC: NIC0 alone, NIC1 alone, both | `scripts/sosp24-experiments/dualnic_exp.sh` | icx |
| Dual-NIC: sweep flows / offered load | `dualnic_flow_sweep.sh` / `dualnic_load_sweep.sh` (same folder) | icx |
| Dual-NIC through PIPS: the flow sweep once per batcher depth/time, drain cap off and on, TLP log checked in every run | `scripts/sosp24-experiments/dualnic_pips_sweep.sh --cfgs "1:0 8:22"` | NIC host behind PIPS |
| Dual-NIC: one configuration | `scripts/run-dualnic-experiment.sh` (`--pips-log 1` behind PIPS) | icx |
| Dual-NIC: map NIC → pcm-iio row | `sudo bash utils/discover-pcie-topology.sh` | icx |
| NIC host's PCIe path, NIC settings, TCP settings, counters (read-only) | `bash scripts/nic-host-snapshot.sh [IFACE ...]` → `~/nic-snapshot-<host>-<time>.tar.gz` | styx (sender), icx |
| Dual-NIC: tables from results | `python3 scripts/dualnic-results.py summary ~/<sweep>.jsonl` | any |
| Which IOMMU mode a device got | `bash utils/iommu-mode.sh <intf\|nvme dev\|BDF>` | any |
| Reproduce a SOSP'24 figure | `scripts/sosp24-experiments/{flows_exp,ringbuffer_exp,latency_fig7,no_hcc_fig8,hcc_fig8}.sh` | receiver |
| Just move packets, no PCM | `scripts/local/run-traffic.sh` (check first: `preflight.sh`) | icx |
| Survey a machine | `bash scripts/collect-setup-info.sh` | any |
| PIPS switch: bring-up (enumeration, BAR0, regfile, DMA, DDR, empty log) | `sudo bash scripts/pips/pips-bringup.sh` | PIPS host |
| PIPS switch: one fio run with the TLP log collected from FPGA DDR | `sudo bash scripts/pips/pips-fio-log.sh` | PIPS host |
| PIPS switch: one register / test point / log by hand | `sudo scripts/pips/pips <command>` ([scripts/pips/README.md](scripts/pips/README.md)) | PIPS host |
| PIPS switch: which build, which log format | `sudo scripts/pips/pips cfg` (`design_id=`, `log_format=`; design IDs: [scripts/pips/README.md](scripts/pips/README.md) "Design IDs") | PIPS host |
| PIPS switch: same over JTAG | `source scripts/pips/pips-xsct.tcl` in XSCT | XSCT host |
| PIPS switch stopped answering: save the state first | `bash scripts/pips/pips-hang-snapshot.sh` (read-only), then XSCT | PIPS host |
| PIPS tools: test without hardware | `make -C scripts/pips check` | any Linux |
| PIPS design 0x0A06 campaign: every sweep, the pending analysis, one tarball in ~ | `bash scripts/pips/pips-campaign.sh ssd\|nic --tmux` (`--dry-run`: plan, ETA, commands) | bigserver / icx |
| PIPS page batcher status (0x0A06): spills, stuck, MRd wait | `sudo scripts/pips/pips status` (read clears); per sweep `python3 scripts/pips/pips-status-table.py ~/<sweep>.manifest.tsv` | PIPS host |
| PIPS analysis, everything one testbed needs in one run (page order + model, then payload or control by length, both designs) | `bash scripts/pips/pips-analyze.sh ssd\|nic --tmux` | the host with the logs |
| PIPS: page order of one sweep | `bash scripts/pips/pips-seq-grab.sh ssd\|nic` or `--manifest ~/<sweep>.manifest.tsv` | the host with the logs |
| PIPS: one log's page order, arrival order and batcher model | `python3 scripts/pips/pips-page-seq.py LOG --model self,std,sweepc1 --show 200 --port out,arr` | any (needs the log) |
| PIPS: payload or control writes, by TLP length | `python3 scripts/pips/pips-traffic.py [LOG\|DIR ...] [--list FILE]` | any (needs the logs) |
| PIPS: batcher time limits for a depth sweep | `python3 scripts/pips/pips-timeout-pick.py ~/<sweep>-d1t0.jsonl [--fifo 512]` | any (JSONL only) |
| PIPS: rebuild a report page | `cd dualssd/report-gen && py -3 page4.py` (§7) | the analysis machine |

Per-host config lives in `utils/setup-server.sh`, which is **git-ignored**.
Create it from `utils/setup-server.sh.example` (upstream / icx) or
`utils/setup-server.sh.bigserver.example` (bigserver).

---

## 2. Call graphs

`─` calls, `·` sources. Paths are relative to the repo root.

### 2.1 Dual-SSD (bigserver, Skylake-SP)

```
scripts/sosp24-experiments/dualssd_pips_sweep.sh    once per PIPS batcher setting (--cfgs x --caps):
 · scripts/pips/pips-lib.sh       pips_build, pips_find_usp, pips_lock, pips_tag, cfg_of, cap_of,
                                  design_of, pips_idtag, pips_design_ge
 ─ scripts/pips/pips cfg set      depth/time/batch_mrd/cap through BAR0; restored at the end
 ─ dualssd_sweep.sh -o <NAME>-id<XXXX>-<setting> --asy, DUALSSD_ARGS += --pips-log 1
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
 · scripts/pips/pips-lib.sh       runner hooks: pips_identify (preflight; drives behind PIPS
                                  → design ID + setting in the JSONL), pips_run_cfg (per run:
                                  pips-cfg.txt), pips_meta, pips_report
 with --pips-log 1, per run (pips-lib.sh pips_record, pips_collect):
 ─ make -C scripts/pips; sudo scripts/pips/pips cfg, log-clear, log-start, log-wait|log-stop, log-dump
 ─ scripts/pips/pips-log-decode.py --design-id --rpt   → logs/<exp>-RUN-<j>/pips-log-id<XXXX>.bin.gz,
                                                         reports/<exp>-RUN-<j>/pips-log.rpt (status)

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
scripts/sosp24-experiments/dualnic_pips_sweep.sh   once per PIPS batcher setting (--cfgs x --caps):
 · utils/ssd-lib.sh (relaunch_in_tmux), scripts/pips/pips-lib.sh (as dualssd_pips_sweep.sh)
 ─ scripts/pips/pips cfg set      depth/time/batch_mrd/cap through BAR0; restored at the end
 ─ dualnic_flow_sweep.sh -o/-p <NAME>-id<XXXX>-<setting>, DUALNIC_ARGS += --pips-log 1
 ─ scripts/dualnic-results.py summary   all settings → ~/<NAME>.txt
scripts/sosp24-experiments/dualnic_exp.sh          3 points: NIC0, NIC1, both
scripts/sosp24-experiments/dualnic_load_sweep.sh   offered-load sweep
scripts/sosp24-experiments/dualnic_flow_sweep.sh   flow-count sweep (-p PREFIX names its runs;
  │                                                 DUALNIC_ARGS go to the runner)
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
 · scripts/pips/pips-lib.sh       NICs behind PIPS: the same runner hooks as run-dualssd-experiment.sh;
                                  --pips-log 1 records after the senders start, collects after the window

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
 ─ scripts/pips/pips-log-decode.py           the smoke recording, log-smoke-id<XXXX>.bin
 ─ utils/iommu-mode.sh <BDF>                 devices behind the switch

scripts/pips/pips-fio-log.sh                 one fio run with a TLP log
 · scripts/pips/pips-lib.sh       also pips_nvme_below, blk_bdf
 ─ pips info / cfg / dma, log-clear, log-start, log-wait | log-stop, log-dump
 ─ fio (system binary, --readonly)
 ─ scripts/pips/pips-log-decode.py           log-id<XXXX>.bin → log-summary.txt/.json, log.csv
 ─ utils/iommu-mode.sh <dev>

scripts/pips/Makefile  check ─ pips-sim (pips.c + pips_sim.c; PIPS_SIM_DESIGN picks the build)
                             ─ scripts/pips/test-sim.sh
                                 ─ pips-log-decode.py and the three analysis tools on v1 and v2 logs
                                 ─ pips-lib.sh runner hooks, dualssd-results.py, dualnic-results.py
                                 ─ pips-fio-log.sh with a stand-in fio
                                 ─ dualssd_pips_sweep.sh, dualnic_pips_sweep.sh with stand-in sweeps
```

### 2.6 PIPS analysis (`scripts/pips/`, on the host with the logs)

```
scripts/pips/pips-analyze.sh ssd|nic         one run per testbed, both designs, heartbeat
 ─ pips-seq-grab.sh ssd | --manifest F       per sweep (default: the 0x0A04 sweep from utils/logs,
 │                                             the 0x0A05 depth sweep from ~/<sweep>.manifest.tsv)
 │    ─ pips-page-seq.py LOG --json --show --port out,arr --iotlb --model ... --progress   (xargs -P)
 │         · pips-addr-pattern.py (tlp_events) · pips-log-decode.py (detect, load)
 │         model: batcher() = axi4_mwr_batch.v; FIFO by design ID; output = 1 cycle/beat,
 │         +3 per grant, no faster than the uplink (--link gen3x8 drives, gen4x8 NICs)
 │    heartbeat: done/total + each running log's --progress stage, every HEARTBEAT s
 ─ pips-traffic.py --list logs.txt           every log of those sweeps: payload / ring / MSI by
                                               address, the size rule and verdict per kind and design
scripts/pips/pips-timeout-pick.py            · pips-page-seq.py (batcher, parse_setting, fifo_limits)
scripts/pips/pips-mwr-sizes.py, pips-addr-pattern.py   · pips-log-decode.py
scripts/pips/pips-hang-snapshot.sh           read-only state capture when the switch stops answering
scripts/pips/pips-status-table.py            manifests -> each run's pips-status.txt (0x0A06): spills, stuck, MRd wait
```

The 0x0A06 campaign wraps the sweeps and the analysis:

```
scripts/pips/pips-campaign.sh ssd|nic [--tmux] [--dry-run]   phases, ETA, heartbeat, hang handling
 ─ (nic) nic-host-snapshot.sh here and on styx (ssh), before and after
 ─ dualssd_pips_sweep.sh | dualnic_pips_sweep.sh --tag <stamp><phase> --pbs --set ...   per phase
 │    (the runners read `pips status` per run: pips-lib.sh pips_status_collect)
 ─ (switch gone) pips-hang-snapshot.sh, later switch phases skipped
 ─ pips-status-table.py <every manifest>      status.txt/.tsv
 ─ pips-analyze.sh <kind> --sweeps "" --manifest ...   the new sweeps (no model on 0x0a06)
 ─ pips-analyze.sh <kind> [--no-lengths]      the pending 0x0A04/0x0A05 analysis
 ─ tar: ~/pips-campaign-<kind>-<stamp>.tar.gz (results, manifests, runs' small files, analyses)
```

Outputs come back to the analysis machine as tarballs and feed the report
generators in `dualssd/report-gen/` (§7).

---

## 3. Shared pieces and who uses them

| File | What it holds | Used by |
|---|---|---|
| `utils/setup-server.sh` (git-ignored) | Per-host config: paths, PCM, interfaces/IPs, client ssh, `SSD_*` | Sourced by nearly every runner and wrapper, `record-host-metrics.sh`, `setup-envir.sh`, `run-netapp-tput.sh`, `run-ssdapp.sh`, both `discover-*.sh` |
| `utils/setup-server.sh.example` | Template for icx | Copied by hand |
| `utils/setup-server.sh.bigserver.example` | Template for bigserver (drive serials, cores, pcm-iio row) | Copied by hand |
| `utils/ssd-lib.sh` | `ssd_resolve`, `iommu_unit`, `relaunch_in_tmux`, `pci_chain`, `bdf_link`, `link_gbps`, `shared_link_gbps`, `csv_col` | `run-dualssd-experiment.sh`, `dualssd_sweep.sh`, `dualssd_pips_sweep.sh`, `discover-ssd-pcie.sh`; `dualnic_pips_sweep.sh` (`relaunch_in_tmux`) |
| `utils/record-host-metrics.sh` | The measurement harness: `sar`, pcm-iio, pcm-memory, netstat, tcplog, IIO occupancy, perf | Every driver: `run-dual{nic,ssd}-experiment.sh`, `run-dctcp-tput-experiment*.sh`, `run-ssd-*.sh` |
| `utils/iommu-mode.sh` | Prints off / pt / strict / lazy / on for an interface, block device or BDF | `run-dual{nic,ssd}-experiment.sh`, `dualnic_flow_sweep.sh`, `dualssd_sweep.sh`, `discover-ssd-pcie.sh` |
| `utils/opCode-6-85.txt` | pcm-iio events, Skylake / Cascade Lake (model 85): paper's VT-d set | pcm-iio, run from `utils/` on bigserver |
| `utils/opCode-6-106.txt` | pcm-iio events, Ice Lake-SP (model 106) | pcm-iio, run from `utils/` on icx |
| `scripts/dualssd-results.py` | `fio-sum`, `dump`, `summary` (plus every PCM value, and the PIPS log table), `grid`. Records with a PIPS batcher setting (`pips_batch`) group as `<iommu> <setting>`, plus `@<design ID>` when they have one (`off d8t22c1@0a04`); summaries start with a `PIPS design ID:` line | `run-dualssd-experiment.sh`, `dualssd_sweep.sh`, `dualssd_pips_sweep.sh`, `discover-ssd-pcie.sh` |
| `scripts/dualnic-results.py` | `dump`, `summary` (with the PIPS log table). Groups like `dualssd-results.py` | `run-dualnic-experiment.sh`, `dualnic_flow_sweep.sh`, `dualnic_pips_sweep.sh` |
| `scripts/pips/pips-lib.sh` | PIPS device lookup, `pips_tag`/`cap_of`/`design_of`/`pips_idtag`, and the runner hooks (`pips_identify`, `pips_run_cfg`, `pips_record`, `pips_collect`, `pips_meta`, `pips_report`) | both runners, both PIPS sweeps, `pips-bringup.sh`, `pips-fio-log.sh` |
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
| `.gitignore` | the Linux kernel's ignore file plus repo entries; ignores `.*`, `utils/setup-server.sh`, `utils/logs/`, `utils/reports/`, `/dualnic/`, `/dualssd/`, `claude.md` (local Claude Code instructions and pointers) |
| `.gitattributes` | pins LF line endings |
| `LICENSE` | upstream license |

### `scripts/`

| File | Role |
|---|---|
| `run-dualssd-experiment.sh` | driver: dual-SSD, one configuration (§2.1) |
| `ssd-irq-placement.sh` | manual / called by `pips-campaign.sh ssd`: for `SSD_CORES`, each fio core's queue and completion-interrupt CPU per drive; `--check` fails when both drives complete on one CPU or fio runs on an interrupt CPU (the 10-25 soft lockups). Run after every reboot |
| `run-dualnic-experiment.sh` | driver: dual-NIC, one configuration (§2.2) |
| `nic-host-snapshot.sh` | manual, read-only, on the host itself: each NIC's PCIe path to its root port (link status and capability, raw Gbps, MPS/MRRS, relaxed ordering, RCB), the kernel's "available PCIe bandwidth" lines, NIC settings (pause, offloads, channels, rings, coalescing, mlnx_qos, qdisc, IRQ CPUs), TCP sysctls, counters (`ethtool -S`, `nstat`); prints a summary → `~/nic-snapshot-<host>-<time>.tar.gz`. For styx's shared card (HANDOFF §8 item 13) |
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
| `dualssd_pips_sweep.sh` | entry: the cross sweep with `--asy`, once per PIPS batcher setting (`--cfgs` x `--caps`, the drain cap off and on), with the switch's TLP log in every run |
| `dualnic_exp.sh` | entry: three-point dual-NIC comparison |
| `dualnic_flow_sweep.sh` | entry: dual-NIC flow-count sweep; `-p PREFIX` and `DUALNIC_ARGS` for `dualnic_pips_sweep.sh` |
| `dualnic_pips_sweep.sh` | entry: the flow sweep once per PIPS batcher setting (`--cfgs` x `--caps`), with the switch's TLP log in every run |
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
| `pips-lib.sh` | lib: tool build, device discovery below the switch, lspci summary, output folder, run lock, batcher setting names (`pips_tag`, `c1` for the drain cap; from 0x0A06 `p1 o1 q<N> w<N>`, `pb_of`, `pips_tag_of <readout>`), design ID tags (`design_of`, `pips_idtag`), the runner hooks (from 0x0A06 `pips status` at each run's start and after its window, `pips_status_collect` → `pips-status.txt`, `pips_stat_*` in the `.rpt`; from 0x0A07 `pips_bp_start`/`pips_bp_stop`: `pips counters` every `PIPS_BP_EVERY` (2) s in the background → `pips-bp.tsv`, `pips_bp_summary` → `pips_stat_bp_*` refused shares; rate caps in `pb_of` and the tag `r<a>x<b>x<c>`), and the sweep identity (`pips_sweep_begin`: sweep ID and manifest; per run `sweep-id.txt`, a manifest row, `pips_sweep_id`). Also sourced by both runners and both PIPS sweeps |
| `pips.c` | called/entry: the BAR0 tool (`pips`): registers, window, regfile (with the drain cap, design ID, log format; from 0x0A06 reg2/reg3 `pb= pushoff= quantum= thr=` and `status`; from 0x0A07 reg4 `rcap= rcap0= rcap1= rcapout=` and `counters`), DMA, log, DDR dumps, `hwtest`, `soak` |
| `pips_regs.h` | data: register map, from the FPGA repo's `sw_handoff/` (design 0x0a04) and `pips_batch_ctrl.v` (0x0A06 page batcher) |
| `pips-log-decode.py` | called/entry: TLP log (`.bin` or `.gz`) → whole-or-cut status, per-port summary, CSV, JSON, `.rpt`. Record format v1 or v2 by design ID (`--design-id`, `-id<XXXX>` in the name, `pips-cfg.txt` beside it, else v1); `detect()`/`load()` serve the three tools below |
| `pips-addr-pattern.py` | manual: TLP logs or sweep log folders → address width, page spread, IOVA reuse, out-stream runs and hold, LRU reuse distance and predicted IOTLB misses; one table line and one JSON line per log. Imports `pips-log-decode.py`'s loader |
| `pips-page-seq.py` | manual: one TLP log → page access sequence run by run, per-drive interleaving, batching what-if (windows regrouped by drive / page / ideal, on the output and on the arrival order), optional set-associative IOTLB simulation, CSV of every TLP. v2 logs: the arrival order rebuilt from `pkt_wait` (stream `arr`), and `--model` runs the `axi4_mwr_batch.v` batcher on it (groups self, std, sweep, sweepc1, deep, each with an optional `fBEATS` FIFO size; or any `dDtT[m1][c1][fBEATS]`), counting what asked for each drain. Output timing: 1 cycle per beat, `--grant-gap` (3) per new drain, no faster than `--link` (gen3x8 drives, gen4x8 NICs); FIFO size from the design ID (`--fifo`). `self` on a page batcher log drops `p1 o1 q w r` fields (left out on `p1` logs). `--progress` prints stages to stderr. `--kind nic` (default for `dualnic` paths): 16 DW writes are the completions, a packet's visit ends at its short last TLP. Imports `pips-addr-pattern.py` (`tlp_events`) |
| `pips-seq-grab.sh` | manual, on the host with the logs: `ssd`/`nic` → `pips-page-seq.py --json --show` on one log per point and batcher setting of a sweep (default the 0x0A04 sweeps, every point), with both orders and the batcher model (default `self,std,sweep,sweepc1,sweepc1f512`; on a manifest the sweep's settings and the other build's FIFO; on a 0x0A06+ sweep none unless `--model` or `PIPS_PB_MODEL`), packed as `~/seq-<sweep>.tar.gz`; `--manifest` takes exactly one sweep's runs. A line per log and a heartbeat (`HEARTBEAT` s) with each running log's stage. Calls `pips-page-seq.py` |
| `pips-timeout-pick.py` | manual: a sweep's results JSONL → per depth, the time threshold the depth trigger can beat, from synthetic per-input arrivals run through `pips-page-seq.py`'s batcher (`--eval` given settings, `--validate` against the logged waits). Imports `pips-page-seq.py` |
| `pips-mwr-sizes.py` | manual: TLP logs or sweep log folders → per-drive map of MWr payload sizes (DW), with size-free checks of the "≤ 4 DW = completion entry" rule (mixed pages, interrupt after, bytes per entry); summed per sweep / IOMMU / setting / block size; long CSV; `--show` size sequence. Imports `pips-addr-pattern.py` |
| `pips-traffic.py` | manual: every TLP log under `utils/logs` (or the paths given, or `--list FILE`), either format, drives and NICs → per device: writes classed by address behaviour (ring entries, payload bursts, MSI), the size rule that splits them and how reliable it is, payload-length motifs per completion, time in the batcher per class (v2); a progress line per log, tables summed per kind / design / IOMMU / setting, CSV, JSONL. Labels sweeps named `-<N>` or by tag (`dsweep1`). Imports `pips-log-decode.py` |
| `pips-xsct.tcl` | manual: config and drain registers, design ID, DMA and log over JTAG (XSCT) |
| `pips-analyze.sh` | manual, on the host with the logs: everything the report needs from one testbed in one run: `pips-seq-grab.sh` on each sweep (default the 0x0A04 sweep and the 0x0A05 depth sweep by its manifest), then `pips-traffic.py --list` over all their logs (payload or control by length, per design), with liveness lines, into `~/pips-analyze-<kind>-<date>.tar.gz`. Calls both |
| `pips-campaign.sh` | entry, on bigserver / icx: the design 0x0A06/0x0A07 campaign (§2.6): every phase as a PIPS sweep, hang handling, the new (with `PIPS_PB_MODEL`, default `self,sweepc1,sweepc1f512`) and the pending analysis, one tarball `~/pips-campaign-<kind>-<stamp>.tar.gz`. `--minimal`: the 0x0A07 rerun (HANDOFF §8 "0x0A07 minimal rerun"). `--dry-run` prints the plan, ETA and commands |
| `pips-status-table.py` | manual / called by `pips-campaign.sh`: sweep manifests → each run's page batcher status (`pips-status.txt`): overflow spills, stuck, longest MRd wait, and from 0x0A07 the refused share per input (`pips-bp.tsv`); flags, worst per setting, `--tsv` |
| `pips-hang-snapshot.sh` | manual, when the switch stops answering, before reprogramming: read-only capture of the Xilinx/Mellanox functions and the bridges above them (`lspci -vvv`, AER counters), `pips cfg`, the kernel log, `devlink health`, the newest sweep log → `~/pips-hang-<host>-<time>.tar.gz` |
| `pips_sim.c` | data: BAR0 model for `make check`, any design (`PIPS_SIM_DESIGN`); never on a testbed |
| `test-sim.sh` | called: by `make check` |
| `Makefile` | builds `pips`; `check` builds `pips-sim` and runs `test-sim.sh` |
| `README.md` | doc: test points, order, expected values |
| `SWEEP-LOGS.md` | doc: how to read one PIPS sweep's logs and nothing else: sweep ID, manifest format, rules for a parser, names, the 10-17 depth sweep, earlier runs to ignore |
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
| `/dualssd/`, `/dualnic/` | copies of `~/*.jsonl` / `.txt` and the analysis tarballs brought back for analysis, one folder per batch (MMDD; sweep names repeat across batches), the report generators and the built pages: §7 | no (ignored) |
| `/tmp/dualssd-experiment.lock` | `run-dualssd-experiment.sh`: one run at a time | no |
| `utils/logs/pips-bringup-<date>-<time>/`, `utils/logs/pips-fio-<date>-<time>/` (or `-o` / `-E` name) | `pips-bringup.sh`, `pips-fio-log.sh`: lspci, dmesg, register readouts (`cfg*.txt` with `design_id=`), `hwtest.txt`, fio JSON, `log-id<XXXX>.bin` / `log-smoke-id<XXXX>.bin` + its decode | no |
| `/tmp/pips-run.lock`, `/tmp/pips-bar0.lock` | the PIPS scripts and both PIPS sweeps (one at a time) and the `pips` tool (one BAR0 user at a time) | no |
| `utils/logs/<sweep>/<config>-RUN-<j>/pips-log-id<XXXX>.bin.gz` (`pips-log.bin.gz` before design IDs), `pips-log-summary.txt/.json`, `pips-cfg.txt`; `utils/reports/<sweep>/<config>-RUN-<j>/pips-log.rpt` | `run-dualssd-experiment.sh --pips-log 1`: each run's TLP log from FPGA DDR, its decode, and its status (FULL, CUT, +DROPS, NO_TRAILER, BAD, FAILED) with `design_id:`. `pips-cfg.txt` is written whenever the drives are behind PIPS | no |
| `utils/logs/<exp>-RUN-server-<j>/pips-log-id<XXXX>.bin.gz`, ...; `utils/reports/<exp>-RUN-server-<j>/pips-log.rpt` | `run-dualnic-experiment.sh --pips-log 1`: the same, per dual-NIC run | no |
| `~/<NAME>.txt`, `~/<NAME>-id<XXXX>-<setting>.{jsonl,txt}`, `utils/logs/<NAME>/pips-sweep.log`, `cfg-<setting>.txt` | `dualssd_pips_sweep.sh`, `dualnic_pips_sweep.sh`: every setting side by side with the log check (first lines name the design ID); one cross / flow sweep per setting. Before design IDs: `~/<NAME>-<setting>.*` | no |
| `scripts/pips/pips`, `scripts/pips/pips-sim` | `make` in `scripts/pips/` | no (ignored) |
| `~/<NAME>.manifest.tsv`, `utils/logs/<NAME>/manifest.tsv`, `.../sweep-id.txt` | both PIPS sweeps (from 10-17): every run of the sweep with its setting, point, folders, TLP log and status; parse a sweep only through it (SWEEP-LOGS.md) | no |
| `~/seq-<sweep>/` + `.tar.gz` | `pips-seq-grab.sh`: `seq-<setting>-<point>.txt` (report + listings), `seq.jsonl` (one line per log: interleave, what-ifs, `windows_arr`, `model[]`, `link` (`fitted`, `rate_given`), `fifo`, `grant_gap`, `arrival` (`lost`: share of the log's time missing from the logged output, `link_fit`, `held`)), `calibrate.txt` (the uplink fit per log, `segments lost fit clean`; the median of the clean ones is every log's `--link-rate`, also in `manifest.txt`), `manifest.txt` | no |
| `~/pips-analyze-<kind>-<date>/` + `.tar.gz` | `pips-analyze.sh`: `seq-<sweep>/` per sweep, `logs.txt`, `traffic.txt/.jsonl`, `traffic-sizes.csv`, `analyze.log` | no |
| `~/pips-hang-<host>-<time>/` + `.tar.gz` | `pips-hang-snapshot.sh` | no |
| `~/pips-campaign-<kind>-<stamp>/` + `.tar.gz` | `pips-campaign.sh`: `campaign.log`, `plan.txt`, `notes.txt`, `README.txt`, `results/` (each sweep's `.txt`, `.manifest.tsv`, per-setting `.jsonl/.txt`), `sweeplogs/<name>/`, `runs/` (each run's `pips-cfg.txt`, `pips-status*.txt`, `pips-bp.tsv`, `pips-log-summary.*`, `.rpt`s), `status.txt/.tsv`, `analyze-new/`, `analyze-pending/`, `snapshots/`. Unpack in `dualssd/<MMDD>/` or `dualnic/<MMDD>/` | no |
| per run (from 0x0A06): `utils/logs/<run>/pips-status-before.txt`, `pips-status.txt`; from 0x0A07 `pips-bp.tsv` (refused-cycle counters every 2 s); NIC runs also `nstat-client.txt`, `ethtool-{srv,cli}-nic<i>-{before,after}.txt`, `utils/reports/<run>/retx-client.rpt`, `nicstats-nic<i>.rpt` | the runners (`pips-lib.sh`, `run-dualnic-experiment.sh`) | no |
| `~/traffic*.txt/.jsonl/.csv` | `pips-traffic.py` run by hand (10-16: `traffic-ssd.txt`, `traffic-nic.txt`) | no |

Sweep names never repeat: `<prefix>-<iommu>-<N>` with the first unused `N`
(prefixes `dualssd-sweep`, `dualssd-bssweep`, `dualssd-xsweep`,
`dualnic-flowsweep`, `dualssd-pips`, `dualnic-pips`; the PIPS sweeps' settings
add `-id<XXXX>-<setting>`). A dual-SSD run whose `-E` name already has output
is refused; a dual-NIC run's is replaced, which is why the dual-NIC PIPS sweep
names its runs after each setting (`-p`).

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
- Scripts that run for hours print liveness: a line per unit of work and a
  periodic heartbeat (see `pips-seq-grab.sh`, `pips-analyze.sh`).

---

## 7. The local analysis tree (git-ignored)

Results are copied from the hosts to the machine where they are analysed
(here: the Windows checkout) into `dualssd/` and `dualnic/`, both ignored
by git. One folder per batch, named by the date the copy was made (MMDD);
sweep names repeat across batches, so the folder says which. Raw TLP logs
stay on the hosts; only results, grabs and reports come back.

### `dualssd/` (drives, bigserver)

| Folder / file | Holds | Design, sweep | Read by |
|---|---|---|---|
| `1006/` | `dualssd-sweep-*`, `-bssweep-*`, `-xsweep-*` JSONL/TXT, IOMMU off and strict, no switch | — (direct, then designs A-D) | HANDOFF §7; the cross-sweep page |
| `1010/` | `dualssd-xsweep-{off,strict}-*` on switch designs C/D | design D | HANDOFF §7 "Fifth result" |
| `1013/` | `dualssd-pips-{off,strict}-1-<setting>` (4 settings), `addr-pattern-1013.jsonl`, `iotlb-fit-1013.jsonl`, `seq-1013*.jsonl`, `seq-*.txt` | `0x0A02`, 10-13 | `report-gen/build.py` (0x0A02 page) |
| `1016/` | `dualssd-pips-strict-1-id0a04-<setting>` (8: cap off/on), `traffic-ssd.*`, `seq-dualssd-pips-strict-1-id0a04/` (first grab, 7 points), `seq-dualssd-0a04-arr/` (regrab, all 90 points, arrival order + model before the uplink fix) | `0x0A04`, 10-15/16 | `report-gen/load4.py`, `build4.py`, `seq4.py`, `seqarr.py` |
| `1019/` | `dualssd-pips-strict-dsweep1-id0a05-<setting>` (8 depths, cap on), `dualssd-pips-strict-dsweep1.txt`; `pips-analyze-ssd-20261019-1723/` (+ `.tar.gz`): the 10-19 analysis of both drive sweeps (`seq-dualssd-pips-strict-1-id0a04/`, `seq-dualssd-pips-strict-dsweep1/`, 720 logs each; `traffic.txt` = payload or control by size, verdicts per design at its end). Its page-order model is unusable (HANDOFF §8 item 11); the lengths stand | `0x0A05`, depth sweep 10-17/18 (and the 0x0A04 sweep's reanalysis) | `report-gen/a05.py`; `sizes.py` reads its `traffic.jsonl` (Table 11) |
| `1026/` | `pips-campaign-ssd-c10251425/` (+ `.tar.gz`): the 0x0A06 drive campaign: `results/` (each sweep's `.txt`, `.manifest.tsv`, per-setting `.jsonl`), `runs/` (per-run cfg/status/rpt), `status.txt/.tsv`, `analyze-new/` (page order of all 828 logs, `traffic.txt`), `analyze-pending/` (0x0A04/0x0A05 model rerun), `campaign.log`, `plan.txt`, `irq-placement.txt`; `c1026-ssd.txt` (the tables) | `0x0A06`, 10-25/26 | `report-gen/c1026.py`; HANDOFF §8 "0x0A06 campaign results" |
| `report-gen/` | the page generators (below) | | |
| `seqdata/<kind>/<point>.json` | per-point data for the 0x0A04–0x0A05 page's Figures 3-6 (`seqarr.export`), published beside the page as `seq/<kind>/` | | the page (fetch) |
| `dualssd-pips-0a04-report.html` | "PIPS 0x0A04–0x0A05 Sweeps", https://claude.ai/artifact/MbNxzaJ5KgmuM59PPC4NcA | | |
| `dualssd-pips-0a06-report.html` | "PIPS 0x0A06 Campaign", https://claude.ai/artifact/L3U8deVtMb4nHmb91AscK3: hand-written, numbers copied from `1026/c1026-ssd.txt` and `dualnic/1026/c1026-nic.txt` into its inline script; republish the file as is. v2 adds the page-order section (Figures 6-9), spliced in by `page6.py` between `<!--SEQ6-BEGIN-->` and `<!--SEQ6-END-->`; publish with the 52 `seq6/<kind>/*.json` as `seq/<kind>/` | `0x0A06`, 10-25/26 | `c1026.py` (tables), `seqrec6.py` + `page6.py` (Figures 6-9) |
| `seq6/` | `index.json` and `<kind>/<point>.json` (40 drive, 12 NIC points: each log's listing rows, recorded, and for pb0 logs the model, floor, raw lines) | `0x0A06` | `report-gen/seqrec6.py --export` |
| `dualssd-pips-tlp-report.html` | "PIPS TLP Patterns", https://claude.ai/artifact/Ni2PkBjsera7xFxx6wJdF2 (v5, 10-26): the averaged page-order summary of 0x0A04, 0x0A05 and 0x0A06, one chart per drive block size and two for the NICs, uncapped and capped at 50 Gbps (0x0A06 only) (recorded marks per design and setting; lines from the measured arrival order: raw, the host's batcher model at FIFO 128/512 or pooled, floor; only the points all three designs ran), and a table of the model's own-setting checks; self-contained | `0x0A04`-`0x0A06` | `report-gen/sumpage.py` |
| `dualssd-pips-tlp-viewer.html` | local only: v1-v2 of that artifact (pages per I/O and the listing viewer for 0x0A04/0x0A05); needs `tlpdata/` beside it as `tlp/` | `0x0A04`, `0x0A05` | `report-gen/tlpdump.py` |
| `tlpdata/` | `summary.json` (one row per log) and `<kind>/<design>-<setting>.json` (30 bundles, ~71 MB: every point's listings as arrays), published as `tlp/<kind>/`; the `.json.gz` files beside them are a first attempt (artifacts serve no `.gz`) and can be deleted | | `tlpdump.py` |
| `dualssd-pips-report.html` | "PIPS Batcher Sweeps" (0x0A02), https://claude.ai/artifact/XsrLugEhsaMzY6vwARSLGU | | |
| `dualssd-xsweeps-report.html` | "Dual-SSD Cross Sweeps" (designs A-D), https://claude.ai/artifact/AcYH8Ff2Drt5kon44un3gX; its generator was not kept | | |

### `dualnic/` (NICs, icx)

| Folder / file | Holds | Design, sweep | Read by |
|---|---|---|---|
| `1001/` | `dualnic-flowsweep-{off,strict}-*` (09-29, no switch) | — | HANDOFF §4.1; `build4.py` table10 (09-29 comparison) |
| `1016/` | `dualnic-pips-strict-1-id0a04-<setting>` (8), `traffic-nic.*`, `seq-dualnic-pips-strict-1-id0a04/` (first grab), `seq-dualnic-0a04-arr/` (regrab, 12 points, before the uplink fix) | `0x0A04`, 10-15/16 | `load4.py`, `build4.py`, `seq4.py`, `seqarr.py` |
| `1019/` | `dualnic-pips-strict-dsweep1-id0a05-<setting>` (6 settings ran), `.manifest.tsv`, `jounalctl.txt` (the kernel log of the switch's stop); `pips-analyze-nic-20261019-1723/` (+ `.tar.gz`): the 10-19 analysis, 0x0A04 sweep only (`seq-dualnic-pips-strict-1-id0a04/`, 96 logs, model matches; `traffic.txt`, read by `sizes.py`) | `0x0A05`, depth sweep 10-17 | `a05.py`; HANDOFF §8 "0x0A05 depth sweep" item 7, "0x0A04 results" item 11 |
| `1026/` | `pips-campaign-nic-c10251157/` (+ `.tar.gz`): the 0x0A06 NIC campaign, same layout as the drives' (14 sweeps incl. `alone*`, `hw*`, `wire*`; `snapshots/` of icx and styx); `c1026-nic.txt` (the tables) | `0x0A06`, 10-25/26 | `c1026.py`; HANDOFF §8 "0x0A06 campaign results" |

### `dualssd/report-gen/` (the generators; `README.txt` there has the commands)

| File | Role |
|---|---|
| `page4.py` | entry: writes `dualssd-pips-0a04-report.html` from `template4.html`, filling `{{SLOTS}}` from the modules below; prints the quoted numbers. Move the HTML to `dualssd/` and publish with the `seq/<kind>/*.json` files |
| `template4.html` | the 0x0A04–0x0A05 page: CSS, prose, slots; the explorer JS |
| `load4.py` | loaders: `dualssd/1016`, `dualnic/1016` JSONL (0x0A04) |
| `build4.py` | 0x0A04 figures and tables: cap heatmaps (Figure 1), link split, waits, pcm-iio samples, NIC heatmap (Figure 2), icx PCM, 09-29 comparison |
| `seq4.py` | Tables 6-7 (page order as sent, first grab) |
| `seqrec.py` | page order recovered from the 10-19 grabs' listings (no raw logs): each device's own order, the batcher model on it with I/O bursts and an output rate fitted to each log's wait, the window ideal, the check; `py -3 seqrec.py --write` (~15 min, 8 processes) caches `seqrec.json`, prints the checks (`seqrec-check.txt`) |
| `seqarr.py` + `seqarr.js` | Figures 3-6: per-point data files (listing as sent, recorded, seqrec's lines for both FIFOs), the bullets under Figures 4 and 6 (`order_points()`), the TL;DR numbers; JS draws each device's own order and the lines averaged over each point's logs (both designs' for the drives) |
| `deep4.py` + `deep/` | Figure 7, Table 8: time limits per depth, from `pips-timeout-pick.py` output (`pick-*`, `eval-*`, `eval-*-f512` = 0x0A05 FIFO) |
| `a05.py` | the 0x0A05 section: Figure 8 (each depth vs d1t0c1), Table 9 (waits, link split), Table 10 (NICs) |
| `nicorder.py` | not a page part: why one NIC alone splits its packets and two together don't (HANDOFF §8 item 13). Per NIC: rate, wait p50/p99, own order over the whole log (`dualnic/1016` JSONL + the 10-19 grab's headers), and each packet's receive queue from its completion address (the listings); `py -3 nicorder.py > ../../dualnic/1019/nicorder.txt` |
| `c1026.py` | not a page part (yet): the 0x0A06 campaign's tables from `dualssd/1026`, `dualnic/1026` (results JSONL + `analyze-new` seq.jsonl): noise from repeated points, page_batch_en 0 vs 1 per depth and size, knob phases vs main, drive 0 alone, NIC splitting (in0 TLPs per run, pauses, discards); `py -3 c1026.py [ssd|nic]`. Its numbers are copied by hand into `dualssd-pips-0a06-report.html` |
| `seqrec6.py`, `seqarr6.js`, `seq6-section.html`, `page6.py` | the 0x0A06 page's Figures 6-9: `seqrec6.py` runs `seqrec.py`'s batcher model, floor and raw on the pb0 logs of the main sweeps (`dualssd/1026`, `dualnic/1026` `analyze-new/`, FIFO 1536 and 512; caches `seqrec6.json`, prints the checks; under a minute), `--export` writes `../seq6/`; `seqarr6.js` is `seqarr.js` adapted (pb0/pb1 marks, FIFO 1536/512, figure ids f6-f9); `page6.py` splices section + index + JS into the page (and once added tokens, styles, tooltip) |
| `sumpage.py` + `sum-template.html` | the "PIPS TLP Patterns" summary page: recorded page switches per page or packet from `seq.jsonl` (`analyze-pending/` for 0x0A04/0x0A05, `analyze-new/` main for 0x0A06), averaged over the common points; since v5 raw (`windows_arr` w=1) and model (`model`, cap on t255, from the 0x0A04/0x0A05 logs) from the same `seq.jsonl` files, floor from `rawfloor.json` + `seqrec6.json`; `py -3 sumpage.py` writes `../dualssd-pips-tlp-report.html` (`--print` only prints the numbers) |
| `tlpdump.py` + `tlp-template.html` | the TLP pattern page: reads `analyze-pending/` of `dualssd/1026` and `dualnic/1026` (the campaign's rerun of 0x0A04/0x0A05: `seq.jsonl` + each `seq-<setting>-<point>.txt`), writes `dualssd/tlpdata/` and `dualssd/dualssd-pips-tlp-report.html` (template with the summary inlined); `py -3 tlpdump.py` (~20 s). Publish the 30 bundles in two calls (64 MB per publish): 0x0A04 + NICs, then 0x0A05 drives |
| `sizes.py` | the "Payload or control, by size" section: Table 11 and its `SZ*` slots, from the 10-19 analyses' `traffic.jsonl` (`FILES`; add the NICs' 0x0A05 one when it comes) |
| `build.py`, `load.py`, `template.html`, `seqfigs.py`, `seqtabs.py`, `seqruns.json`, `seq14.json`, `seq/` | the 0x0A02 page ("PIPS Batcher Sweeps") from `dualssd/1013` (+1006, 1010); `seq/` holds three small 0x0A02 logs and a CSV it was built from |
