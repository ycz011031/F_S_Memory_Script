# Knowledge map

Orientation for this fork: what the original artifact does, how its pieces call
each other, what was added on top, and where the traps are.

- **Upstream:** `host-architecture/Fast-and-Safe-IO-Memory-Protection` (SOSP'24 artifact)
- **This fork:** `ycz011031/F_S_Memory_Script`
- **Branches:** `master` = pristine mirror of upstream · `local-setup` = all local work
- `git diff master local-setup` always shows exactly what was added here.

## Contents

1. [Where do I look for X](#1-where-do-i-look-for-x)
2. [The original repo](#2-the-original-repo)
3. [What was added](#3-what-was-added)
4. [Findings ledger](#4-findings-ledger)
5. [This testbed](#5-this-testbed)
6. [Status](#6-status)

---

## 1. Where do I look for X

| I want to... | Go to |
|---|---|
| Just get packets moving | [scripts/local/](scripts/local/) — no PCM, no kernel patch |
| Reproduce a paper figure | [scripts/sosp24-experiments/](scripts/sosp24-experiments/) |
| Change IPs, cores, paths | [scripts/local/config.sh](scripts/local/config.sh) (new) or the hardcoded blocks in the upstream drivers |
| Understand what F&S changes in the kernel | [fands.patch](fands.patch), and §2.2 below |
| Know what hardware/software I need | [utils/README.md](utils/README.md) and [LOCAL-SETUP.md](LOCAL-SETUP.md) |
| Survey a machine's CPU/NIC/IOMMU | [scripts/collect-setup-info.sh](scripts/collect-setup-info.sh) (new) |
| Find out why a metric is wrong | §4, especially the Ice Lake counter mismatch |
| Tune MTU / ring / DDIO / offloads | [utils/setup-envir.sh](utils/setup-envir.sh) |
| Find where a number came from | §2.5 data flow table |

---

## 2. The original repo

### 2.1 The claim

The IOMMU protects host memory from a misbehaving NIC by translating every DMA
address, and that translation costs throughput. Prior work attacks the **number**
of IOTLB misses. F&S argues the miss count is irreducible under strict protection,
so it attacks the **cost per miss** instead, by keeping page-table walks inside the
IOMMU's page-walk caches. Three changes, all in the Linux kernel:

1. Allocate contiguous IOVAs within each Tx/Rx ring — gives the walker locality.
2. Stop invalidating page-table caches on every unmap; invalidate only when the
   page table structure actually changes.
3. Batch DMA unmaps per descriptor, which the contiguous IOVAs make possible.

### 2.2 The kernel patch

[fands.patch](fands.patch) is against Linux 6.0.3. It splits cleanly along those
three ideas:

| Area | Files | Hunks | Maps to idea |
|---|---|---|---|
| IOVA allocation | `drivers/iommu/iova.c` | 5 | 1 — contiguous IOVAs |
| DMA/IOMMU core | `drivers/iommu/dma-iommu.c` | 9 | 2, 3 — invalidation + batching |
| Intel VT-d | `drivers/iommu/intel/{iommu,dmar}.c` | 2 | 2 — selective invalidation |
| IOMMU generic | `drivers/iommu/iommu.c` | 3 | 2 |
| **mlx5 driver** | `.../mlx5/core/en_rx.c` | **18** | 1, 3 — the Rx datapath |
| mlx5 support | `en.h`, `en/txrx.h`, `en/xdp.c`, `en_main.c` | 5 | 1, 3 |
| Headers | `include/linux/{dma-iommu,dma-mapping,iommu}.h` | 3 | plumbing |
| Build | `Makefile` | 1 | version string |

**The heaviest single file is the Mellanox Rx path.** That is the practical
portability limit: F&S as shipped is a ConnectX/mlx5 result. Another NIC would
need its driver's Rx path ported.

### 2.3 Tree

```
.
├── fands.patch                  the kernel patch (§2.2)
├── Fast & Safe IO Memory Protection.pdf    the paper
├── .gitignore                   <- the LINUX KERNEL's gitignore, not a repo one.
│                                   A fossil from this tree's origin. Ignores `.*`,
│                                   so new dotfiles need an explicit `git add`.
│
├── scripts/                     experiment orchestration
│   ├── sosp24-experiments/      figure wrappers — the entry points
│   │   ├── flows_exp.sh         Fig 2 / 5
│   │   ├── ringbuffer_exp.sh    Fig 3 / 6 / 9
│   │   ├── latency_fig7.sh      Fig 7
│   │   ├── no_hcc_fig8.sh       Fig 8, without hostCC
│   │   ├── hcc_fig8.sh          Fig 8, with hostCC
│   │   └── clean_logs.sh        <- CALLED BY 4 OF THE ABOVE, NOT IN THE REPO
│   ├── run-dctcp-tput-experiment.sh       throughput driver
│   ├── run-dctcp-tput-experiment-hcc.sh   same + hostCC kernel module
│   ├── run-dctcp-latency-experiment.sh    latency driver
│   ├── collect-tput-stats.py    .rpt files -> tput_metrics.dat
│   ├── collect-lat-stats.py     .rpt files -> lat_metrics.dat
│   ├── collect-rdma-tput-stats.py         <- ORPHAN, nothing calls it
│   ├── report-tput-metrics.py   tput_metrics.dat -> stdout
│   └── report-lat-metrics.py    lat_metrics.dat -> stdout
│
└── utils/                       measurement + host configuration
    ├── setup-envir.sh           MTU, ring, sockbuf, ECN, DDIO, prefetch, PFC
    ├── setup-envir-qizhe.sh     <- ORPHAN. Differs in 3 lines: no sudo on
    │                               ddio-bench, and prefetch MSR 0xf vs 1
    ├── record-host-metrics.sh   the measurement harness (sar/PCM/netstat/perf)
    ├── collect_iio_occ.c        IIO occupancy via raw MSRs — SKYLAKE ONLY
    ├── opCode-85.txt            PCM counter defs: Skylake / Cascade Lake
    ├── opCode-106.txt           PCM counter defs: Ice Lake-SP
    ├── opCode-134.txt           PCM counter defs: Snow Ridge
    ├── cpu_util.py              sar log -> average busy %
    ├── print_retx_rate.py       netstat before/after -> retx %
    ├── print_netperf_lat_stats.py   netserver.log -> pandas percentiles
    ├── parse_tcplog.py          ftrace tcp_probe -> csv (cwnd, srtt, ...)
    ├── set_mba_levels.sh        Intel MBA throttle on  (hostCC only)
    ├── reset_mba_levels.sh      Intel MBA throttle off (hostCC only)
    └── tcp/
        ├── run-netapp-tput.sh   spawns iperf3 servers or clients
        ├── run-netapp-lat.sh    spawns netserver or netperf
        └── netperf-logging.diff patch netperf for p99.9/p99.99
```

### 2.4 Control flow

**The driver runs on the RECEIVER and reaches out to the sender over SSH.** This
is the single most important fact about the layout.

```
sosp24-experiments/flows_exp.sh                        <- you run this
 │
 ├─ ./clean_logs.sh                                    [MISSING FROM REPO]
 │
 ├─ run-dctcp-tput-experiment.sh                       <- driver, ON THE RECEIVER
 │   │
 │   ├─ cleanup()
 │   │    ├─ pkill iperf3 / mlc, locally and over ssh
 │   │    ├─ bounce the server interface
 │   │    └─ /home/benny/restart.sh                    [MISSING FROM REPO]
 │   │
 │   ├─ LOCAL   mlc --loaded_latency                   memory contention (optional)
 │   │
 │   ├─ LOCAL   utils/setup-envir.sh
 │   │            ├─ terabit-network-stack-profiling/network_setup.py  (aRFS/TSO/GRO/ring)
 │   │            ├─ ddio-bench/change-ddio-{on,off}
 │   │            ├─ wrmsr 0x1a4           hardware prefetch
 │   │            └─ mlnx_qos              PFC (Mellanox only)
 │   │
 │   ├─ LOCAL   utils/tcp/run-netapp-tput.sh -m server   -> iperf3 -s  xN
 │   ├─ LOCAL   ftrace tracing_on=1                      IOVA logging hook
 │   │
 │   ├─ SSH     setup-envir.sh  +  run-netapp-tput.sh -m client -> iperf3 -c  xN
 │   │
 │   ├─ SSH     record-host-metrics.sh  --pcie 0 --membw 0 --retx 1   (sender)
 │   ├─ LOCAL   record-host-metrics.sh  --pcie 1 --membw 1 -I 1       (receiver)
 │   │
 │   ├─ SCP     client:retx.rpt  ->  local reports/
 │   └─ LOCAL   collect-tput-stats.py    -> tput_metrics.dat
 │
 └─ report-tput-metrics.py                             -> stdout
```

Everything uarch-sensitive — PCM, IOMMU counters, memory bandwidth, MLC — is on
the receiver. The sender only runs iperf3, `sar` and `netstat`. That asymmetry is
why an older sender machine is acceptable, and why the receiver is the one that
needs the IOMMU and the patched kernel.

The latency driver inverts one thing: bulk iperf3 flows go sender→receiver, but
netperf RPCs go **receiver→sender** (`netserver` starts on the client). So the
patched netperf is needed on both machines.

### 2.5 Data flow

Every number in the paper traces back through this chain. Reports live under
`utils/reports/<exp>-RUN-<j>/`, raw logs under `utils/logs/<exp>-RUN-<j>/`
(latency uses `-LATRUN-<j>`).

| Producer | Raw log | Parser | Report | Consumed by |
|---|---|---|---|---|
| iperf3 servers | `iperf.bw.log` | `collect_stats()` greps interval `30.*-60.*` | `iperf.bw.rpt` | `collect-tput-stats.py` |
| `sar -P` | `cpu_util.log` | `cpu_util.py` | `cpu_util.rpt` | `collect-tput-stats.py` |
| `netstat -s` before/after (**sender**) | `retx.log` | `print_retx_rate.py` | `retx.rpt` | scp'd back, then `collect-tput-stats.py` |
| `pcm-iio` | `pcie.csv` | `parse_pciebw()`, awk by **column index** | `pcie.rpt` | `collect-tput-stats.py` |
| `pcm-memory` | `membw.log` | `parse_membw()`, greps NODE 0–3 | `membw.rpt` | `collect-tput-stats.py` |
| `collect_iio_occ` | `iio.log` | — | — | **nothing. Never parsed.** |
| netperf (patched) | `netperf-<size>.lat.log` | `print_netperf_lat_stats.py` | `netperf-<size>.lat.rpt` | `collect-lat-stats.py` |
| ftrace `tcp_probe` | `tcp.trace.log` | `parse_tcplog.py` | `tcp.trace.csv` | manual inspection only |

Then:

```
reports/<exp>-RUN-*/*.rpt  --collect-tput-stats.py-->  reports/<exp>/tput_metrics.dat
                                                             |
                                                  report-tput-metrics.py  -->  stdout
```

`tput_metrics.dat` is a single-row CSV of mean/stddev pairs. With upstream's
`num_runs=1` every stddev is 0, and `report-tput-metrics.py` silently skips the
stddev block when `net_tput_stddev` is falsy.

`report-tput-metrics.py` also does not report raw counters. It divides everything
by an estimated descriptor rate to get **misses per page** — so a wrong throughput
number corrupts every IOMMU metric too.

### 2.6 Experiment catalogue

Three kernel configurations recur: **Linux (IOMMU off)**, **Linux + IOMMU on**,
and **Linux + IOMMU on + F&S**. The first two are stock upstream 6.0.3 — no patch
needed. Only the third (and the Fig 9 "preserve-only" variant) needs a build.

| Wrapper | Figure | Sweeps | Needs the patch? |
|---|---|---|---|
| `flows_exp.sh` | 2 / 5 | 5, 10, 20, 40 flows | Fig 2 no · Fig 5 yes |
| `ringbuffer_exp.sh` | 3 / 6 / 9 | ring 2048→256 | Fig 3 no · 6, 9 yes |
| `latency_fig7.sh` | 7 | RPC 128B→32KB under load | baseline bars no |
| `no_hcc_fig8.sh` | 8 | MLC cores none/1/2/3 | no |
| `hcc_fig8.sh` | 8 | same, + hostCC module | no, but needs hostCC built |

Part (e) of Figs 2/3/5/6 (IOVA locality) is **not reproducible from this repo** —
it needs a separate logging kernel the authors did not ship.

---

## 3. What was added

### 3.1 Why

The upstream drivers couple "move packets" to Intel PCM, MLC, ddio-bench, the
terabit profiling repo, `mlnx_qos`, ftrace, `sshpass`, and a `restart.sh` that is
not in the repo. Any one of those missing means no traffic and no clear reason
why. The additions separate *can these two boxes move packets* from *is the
measurement apparatus correct*.

### 3.2 `scripts/local/` — the minimal path

```
config.sh           six required values; everything else defaulted
_common.sh          shared: load_config, rsh, pick_cores, output helpers
preflight.sh        READ-ONLY validation. Changes nothing.
run-traffic.sh      the driver
_remote-client.sh   sender side, invoked over ssh — not run by hand
README.md           usage
```

```
run-traffic.sh                                  <- ON THE ICE LAKE
 │
 ├─ _common.sh :: load_config       resolve REPO_DIR, verify the six values
 ├─ _common.sh :: pick_cores        NUMA-local to the NIC, skip core 0 and HT siblings
 │
 ├─ [optional] apply tuning         MTU / ring / sockbuf, plain ip+ethtool+sysctl
 │                                  gated behind APPLY_NET_TUNING, default OFF
 │
 ├─ LOCAL   iperf3 -s xN  (taskset, --one-off)
 ├─ LOCAL   ss -ltn                 confirm all N receivers actually bound
 ├─ LOCAL   sar -P                  receiver CPU, if sysstat is present
 │
 ├─ SSH  -> _remote-client.sh                   <- ON THE BROADWELL
 │            ├─ pick_cores         same NUMA logic, remote NIC
 │            ├─ iperf3 -c xN --json
 │            └─ python3            sum -> FLOW/FLOWS_OK/TOTAL_GBPS/RETRANSMITS
 │
 └─ report   Gbps, flows, retransmits, link utilisation, CPU
             + an explicit warning below 70% utilisation
```

Design choices that deliberately depart from upstream:

| Choice | Upstream | Here | Why |
|---|---|---|---|
| First-run system changes | always tunes | `APPLY_NET_TUNING=0` | isolate connectivity from tuning |
| Congestion control | `dctcp` | `cubic` | DCTCP needs switch ECN marking; without it, it underperforms in ways that mimic a host bug |
| MTU | 4000 | 1500 | 4000 needs end-to-end jumbo frames or traffic blackholes |
| Core pinning | hardcoded `4,8,12,16,20` | auto, NUMA-local | those core IDs may not exist on either machine |
| Throughput measurement | grep an iperf3 log for `30.*-60.*` | `--json`, sum `sum_received` | the grep is positional and silently yields empty |
| SSH | `sshpass -p benny` | keys, `BatchMode=yes` | no plaintext password; fail fast instead of hanging |
| Auth failure | hangs on a prompt | preflight rejects it | `screen`+`sudo` over ssh has no TTY |

### 3.3 Survey and worksheet

- **[scripts/collect-setup-info.sh](scripts/collect-setup-info.sh)** — read-only,
  9 sections: identity, CPU/NUMA topology, every NIC with driver + speed + ring
  limits + NUMA node, IOMMU state, TCP stack, 16 required tools, expected helper
  repo paths, SSH/sudo readiness. Run on both machines.
- **[LOCAL-SETUP.md](LOCAL-SETUP.md)** — worksheet for what the survey cannot
  infer: SSH identity, path symmetry, `restart.sh` semantics, scope, core budget,
  and the PCM column-layout capture.

### 3.4 Commits on `local-setup`

| Commit | What |
|---|---|
| `254e7e5` | survey script + worksheet |
| `86775c0` | `scripts/local/` minimal traffic path |
| `96510b5`, `0270653` | `.gitattributes` pinning LF endings |

---

## 4. Findings ledger

Ordered by how much damage they do.

### 4.1 Ice Lake VT-d counters are a different event set — silent wrong data

`parse_pciebw()` in [record-host-metrics.sh:158-166](utils/record-host-metrics.sh#L158-L166)
reads IOMMU stats by **hardcoded column index** (`$8`–`$14`), written against
`opCode-85.txt` (Cascade Lake). Ice Lake loads `opCode-106.txt`:

| Slot | opCode-85 (paper) | opCode-106 (Ice Lake) |
|---|---|---|
| 1 | IOTLB Hit | IOTLB **Lookup** |
| 2 | IOTLB Miss | IOTLB Miss |
| 3 | VT-d CTXT **Miss** | Ctxt Cache **Hit** |
| 4 | VT-d L1 Miss | **512G** Cache Hit |
| 5 | VT-d L2 Miss | **1G** Cache Hit |
| 6 | VT-d L3 Miss | **2M** Cache Hit |
| 7 | VT-d Mem Read | **4K** Cache Hit |

Ice Lake reports page-walk-cache *hits by page size*; Cascade Lake reported
*misses by walk level*. Nothing errors — `report-tput-metrics.py ... iommu` prints
"L1/L2/L3 misses" that are really 512G/1G/2M **hits**, inverting the paper's
argument. The grep key `Socket0,IIO Stack 2 - PCIe1,Part0` is also Skylake stack
nomenclature and will likely match nothing on Ice Lake, in which case
[collect-tput-stats.py:103](scripts/collect-tput-stats.py#L103) substitutes zeros.

Silver lining: the Ice Lake event set is arguably *better* for the thesis. F&S
claims walks terminate in the page-table caches; "2M/1G Cache Hit" measures that
directly. Relabel, don't discard.

**Fix:** resolve columns by header name. Needs Part C of `LOCAL-SETUP.md`.

### 4.2 `collect_iio_occ.c` is Skylake-only

[collect_iio_occ.c:22-30](utils/collect_iio_occ.c#L22-L30) hardcodes
`IIO_MSR_PMON_CTL_BASE 0x0A48`, `IIO_PCIE_1_PORT_0_BW_IN 0x0B20` (comment cites
the *Skylake* manual) and VT-d encodings on `ev_sel=0x41`, which selects different
events on Ice Lake. Reads garbage. **Harmless to delete** — `iio.log` is never
parsed; [record-host-metrics.sh:322](utils/record-host-metrics.sh#L322) has the
unfinished TODO. Change `-I 1` to `-I 0`.

### 4.3 Missing files, called but not committed

| File | Called from |
|---|---|
| `scripts/sosp24-experiments/clean_logs.sh` | 4 of the 5 wrappers, line 1 |
| `/home/benny/restart.sh` | `cleanup()` in both tput drivers |

Confirmed absent via `git ls-files`.

### 4.4 Hardcoded testbed identity

`home=/home/benny`, `uname=benny`, `password=benny`, `ssh_hostname=genie04.cs.cornell.edu`,
IPs `192.168.11.116/117`, interface `ens2f1np1` (repeated in all five wrappers),
`taskset -c 31` for PCM, `-c 28` for IIO, `cpu_mask 4,8,12,16,20`, `lat_app_core 20`.
See [run-dctcp-tput-experiment.sh:38-70](scripts/run-dctcp-tput-experiment.sh#L38-L70).

### 4.5 The repo path must match on both machines

`$setup_dir` is computed on the receiver and shipped over SSH as a literal to the
sender ([run-dctcp-tput-experiment.sh:227](scripts/run-dctcp-tput-experiment.sh#L227)).
Different home directories break it.

### 4.6 Passwordless sudo is mandatory on the sender

The remote path is `ssh` → `screen -dmS` → `sudo bash -c`. No TTY, so a sudo
prompt cannot be answered — the load generator silently never starts.

### 4.7 A slow sender masquerades as a fast receiver

These experiments only mean anything with the receiver at line rate. If the
Broadwell cannot fill the link, both IOMMU-on and IOMMU-off curves flatten and
read as "the IOMMU is free" when the regime under test was never reached.
`run-traffic.sh` warns below 70% utilisation. Establish the sender ceiling first.

### 4.8 Smaller traps

- **`parse_membw` assumes 4 sockets** (greps NODE 0–3). Survivable: only
  `Node0_total_bw` is consumed.
- **`num_runs=1`** everywhere, so every stddev is 0 and the stddev block is skipped.
- **Throughput grep is positional** — `collect_stats()` greps `30.*-60.*` against
  an iperf3 log with `-i 30`. Change the interval and it silently yields nothing.
- **Repo-name mismatch** — `utils/README.md` says clone
  `Understanding-network-stack-overheads-SIGCOMM-2021`;
  [setup-envir.sh:146](utils/setup-envir.sh#L146) uses `terabit-network-stack-profiling/`.
- **DDIO control on Ice Lake** — all wrappers leave `ddio=0`, calling
  `change-ddio-off`. ddio-bench documents Haswell–Cascade Lake; Ice Lake-SP moved
  those registers. A silent failure leaves DDIO on and shifts every PCIe number.
- **Orphans** — `collect-rdma-tput-stats.py` and `setup-envir-qizhe.sh` are never
  referenced. The drivers' own `help()` strings still say
  "Usage: run-rdma-tput-experiment", a fossil of the RDMA artifact this was forked from.
- **Kernel `.gitignore`** — ignores `.*`, so new dotfiles need explicit `git add`.
- **`rm netserver.log`** without `-f` in
  [run-netapp-lat.sh](utils/tcp/run-netapp-lat.sh) errors on the first run.

---

## 5. This testbed

| | Receiver / server | Sender / client |
|---|---|---|
| Host | `icx` | `styx-tower` |
| uarch | Ice Lake (PCM model 106) | Broadwell |
| Role | system under test — IOMMU + PCM here | load generator only |
| Test NIC | `enp153s0f0np0` @ 192.168.10.88 | `ens1f1np1` @ 192.168.10.52 |
| Management | `eno1` @ 192.17.103.88/22 | `eno1` @ 192.17.100.255/22 |
| User / path | `yz69` : `~/F_S_Memory_Script` | identical |

**Run everything on `icx`.** It drives `styx-tower` over SSH.

A second shared subnet exists as a fallback: `enp154s0np0` (192.168.100.88) on
icx and `ens1f0np0` (192.168.100.90) on styx-tower. `preflight.sh` prints link
speed for every interface, so compare before committing to one.

SSH is configured over the **management** link so control traffic stays off the
measured path.

---

## 6. Status

**Done**

- Fork created, `master` pushed as a pristine mirror, `local-setup` pushed
- Minimal traffic path written; all five scripts syntax-checked, error paths tested
- Testbed config written for the 192.168.10.0/24 link
- LF endings pinned so scripts survive a Windows-authored round trip

**Next**

1. Run `preflight.sh` on icx, fix what it flags, then `run-traffic.sh`
2. Establish the Broadwell's sender ceiling — raise `NUM_FLOWS` until it plateaus
3. Only then layer measurement back on: build PCM, capture Part C of
   `LOCAL-SETUP.md`, rewrite `parse_pciebw` to resolve by header name
4. With correct counters, run the stock-kernel baselines: boot icx with
   `intel_iommu=off`, then `intel_iommu=on iommu.strict=1`, and run the wrappers
   each time. That is Figs 2, 3, 7 and 8a — the full IOMMU-overhead result,
   with no patched kernel required.
5. Build the F&S kernel only if the baselines show a gap worth closing

**Open questions** — Parts B and C of [LOCAL-SETUP.md](LOCAL-SETUP.md): what
`restart.sh` should do, whether hostCC is in scope, whether MLC is installed, and
the PCM CSV header layout.
