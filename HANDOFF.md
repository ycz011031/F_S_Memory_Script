# Handoff — IOMMU contention testbeds behind the PIPS switch

Everything needed to run the two testbeds (icx: two NICs; bigserver: two NVMe
drives, both behind the PIPS FPGA switch), plus what is known, unknown and broken.
Companion docs: [FILE-MAP.md](FILE-MAP.md) for which script does what and
calls what, [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md) for how the repo fits
together, [LOCAL-SETUP.md](LOCAL-SETUP.md) for first-time provisioning,
[QRH.md](QRH.md) for every script option on one page (keep it in step when
an option is added).

- **Branch:** `icx-dualnic` on `ycz011031/F_S_Memory_Script`
- **Upstream:** `host-architecture/Fast-and-Safe-IO-Memory-Protection` (remote `upstream`)
- `master` is a pristine mirror. `git diff master..icx-dualnic` is the whole delta.
- **Where things are:** [FILE-MAP.md](FILE-MAP.md) for every script, call
  graph and output (§2.6 the PIPS analysis chain), and §7 for the
  git-ignored analysis tree (`dualssd/`, `dualnic/`: which batch folder holds
  which sweep and design, which report generator reads what, the published
  pages). On the Windows analysis machine `claude.md` (git-ignored) adds its
  local paths, tools and editing gotchas.
- **Last updated:** 2026-11-09 (15:30): **icx `nic --bg` (c11091247, started 12:47) stopped
  short the same way**: at 15:15 the first engine-on run (bith16, f5 nic0only RUN-0) gave "the
  engine did not start", the stop file skipped every later engine-on sweep, and the campaign
  ended DONE at 2 h 27. Most likely icx ran the runner from before `ceebe0666` (12:42, the
  30 s / 3-try start below); the run's `bg-cmd.txt` says (try lines = the fix was in). Not
  styx: styx-check said SAFE. Relaunch with `--fresh` (a resume would skip the engine-on
  sweeps). Also: the campaign now syncs styx's repo only when styx's copies of the files it
  runs differ from icx's (`git hash-object`), stops if one still differs after the sync, and
  says when a styx snapshot fails for lack of user disk room.
- **2026-11-09:** **bigserver `ssd --bg` (c11082355) is NOT complete**: it ran
  5 h 27 of ~44 h 30 (`dualssd/1108/`). In each half `pips bg run` gave no output within the
  runner's 5 s start wait, once (native: bnh16 d1t0c1p1w31 8k ssd0only RUN-0, after 14 good
  engine runs; vfio: bvh16f d1t0c1p1w31 4k ssd0only RUN-0, after 2), and that one "did not
  start" wrote the stop file, which skips every later engine-on sweep of the half. So the
  data has no engine-under-load results beyond bnh16's first 7 experiments (15.5 M reads/s,
  0 errors) and bvh16f's first 2. Complete: nprep, nalone, valone (x1, x2, T8b 155 tables),
  census and deep census, and the engine-off sweeps bnoff, bnsoff, bnhoff, bnq128off,
  bnq512off, bvofff/e/t (no failures). **Cause (the host's bg-run.txt of both runs): the
  engine DID start**, at ~5 s, the moment the runner's 5 s wait ran out; the runner then
  sent SIGINT ("signal 2 at 0.0 s", 450k reads, 0 errors). Why pips took ~5 s to start is
  not known (the BAR0 lock, whose `take_lock` also gives up at 5 s, or a slow sudo). Also:
  after exit 3 the runner's leftovers kept the experiment lock, so the sweep's next 6
  experiments were refused ("another experiment is already running"). **Fixed 11-09:**
  both runners' `bg_begin` wait 30 s, retry up to 3 times (not after a config refusal), and
  log `bg_start_ms` in bg-cmd.txt and "started in N ms" on the console; failed tries kept as
  `bg-run-try<k>.txt`; pips says "waiting for /tmp/... (another pips holds it)" after 1 s
  on the lock; the bp sampler closes fd 9 and `cleanup` stops it; the campaign's pack keeps
  the stopping run's engine files in `bg/stopped/`. Rerun with `--fresh` (the old stamp
  would resume at vstress and never redo the native engine-on sweeps).
- **2026-11-08:** **icx campaign (`nic --bg`) started 23:33 and stopped by the
  user: styx's disk is full** (`/` 751G, 713G used, 0 available to users; our logs and
  reports there are ~27 MB, so it is someone else's data; admin contacted). Its repo could
  not fetch and the styx snapshot failed. The campaign does not need styx's repo current
  (nothing styx runs changed since alias campaign 2), only matching copies, a built
  alias-rdma and root write room (the loads run under sudo, into ext4's root reserve).
  `bash scripts/pips/styx-check.sh` (on icx) checks exactly that and prints SAFE / NOT SAFE;
  then `pips-campaign.sh nic --bg --tmux` resumes.
- **2026-11-07 (19:30):** **the 0x0A08 stress campaign now covers both hosts,
  written, not run** (§8 "0x0A08 stress campaign"). bigserver (`ssd --bg`, ~44 h 30): the base
  fio runs widened (user, 11-07): 8k in nstress/nheavy, `nseq` (fio sequential reads, each
  instance its own slice), `ndeep` (iodepth 128 and 512, its own tag census). icx (`nic --bg`,
  ~33 h, no reboot): iperf3 TCP and alias-rdma (fits / one-set rotation / capacity) under the
  engine, the engine alone, and the IOTLB's replacement policy from traced tables. The NIC
  runner got `PIPS_BG`; the tag window takes 128-255 when the free range reaches 255.
- **2026-11-07 (icx, 18:25):** **0x0A08's tests pass on icx too (T0-T9)**: each
  port reads in its own NIC's domain, 8.2 G engine reads under both NICs' load all SC, one
  IOTLB for both NICs (a page evicted after 256 fresh ones: 32 x 8). Cost: idle-fill free up
  to 15 M reads/s, engine-first -4% at 25 M, -30% at 87 M, -64% at 167 M. Engine tags 128-255
  on both hosts (NIC tags grow under load). Test doc §4 "Third icx run".
- **2026-11-07 (evening):** **the 0x0A08 stress campaign is written, not
  run** (§8 "0x0A08 stress campaign"): `pips-campaign.sh ssd --bg` uses the engine as a cheap
  IOMMU stressor, ~30 h on bigserver, IOMMU strict. Native half first (drives on nvme, the
  engine reading a region a new module maps in each drive's DMA domain), then the vfio half
  (holder, static pages, the holder's new `bgmap`). Measures the drives' misses per I/O and
  throughput by engine level and batcher setting. Also the engine alone (rate and latency
  against MAX_OUT, capacity knee, T8b replacement probe). `--smoke` (~1 h 30) runs every
  step once. icx side not written yet.
- **2026-11-07 (third run, 15:00):** **every 0x0A08 assumption test passes
  (T0-T9)**: F0 holds (no fallback needed), 5.27 G engine reads under both drives' load all
  SC, **one IOTLB for both domains** (T8: drive 1's pages evict drive 0's entry exactly as
  drive 0's do). Cost to the drives: idle-fill none (max 0.66 M reads/s), engine-first none
  up to ~2.5 M reads/s, -4% at 8 M, -13% at 25 M, -59% at 118 M. IOTLB replacement: after
  a flush ~130 fresh pages fit; once full, a page read once or twice (4 us apart) is evicted
  by <= 32 fresh pages, while pages reused over time survive thousands: one-shot engine
  reads evict only entries not yet reused. Open: what earns that hold (T8b proposed). T6
  analysis bug fixed. Test doc §4 "Third run".
- **2026-11-07 (second run, 01:37):** with the engine's tags in 128-255 **T0-T5
  and T9 pass**: 32 M engine reads under both drives' load, all SC, no leak, no straddle, no
  device tag in the window. T7: hit 688 / miss 1076 ns median, 2.6% misclassified per read
  (now a pass). T8 inconclusive: a page read twice survived thousands of later misses, so
  the IOTLB looks reuse-protected; T8 rewritten (flushed IOTLB, fresh pages, once / cross /
  twice). T4 trains now run 20 s (T6). Next: rerun, `--start-holder --reboot --tmux`.
  Test doc §4 "Second run".
- **2026-11-07 (first run):** **0x0A08's main assumption holds (F0)**: on
  bigserver a read under a downstream port's ID returns that drive's page, and only through
  its own port (T2, T3 PASS). T4 failed: the engine's tags collided with drive 0's tags
  (0-127) inside the PCIe core, giving a malformed completion and a timeout in every train.
  The script now keeps the engine's tags in the census's free range (128-255); rerun.
  Results: `dualssd/1106/rid-live/`; [docs/PIPS-0A08-ASSUMPTION-TEST.md](docs/PIPS-0A08-ASSUMPTION-TEST.md)
  §4 "First run".
- **2026-11-07 (later):** **0x0A08 is built** (FPGA repo `5fe3bda`, P1-P3, not
  yet run on hardware) and **its live-test tools are written, not yet run**:
  `scripts/pips/pips-rid-live.sh` (T0-T12), `pips bg` (pips.c, `PIPS_BG_*` merged into
  `pips_regs.h`), the holder's `map` command (alias-nvme: fresh page tags without I/O),
  `ridcheck/pips_bg_pages.c` (F3). Checked here: C syntax (MinGW, stub headers), the
  script's syntax, dry run and its Python on synthetic data. No engine model in pips_sim.
- **2026-11-07:** **0x0A08 becomes the assumption-test build**
  ([docs/PIPS-0A08-ASSUMPTION-TEST.md](docs/PIPS-0A08-ASSUMPTION-TEST.md)): the engine core
  plus requester-ID slots, tag window and clash detector (fallback F2), leak monitor, tag
  census, straddle / flow-control / head-of-line counters, completion capture; live tests
  T0-T12 and the fallbacks F0-F4. Host-only check of the main assumption written now:
  `scripts/pips/pips-rid-check.sh` (+ read-only module `scripts/pips/ridcheck/`), not yet
  run on a host (parser checked here on synthetic debugfs dumps; module not compiled here).
- **2026-11-06 (night):** **design of a background read engine in the
  FPGA** (`pips_bg_rd`, target design `0x0A08`; user, 11-06): MRds under a PIPS
  downstream port's requester ID to pinned pages in the device's IOMMU domain, completions
  sunk before the router, per-read latency. Spec, register map (AXI segment `0xA402_0000`),
  host software and experiment plan in [docs/PIPS-BG-READ-ENGINE.md](docs/PIPS-BG-READ-ENGINE.md),
  for the hardware agent. Nothing built; no code changed.
- **2026-11-06 (evening):** **icx's first alias2 launch
  (`c11060312`) ran only the first sweep of each phase** (12 sweeps, 96 runs,
  4h25): `a2_phase` read its spec lines on stdin and the NIC runner's ssh to
  styx swallowed the rest. Fixed (spec lines on fd 3, runner stdin
  /dev/null); the 11-05 reanalysis now also finds the manifests in
  `~/pips-campaign-<kind>-c1105*/results/` and `utils/logs/`. Recovery: resume
  the same stamp (§8 "Alias campaign 2", "First launch").
- **2026-11-06 (later):** **alias campaign 2 set up, not run** (§8 "Alias
  campaign 2"): `--alias2` on both hosts; alias-rdma `--sge-bytes`/`--mtu`, alias-nvme
  per-drive patterns, `--cursor shared`, holder extras (v2), NIC READ latency in the results,
  the analysis's IOTLB simulation fixed for alias sweeps. Untested on the hosts.
- **2026-11-06:** **the alias campaign is in and analysed** (§8 "Alias campaign 1 in short", archived as
  "Alias campaign results"; page "PIPS Alias Campaign" https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q): icx's IOTLB 256 entries
  set-associative (< 16 ways), bigserver's ~96 with no set conflicts; two devices that fit
  alone thrash together; misses cost nothing measurable; the batcher doesn't move them.
  Next campaign proposed on the page (not set up).
- **Earlier entries** (11-05 back to 09-29): [docs/archive/handoff-log.md](docs/archive/handoff-log.md).
- **Where the study stands (11-06):**
  - **Build:** design `0x0A07` (§8 "Switch designs") for the campaigns;
    `0x0A08` (0x0A07 + the background read engine) on bigserver since 11-07.
    0x0A02-0x0A06 are retired; their results are in the archive (below) and
    on their report pages (§8).
  - **Batcher study: done** (§8 "Verdict", 10-30), judged on page order
    only: NICs at the legal floor, drives 4k/16k within 20-40% of it, drives
    64k/1m 2.3-2.8x (page segments run out). One optional build (more
    segments) only if large drive I/Os matter.
  - **Paper campaign on 0x0A07, four IOMMU modes: done** (11-02, §8
    "0x0A07 in short"). Batching costs the hosts nothing measurable; page
    order doesn't move IOTLB misses; strict costs throughput only for drives
    at 4k; for the NICs the IOMMU mode doesn't matter.
  - **Alias campaign 1: done** (11-06, §8 "Alias campaign 1 in short"):
    icx's IOTLB has 256 entries, set-associative; bigserver's ~96, no set
    conflicts; a miss costs nothing measurable; the batcher doesn't move
    aliasing misses.
  - **Alias campaign 2 in (11-07):** icx's IOTLB is **32 sets x 8 ways**
    (index = low 5 page bits), LRU-family replacement; rotation in one set
    reaches 7-12 misses per page and the batcher cuts it 7.4 -> 2.0; scattered
    256 B pieces cost 15-22% Gb/s at 4 QPs. bigserver: not LRU (another
    drive's ~10 misses evict a page; fits ~40 entries, random replacement).
    §8 "Alias campaign 2 results".
  - **0x0A08 background read engine: works (11-07)** (§8 "0x0A08: the
    background read engine"): every assumption test passes on bigserver. A
    downstream port's ID reads in its drive's domain (F0), one IOTLB serves
    both domains, engine tags 128-255; engine-first is free up to ~2.5 M
    reads/s; one-shot reads evict only entries not yet reused. **Stress
    campaign written for both hosts (11-07, `ssd|nic --bg`, not run):** §8 "0x0A08 stress campaign".
- **Headline across both testbeds:** IOMMU strict costs throughput only
  where every I/O is mapped and unmapped and the I/O is small: drives at 4k
  (strict ~30-40% of off). Everywhere else (NICs at any flow count, drives
  from 16k up) strict and off move the same bytes.

## Archive: retired designs and old logs

Moved out verbatim on 2026-11-06, headings kept: a reference such as
HANDOFF §8 "0x0A06 campaign results" or §7 "Fifth result" still finds its
text; look its heading up in this table. Each file is tracked in git and
published as an artifact (rebuild a page: `py -3 docs/archive/mkpage.py
<out-dir>`, then publish to the same URL).

| Era | Moved here (headings) | File | Artifact |
|---|---|---|---|
| icx and bigserver before PIPS, 09-29 to 10-11 | §4.1, §4.2, §5 (icx); §7 "First result" to "Fifth result", "Next on bigserver"; KNOWLEDGE-MAP §6 | [pre-pips.md](docs/archive/pre-pips.md) | https://claude.ai/artifact/G5s7nD5CRPLV646Jq6QrhT |
| PIPS 0x0A02-0x0A05, 10-11 to 10-20 | §8 sweep and report bullets, "Depth sweep", "0x0A04 results" (items 1-13), "0x0A05 depth sweep"; SWEEP-LOGS "The 10-17 depth sweep", "Earlier runs on the hosts"; PIPS README "First hardware run"; PIO-MANUAL §12, §15 first item | [pips-0a02-0a05.md](docs/archive/pips-0a02-0a05.md) | https://claude.ai/artifact/FiRJK1qrLUmWXMAqjtE17A |
| PIPS 0x0A06, 10-23 to 10-26 | "0x0A06 campaign", "0x0A06 campaign results" (R1-R10) | [pips-0a06.md](docs/archive/pips-0a06.md) | https://claude.ai/artifact/HW13EiQXS5414G5ASfyZna |
| PIPS 0x0A07 campaigns, 10-28 to 11-02 | "0x0A07 minimal rerun", "0x0A07 drive results", "0x0A07 NIC results", "0x0A07 paper campaign", "0x0A07 paper campaign results" | [pips-0a07.md](docs/archive/pips-0a07.md) | https://claude.ai/artifact/3iQfW7DoaUFDhcwMx2wfqn |
| Alias campaign 1, 11-05/06 | "Alias campaign", "Alias campaign results" (+ follow-up); "Next" statuses of 11-05: the bigserver freeze debug log, the NIC smoke tests | [pips-alias-1.md](docs/archive/pips-alias-1.md) | https://claude.ai/artifact/VJj7kKdHEfRyksGJ5zLeZM |
| Logs | the changelog (11-05 back to 09-29); "Next" statuses 11-02 back to 10-20 and its item lists (0-5, the 10-26 lists) | [handoff-log.md](docs/archive/handoff-log.md) | https://claude.ai/artifact/RV2WxMKKri8YBcBSJMssSZ |
| CLAUDE.md (local) | its "State as of" notes, 10-20 to 11-06 | [claude-md-state-log.md](docs/archive/claude-md-state-log.md) | https://claude.ai/artifact/6sWcrEA4pqrrJTZQeoGAjD |

---

## 1. Testbed

| | Receiver / server | Sender / client |
|---|---|---|
| Host | **icx** `192.17.103.88` | **styx-tower** `192.17.100.255` |
| CPU | Xeon Platinum 8380, Ice Lake-SP, 80 cores, 2 sockets | Xeon E5-2660 v4, Broadwell, 14C/28T @ 2.0 GHz, 1 socket |
| Role | system under test: IOMMU + Intel PCM here | load generator only |
| NIC 0 | `enp153s0f0np0` 192.168.10.88 | `ens1f1np1` 192.168.10.52 |
| NIC 1 | `enp154s0np0` 192.168.100.88 | `ens1f0np0` 192.168.100.90 |
| Kernel | `6.8.0-110-generic`, stock Ubuntu. **Not** the paper's 6.0.3 (§4.1) | not recorded |
| PCIe | Gen4; both NICs share one x8 uplink (below) | Gen3 only; both test ports are one dual-port card (`ens1f0`/`ens1f1`), link width not verified |
| Repo | `/home/yz69/F_S_Memory_Script` | identical path, required |
| User | `yz69` | `yz69` |

**Run everything on icx. It drives styx over ssh. Never run the experiment on
styx** — the runner refuses, but the reason is that it would ssh to the host it
is already on and measure nothing.

### PCIe topology — the fact that shapes everything

```
enp153s0f0np0  pci0000:96 -> 96:02.0 -> 97:00.0 -> 98:00.0 -> 99:00.0
enp154s0np0    pci0000:96 -> 96:02.0 -> 97:00.0 -> 98:01.0 -> 9a:00.0
                             ^^^^^^^^   ^^^^^^^^
                             one root   PCIe switch
                             port       upstream port
```

Every hop is **x8 @ 16 GT/s (Gen4)**: 16 GT/s × 8 lanes × 128/130 encoding =
~126 Gbps per direction, raw. After PCIe packet overhead roughly 110–115 Gbps is
usable (depends on max payload size, not yet checked). Both NICs share the root
port and the switch uplink, so:

- **~252 Gbps of endpoint bandwidth funnels into ~126 Gbps.** A hard 2:1
  oversubscription. Both NICs at line rate is physically impossible. Measured
  ceiling with both NICs: 110.5 Gbps PCIe write, 105.7 Gbps TCP throughput.
- **No per-NIC hardware attribution.** Sharing the root port means sharing the
  IIO stack *and* the Part. IOMMU events are per-stack (`ch_mask=0x0`,
  `vname=Total`) and IB/OB bandwidth is per-Part, so every `pcm-iio` number is a
  sum over both NICs. Per-NIC data comes from iperf3 only.

This is not a defect to engineer around. **Contention requires a shared IOMMU,
and a shared IOMMU means shared counters.** A cross-socket pair would give clean
per-NIC attribution and no PCIe bottleneck, but the NICs would sit behind
different DMAR units with nothing to contend for.

---

## 2. Quick reference

All commands run **on icx**, from `~/F_S_Memory_Script`.

### Run an experiment

```bash
git pull                                              # always first

# three-point comparison: NIC0 alone, NIC1 alone, both
./scripts/sosp24-experiments/dualnic_exp.sh uncapped 8    # line rate
./scripts/sosp24-experiments/dualnic_exp.sh 30g 8         # capped at 30 Gbps/NIC

# load sweep: several rates plus line rate, with repeats
./scripts/sosp24-experiments/dualnic_load_sweep.sh "15 30 45 60 uncapped" 8 3

# flow sweep: one NIC0-alone datapath check, then co-run (both NICs) at
# 5/10/15/30 flows/NIC, uncapped, 3 repeats. Once per IOMMU boot setting.
./scripts/sosp24-experiments/dualnic_flow_sweep.sh              # [-o name] [flows] [rates] [runs] [modes]

# single configuration
./scripts/run-dualnic-experiment.sh -E mytest --nics 2 --uncapped -S 8 --runs 3

# NICs behind PIPS: the flow sweep once per batcher setting, drain cap off and
# on, with the switch's TLP log in every run (§8)
./scripts/sosp24-experiments/dualnic_pips_sweep.sh --cfgs "1:0 8:22" --single --tmux
```

### `run-dualnic-experiment.sh` options

| Flag | Meaning |
|---|---|
| `-E <name>` | experiment name; names the output directories |
| `--nics 1\|2` | how many NICs to drive |
| `--nic-index N` | which NIC when `--nics 1` |
| `-S` / `-C <n>` | iperf3 flows per NIC (server / client) |
| `-b <rate>` | **aggregate per NIC**, divided across flows |
| `--uncapped` | no rate limit; same as `-b uncapped\|0\|unlimited` |
| `--runs N` | repeat each config; report gains mean ± stddev |
| `--cca <name>` | congestion control on the sender (default `dctcp`) |
| `-M`, `--ring_buffer`, `--buf`, `-d` | MTU, NIC ring size, socket buffer MB, duration |
| `--sync-client` | git fetch/checkout/pull on styx before running |
| `--results <file>` | JSONL file to append the result to (default `~/<exp>-<N>.jsonl`, first unused N) |
| `--pips-log 0\|1` | NICs behind PIPS: also record the switch's TLP log in every run (§8). Without it, NICs behind PIPS still get the design ID and batcher setting in the result |

`-b` is an **aggregate per-NIC** rate and is divided by the flow count before
reaching iperf3, whose own `-b` is per-flow. `-b 40g` with 8 flows sends 5 Gbps
per flow. Getting this wrong is why an early run asked for 40g and delivered 97.

### Reading the output

```
IOTLB misses per Gbps : 34576.2   <-- compare THIS across runs
```

**Compare the normalized metric, never raw miss counts.** Misses scale with
bytes moved, so a 1-NIC and a 2-NIC run that carried different traffic volumes
are not comparable. An uncapped 2-NIC run shows *fewer* total misses than the
sum of the baselines purely because the uplink capped its throughput; normalized,
the same data shows misses per Gbps *rising*.

Contention = `both / mean(nic0only, nic1only) - 1`.

Results land in `utils/reports/<exp>-RUN-server-<run>[-nic<N>]/`:
`iperf.bw.rpt` per NIC, `pcie.rpt` shared, `cpu_util.rpt`, `membw.rpt`.

Every experiment also writes one JSON line (config, IOMMU mode read from
sysfs, every run, mean/sd) to `~/<exp>-<N>.jsonl`. The flow sweep collects its
experiments into `~/dualnic-flowsweep-<iommu>-<N>.{jsonl,txt}`, or
`~/<name>.{jsonl,txt}` with `-o <name>`. Unnamed dumps take the first unused N,
so a rerun never overwrites an earlier result. Side-by-side table of any set of
these files:

```bash
python3 scripts/dualnic-results.py summary ~/dualnic-flowsweep-*.jsonl
```

`cpu_util` covers every active NIC's cores. Before the flow sweep was added it
covered only NIC 0's, so 2-NIC `cpu_util` from earlier runs is half the picture.

### Stopping a run

```bash
pkill -f 'dualnic_flow_swee[p]'; pkill -f 'run-dualnic-experimen[t]'
```

The runner kills iperf3 on both hosts on the way out; it may first finish a
sleep of up to ~75 s. Ctrl-C in the terminal does the same. Only one
experiment can run at a time (`/tmp/dualnic-experiment.lock`): every run kills
iperf3 on both hosts, so two copies zero each other's traffic. A second copy
refuses to start and lists the one that is running.

### Diagnostics

```bash
sudo bash utils/discover-pcie-topology.sh   # NIC -> root port -> pcm-iio stack
bash scripts/collect-setup-info.sh          # CPU, NIC, IOMMU, tooling survey
```

---

## 3. Cold start and after a reboot

Most host state is re-applied by `setup-envir.sh` on every run, so a reboot is
largely self-healing. These are the exceptions.

### Survives a reboot — no action

- `/etc/sudoers.d/fands` (passwordless sudo), ssh keys, both repos
- `utils/setup-server.sh` on both hosts
- IOMMU setting in the kernel command line

### Re-applied automatically every run — no action

- NIC IP, MTU, ring buffer (`ifconfig` / `network_setup.py` in `setup-envir.sh`)
- `tcp_rmem` / `tcp_wmem` / `tcp_moderate_rcvbuf` / `tcp_ecn`
- `modprobe msr` for PCM (inside `record-host-metrics.sh`)
- ftrace state

### Check after a reboot

```bash
# 1. IOMMU in the intended mode? "strict" for on runs, "off" for off runs.
for i in enp153s0f0np0 enp154s0np0; do echo "$i $(bash utils/iommu-mode.sh $i)"; done

# 2. Interface names unchanged? Renaming silently invalidates setup-server.sh.
ip -br addr | grep -E 'enp153s0f0np0|enp154s0np0'

# 3. Both links up at 100000?
for i in enp153s0f0np0 enp154s0np0; do echo "$i $(cat /sys/class/net/$i/speed)"; done

# 4. styx reachable without a password?
ssh -o BatchMode=yes yz69@192.17.100.255 true && echo ssh OK
```

The runner pings each data-plane link after NIC setup and aborts with both
addresses if it fails, so a missed reboot step surfaces immediately rather than
as a confusing iperf3 error.

### Toggling the IOMMU

```bash
grep -n iommu /etc/default/grub /etc/default/grub.d/* 2>/dev/null   # current setting
sudo nano /etc/default/grub   # in GRUB_CMDLINE_LINUX_DEFAULT, set the iommu tokens to
                              #   on : intel_iommu=on iommu.strict=1
                              #   off: intel_iommu=off
sudo update-grub && sudo reboot
bash utils/iommu-mode.sh enp153s0f0np0   # after reboot: strict | lazy | pt | off
```

Trust `iommu-mode.sh` over the command line: it reads the NIC's DMA domain
type, i.e. what the kernel did rather than what it was asked. The runner
records it in every JSON result, and the flow sweep puts it in every experiment
name, so on and off sweeps never overwrite each other's reports.

### Cold start in a new session

Nothing special. `setup-server.sh` is git-ignored and lives on disk, so it
persists. If it is ever lost, rebuild from `utils/setup-server.sh.example` and
copy to **both** hosts — `scp` it, since `git clone` will not bring it.

### If PCM stops working

`PCM_DIR=/home/jiaqi/tools/pcm` — a colleague's directory, world-executable.
If it disappears, build your own (~3 min) and repoint `PCM_DIR`:

```bash
git clone --recursive https://github.com/intel/pcm.git ~/tools/pcm
cd ~/tools/pcm && mkdir -p build && cd build && cmake .. && make -j"$(nproc)"
sed -i 's|^PCM_DIR=.*|PCM_DIR="/home/yz69/tools/pcm"|' ~/F_S_Memory_Script/utils/setup-server.sh
```

`pcm-iio` reads `opCode-6-106.txt` from the **current directory**, which is why
the scripts `cd` into `utils/` before invoking it. Run it from elsewhere and it
silently falls back to defaults without IOMMU events, shifting every column.

### If the NICs are moved or re-cabled

Re-run `discover-pcie-topology.sh` and update `PCIE_PATTERN` in
`setup-server.sh`. If the NICs end up on **different** root ports you may gain
per-NIC counters but lose the shared IOMMU, and then the contention experiment
no longer measures contention. Check which IOMMU unit each NIC is behind
(IOMMU on; substitute the new addresses):
```bash
for d in 0000:99:00.0 0000:9a:00.0; do
    echo "$d -> $(basename "$(readlink -f /sys/bus/pci/devices/$d/iommu)")"
done                                       # same dmarN = shared IOMMU
```

---

## 4. Results so far

### 4.1-4.2 icx before PIPS (09-29 and earlier): archived

The flow sweep strict vs off (09-29), the capped 8-flow run, the derived
metrics and the speculated reasons A-F are in
[docs/archive/pre-pips.md](docs/archive/pre-pips.md). In short (NICs on the board's PCIe switch,
kernel 6.8):
- Strict and off gave the same throughput at every flow count (5-30 per NIC).
  Both NICs together sat at the shared x8 Gen4 uplink (105.7 Gbps TCP, 110.5
  PCIe write); 30 flows fell to 48.5 Gbps in both modes (a host limit, not
  the IOMMU).
- Strict: ~12% IOTLB miss rate, ~1.1 misses and ~9 lookups per 4 KB written,
  misses served by the 4K page-walk cache. Its only cost was receiver CPU
  (NIC0 alone +8%, 30 flows +10%).
- The later PIPS campaigns repeated this: for the NICs the IOMMU mode doesn't
  matter (§8 "0x0A07 in short").

### 4.3 What the IOMMU counters can and cannot show

Checked on 2026-09-29 against Intel's Ice Lake-SP event list:
[`intel/perfmon`, `ICX/events/icelakex_uncore_experimental.json`](https://github.com/intel/perfmon/tree/main/ICX/events).
Intel marks these events "experimental".

**The 8 events we record are labelled correctly:**

| `pcie.rpt` key | Event / umask | Intel's definition |
|---|---|---|
| `IOTLB_lookups` | 0x40 / 0x01 | IOTLB lookups, **first** lookup per transaction only |
| `IOTLB_misses` | 0x40 / 0x20 | IOTLB fills (= misses); each starts a page walk |
| `CTXT_cache_hits` | 0x40 / 0x80 | first lookup hits the root/context cache |
| `PWC_4K_hits` | 0x41 / 0x02 | first lookup hits the second-level page-walk cache at the 4K level |
| `PWC_2M_hits`, `PWC_1G_hits`, `PWC_512G_hits` | 0x41 / 0x04, 0x08, 0x10 | same, at the 2M / 1G / 512G level |
| `IOMMU_mem_access` | 0x41 / 0x40 | "IOMMU sends out memory fetches when it misses the cache look up" |

**There are no per-level miss counts on this CPU.** The paper's Cascade Lake
exposed "VT-d L1/L2/L3 Miss", page-walk-cache misses by walk level. Ice Lake
exposes hits by level instead. On this machine the old scripts' `L1/L2/L3_Miss`
were the 512G/1G/2M hits under wrong names (§6).

**Available but not recorded:**

| Event / umask | Counts | Use |
|---|---|---|
| `PWT_CACHE_LOOKUPS` 0x41 / 0x01 | page-walk-cache lookups | denominator for a page-walk-cache miss rate |
| `PWC_CACHE_FILLS` 0x41 / 0x20 | page-walk-cache misses | nearest equivalent of the paper's L-misses (total, not per level). Today these can only be estimated as misses − PWC hits ≈ 0, which is unreliable because PWC hits exceed misses by 2–8% |
| `NUM_INVAL_GBL` / `_DOMAIN` / `_PAGE` 0x43 / 0x01, 0x02, 0x04 | IOTLB invalidations | hardware-side test of whether strict mode invalidates constantly (§4.1 B) |
| `CYC_PWT_FULL` 0x41 / 0x80 | cycles the page walker is at its outstanding-walk limit | direct sign that the IOMMU is the bottleneck |
| `PWT_OCCUPANCY` 0x42 | page walks outstanding | same |
| `4K_HITS` / `2M_HITS` / `1G_HITS` 0x40 / 0x04, 0x08, 0x10 | IOTLB hits by page size | whether any DMA uses large-page mappings |

`IOMMU_mem_access` stays unexplained. Intel's one-line description does not
account for ~5 fetches per miss, nor for the 75–138 k/s it reads with the IOMMU
off. `PWC_CACHE_FILLS` would give an independent count to compare it with.

---

## 5. Next experiments and open items (icx, 09-29): archived

The list as of 09-29/10-15 (items 1-7, "Still open from before",
"Instrumentation gaps") is in [docs/archive/pre-pips.md](docs/archive/pre-pips.md). Item 1 was
done (the NICs moved behind PIPS, 10-15). Item 3 (map/unmap counts) became the
paper campaign's E7, which has no data: `perf` runs on neither kernel. Never
done: item 2 (the unrecorded IOMMU events of §4.3), item 5 (the paper's 6.0.3
kernel), item 6 (the 30-flow cliff), and `IOMMU_mem_access`'s meaning.

---

## 6. Traps

- **This kernel is not the paper's.** icx runs stock `6.8.0-110-generic`; the
  paper's baselines are on 6.0.3. The IOMMU cost may not reproduce (§4.1 B).
- **icx now boots `6.12.43-vanilla`** (since at least 10-26; §1 and §4 are
  from the 6.8 days). A vanilla kernel has no `linux-tools-$(uname -r)`
  package: `perf` would have to come from its source tree.
- **Uncapped 2-NIC throughput cannot show an IOMMU cost.** It is pinned at
  ~105.7 Gbps by the shared uplink whatever the IOMMU does.
- **Two experiments at once zero each other's traffic.** Each kills iperf3 on
  both hosts. The runner now takes a lock, but a sweep from an old checkout
  still running in tmux or nohup will not. Check with
  `pgrep -af 'dualnic|iperf3'` before starting.
- **`record-host-metrics.sh: line …: Killed  sar …` is normal.** It stops its
  own CPU sampler at the end of the window.
- **`iperf3 -b` is per-flow.** The runner divides for you; anything calling
  `run-netapp-tput.sh` directly must divide itself.
- **Raw miss counts are not comparable across runs.** Normalize by PCIe write.
- **`setup-server.sh` is git-ignored.** `git pull` never updates it. After
  changing `setup-server.sh.example`, diff and copy across by hand, to both hosts.
- **Never paste commands under an interactive `ssh`.** The session eats them as
  stdin and they run on the *local* host after logout. This silently left styx's
  repo stale for several rounds. Use `ssh host 'cmd'` or `--sync-client`.
- **`pkill -f <pattern>` matches its own command line.** All call sites use
  process-name matching now; keep it that way.
- **`fands.patch` on this branch is the FIXED version** from upstream `master`.
  The `pips-dev` copy releases pages before unmap/invalidate — a stale IOTLB
  entry can point at a recycled page. If a kernel was built from that tree, its
  results carry the bug.
- **`report-tput-metrics.py` from `pips-dev` was not imported.** Its
  `metrics = map(...)` is a one-shot iterator, so only the first metric is ever
  evaluated.
- **Counter names were wrong before this branch.** `L1/L2/L3_Miss` were really
  512G/1G/2M page-walk-cache *hits* — a sign inversion. `pcie.rpt` now writes
  correct names plus legacy aliases; `collect-tput-stats.py` reads either.
  Ice Lake has no per-level miss events at all, so the paper's L1–L3 miss
  numbers have no direct equivalent here (§4.3).
- **`collect_iio_occ` is Skylake-only** (hardcoded MSRs) and disabled. Its output
  was never parsed by anything.

---

## 7. bigserver: dual-SSD on Skylake-SP

The same contention experiment with two NVMe SSDs and fio in place of two NICs
and iperf3. fio runs locally, so there is no client host. Set up and first
swept (strict) on 2026-10-05.

### Testbed (survey 2026-10-05)

| | |
|---|---|
| Host | **bigserver**, shared with other users who also run PCM and fio |
| CPU | 4× Xeon Gold 6140, Skylake-SP (family 6, model 85, stepping 4), 18 cores per socket, no SMT. NUMA node N = CPUs 18N–18N+17 |
| Kernel | `5.15.0-177-generic`, booted `intel_iommu=on iommu.strict=1` (domain type `DMA`). Neither icx's 6.8 nor the paper's 6.0.3 |
| PCM | installed, `/usr/local/bin/pcm-iio`. Version unknown: its banner prints an unfilled `$Format:%ci ID=%h$`. Loads `opCode-6-85.txt` without complaint |
| fio | `fio-3.41-39-g9f87c`, `/usr/local/bin/fio` |

| Index | Drive | Serial | PCI | State |
|---|---|---|---|---|
| 0 | Samsung 9100 PRO 1TB (Gen5 drive, linked Gen4 x4) | `S7YENJ0Y313233B` | `b3:00.0` | ext4, not mounted, ~784 GB written |
| 1 | Samsung 990 EVO Plus 1TB (Gen4 x4) | `S7U5NJ0Y308972P` | `b4:00.0` | no filesystem, ~1.6 GB written |

```
9100 PRO      pci0000:b0 -> b0:00.0 -> b1:00.0 -> b2:00.0 -> b3:00.0
990 EVO Plus  pci0000:b0 -> b0:00.0 -> b1:00.0 -> b2:01.0 -> b4:00.0
                            ^^^^^^^    ^^^^^^^
                            one root   PCIe switch
                            port       upstream port
```

The same shape as icx. Both drives share IOMMU unit `dmar7`, one root port, so
one IIO stack and one Part: every `pcm-iio` number is a sum over both drives,
and per-drive numbers come from fio. Both are on NUMA node 2 (CPUs 36–53).
The uplink above the switch (`b0:00.0` to `b1:00.0`) is **8 GT/s x8, ~63 Gbps**,
the same as one drive's own Gen4 x4 link. Both drives together cannot exceed
it. At 4k the full co-run moves ~25 Gbps, so the link does not bind there.
At 1 MiB it would; the summary marks such rows LINK BOUND.

nvme2–5 (NUMA 3, `dmar11`) are `linux_raid_member` drives: someone's md array.

### Setup, once

```bash
git clone <fork> ~/F_S_Memory_Script && cd ~/F_S_Memory_Script && git checkout icx-dualnic
cp utils/setup-server.sh.bigserver.example utils/setup-server.sh
sudo bash utils/discover-ssd-pcie.sh    # prints SSD_PCIE_PATTERN; paste it into setup-server.sh
```

The discovery loads each drive alone with read-only fio and reports which
`pcm-iio` row carries its traffic. It also checks that PCM loaded
`opCode-6-85.txt` and that the VT-d counters are non-zero. **Do not sweep until
they are**: with zeros, every IOMMU column of the sweep is zero too. It keeps
its output in `utils/logs/discover-ssd-pcie-<date>-<time>/`.

Result on 2026-10-05: `SSD_PCIE_PATTERN="Socket2,IIO Stack 3 - PCIe2,Part0"`,
both drives on that row. Each drive alone (4 jobs × iodepth 32, 4k) did
~530K IOPS, with ~1.4 IOTLB misses per I/O. Per IOTLB miss there were
0.52–0.62 VT-d L1/L2/L3 misses at each level and 3.3–3.4 VT-d memory reads.
On icx nearly every miss hit the page-walk cache; here walks are deep.

### Run

```bash
sudo -v     # bigserver has no NOPASSWD sudo: cache the password in this terminal first

# co-run at 1,2,4,8,16,32 fio instances per drive, 4k random reads, 3 repeats
./scripts/sosp24-experiments/dualssd_sweep.sh                  # [-o name] [--single] [--tmux] [instances] [block sizes] [runs]
./scripts/sosp24-experiments/dualssd_sweep.sh --single         # also each drive alone (baselines for CONTENTION)
./scripts/sosp24-experiments/dualssd_sweep.sh "1 2 4 8" "4k 1m" 3   # up to 8 instances, 4k and 1 MiB

# the same in a tmux session instead of this terminal (survives a dropped ssh)
./scripts/sosp24-experiments/dualssd_sweep.sh --single --tmux

# block-size sweep: 4 instances per drive, 4k 16k 64k 256k 1m, 3 repeats
./scripts/sosp24-experiments/dualssd_bs_sweep.sh                # [-o name] [--single] [--tmux] [block sizes] [instances] [runs]
./scripts/sosp24-experiments/dualssd_bs_sweep.sh "4k 8k 16k 32k 64k 128k 256k 512k 1m"

# cross sweep, every block size at every instance count: 4k 8k 16k 64k 1m x 1,2,4,8,16,32, 1 run
./scripts/sosp24-experiments/dualssd_cross_sweep.sh             # [-o name] [--single | --single-ssd N] [--tmux] [block sizes] [instances] [runs]
./scripts/sosp24-experiments/dualssd_cross_sweep.sh --single    # also drive 0 alone; only drive 0, to save time
DUALSSD_ARGS="--membw 0" ./scripts/sosp24-experiments/dualssd_cross_sweep.sh --single   # ~half the time

# uneven co-runs too: one drive 2/4/8 instances, the other 16/32, both ways round
./scripts/sosp24-experiments/dualssd_cross_sweep.sh --single --asy     # [--asy-low "2 4 8"] [--asy-high "16 32"] [--no-swap]

# single configuration
./scripts/run-dualssd-experiment.sh -E mytest --ssds 2 -J 4 --runs 3
./scripts/run-dualssd-experiment.sh -E myasym --ssds 2 -J 4,32         # 4 on drive 0, 32 on drive 1

# side by side, strict vs off
python3 scripts/dualssd-results.py summary ~/dualssd-sweep-*.jsonl
python3 scripts/dualssd-results.py grid ~/dualssd-xsweep-*.jsonl      # block size x instances tables
```

**Single-drive runs.** `--single` on `dualssd_sweep.sh` and
`dualssd_bs_sweep.sh` runs each drive alone at every point. `--single-ssd N`
(any of the three sweeps) runs only drive N alone, which halves the
single-drive time. On `dualssd_cross_sweep.sh`, `--single` means
`--single-ssd 0`: drive 0, the 9100 PRO (`nvme0`). Drive 1, the 990 EVO Plus
(`nvme1`), is the one with the host memory buffer (Third result, item 7);
pick it with `--single-ssd 1`. With one drive alone the summary fills KEPT%
for that drive but not CONTENTION, which needs both.

| `run-dualssd-experiment.sh` flag | Meaning |
|---|---|
| `-E <name>` | experiment name; names the output directories. Refused if already used. May contain `/` to group runs in a folder |
| `--ssds 1\|2`, `--ssd-index N` | how many drives (default 2); which one when 1 |
| `-J <n>` | fio instances **per drive**, the analogue of iperf3 flows |
| `--bs`, `--iodepth`, `--rw`, `--ioengine` | default `4k`, `32`, `randread`, `libaio`. `--rw` accepts only `read`/`randread` |
| `-d`, `--warm` | measurement window (default 20 s) and fio ramp time (10 s) |
| `--membw 0\|1` | `pcm-memory` window, on by default (adds 30 s + window per run) |
| `--runs N`, `--results <file>` | as in the NIC runner |

Each instance is a separate fio process, a single job with `--thread`, pinned
round-robin over the drive's cores (`SSD_CORES`, 9 per drive). From 10
instances per drive up, cores run several each (3–4 at 32). The 9 is a
choice, not a limit of the drive: node 2 has 18 cores (36–53), split between
the two drives so a co-run never puts both drives' instances on one core. The
warm-up starts once every instance is running (since 2026-10-07), and the
window opens 1 s after the ramp plus 1 s per 16 instances (since 2026-10-10).
Every run uses
`--readonly`, `O_DIRECT`, `--randrepeat=0 --norandommap` across the whole drive.
If any fio output ever reports bytes written or trimmed, `dualssd-results.py`
stops with FATAL.

**fio is checked against the measurement windows (since 2026-10-05).**
- `record-host-metrics.sh` writes each window's start and end (epoch ms) to
  `windows.txt`: CPU, then `pcm-iio`, then `pcm-memory`.
- Each fio instance writes a per-second IOPS log stamped in epoch ms. fio logs
  nothing during `ramp_time`; checked with fio 3.43.
- `fio-sum --windows` averages each log over exactly those windows. The IOPS
  and GB/s in the reports and summary therefore cover only the measured
  seconds.
- IOTLB misses per I/O divide by the IOPS of the `pcm-iio` window; CPU per I/O
  divides by the IOPS of the CPU window.
- It also requires every instance to cover the whole span: in its log (no
  late start, no early end, no hole over 2 s), and by fio's own `job_start` and
  runtime.
- If any instance falls short, or one dies during measurement, the runner
  prints why and stops with exit status 3. That run is not recorded.
- **A run where `pcm-iio` logged no rows for the SSD row** fails the same way
  when the IOMMU is on: its counters are what the run is for. With the IOMMU
  off or `pt`, it is kept with a warning, since fio's IOPS and the CPU cost
  are the comparison there. Its PCIe and IOMMU values are recorded as missing
  (`n/a`, `pcie_samples: 0`), not as 0. The off sweeps of 2026-10-05/06 all
  had `pcm-iio` rows: bandwidth as usual, VT-d counters near 0. So no rows
  with the IOMMU off is still worth a look at `pcm-iio.out`. On 2026-10-10 it
  happened in 3 strict runs (4k, 40 and 64 instances in total) and 3 off
  co-runs (4k at 1 and 2 per drive, 8k at 1); cause not yet looked at.
- **A sweep never aborts on a failed point (since 2026-10-10).** Whatever the
  failure, including the datapath check, the sweep logs the point with the
  runner's first error and moves on. It writes them to
  `utils/logs/<sweep>/failed.txt` and lists them at the top of the `.txt`;
  they show as `-` in the grids. Only a stop by hand ends it early (Ctrl-C or
  the pkill below), and it still writes the summary of what finished. Before
  this, the first failure ended the sweep: `dualssd-xsweep-strict-8` stopped
  at 4k / 32 per drive / both, where the 64-instance co-run had two late
  starts, a 4 s stall and no `pcm-iio` rows, so 8k–1m never ran.

**Uneven co-runs (`--asy`, since 2026-10-10).**
- One drive runs LOW instances and the other HIGH: LOW from `--asy-low`
  (default `2 4 8`), HIGH from `--asy-high` (default `16 32`), at every block
  size. The even points of the sweep, including 32+32, still run.
- **Both ways round by default:** drive 0 LOW, then drive 1 LOW. The two
  orientations should agree; if they don't, the drives or their slots differ,
  not the load. `--no-swap` runs drive 0 LOW only.
- **Cores are split in proportion** to the two counts, from both drives'
  `SSD_CORES` together, so every core runs about as many instances. The
  lighter drive keeps the head of its own list (fio off the interrupt CPUs).
  With 18 cores: 2+32 → 1 and 17 cores; 4+32 → 2 and 16; 8+16 → 6 and 12;
  2+16 → 2 and 16. Even co-runs keep the 9 + 9 split. Each record stores
  `instances_ssd<i>` and `cores_ssd<i>`; `instances_per_ssd` is `"n0+n1"`.
- **Against 32, the split halves the light drive's cores** (2 instances per
  core, against 1 in the even run `vsLOW` compares with). At 4–8k that alone
  costs it about half its IOPS, so `vsLOW` there mixes the neighbour's cost
  with the core loss (Fifth result, item 3). Against 16 the light drive keeps
  about one core per instance (8+16: 6 cores). To separate the two, the light drive needs one core
  per instance; the runner has no option for that yet.
- **The summary adds an "uneven co-runs" table.** It shows both orientations
  side by side, with the even co-runs at LOW and at HIGH. `vsLOW` is the LOW
  drive's IOPS as % of its own IOPS when both drives ran LOW: what a heavier
  neighbour costs it.
- KEPT% and CONTENTION compare each drive with its own single-drive run at
  its own count. Drive 1's KEPT% needs drive 1 alone, which the cross sweep's
  `--single` does not run (drive 0 only).
- With the defaults that is 12 points per block size: 60 more runs on the
  cross sweep, 12 × 3 on the instance sweep.

fio's own summary number starts after `ramp_time` (its `job_start`) and ends at
the stop, so it never included the cold start. It is kept as
`fio_IOPS_postramp` for comparison. Sweeps before this change used it for IOPS.

**Nothing is overwritten.** The runner refuses an `-E` name that already has
output. Each sweep takes a fresh name, `dualssd-sweep-<iommu>-<N>`, or the
`-o` name, which is refused if already used. Where a sweep's output goes:

| Path | Contents |
|---|---|
| `~/<sweep>.jsonl`, `~/<sweep>.txt` | one JSON line per configuration; the summary table, then every `pcm-iio` and `pcm-memory` value |
| `utils/logs/<sweep>/sweep.log` | everything the sweep printed |
| `utils/logs/<sweep>/<config>.console.log` | one configuration's runner output |
| `utils/logs/<sweep>/<config>-RUN-<j>/` | raw logs: `pcie.csv` (`pcm-iio`, every stack, every second), `pcm-iio.out` (its banner and warnings), `membw.log` (`pcm-memory`), `pcm.txt` (binary, core, row parsed), the `opCode-6-85.txt` that defines the CSV columns, `cpu_util.log`, `windows.txt` (window start/end), `fio-ssd<i>-<k>.json/.err` and `fio-ssd<i>-<k>_iops.1.log` (per-second IOPS) |
| `utils/reports/<sweep>/<config>-RUN-<j>[-ssd<i>]/` | parsed `pcie.rpt`, `membw.rpt`, `cpu_util.rpt`, `fio.rpt` |
| `utils/logs/<sweep>/datapath.jsonl` | the pre-sweep datapath check, kept out of the summary |
| `utils/logs/<sweep>/failed.txt` | each failed point: config, exit status, the runner's first error |

**Terminal or tmux.** Both scripts run in the current terminal by default.
`--tmux` (sweep or runner) starts them in a new tmux session named
`dualssd-sweep-<N>` or `run-dualssd-experiment-<N>` and attaches. The session
asks for the sudo password itself, because sudo caches it per terminal.
Detach with Ctrl-b then d, and re-attach with `tmux attach -t <name>`. When
the script ends, the window stays open on its output. Progress: each sweep
configuration prints `[k/N]` with the time so far and an estimate of the time
left. From another terminal, `tail -f utils/logs/<sweep>/sweep.log` follows
it without attaching.

About 110 s per run with `pcm-memory`, ~60 s with `DUALSSD_ARGS="--membw 0"`.
Both sweeps default to 1, 2, 4, 8, 16 and 32 instances per drive (since
2026-10-07; 1–8 before). The default sweep (19 runs) takes ~35 min and
`--single` (55 runs) ~100 min per IOMMU mode. The default cross sweep is 31
runs, ~1 h (~30 min without `pcm-memory`); `--single` doubles that. Its results are named
`dualssd-xsweep-<iommu>-<N>`, the block-size sweep's
`dualssd-bssweep-<iommu>-<N>`. Lock:
`/tmp/dualssd-experiment.lock`. Stop with
`pkill -f 'dualssd_swee[p]'; pkill -f 'run-dualssd-experimen[t]'`. The runner
stops its own fio on the way out. The first sweep (2026-10-05) predates this
layout: its runs are directly under `utils/logs/` and `utils/reports/` as
`dssd-strict-*`, and a rerun under the old scripts would have overwritten them.

### Reading the output

- **Compare IOTLB misses per I/O** (misses/s ÷ IOPS), not raw counts. Across
  block sizes compare **MISS/4K**, misses per 4 KiB read.
- **Every PCM value is in the JSONL and the `.txt` (since 2026-10-10).**
  - From `pcm-iio`, on the SSD row:
    - inbound write and read (`PCIe_wr_tput`, `PCIe_rd_tput`)
    - outbound read and write (`PCIe_ob_*`: the CPU's MMIO, i.e. NVMe doorbells)
    - all 7 VT-d events
    - `pcie_samples`
  - From `pcm-memory`:
    - read, write and total MB/s per socket (`Node<N>_*_bw`) and system-wide
      (`System_*_bw`)
    - `membw_samples`
  - Each record lists these keys under `pcm_keys`, and also stores `pcm_row`
    and `membw` (on/off). The `.txt` prints two more tables after the summary.
  - **Earlier records lack the outbound and all `pcm-memory` values.** The old
    awk parser wrote empty values on bigserver: it matched only older PCM's
    `NODE n Mem Read` lines, and current PCM prints `SKT  n`. Not yet checked
    against a real bigserver `membw.log`; the first run shows values or prints
    a warning with the log's first lines. The raw logs still hold the data:
    `python3 utils/parse_membw.py utils/logs/<sweep>/<config>-RUN-<j>/membw.log`.
  - Per-channel memory bandwidth and the other `pcm-iio` stacks stay in the
    raw logs only.
- **Block size** (`dualssd_bs_sweep.sh`): a 1 MiB read costs one map, unmap
  and invalidation, like a 4 KiB read, for 256× the data. If the 4k ceiling
  is a per-I/O cost, GB/s rises with block size until the uplink binds (LINK
  BOUND). If GB/s stays near 3 GB/s at every size, the limit is bandwidth.
- **CONTENTION** compares the co-run's misses per I/O to each drive's
  single-drive figure, weighted by that drive's share of the co-run's IOPS. A
  plain mean of the two baselines would be wrong because the drives differ
  (traps below). It compares at the same instances *per drive*, so the co-run
  has twice the total instances. Misses per I/O also rise with total instances
  on one drive, so check the co-run at J against one drive at 2J too (First
  result, below).
- **KEPT%** is each drive's IOPS in the co-run as a share of its IOPS alone at
  the same block size and instances, e.g. `s0:55` (drive 0 kept 55%). It needs
  only that drive's single run, and it also means something with the IOMMU off.
- **Grids** (`dualssd-results.py grid`, printed at the end of a cross sweep):
  per IOMMU mode, block size down and instances across, for the co-run's total
  kIOPS (`*` = LINK BOUND), the drive 0 / drive 1 split, GB/s, CPU µs per I/O
  and misses per 4 KiB, and for each drive run alone, its kIOPS and KEPT%.
  Where strict mode's per-I/O ceiling (flat kIOPS along a row) turns into the
  link ceiling (flat GB/s down a column) shows which binds where.
- **Strict vs off:** IOPS and `CPU_us/IO` at the same block size and instance
  count. With the IOMMU off the miss columns read 0.
- **Why this may show what icx did not:** with `O_DIRECT` the NVMe driver maps
  every I/O's buffer on submit and unmaps it on completion. In strict mode
  every completion is a synchronous IOTLB invalidation through `dmar7`'s single
  invalidation queue, which all instances on all cores share. That is the
  per-I/O churn §4.1 B suspects mlx5's page recycling avoids. 4k reads maximise
  it per byte.

### Results before PIPS (10-05 to 10-11): archived

The First to Fifth results (strict 4k, interrupt-aware placement, block-size
sweep strict vs off, cross sweeps on switch designs A-C, design D) are in
[docs/archive/pre-pips.md](docs/archive/pre-pips.md); report "Dual-SSD Cross Sweeps"
https://claude.ai/artifact/AcYH8Ff2Drt5kon44un3gX. In short:
- **Strict caps 4k random reads at ~40% of off** (652K vs 1.64M IOPS, off at
  the Gen3 x8 uplink). From 16k up both modes sit at the link. The cost is
  per I/O (map, unmap, synchronous invalidation), not per IOTLB miss.
- **fio must run off the drives' interrupt CPUs** (Second result;
  `scripts/ssd-irq-placement.sh` checks a boot's layout).
- **Switch designs A and C starved drive 0** on a full link; B and D share it
  about evenly. D was the design for IOMMU work until PIPS.
- The "extra inbound writes" at strict 4k on C and D were a `pcm-iio`
  undersampling artifact (withdrawn 10-16; Traps below).
### Counters on Skylake

`opCode-6-85.txt` is the paper's own event set (its Cascade Lake is also model
85), and PCM ships the same events. Here the paper's names are accurate:
`pcie.rpt` writes `IOTLB_hits`, `IOTLB_misses`, `CTXT_Miss`,
`L1_Miss`/`L2_Miss`/`L3_Miss` (VT-d misses by walk level) and `Mem_Read`
(VT-d memory reads), and starts with `cpu_model: 85`.

- **On icx the same keys are legacy aliases with different meanings** (§6).
  Never compare icx and bigserver `pcie.rpt` files by key name.
- The VT-d events are per stack and appear on the stack's Part0 row. Bandwidth
  is per Part, read from the `SSD_PCIE_PATTERN` row. On bigserver both are the
  Part0 row of the stack holding `b0:00.0`.
- `IOTLB Hit` (umask 0x01) is called `L4_PAGE_HIT` in `collect_iio_occ.c`.
  Intel's public perfmon lists have no Skylake VT-d events, so neither name can
  be checked against Intel's own definitions.
- Current PCM rejects a `divider` key in event files, and older PCM may not
  accept `unit`, so the file uses neither. If bigserver's PCM is old enough to
  need `divider`, the discovery script shows a parse error or no CSV.
- `record-host-metrics.sh` picks the parser by CPU model, so icx output is
  unchanged. `PCM_BIN` and `PCM_CORE` in `setup-server.sh` override where PCM
  lives and the core it runs on (icx defaults: `$PCM_DIR/build/bin`, core 15).

### Traps (bigserver)

- **NVMe numbering is not stable across reboots,** and every strict/off
  comparison needs one. Drives are configured by serial and resolved at run
  time. Never put a `/dev/nvmeN` name in the config.
- **Shared host.** `record-host-metrics.sh` ends each window with `pkill -9 pcm`
  and `pkill -9 -x sar`, which would kill other users' copies. Two PCMs also
  corrupt each other's counters. The runner refuses to start while any
  `pcm*` or `sar` is running, and lists other users' fio.
- **The two drives are not a matched pair.** Different models, and the 990
  EVO Plus is DRAM-less. It uses a 64 MiB host memory buffer, confirmed at
  boot: `nvme nvme1: allocated 64 MiB host memory buffer`. Its accesses to
  that buffer are extra DMA through the same root port and IOMMU. From 64k up
  they appear in `PCIe_wr` but not in fio (third result, item 7). The 990 EVO
  Plus is also nearly empty: reads of never-written blocks
  return without touching flash, so its IOPS measure the controller, not the
  NAND. Expect different single-drive misses per I/O; hence the weighted
  CONTENTION.
- **No passwordless sudo on bigserver.** Everything works only while a recent
  password entry is cached. Run `sudo -v` in the same terminal (same tmux pane)
  right before a runner or sweep; their own sudo calls keep the cache alive.
  Earlier "passwordless" checks passed only because a `sudo` had just been
  typed. Do not add a NOPASSWD rule on this shared machine without the admins.
- **Read-only by design.** nvme0 holds an unmounted ext4 filesystem with data.
  fio always runs `--readonly`, and the runner refuses drives that are mounted
  or held by md, LVM or dm.
- **The Gen3 uplink may bind before the IOMMU does.** The summary marks
  LINK BOUND when PCIe write exceeds 85% of the narrowest shared link. On
  designs C and D in strict mode at 4k, the extra inbound writes trip it while
  fio moves only ~25 Gbps (Fifth result, item 4): check fio's GB/s there.
- **`pcm-iio` sometimes logs only 1–5 samples, and then every rate it reports
  is ~2× high** (inbound writes, reads, IOTLB hits and misses alike). Seen at
  heavy strict 4k points on design D (10-10) and 0x0A04 (10-16), always the
  same points; 0x0A02 (10-13) logged 15–17 everywhere. Check `pcie_samples`
  in the JSONL (`mean.pcie_samples`) before using any `pcm-iio` value; treat
  < 10 as missing. Runs with 0 samples are dropped by the runner. Cause not
  yet known: read `pcm-iio.out` and `pcie.csv` in such a run's
  `utils/logs/<name>-RUN-<j>/` folder.
- **1 MiB at 32 instances puts 1 GiB in flight per drive** (1024 reads). On
  switch designs that starve drive 0 at 1m, its reads waited ~1 s at 4
  instances, so expect several seconds at 32, against a 30 s NVMe timeout.
  Ran on design D (2026-10-10), which shares the link fairly: p99 ~0.45 s per
  drive, no failed point. `dmesg` not checked; still untested on A or C.
- **Never use a bare `wait` in a script that logs through
  `exec > >(tee ...)`.** It also waits for that `tee`, which never exits
  while the script runs. Reproduced on bash 5.0 and 5.1. This hung every run
  after the last measurement window on 2026-10-05 (`perf-j8`,
  `dualssd-sweep-strict-3`); fixed in the runner by waiting on the fio PIDs.
  Those two runs are incomplete; ignore them.
- `cpu_util.py` now parses `sar` output in both 12- and 24-hour locales. It
  previously needed the 12-hour format, and bigserver's locale is unchecked.
- **Drive b4 (990 EVO Plus) can freeze the whole host when it is reset after
  a load under vfio-pci** (5 of 6 times on 11-05; never at open). It claims
  Immediate Readiness, so 5.15 skips the wait after its FLR (§8 "Next",
  "bigserver freeze at b4's reset"). The drive alias campaigns therefore hold
  the drives and end with a reboot.

---

## 8. PIPS switch: batcher sweeps on the drives and the NICs

PIPS is the FPGA PCIe switch (VCK190, FPGA repo `pips_batch`,
`C:\Xilinx_Projects\pips_batch_new\Programmable-Intelligent-PCIe-Switch`)
whose batcher regroups the devices' upstream writes. The host reaches its
config, log DMA and TLP log through the upstream port's BAR0 (the PIO). How it
works, every register, and the log format:
[scripts/pips/PIO-MANUAL.md](scripts/pips/PIO-MANUAL.md); the tools and test
points: [scripts/pips/README.md](scripts/pips/README.md).

- **Drives:** bigserver, both NVMe drives behind PIPS since 2026-10-11 (first
  PIPS sweeps 10-13, design `0x0A02`).
- **NICs:** behind PIPS since 2026-10-15, one per downstream port. Run the NIC
  experiments on that server, as before on icx (§2); `run-dualnic-experiment.sh`
  finds the NICs below the switch by their PCI path.
- Every sweep and campaign so far, with its data folder: the archive files
  (top of this file) and FILE-MAP §7.

**Report pages (artifacts), one per design or campaign:**

| Page | Covers | Built from (git-ignored `dualssd/`) |
|---|---|---|
| "Dual-SSD Cross Sweeps" https://claude.ai/artifact/AcYH8Ff2Drt5kon44un3gX | drives before PIPS, switch designs A-D (10-06, 10-10) | `dualssd-xsweeps-report.html`, generator not kept |
| "PIPS Batcher Sweeps" https://claude.ai/artifact/XsrLugEhsaMzY6vwARSLGU | 0x0A02, drives, IOMMU off and strict (10-13) | `report-gen/build.py` |
| "PIPS 0x0A04–0x0A05 Sweeps" https://claude.ai/artifact/MbNxzaJ5KgmuM59PPC4NcA | 0x0A04 drives and NICs, 0x0A05 depth sweep (v10) | `report-gen/page4.py` |
| "PIPS 0x0A06 Campaign" https://claude.ai/artifact/L3U8deVtMb4nHmb91AscK3 | 0x0A06 campaign R1-R8, page order (v2) | hand-written `dualssd-pips-0a06-report.html` + `report-gen/page6.py` |
| "PIPS 0x0A07 Campaign" https://claude.ai/artifact/91VNbNGeJVyfuLLH8acGvY | 0x0A07 minimal rerun, verdict, paper campaign (v2) | hand-written `dualssd-pips-0a07-report.html` |
| "PIPS TLP Patterns" https://claude.ai/artifact/Ni2PkBjsera7xFxx6wJdF2 | averaged page-order summary, 0x0A04-0x0A07 (v6) | `report-gen/sumpage.py` |
| "PIPS Alias Campaign" https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q | alias campaign 1 (v1) | `report-gen/page1105.py` |

How each page is rebuilt: `dualssd/report-gen/README.txt` and FILE-MAP §7.

### Switch designs (design ID)

Every build reports a design ID (`sudo scripts/pips/pips cfg`, `design_id=`).
Two changes since the 10-13 sweeps matter to the experiments:

| Design | FPGA repo | Change |
|---|---|---|
| `0x0A02` | `e389cca`, 10-11 | design ID register. The 10-13 sweeps |
| `0x0A03` | `2c6c3f5`, 10-14 | **drain depth cap** (regfile reg1, `pips cfg set cap=1`): a drain sends at most `depth_threshold` packets instead of the whole FIFO. Off (0) is the reset value and what `0x0A02` did |
| `0x0A04` | `591d854`, 10-15 | **TLP log format v2**: one record per TLP leaving the batcher, tagged with its input and its time in the batcher (`pkt_wait`); no separate input records. Same trailer, so only the design ID tells the formats apart |
| `0x0A05` | `64193c6`, 10-17 | **batching FIFOs of 512 beats** (`FIFO_DEPTH`, was 128; FIFO 2 too): an input stops at 493 beats and asks for a drain above 477, so a batch reaches 95 drive or 53 NIC TLPs (18 / 10 before). Nothing else changed. The depth sweep ran on it |
| `0x0A06` | `9673e37` + timing fix `d44fdd0`, 10-23/24 | **page batcher** (`axi4_mwr_batch_pp`): per device, packets batch **by page** (8 segments of 128 rows, a 512-row overflow, a completion lane that fences: a device's older data leaves before its completion), weighted round robin by open pages, a read flushes its own device first. reg2 = completion size per input (0 = 16 DW), reg3 = `page_batch_en` (power-on 0: one in-order FIFO per input, 1536 rows, 0x0A05's triggers; but the build ties `wrr_en` = 1 (`pips_batch_ctrl.v:121`), so the arbiter stays open-page weighted, completions-first and read-flush-first even at 0: not 0x0A05's plain round robin, see result 9), `ctrl_push_off`, `grant_quantum`; status at `0x24`-`0x2C` (spills, stuck watchdog, longest MRd wait; `0x24` read clears). `batch_mrd` tied off. Depth/time/cap keep their meaning. PIO-MANUAL §6 |
| `0x0A07` | `28ff5b6`, 10-27 (AXI4-switch `aa823c9` + `1803d4a`) | As 0x0A06 plus: **rate caps** (reg4 `0x10`: in0, in1, out one byte each, n beats per 256 cycles = n x 0.5 Gb/s of 64-byte beats, 0 = uncapped = power-on; token bucket, held only between TLPs, reads and completions held too; input caps ahead of the `pkt_wait` stamp, the out cap inside it), **refused-cycle counters** (`0x30`/`0x34` in0/in1, any reason; `0x38`/`0x3C` the cap's part; free-running 32 bit, wrap after 17.2 s counted). **Read flush changed:** a read waiting at its barrier no longer preempts the other input's drain episode (0x0A06's did, and with reads waiting on both drives the two went out interleaved packet by packet); its input takes the next episode and drains to the barrier in one run, drain cap ignored. Worst-case read wait now includes the other input's episode (`axi4_page_batch_ch.v` header: ~30-77 us cap off, ~18-46 us cap on). `wrr_en` still tied 1. PIO-MANUAL §6 |
| `0x0A08` | `5fe3bda`, 11-07 | As 0x0A07 plus the **background read engine** `pips_bg_rd` with its test extensions (`BG_ID` "RIDP"): MRds under a switch port's ID, completions swallowed before the router. §8 "0x0A08: the background read engine" |

**Every artifact carries the design ID from now on**: raw logs in the name
(`pips-log-id0a04.bin.gz`), sweeps in the name (`<NAME>-id0a04-d8t22c1`), text
inside (`pips-cfg.txt`, `.rpt`, JSONL `pips_design_id`, summary first lines,
rows labelled `strict d8t22c1@0a04`). The decoders pick the log format by it:
`-id<XXXX>` in the name, else a `pips-cfg.txt` beside the log, else v1 (every
log from before). So the 10-13 logs still decode as before. Details:
[scripts/pips/README.md](scripts/pips/README.md), "Design IDs".

Settings are named `d<depth>t<time>[m1][c1]`: `d8t22c1` = depth 8, time 0x16,
drain cap on. A name without `c1` has the cap off, as every name from before.
From 0x0A06 the page batcher's fields follow when not at power-on: `p1`
per page, `o1` ctrl_push off, `q<N>` grant quantum, `w<N>` completion
threshold (`d64t255c1p1q256w31`); from 0x0A07 `r<in0>x<in1>x<out>` when a
rate cap is set (`d1t0c1r200x0x0`).

### Run

```bash
git pull; sudo -v
sudo bash scripts/pips/pips-bringup.sh        # after programming a new design: hwtest now checks reg1

# the depth sweep (below): cap on only, depths 1-64 with their timeouts
CFGS="1:0 2:22 4:50 8:106 16:218 24:255 36:255 64:255"
# drives (bigserver): the cross sweep + uneven co-runs per setting
DUALSSD_ARGS="--membw 0" ./scripts/sosp24-experiments/dualssd_pips_sweep.sh \
    --cfgs "$CFGS" --caps 1 --tag dsweep1 --tmux
# NICs (icx, behind PIPS): the flow sweep per setting, co-run only, one datapath check
./scripts/sosp24-experiments/dualnic_pips_sweep.sh --cfgs "$CFGS" --caps 1 --datapath-once --tag dsweep1 --tmux

# the 10-15/16 sweeps were:  ... dualssd_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64" --tmux
#                            ... dualnic_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64" --single --tmux
```

Both take each `--cfgs` setting with the drain cap off and then on (`--caps
"0 1"`, the default; twice the runs of the 10-13 sweeps; `--caps 0` for the old
set, `--caps 1` for cap on only). Cap on needs design `0x0A03` or later; on an
older build they refuse to start. Each setting is a full sweep named
`<NAME>-id<XXXX>-<setting>`, with a TLP log in every run checked FULL / CUT;
`~/<NAME>.txt` has every setting side by side, the log check, and the time in
the batcher (`WAIT_us`, v2 logs). `--tag LABEL` names the sweep
`<kind>-pips-<iommu>-<LABEL>` (else the next free `-<N>`); `--datapath-once`
runs the datapath check before the first setting only. Defaults:
`dualnic_pips_sweep.sh` 5/10/15/30 flows per NIC, uncapped, 1 run, co-run only
(`--single` adds each NIC alone, for CONTENTION); about 11 min per setting
without `--single` and with `--datapath-once`. Stop and restore as their `-h` says.

**Every sweep has a sweep ID** (`<NAME>@<host>@<start time>`) in each of its
runs and a manifest of them (`~/<NAME>.manifest.tsv`, also
`utils/logs/<NAME>/manifest.tsv`). Parse a sweep from its manifest, never by
globbing `utils/logs`: [scripts/pips/SWEEP-LOGS.md](scripts/pips/SWEEP-LOGS.md)
(format, rules, this campaign's names and counts, earlier runs to ignore).

### Retired designs: what each found

The sections themselves are archived (table at the top): 0x0A02-0x0A05 in
[pips-0a02-0a05.md](docs/archive/pips-0a02-0a05.md), 0x0A06 in
[pips-0a06.md](docs/archive/pips-0a06.md), the 0x0A07 campaigns in
[pips-0a07.md](docs/archive/pips-0a07.md). One line each:
- **0x0A02** (10-13, drives, off and strict): first PIPS sweeps; the batcher
  setting changes how a full link is shared, not the throughput.
- **0x0A04** (10-15/16, strict, cap off and on): the drain cap moves a full
  link's split, not its total; d1t0c1 holds one NIC to 75-78 Gbps; the v2
  log works (804 logs FULL); `pcm-iio` undersampling found (C/D's extra
  writes withdrawn). Page order: the cap at depth 1 doubles page switches;
  misses don't move.
- **0x0A05** (10-17/18, depth sweep 1-64, cap on): depth doesn't move
  throughput; the 512-beat FIFO makes the wait on a full link ~3x longer
  (4.2-4.7 µs mean); the NIC sweep stopped at `d24t255c1` when the switch
  stopped answering.
- **Page-order method** (10-19 to 10-26, "0x0A04 results" items 8-13, 0x0A06
  result 10): lines from the measured arrival order (`seq.jsonl`), the model's
  output held to the uplink with the stalls put back, the grant gap charged
  only on a re-grant to the same input.
- **0x0A06** (10-25/26, page batcher): page batching regroups pages (runs per
  I/O -28% drives, -50% NICs at d64) but strict mode's misses and throughput
  don't move; it ends the NICs' pause frames; page segments spill constantly;
  the knobs have no effect; reads wait up to 262 µs on a full uplink; NIC
  packet splitting is the NIC's receive backlog, decided by frame spacing on
  its wire. Result 10 (excess page switches) traced to the read flush.

### 0x0A07 in short

- **Minimal rerun** (drives 10-28, NICs 10-30): result 10 solved (pb0 back to
  0x0A05's page switches; the model within 2% at d16-64); pb1 d64 16k / 64k /
  1m 8.3 / 9.1 / 5.9 -> 2.6 / 3.4 / 3.5; NICs at the legal floor (2.29 per
  packet vs 2.28); the FPGA rate cap splits a NIC's packets. Then the
  verdict (next section).
- **Paper campaign** (11-01/02; legs strict, lazy, pt, off): batching costs
  nothing measurable (Gb/s -0.8..-2.1%, fio p99 within 1.2%); page order is
  the switch's, not the IOMMU's (within ±3% across modes); page order
  doesn't move IOTLB misses; strict costs throughput only for drives at 4k
  (j4: strict 16.2, lazy 46.2, pt 54.0, off 53.9 Gb/s); NICs within 0.3%
  across modes. E7 (map/unmap counts) has no data: no `perf` on either
  kernel. Drives' strict leg was refused at start (interrupt layout); the
  10-28 rerun stands in (user, 11-02).
### Verdict (2026-10-30): the switch study is done

The question the user asked ("is the study over, or do we keep adding to the
FPGA?"), judged on page order only:
- The 0x0A06 defect is fixed and nothing new broke (drives result 1, 5).
- NICs are at the legal floor; drives 4k/16k within 20-40% of it.
- The model reproduces pb0 within 2% at d16-64 on both hosts.
- NIC splitting is the NIC's receive backlog, not a switch feature to add.
- Left: drives at 64k/1m, 2.3-2.8x the legal floor, from page-segment
  spills. **Optional, one build:** more segments per device (or a spill
  that evicts the oldest segment instead of arrival-order overflow mode),
  plus a 32-bit spill counter; test drives 64k/1m, d16/d64, pb1 (~20 runs,
  30 min); bound 3.43 → 1.49, 3.46 → 1.25. Only if large drive I/Os matter.
- **Not worth building here:** completion coalescing (hold completions so
  several share a page), the only way below the legal floor (NICs 2.28 →
  ~1.3): it delays when the host learns an I/O finished, a trade this clean
  testbed can't judge; a separate study.

### IOMMU legs (copied from the paper campaign, still the boot lines to use)

One IOMMU mode per boot; campaigns read the booted mode and never change it
(user rule: reboots and GRUB are the user's). icx boots `6.12.43-vanilla`
(since at least 10-26): every leg must run on the same kernel. A typo such as
`intel_iommu_on` (underscore) is ignored and boots with the IOMMU off.

| Leg | Kernel command line (iommu tokens in `GRUB_CMDLINE_LINUX_DEFAULT`) | Group type |
|---|---|---|
| strict (the hosts' boot now) | `intel_iommu=on iommu.strict=1` | `DMA` |
| lazy | `intel_iommu=on iommu.strict=0` | `DMA-FQ` |
| pt | `intel_iommu=on iommu=pt` (no `iommu.strict`) | `identity` |
| off (optional) | `intel_iommu=off` | no group |

`scripts/pips/pips-iommu.sh mode` reads it from the devices behind the switch;
`pips-campaign.sh --leg M` refuses to start unless the devices are M.
### Alias campaign 1 in short (11-05/06)

Setup, results, the 11-06 follow-up and the 11-05 bring-up log are in
[docs/archive/pips-alias-1.md](docs/archive/pips-alias-1.md); page "PIPS Alias Campaign"
https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q; tools
[scripts/pips/alias/README.md](scripts/pips/alias/README.md); data
`dualssd/1105/`, `dualnic/1105/` (tables `py -3 dualssd/report-gen/c1105.py`,
model `geom1105.py`). In-house generators replace fio and iperf3: drives
`alias-nvme` (polled NVMe over VFIO), NICs `alias-rdma` (RDMA READs from
styx); a fixed set of pages `first + i*stride` (i < ws) mapped once, so the
misses are aliasing by design. Both hosts strict, 72 runs each.
1. The pattern sets the misses: 0 to ~1 per 4 KiB page; lookups per page =
   TLPs per page (drives 17.6, NICs 9.1).
2. **icx (Ice Lake-SP): 256 entries, set-associative, LRU, fewer than 16
   ways**, set index = low IOVA page bits (128x2, 64x4, 32x8 fit; the follow-up
   rules out 2 ways).
3. **bigserver (Skylake-SP): ~96 entries, no set conflicts**; its soft knee
   came from alias-nvme's per-queue cursors drifting.
4. Two devices that fit alone thrash together.
5. **A miss costs nothing measurable** (Gb/s within -0.24..+0.15%; up to 1.77
   M misses/s drives, 3.43 M/s NICs).
6. **The batcher doesn't move aliasing misses** (drives within 0.01 per page,
   NICs within 0.08).
7. Page order and cost as in the paper campaign.

Missing in campaign 1: NIC READ latency, per-device misses; the host
analysis's IOTLB simulation was wrong for alias sweeps (`--strict`). Follow-up
(11-06): drive 0 has no NVMe SGL (at most 1 miss per 4 KiB); page switches can
cost only through misses, which needs pages evicted between two of their own
TLPs: on icx with one set and more open pages than ways (campaign 2's
`n2rot`). Campaign 2 adds the latency, per-device patterns and the fixed
simulation.
### Alias campaign 2 (set up 2026-11-06, not run)

Asked by the user (11-06): a comprehensive run on icx that checks everything
discussed after the 11-05 results (rotation, small and scattered writes,
placement, geometry, walk depth, latency), runtime no issue; on bigserver a
deeper sweep where it can show more of the IOMMU (it can: below), with misses
per unit of data as the measure (bigserver's misses/s and Gb/s can't move).
`bash scripts/pips/pips-campaign.sh nic --alias2 --tmux` on icx (~19 h 30 with
the analysis), `bash scripts/pips/pips-campaign.sh ssd --alias2 --tmux` on
bigserver (~5 h, then the planned reboot). One strict boot each, as now.
`--dry-run` prints every command. `--runs` (default 2) repeats the comparisons.

New in the tools (only `bash -n`, the dry runs and MinGW `-fsyntax-only`
with stub headers checked here):
- `alias-rdma --sge-bytes B` (each scatter entry B bytes into the next pattern
  page: 4 KiB READs, small scattered writes), `--mtu B` (caps the RoCE path MTU;
  the server takes the smaller). JSON adds `sge_bytes`, `mtu_cap`.
- `alias-nvme`: each drive has its own pattern, backing and region
  (`--ws1 --stride1 --first1 --order1 --page-list1`); `--cursor shared` (one
  cursor per drive: strict pattern order; the default per-queue cursors drift,
  which made bigserver's 11-05 knee soft); sparse patterns (a page list, or a
  span over 64x the pages) map only their own pages (a 64 GiB span = 32
  mappings). Holder state `ready <pid> v2`; load command takes
  `KEY=VALUE` extras after the ready file: `first= list= ws1= stride1= order1=
  first1= list1= cursor= seed=`; a drive's region is remapped only when its
  pattern changes. Drive 1's seed is drive 0's + 1 (shuffle order differs per
  drive; was shared).
- Runners: `run-dualssd-experiment.sh` `--ws1 --stride1 --first1 --order1
  --page-list1 --cursor` (under the holder now also `--first`, `--page-list`;
  holder load wait 120 s); `run-dualnic-experiment.sh` `--ws1 ... --page-list1`
  (NIC 1), `--sge-bytes`, `--rdma-mtu` (NIC 1's seed 2), ready wait 90 s.
  Results add `alias_cursor`, `alias_*1`, `alias_sge_bytes`, `alias_rdma_mtu`;
  `dualnic-results.py` now reads each NIC's `fio.rpt`: `iops_nic<i>`,
  `lat_us_nic<i>`, `p99_us_nic<i>`, `window_covered_nic<i>` (the NIC READ
  latency the 11-05 data lacks).
- `pips-seq-grab.sh`: `PIPS_SEQ_STRICT=0|1` and `PIPS_SEQ_IOTLB` override the
  "-strict-" rule and the geometries; `pips-campaign.sh --alias`/`--alias2` set
  them (icx `32x8,64x4,128x2,1x256`, bigserver `1x96,1x64,1x128,1x256`, not
  strict). `--alias2` also reanalyses the 11-05 alias sweeps that way
  (`analyze-1105/`) and packs the generators' JSON and logs per run.

Phases (`a2_specs` in the campaign; labels in brackets):
- icx: **n2ways** (user 11-06: pin 4 vs 8 ways; nwy: stride 4096 = one set, ws
  1-16, NIC0 alone and both, 1 QP (strictly cyclic) and 4 QPs: the first ws that
  misses = ways + 1, both NICs miss once 2 ws > ways; nwyf: the same in sets 7
  and 13 (a ring or MTT page in set 0 would shift the knee); nwyk: stride 16384;
  nwyr/nwys: random and shuffled order at ws 4-16, the replacement policy),
  **n2sets** (nst: NIC0 alone, ws 5 and 9 at strides 2-1024: ws 5 misses from
  stride 64 on if 4 ways (64 sets), never if 8; ws 9 from 32 either way; odd
  multiples of 32 (96/192/320) check the index is the plain low bits; ws 3 and
  17 at 32-256: 2 and 16 ways ruled in or out),
  **n2rot** (nrt: ws 64 in one set, QPs 2/8/32 x MTU 2048/1024/512/256, d1t0c1
  and d16t218c1 x pb 0/1, NIC0 alone and both; misses per page above 1 =
  a page's TLPs evicted by other open pages of its set; page batching should
  cut them; control ws 64 stride 1), **n2small** (nsm: `--rdma-bs` 4096-256
  at ws 64/4096, 4 and 16 QPs: where misses start to cost), **n2sge** (nsg:
  4 KiB READs, 2048-256 B per page), **n2place** (npl: both NICs in the same
  sets, NIC 1 shifted by `--first1`; predicted 0 misses once the sets are
  disjoint), **n2share** (nsh: NIC0 ws 128, NIC1 ws 32-512), **n2walk** (nwk:
  ws 32, stride 32-65536), **n2cap** (ncp/nco: 192-320 pages; shuffle and
  random order), **n2lat** (nlt: 1 QP x 1 READ: hit, capacity, conflict,
  deep walk, 3 runs), **n2quant** (nqq: grant quantum 0 vs 4095), **n2rep**
  (nrp: the batcher grid at 3 patterns, 3 runs).
- bigserver (shared cursor throughout): **s2cap** (scp: ws 32-160 step 8,
  drive 0 alone and both: the exact size and LRU vs not), **s2probe** (spr:
  drive 0 ws 8 with its input capped `rcap0` 0/64/16/8/4/2/1 while drive 1
  thrashes at ws 65536 (`--single-ssd 1`: drive 1 alone in the same sweep, to
  subtract its misses); sprq: drive 1 idle at ws 16, drive 0 alone too). At
  rcap0=1 drive 0's 256 B writes are ~5 us apart (5 beats per 1.024 us window),
  so a page's 16 writes span ~80 us while drive 1 adds ~1.1 new pages per us.
  Random replacement predicts ~1 + 15 x (1 - (1 - 1/96)^k) misses per victim
  page, k = drive 1's pages per gap (rcap0=1: ~0.9 extra); LRU predicts 1
  (k << 96). Page switches per victim page reach 16. If it stays at 1 (LRU),
  only an engine adding ~20 M distinct translations/s between the victim's
  writes evicts it: the FPGA MRd engine's case (bypassing the out cap).
  **s2place** (spl: random pages in a 16 GiB span, and pages with equal low
  17 bits; FA predicts the same knee as s2cap, a hashed set index an earlier,
  softer one), **s2order** (sor: random/shuffle order), **s2walk** (swk: ws 32
  at pages 2 MiB-2 GiB apart; ws 128-2048 at 2 MiB apart: the walk caches),
  **s2rep** (srp).

Analysis when the tarballs are back: unpack in `dualssd/<MMDD>/`,
`dualnic/<MMDD>/`; extend `report-gen/c1105.py` (new keys: `alias_*1`,
`alias_cursor`, `alias_sge_bytes`, `alias_rdma_mtu`, `lat_us_nic*`) and
`geom1105.py` (shared cursor = 1 cursor), then a page.

**First launch (icx, 11-06, `c11060312`):** done in 4h25 with 12 sweeps, the
first of each phase (96 runs). Cause: `a2_phase` fed its spec lines to a
`while read` loop on stdin; the NIC runner's `ssh` to styx inherited that
stdin and ate the remaining lines, so each phase ended after one sweep. The
dry run never runs ssh, so it showed all 151. Fixed: the loop reads on fd 3
and `sweep_run` gets `</dev/null`. The 11-05 reanalysis found nothing in `~`
(those manifests were no longer there); it now also looks in
`~/pips-campaign-<kind>-c1105*/results/` and `utils/logs/<sweep>/manifest.tsv`.
Recovery, same stamp (its `progress.tsv` skips the 12 done sweeps; the
analysis and the tarball then cover all of them; ~17 h left):
`rm ~/pips-campaign-nic-c11060312/DONE; bash scripts/pips/pips-campaign.sh nic
--alias2 --stamp c11060312 --tmux`. bigserver's launch
(`ssd-c11060312`, same stamp by chance) was not hit: all 58 sweeps are in ~
(nothing in the drive runner reads stdin); tarball
`~/pips-campaign-ssd-c11060312.tar.gz`, to copy back. Its 11-05
reanalysis likely found nothing either (no c1105 files left in ~).

**Back (11-07):** both tarballs unpacked: `dualssd/1106/pips-campaign-ssd-c11060312/`
(58 sweeps, 5h00, switch fine), `dualnic/1106/pips-campaign-nic-c11060312/`
(151 sweeps after the resume, 23h44, switch fine; the first launch's 12-sweep
tarball is `dualnic/1106/pips-campaign-nic-c11060312-partial.tar.gz`). The NIC
resume's analysis did not run: `pips-analyze` refused because the first
launch's `analyze-new/` was there (its `analyze-new/` in the tarball is the
first launch's, 12 sweeps). Fixed in the campaign (an earlier analysis
folder is moved aside to `<dir>.prev-<time>`). Redo it by hand on icx
(about 2-3 h): `O=~/pips-campaign-nic-c11060312`; move `$O/analyze-new`
aside; `awk -F'\t' '$1=="done"{print "--manifest", $4}' $O/progress.tsv`
gives the manifests; run `pips-analyze.sh nic --sweeps ''
<them> -j 16 -o $O/analyze-new` with `PIPS_SEQ_STRICT=0
PIPS_SEQ_IOTLB=32x8,64x4,128x2,1x256` (what `--alias2` exports). The
counters (misses, lookups, Gb/s, latency) need no analysis: tables from
`results/` and `runs/` locally.

### Alias campaign 2 results (11-07)

Tables: `py -3 dualssd/report-gen/c1106.py [ssd] [nic] [json]` ->
`dualssd/1106/c1106-ssd.txt`, `dualnic/1106/c1106-nic.txt` (counters only:
no page order yet, the NIC analysis is to be redone, "Back" above). Policy
fits: `report-gen/repl1106.py` (icx), `probe1106.py` (bigserver). 1 run per
point except n2rot (2), n2lat/n2rep (3); every sweep's datapath row repeats
its first point and agrees within 0.04 misses/page.

icx (Ice Lake, NICs, alias-rdma READs of 4 KiB = 9.1 lookups per page):
1. **8 ways.** One set (stride 4096), NIC0 alone, 1 QP: ws 1-8 no misses,
   ws 9 0.94 per page, ws 10-16 1.01. The same in sets 7 and 13 and at
   stride 16384 (ws 8 0, ws 9 0.74). Both NICs, one set: ws 4 each (8) no
   misses, ws 5 each (10) 0.83. Placement (n2place) agrees: both NICs ws 8
   stride 4096 in one set 0.93, NIC 1 one set over (`--first1 1`) 0.
2. **32 sets, plain low-bit index.** ws 9 misses from stride 32 on (0.31-0.34,
   4 QPs), none at 2-16; strides 96, 192, 320 (odd multiples of 32) miss
   like 32. ws 5 never misses at any stride (<= 8 ways); ws 17 always. So
   32 x 8 = 256 entries; capacity (n2cap, cyclic stride 1): 240 no misses,
   256 0.09, 272 0.65, 288+ 1.0. Sharing (n2share): NIC0 128 + NIC1 32/64 no
   misses, + 128 0.15, + 192-512 ~0.66.
3. **Replacement: LRU-family.** 1-QP cyclic ws 9 misses 0.94 per visit: LRU,
   tree-PLRU, FIFO predict 1.0 (fit 0.09 over the cyclic rows), bit-PLRU 0.57
   (0.83), random 0.22 (1.96). Not resolved between LRU, tree-PLRU, FIFO: a
   list that re-touches a page (A..H, A, I) separates LRU from FIFO. Note:
   alias's "shuffle" is one fixed permutation cycled, so in one set it is
   cyclic (its 4-QP rows equal the 4-QP cyclic rows: 0.33 at ws 9 = the QPs'
   reordering); i.i.d. random order gives 1 - 8/ws under any policy.
4. **Rotation in one set makes several misses per page** (n2rot, ws 64 stride
   4096): NIC0 alone at 32 QPs, d1t0c1: 7.1-7.5 per page (MTU 1024-2048),
   11.6 at MTU 256; both NICs 8 QPs MTU 1024 3.6. **The batcher cuts it where
   one NIC rotates:** NIC0 alone 32 QPs MTU 2048 7.4 -> 2.0 (d16t218c1), MTU
   1024 7.1 -> 4.0, 8 QPs MTU 2048 1.5 -> 1.08; Gb/s 80-84 -> 92-96, but
   d1t0c1 alone is slower at 2 QPs too (82 vs 92, no misses), so that Gb/s
   gap is the setting, not the misses. With both NICs the cut is small (8
   QPs MTU 1024 3.6 -> 3.1; 32 QPs 3.46 -> 3.41); pb1 adds little or
   nothing (MTU 256 both: worse). Control ws 64 stride 1: no misses.
5. **First bandwidth cost of misses: scattered pieces at low QP counts**
   (n2sge, 4 KiB READ in 256-1024 B pieces, one page per piece): misses 1.02-
   1.14 per page (16 per READ at 256 B); NIC0 alone 4 QPs 256 B 44.6 vs 57.2
   Gb/s (fits, ws 64) = -22%, 512 B -22%, 1024 B -16%; both 4 QPs 256 B -15%;
   at 16 QPs no cost. READ size alone (n2small): misses 1.03 per READ,
   Gb/s ~unchanged except 1024 B at 4 QPs (-8 to -16%, 1 run).
6. **Walk depth** (n2walk, n2lat): memory accesses per miss 3.0 for pages up
   to 8 MiB apart (stride <= 2048), 6.0 from 16 MiB apart (stride >= 4096).
   READ latency 1 QP x 1 READ: hit 3.4 us, capacity miss (3 accesses) 3.6,
   deep miss (6) 3.8: ~0.2 us per miss level.
7. Grant quantum 0 vs 4095 (n2quant): no change. Repeats (n2rep): misses 1.03-
   1.08 per page in every setting, no batcher effect at 4 QPs stride 1/4096.

bigserver (Skylake, drives, alias-nvme 4 queues x qd 32, 18 lookups per page):
8. **Not LRU: another device's misses evict a page after ~10 insertions**
   (s2probe). Drive 0 ws 8 capped by rcap0, drive 1 ws 65536 (1.01 misses per
   page); drive 0's own misses (total minus drive 1 alone x its share):
   uncapped 0.18 per page (8 foreign misses between two visits of a page),
   rcap0 64 0.28 (12), 16 0.89 (56), <= 8 every visit (>= 117). LRU over
   ~96 entries would need ~88 foreign misses; every 96-128 entry candidate
   (fully associative or hashed sets, LRU or random) predicts at most half
   the measured rate. Fully associative **~40 entries, random replacement**
   fits (`probe1106.py`: 1x40 rnd error 0.20, 1x32 0.23, 1x48 0.27; 1x96 rnd
   0.96). Time alone does not evict: drive 0 capped to rcap0 1 (a page
   revisited every ~0.7 ms) with drive 1 on 16 pages that fit, or alone: no
   misses (sprqr).
9. **Capacity is soft** (s2cap, shared cursor): drive 0 alone no misses up to
   56 pages, 64 0.07, 96 0.21, 128 0.27, 160 0.41 (noisy, 1 run: 136 0.52);
   both drives ws 48 each no misses, 56 0.15, 64 0.31, 96 0.61, 160 0.82.
   Alone misses more than both at the same total (alone 96: 0.21; both 48+48:
   0): not one shared fully associative cache. Open, with item 8: the
   capacity knee (~56-64 per drive) is larger than the ~40 the probe fits.
   Random order (s2order) about as cyclic: completion order already scatters.
10. **No low-bit set conflicts:** 64 pages with equal low 17 bits (splhw64)
    0.09 per page = cyclic 64 (0.07). Random pages in 16 GiB (splrw) miss
    earlier and add L3 walk misses (128: 0.69, L3 0.56); 512 MiB apart (splhw
    96/128) add L2 walk misses (0.30-0.47 per page).
11. **Walk caches** (s2walk): ws 32 never misses at any stride up to 2 GiB
    apart (IOTLB holds them); at 2 MiB apart, L3 walk misses per IOTLB miss
    0.81 at ws 128, 0.97 at 512, 0.99 at 2048.
12. Batcher settings (s2rep, d1t0c1/d16t218c1 x pb0/pb1): misses unchanged
    (0.84 at ws 256 stride 1, 0.23 at ws 64 stride 4096).

### 0x0A08: the background read engine (built and tested 11-07)

What it is: design `0x0A08` = `0x0A07` + `pips_bg_rd`, a requester inside the
switch that issues memory reads (MRd) to host IOVAs under a switch port's
requester ID, interleaves them into the upstream request stream behind the
batcher, and swallows their completions before the router, so no device
ever sees one. Its purpose: evict a drive's IOTLB entries between two of its
own writes, so that page order turns into misses (X3 in the engine doc).
FPGA repo `5fe3bda` (decisions H1-H16 in its untracked `0A08_UPGRADE_PLAN.md`).
Design: [docs/PIPS-BG-READ-ENGINE.md](docs/PIPS-BG-READ-ENGINE.md) (register
map §7, experiments X0-X5 §12). Assumptions, tests and every run's results:
[docs/PIPS-0A08-ASSUMPTION-TEST.md](docs/PIPS-0A08-ASSUMPTION-TEST.md) (§1
A1-A11, §3 the test extensions, §4 the runs). **This build is the test build:
`BG_ID` reads `0x52494450` "RIDP"** (the engine-only `0x0A09` will read
"BGRD").

**Capabilities** (AXI segment `0xA402_0000`, 64 KiB; `BG_CAPS` `0x46cd0100`:
256 tags, table 8192 entries, trace 4096 reads, 64 histogram bins, NP-credit
gating present):

| Area | What it can do | Registers / `pips bg` keys |
|---|---|---|
| Addresses | pattern: `base + (first + i*stride)*4 KiB + offset`, cyclic or random order, `ws` pages; or table mode: up to 8192 entries, each a page index + one of 4 requester-ID slots, read in order | `base= first= stride= ws= order=cyclic\|random seed= offset= src=pattern\|table`, `pips bg table load FILE` (`page:slot` per line) |
| Requester | 4 RID slots; allowed: the two downstream ports (`in0` = `b2:00.0`, `in1` = `b2:01.0`) and the upstream port (`usp`); device IDs only with `unsafe=1` + a tag window + RID+tag sink (fallback F2, not needed) | `rid= rid1= rid2= rid3=` (`in0 in1 usp dev0 dev1 BB:DD.F none`) |
| Read size | 1-16 DW inside one 64-byte block (default 1 DW) | `dw=` |
| Rate | `INTERVAL` minimum clocks between issues (4 ns clocks: 1000 = 0.25 M/s, 1 = every clock), `MAX_OUT` outstanding reads, `COUNT` reads (0 = until stopped), NP header credit reserve | `interval= maxout= count= nphres= secs=` |
| Mux | idle-fill (only into cycles the devices leave free), round robin, engine-first | `arb=idle\|rr\|engine` |
| Tags | **tag window** `TAG_WIN` `[7:0]` lo, `[15:8]` hi, `[16]` enable; `MAX_OUT` must be <= its size (config error 6) | `tagwin=LO-HI\|off` |
| Measures | issued, completions by status (SC/UR/CA/other/poisoned/malformed/unexpected), timeouts, latency sum/min/max, 64-bin histogram, a per-read latency trace (4096 reads from `TRACE_SKIP`), stalls (arb/tags/credits), data check against the holder's page tags | `pips bg counters / hist / trace FILE / run trace=1 dcheck=1 backing=N` |
| Test extensions | leak monitor (completions for the engine that reached the router's outputs: must be 0), **tag census** (every tag each device used, `WIN_HITS`), straddle counters, NP credits and head-of-line cycles (`TFC`, `HOL_ENGINE/DEVICE`), capture of the last 64 completions (descriptor, `req_done`), clash detector (F2) | `pips bg census [clear] / facts [clear] / capture [N]` |

**Tools** (all on the host, tested on both):
- `pips bg ...` (pips.c): `info`, `set`, `start/stop/wait`, `run K=V... [secs=S]`
  (start, heartbeat, stop, print every counter as `key=value`), and the
  commands in the table. `pips bg help` lists the keys.
- `scripts/pips/pips-rid-live.sh`: the live tests T0-T12 (T10-T12 the
  fallbacks, only with `--fallbacks`). On bigserver it starts the alias-nvme
  holder (`--start-holder`), whose `map` command maps a region of tagged
  pages at IOVA `0x4000000000` in each drive's domain (and, as a side effect,
  flushes those IOTLB entries: T8 uses that). Run:
  `bash scripts/pips/pips-rid-live.sh --start-holder --reboot --tmux --no-ridcheck`
  (~16-25 min, reboots at the end: the holder can't release the drives).
  On icx no holder: `pips_bg_region.ko` maps
  65536 tagged pages in each NIC's own domain (DW0 = page mod 8192, DW1 = the
  NIC's number, so T2/T3 see whose domain answered; a reload flushes them for
  T8), and the load windows run alias-rdma READs on both NICs against servers
  on styx (ports BASE_PORTS + 700 as the campaigns, utils/setup-server.sh). Run on icx, IOMMU
  strict or lazy, kernel headers installed, styx's repo pulled:
  `bash scripts/pips/pips-rid-live.sh --tmux` (~16 min, no reboot).
  Output `~/pips-rid-live-<host>-<MMDD-HHMMSS>/` + `.tar.gz`: `summary.txt`,
  `results.tsv`, `T*/`.
- `pips-campaign.sh` refuses 0x0A08 (it accepts 0x0A06/0x0A07 only); the
  batcher and rate caps are 0x0A07's, so the campaigns would run, but
  nothing records the engine's state yet.

**Results on bigserver (3 runs, 11-07; the third: every test passes):**

| Test | Assumption | Result |
|---|---|---|
| T1 | the core sends the engine's RQ beat | PASS (UR from the upstream port's ID, as expected) |
| T2, T3 | **F0: a downstream port's ID reads in its drive's domain, isolated** | PASS in all 3 runs: in0 reads drive 0's page tags, in1 drive 1's; a page mapped only for drive 0 is UR through in1 |
| T4 | no leak under load | PASS: 5.27 G reads in 32 x 20 s trains under both drives' load, all SC, leak 0 |
| T5 | no straddled beats | PASS |
| T6 | the engine doesn't cost the drives | PASS for idle-fill; engine-first costs above ~2.5 M reads/s (table below) |
| T7 | latency tells hit from miss | PASS: hit 684 ns, miss 1064 ns (p50), 3% misclassified per read at 840 ns; 2 MB stride 1364-1436 ns, 1 GB 1568-1592 ns (each walk level ~0.2-0.4 us) |
| T8 | one IOTLB for both domains | PASS: drive 1's pages evict drive 0's entry exactly as drive 0's do |
| T9 | tag census | drive 0 tags 0-127, drive 1 0-63 under load: **128-255 free** |
| (A11, found in run 1) | engine tags must not overlap device tags | the core tracks requests by tag alone and device tags pass through unchanged; overlapping tags gave malformed completions and timeouts. The script now takes the census's free range |

Rate and cost (T4/T6, drives at 866/785 kIOPS without the engine):

| Engine | Reads/s | Drive 0 | Drive 1 |
|---|---|---|---|
| idle-fill, any INTERVAL/MAX_OUT | 0.20-0.66 M (its ceiling) | +-1% | +-1% |
| engine-first, up to INTERVAL 100 | <= 2.5 M | -1% | -1% |
| engine-first, MAX_OUT 8 | 8 M | -4% | -3% |
| engine-first, INTERVAL 10, MAX_OUT 64+ | 25 M | -13% | -8% |
| engine-first, INTERVAL 1, MAX_OUT 64 | 62 M | -29% | -24% |
| engine-first, INTERVAL 1, MAX_OUT 128 | 118 M (MAX_OUT / ~1 us) | -59% | -57% (NP header credits hit 0) |

**Results on icx (3 runs, 11-07; the third: every test passes):** T2/T3: each
port reads its own NIC's region (both regions at IOVA `0xc0000000`; in1's port
read in1's NIC's page there, DW1 2). T4: 8.2 G reads under both NICs' load, all
SC. T7: hit 520 ns, miss 748 ns (p50), 4% misclassified; a 2 MiB stride adds
nothing. T8: one IOTLB for both NICs, a page evicted after 256 fresh ones (32
sets x 8 ways, LRU family; two reads protect nothing). T9: NIC 0 tags 0-7 to
0-21 depending on load, NIC 1 0-3. Rate and cost (NICs at 1587/1588 kIOPS of 4
KiB READs without the engine):

| Engine | Reads/s | NIC 0 | NIC 1 |
|---|---|---|---|
| idle-fill, any setting | 0.25-15.0 M | 0% | 0% |
| engine-first, up to MAX_OUT 8 | <= 12.3 M | 0% | 0% |
| engine-first, INTERVAL 10, MAX_OUT 64+ | 25 M | -4% | -5% |
| engine-first, INTERVAL 1, MAX_OUT 64 | 87 M | -30% | -31% |
| engine-first, INTERVAL 1, MAX_OUT 128 | 167 M | -64% | -65% |

**Rules learned (keep them in any engine use):**
- Engine tags in the census's free range: **128-255 on both hosts** (the
  script cuts a free range ending at 255 to its upper half: NIC 0's tags grew
  from 0-5 to 0-21 under heavy engine trains), so `MAX_OUT` <= 128. Redo the census at the experiment's load (`pips bg census`):
  the set can grow with queue depth.
- `count=0` for timed runs (a count ends the run early).
- Idle-fill gives at most ~0.66 M reads/s under the drives' load, about 0.7
  reads per 1.024 us window, not the ~170 per window X3's plan assumed.
  X3 needs engine-first, whose cost is in the table.
- **The IOTLB keeps reused entries against one-shot reads** (T8 v2 with run 2
  and alias campaign 2): after a flush ~130 fresh pages fit; once full, a page
  read once, or twice 4 us apart, is evicted by <= 32 fresh pages, while pages
  reused over time survive thousands. One-shot engine reads evict only
  entries not yet reused. Whether a drive's page is still evictable between
  two of its writes is open: the replacement probe (T8b, proposed in the
  test doc §4 "Third run", not written) would settle what earns the hold.

**State:** bigserver runs 0x0A08; its holder from the third run still holds
the drives (reboot before the next run). icx: every test passes (third run,
11-07 18:25); nothing held, nothing to reboot. Results in
`dualssd/1106/rid-live/` (FILE-MAP §7).

### 0x0A08 stress campaign (`pips-campaign.sh ssd|nic --bg`, written 11-07, not run)

Why (user, 11-07): the engine loads the IOMMU cheaply. A 1-DW read is one
translation for ~24 B of uplink (a drive's 4 KiB read: ~18 lookups for 4 KiB),
and its completion travels the near-idle downstream direction and is
swallowed in the switch. So the engine can stress Skylake's IOMMU far beyond
what the drives alone make (~30 M lookups/s, <= 1.7 M misses/s). Goal: the
drives' **misses per I/O** (and throughput, latency) under that stress, by
batcher setting, to connect with the page order measured on earlier designs.
Server time is cheap: everything runs, ~30 h. Rules from the user: IOMMU
strict; native nvme with invalidations AND a clean static-page (VFIO) run; no
reboot except the final one; a launched campaign runs to completion;
stability first.

**Design.** Two halves in one campaign, native first (binding the drives to
VFIO can't be undone without a reboot):

| Phase | What |
|---|---|
| `nprep` | Drives on nvme. `ridcheck/pips_bg_region.ko` maps 65536 pages (256 MiB, on 4096 tagged backing pages) contiguously with one `dma_map_sg` in each drive's DMA domain (shared with the port above it: A1). 64-read data check through in0 and in1. Tag census under fio (16 x 4k, 4 x 1m, both drives) -> the engine's tag window (largest free range, 16 tags kept clear of the devices' when wide) and MAX_OUT (window size, <= 128) |
| `nalone` | Drives idle. X2: reads/s and latency against MAX_OUT 1-128 (interval 1) and against INTERVAL 250-1 at MAX_OUT with pcm-iio (IOTLB counters of the engine alone), for hits (ws 8), one-shot misses (ws 65536 random), 2 MiB apart (ws 128 stride 512). X1: capacity knee by latency, ws 16-512 cyclic and random, one read at a time, last 4096 reads traced; module reloaded per point (the unmap flushes) |
| `nstress` | fio random reads 4k/8k/16k/64k/1m x 4 per drive, drive 0 alone and both, d1t0c1 / d16t218c1 x pb 0/1, 2 runs; one sweep per engine level (below), light to heavy |
| `nseq` | fio **sequential** reads (`--rw read`; each instance its own slice of the drive) 4k/8k/1m x 4, same settings; levels off h16 m16 v16 mx |
| `nheavy` | fio 4k/8k/64k x 16 per drive, both; levels off m16 v16 mx |
| `ncross` | the engine in drive 1's domain (in1) with drive 0 alone and both; m16 v16 mx; 1 run |
| `ndeep` | **deeper queues**: a tag census under 4 x qd 512 (random, sequential) gives this phase its own tag window (the engine stays off here if under 32 tags are free), then fio random 4k/8k x 4 at iodepth 128 and 512 (32 elsewhere), same settings; levels off h16 m16 v16 mx |
| `nend` | module unloaded |
| `vprep` | hold_up (both drives to vfio-pci, one `alias-nvme --hold`, BMC guard), the holder's `bgmap` maps the engine's own region (2097152 pages = 8 GiB of IOVA at 0x2000000000, on 65536 backing pages) apart from the drives' load regions; data check; census under alias loads |
| `valone` | drive regions flushed (`map`); X1 (region remapped per point: the unmap flushes); **T8b**: 155 tables (192 warm fresh pages; per round P read k times back to back or d fresh pages apart, N fresh pages, P probed; k 1-32, N 4-256, 0 or 10 us between reads; `t8b/roles.tsv` names each read); X2 down to 1 GiB apart |
| `vstress` | alias 4k x 4 queues, ws 32 (fits) / ws 48 shared cursor (capacity edge) / ws 65536 (thrash), drive 0 alone and both, same settings and levels, 2 runs |
| `vcross` | the engine in drive 1's domain while drive 0 runs; ws 32 and 48; m16 c16 v16 mx |

Engine levels (arb=engine, data check on, tags in the window, MAX_OUT the
window's): `off`; hits ws 8 at 15.6 / 50 M/s / max (`h16 h50 hx`: the link
cost with no IOMMU work, the control); one-shot misses ws 65536 random at 1 /
4 / 15.6 / 50 M/s / max (`m1 m4 m16 m50 mx`: walker load; T8 says these evict
only entries not yet reused); 96 pages reused (`c16`, fits: capacity taken),
256 reused (`v16`, over capacity: reused misses); misses 2 MiB apart (`d16`).

**Reading it.** pcm-iio counts the engine's lookups and misses with the
drives'. Drive misses = total - the engine's: the hit levels add none; for
the others use the engine's latency histogram per run (`bg-hist.txt`, hit
~0.7 us / miss ~1.1 us, T7) or its rate x its miss share from `nalone`/`valone`.
Compare each level with its same-rate hit control: the difference is the
IOMMU's share; the hit control alone is the link's.

**Tools changed for it.**
- `run-dualssd-experiment.sh`: `PIPS_BG="K=V ..."` runs `pips bg run ...
  stopwin=1` through each run (started before the warm-up, stopped after the
  windows): `logs/<run>/bg-run.txt`, `bg-hist.txt`, `reports/<run>/bg.rpt`,
  results `bg_spec bg_label bg_rate_mrd_s bg_lat_ns bg_lat_max_ns bg_errors`
  (`bg_spec=off` without). Any engine problem (non-SC, timeout, data
  mismatch, leak, device tag in the window, no reads) fails the run and writes
  `PIPS_BG_STOPFILE` (campaign: `<out>/bg/stop-<half>`): the rest of that half
  runs no engine. A leak or clash stops it for the campaign (`bg/DEAD`).
- `pips bg run stopwin=1`: stops at once when `WIN_HITS` rises (a device read
  on a tag in the engine's window; exit 6).
- `alias-nvme` holder: `bgmap NAME MASK WS STRIDE [base=A] [backing=N]` (state
  "bgmap"; `hold/bg-<i>` gives the IOVA). Checked before anything that could
  end the holder (a dead holder = BMC reset).
- `ridcheck/pips_bg_region.c`: the native region (`/sys/kernel/debug/pips_bg_region/regions`).
- `pips-bg-lib.sh`: the phases, sourced by `pips-campaign.sh`.
- Soft lockups in the native half end the native half only (the vfio half
  still runs). The campaign reboots at the end only if the vfio half started.

Widened 11-07 (user: "avenues for the base fio runs"): 8k, sequential reads,
deeper queues (rows above). The engine-off sweeps of every phase run even when
the half has no usable engine (they are the base runs); `nseq`/`ndeep` are in
the native half only (the holder's qd and bs are fixed).

**icx (`pips-campaign.sh nic --bg`, ~33 h, IOMMU strict, no VFIO, no reboot):**

| Phase | What |
|---|---|
| `iprep` | the devices below in0's and in1's ports (from `pips bg info`; a note if NIC 0's interface is not in0's), `pips_bg_region.ko` in each NIC's domain, data check, tag census under iperf3 30 flows and alias-rdma 32 QPs (one-set rotation) on both NICs -> window (128-255 expected) |
| `ialone` | X2 and X1 as on bigserver (knee ws 16-512: 256 entries expected) |
| `irepl` | the replacement policy (alias campaign 2 item 3: LRU, tree-PLRU or FIFO), 14 traced tables in one set (pages 5 + 32 j): `fA fB fE` (A..H fresh, A, I fresh, probe A / B / E: FIFO / LRU / tree-PLRU miss there), `u<P>s<S>` uniform random over 9-16 pages, `h6f<K>` 6 hot pages + a fresh one every K reads; `bg/nic/repl/roles.tsv` |
| `itcp` | iperf3 TCP (map/unmap per packet) 5 and 30 flows per NIC, NIC0 alone and both, d1t0c1/d16t218c1 x pb 0/1, 2 runs; one sweep per level |
| `irdma` | alias-rdma READs into a static MR: `f` ws 64 (fits, 4 QPs), `r` ws 64 stride 4096 (one set: the rotation, 7.4 misses per page alone and the batcher's cut to 2.0; 32 QPs, MTU 2048), `t` ws 65536 (4 QPs); same settings and levels |
| `icross` | the engine in NIC 1's domain, patterns f and r, levels m16 v16 mx, 1 run |
| `iend` | module unloaded |

icx levels: as bigserver without `d16` (a 2 MiB stride costs nothing there,
T7); `c16` = 128 pages (4 of each set's 8 ways), `v16` = 512 (twice the
capacity). Rates on icx: engine-first free up to ~12 M reads/s, -4% at 25 M,
-30% at 87 M, -64% at 167 M (§ above). Same reading as bigserver: each level
against its same-rate hit control.

**Run (bigserver, booted strict, drives on nvme, no holder):**
`git pull`, then `bash scripts/pips/pips-campaign.sh ssd --bg --dry-run`, then
`bash scripts/pips/pips-campaign.sh ssd --bg --smoke --only "nprep nalone nstress nseq nheavy ncross ndeep nend" --tmux`
(~1 h 05, native only, no reboot: checks the module, the census, the
runner hook), then `bash scripts/pips/pips-campaign.sh ssd --bg --tmux` (~44 h 30,
reboots at the end). **icx** (booted strict, styx up, kernel headers): `git pull`, then
`bash scripts/pips/pips-campaign.sh nic --bg --tmux` (~33 h; `--smoke` ~2 h 25 first if
wanted). Copy back `~/pips-campaign-nic-<stamp>.tar.gz`. Copy back `~/pips-campaign-ssd-<stamp>.tar.gz`; `bg/` in it
holds the engine-alone data (x1/x2/t8b traces, pcm reports, census).

**Not checked here** (no Linux): the module and the holder change are only
syntax-checked (MinGW, stubs); the scripts by `bash -n` and the dry runs (both
kinds, full and smoke). fio's `--offset=N% --size=N%` (nseq) and the NIC runner's
engine hook have not run on a host.

### Next

Status 11-09 (later): bigserver rebooted by the campaign's end: drive 0's interrupts now on CPUs 39/44 (36/41, 40/45 in earlier boots), so `SSD_CORES[0]` -> "37,42,38,43,40,45" (host-local `utils/setup-server.sh`); re-check `ssd-irq-placement.sh --check` after every boot.
Status 11-09: **bigserver `ssd --bg` c11082355 ran 5 h 27 and stopped short** (engine start failure in each half stopped all engine-on sweeps; engine-off sweeps and the engine-alone phases complete): "Last updated" at the top; results `dualssd/1108/`.
Status 11-08 (23:55): **bigserver `ssd --bg` launched, refused at preflight** (nothing ran): this boot drive 0's queues interrupt on CPUs 36/41 (earlier boots 40/45), and its fio cores held both. bigserver's `utils/setup-server.sh` (host-local) now `SSD_CORES=( "37,42,38,43,39,44" "46,50,47,51,49,53" )`, SSD_SPLIT_CORES=0; `ssd-irq-placement.sh --check`: OK. Relaunch resumes the same stamp. Re-check after the campaign's final reboot.
Status 11-08: **icx campaign stopped at iprep, styx's disk full**: run `bash scripts/pips/styx-check.sh` on icx; on SAFE, `bash scripts/pips/pips-campaign.sh nic --bg --tmux` resumes. bigserver's not started.
Status 11-07 (19:30): **stress campaign for both hosts, not run**: bigserver `pips-campaign.sh ssd --bg --tmux` (~44 h 30, + 8k, nseq, ndeep; reboot at the end), icx `pips-campaign.sh nic --bg --tmux` (~33 h, no reboot). Section above.
Status 11-07 (evening): **0x0A08 stress campaign written, not run** (section above): on bigserver `git pull`, the native smoke (~45 min, no reboot), then `pips-campaign.sh ssd --bg --tmux` (~30 h, reboot at the end). icx side next (needs the engine's bring-up on icx first: census of the NICs' tags, data check).
Status 11-07 (third icx run, 18:25): **T0-T9 all PASS on icx** (test doc §4 "Third icx run"). 0x0A08's assumption tests are done on both hosts.
Status 11-07 (second icx run, 18:02): the NIC load ran. T4: 6.6 G engine reads all SC, but NIC 0's tags grew from 0-5 (T0 census) to 0-21 under heavy trains, 23 inside the window 6-255 -> FAIL, run stopped before T7-T9. Fixed: the window is the upper half (128-255) of a free range ending at 255. Cost on icx: idle-fill free up to 15 M reads/s, engine-first free to ~12 M, -4% at 25 M, -29% at 84 M, -96% at 245 M. Census `cpl0`/`cpl1` maps are swapped vs the doc (both hosts). Rerun the same command.
Status 11-07 (first icx run, 17:47): **T1-T3 PASS: F0 holds on icx** (each port reads its own NIC's region; both regions at IOVA 0xc0000000, in1's port read in1's NIC's page there), T7 hit 520 / miss 752 ns, **T8: one shared IOTLB**, evicted from N 256 (32 x 8). T4-T6, T9 skipped: styx dropped the load's ports 3760/4760; fixed (+700, as the campaigns). Rerun the same command. Test doc §4 "First icx run".
Status 11-07 (icx bring-up): `pips-rid-live.sh` now runs on icx without a holder: pages from `pips_bg_region.ko` in each NIC's domain (DW1 = the NIC's number), a built-in alias-rdma load against styx; the old TLP-log harvest is gone (the pages it found were unmapped once its load ended). To run: `bash scripts/pips/pips-rid-live.sh --tmux` on icx (IOMMU strict or lazy). Copy back `~/pips-rid-live-icx-*.tar.gz`.
Status 11-07 (third run, 15:00): **T0-T9 all PASS.** F0, A7 (one shared IOTLB), engine-first free to ~2.5 M reads/s, the IOTLB keeps reused entries against one-shot reads (test doc §4 "Third run"). Next: the replacement probe (T8b) if the evictor design needs it; 0x0A09 = the engine's extras, tag window default 128-255.
Status 11-07 (first results, 01:04 run): **T2/T3 PASS: F0 holds** (port IDs read their drives' pages, isolated). **T4 FAIL**: in every train one completion came back SC with byte count or "request completed" wrong, then timed out; the failing tags were all in drive 0's 0-127: the core tracks requests by tag alone and the devices' tags pass through to it (new assumption A11). Fixed in the script: the engine's tags = the largest range unused in T0's census (128-255), MAX_OUT capped to it, T4 checks `CPL_MALFORMED` and `WIN_HITS`, captures saved on errors (`req_done=` in `pips bg capture`). Next: a fresh run, as a campaign (the 01:04 run's holder is gone): on bigserver `git pull`, then `bash scripts/pips/pips-rid-live.sh --start-holder --reboot --tmux` (new `--tmux`; ~1 h; reboots at the end; tarball `~/pips-rid-live-bigserver-*.tar.gz` written before the reboot). Its captures say which field the core sets. Test doc §4 "First run".
Status 11-07 (first attempt): bigserver's first `pips-rid-live.sh` run (01:01) stopped at the engine check although the bitstream is right (design 0x0a08, `bg_id=0x52494450`, `bg_caps=0x46cd0100` = RTL `BG_CAPS_VAL`, buses b1/b2/b4): the script's `kv` read only one key per line, and `pips bg info` prints several to a line. Fixed (`kv` reads KEY=value tokens; this also lets `leak_seen`/`clash_seen` from the status line through, which never matched before). Rerun the same command.
Status 11-07 (later): **0x0A08 built (FPGA `5fe3bda`), live tests written.** Once the bitstream is on bigserver: `git pull`, then `bash scripts/pips/pips-rid-live.sh --start-holder --fallbacks` after a reboot (drives on nvme), or without `--start-holder` while a holder runs; ~1 h; ends with the drives held (reboot: `sync; sudo systemctl reboot -ff`). Copy back `~/pips-rid-live-*.tar.gz`. icx: `--load-cmd '<a NIC load>'`. `pips-campaign.sh` still refuses 0x0A08 (it asks for 0x0a06/0x0a07).
Status 11-07: **run `pips-rid-check.sh` on both hosts** (bigserver with `--module --pt --vfio-drive0`, icx with `--module --pt`; read-only apart from drive 0's short VFIO bind) and copy back `~/pips-rid-check-*.tar.gz`. Then the hardware agent builds `0x0A08` ([docs/PIPS-0A08-ASSUMPTION-TEST.md](docs/PIPS-0A08-ASSUMPTION-TEST.md)), and its live tests T0-T12 decide F0/F1/F2/F3/F4.
Status 11-06 (night): **background read engine designed, not built** ([docs/PIPS-BG-READ-ENGINE.md](docs/PIPS-BG-READ-ENGINE.md)): next is the hardware agent's build of `0x0A08` (its §9, testbench §9.1, open questions §13), then host software S1-S8 (§10) and the bring-up X0 on bigserver (§12). The one assumption to test first: a PIPS downstream port's own requester ID translates through its device's IOMMU domain.
Status 11-06 (later): **alias campaign 2 set up, not run** (section above): `pips-campaign.sh nic --alias2 --tmux` (icx, ~19 h 30), `pips-campaign.sh ssd --alias2 --tmux` (bigserver, ~5 h + reboot). Committed and pushed 11-06.
Status 11-06: **the alias campaign is in and analysed** ("Alias campaign results" above; page "PIPS Alias Campaign" https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q). Nothing new is set up: the next campaign (tools T1-T6, phases c/g/i/s/r) is a proposal on the page, waiting for the user.

Older statuses (11-05 back to 10-20) and the item lists of 10-19/20 and
10-26: [docs/archive/handoff-log.md](docs/archive/handoff-log.md); the 11-05 alias bring-up
statuses (the bigserver freeze debug log, the NIC smoke tests):
[docs/archive/pips-alias-1.md](docs/archive/pips-alias-1.md).

**Open, all optional** (still not done, from those lists):
- One build with more page segments per device (drives 64k/1m), only if large
  drive I/Os matter (Verdict).
- Drives 4k j16 per IOMMU mode with `SSD_CORES` off the interrupt CPUs of
  every boot (paper campaign result 9).
- PIPS counters and knobs not built: a 32-bit overflow count (`0x28`
  saturates at 65535), FIFO occupancy high-water, MRd wait mean or histogram,
  hold only when the other input waits, a FIFO limit register, `wrr_en` in a
  register.
- `perf` / VT-d PMU on hold (user, 11-05): E7's map/unmap counts need `perf`
  built for each kernel.
- b4's `reset_method` (below), which would let the drives be released per run
  again.

#### Drive alias campaign, hold mode (bigserver)
**Drive alias campaign, hold mode (set up 11-05 late, user: "ready for the full campaign"):**
`bash scripts/pips/pips-campaign.sh ssd --alias --tmux` on bigserver (72 runs, ~1h20 of sweeps, ~1h55 packed; then it reboots the host). Before the sweeps it binds both drives and starts one `alias-nvme --hold ~/pips-campaign-ssd-<stamp>/hold` (queues 4, qd 32, bs 4k: the alias grids'), then `alias-guard.sh arm` (BMC watchdog 120 s, petted while the holder's heartbeat is fresh; panic on lockup, `kernel.panic=10`). Each runner call gets `ALIAS_HOLD`: the run's load is a command to the holder (`load NAME MASK WS STRIDE ORDER WARM SECONDS OUTDIR READY`), stopped by `hold/stop`; no bind, no restore, no block device (`vfio:<bdf>` in the results' `devices`). At the end: analysis, pack, `DONE`, guard disarmed, `sync; systemctl reboot -ff` (`--no-reboot` leaves it to the user). **Resume (user, 11-05):** every launch looks at `~/.pips-campaign-<kind>-<mode>.current`; a half-done campaign (no `DONE`) is picked up: `progress.tsv` lines `start`/`done` per sweep, done sweeps skipped (their manifests counted for the analysis), a sweep cut short runs again as `<label>r<n>`; in the same boot the holder and the petter are reused; after a reboot (a hang reset by the BMC) the drives are on nvme again and a new holder starts. `--fresh` starts a new campaign. Also fixed: `dualssd_pips_sweep.sh` and `dualssd_sweep.sh` name the sweep by the IOMMU mode of each drive, found through nvme: under `ALIAS_HOLD` they take the BDFs from `hold/drives`. Not yet run on the host: checked here are `bash -n`, the dry run, the resume detection (fake folder), the progress lines; the C with MinGW and stubs. The NIC side (icx) is unaffected: there `--sync-client` now syncs styx before the alias-rdma check (`b4a0c6cab`).

#### bigserver freeze at b4's reset (11-05)

Summary of the 11-05 debug log (verbatim in the alias archive): bigserver
froze, whole host, no kernel line, no pstore, no BMC entry, when drive b4
(990 EVO Plus, `b4:00.0`, behind PIPS port `b2:01.0`) was reset after an
alias-nvme load: vfio-pci's release FLR 3 of 3, the open-style
`VFIO_DEVICE_RESET` 2 of 3, with or without a clean NVMe shutdown first; b4's
resets at open (idle, out of D3hot) never froze; b3 never froze. After one
freeze the PIPS tree did not enumerate at the next boot (no Xilinx function;
FPGA still programmed; reprogram plus reboot fixed it; next time try a warm
reboot first). Fix chosen by the user: hold mode (above); `alias-stability.sh`
passed 14 of 14 loads. Debug tools: `scripts/pips/alias/alias-hangtest.sh`
(`--show`), `alias-postmortem.sh`.
Status 11-05 (b4 freeze, outside confirmation): the user found public reports (Linux 7.3 fix 0f8b5d90d179, Phoronix / Hardware Busters / Arch / Proxmox threads) that the Samsung 990 PRO [144d:a80c] and 990 EVO Plus [144d:a80d] claim Immediate Readiness but read ~0 for up to ~7 ms after an FLR; the kernel then skips the post-FLR wait and its config restore hits a drive that is not answering. 7.3 adds a quirk that ignores the bit for these IDs. That is our trace exactly (b4: no `pci_dev_wait` after `pcie_flr`; status 0x0011). Our 5.15.0-177 lacks the quirk (the trace proves it). On a desktop the restore is just lost; behind PIPS the access to a silent drive froze the host (our inference). Runtime options, no reboot: `reset_method` of b4 empty (no reset at all: vfio-pci then skips the FLR at open and release; nvme's own CC.EN reset on rebind) or `bus` (SBR on b2:01.0, only b4 below it, with the kernel's full wait; untested on PIPS's port). If the empty reset_method passes, drives can be released per run again and hold mode + `reboot -ff` become optional. The D3hot/AER report (Proxmox) does not match: no D3hot error, no AER, no SEL entry here.

