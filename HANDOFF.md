# Handoff — dual-NIC IOMMU contention on icx

Everything needed to run this testbed, plus what is known, unknown and broken.
Companion docs: [FILE-MAP.md](FILE-MAP.md) for which script does what and
calls what, [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md) for how the repo fits
together, [LOCAL-SETUP.md](LOCAL-SETUP.md) for first-time provisioning.

- **Branch:** `icx-dualnic` on `ycz011031/F_S_Memory_Script`
- **Upstream:** `host-architecture/Fast-and-Safe-IO-Memory-Protection` (remote `upstream`)
- `master` is a pristine mirror. `git diff master..icx-dualnic` is the whole delta.
- **Where things are:** [FILE-MAP.md](FILE-MAP.md) for every script, call
  graph and output (§2.6 the PIPS analysis chain), and §7 for the
  git-ignored analysis tree (`dualssd/`, `dualnic/`: which batch folder holds
  which sweep and design, which report generator reads what, the published
  pages). On the Windows analysis machine `claude.md` (git-ignored) adds its
  local paths, tools and editing gotchas.
- **To run (2026-10-20):** `scripts/pips/pips-analyze.sh` again on both hosts
  (§8 "Next" item 0): the 10-19 run's models were wrong (items 11-12); its
  length verdicts stand. Until it is back, the page's Figures 4/6 come from
  the listing-based recovery (item 12). Results come back as
  `~/pips-analyze-<kind>-*.tar.gz`.
- **2026-10-20 (NIC splitting):** why one NIC alone splits its packets and
  two together don't is in §8 item 13: the gap between a NIC's packets on
  its wire decides it; styx's shared dual-port card is the suspect
  (untested; tests in §8 "Next" item 5). Dual-NIC runs never recorded
  retransmits.
- **Last updated:** 2026-10-20 (later): page order **recovered from the
  10-19 listings** without the raw logs (§8 item 12): each device's own order
  is exact from the order as sent; the batcher model runs on it with I/O
  bursts and an output rate fitted to each log's recorded wait; checks
  within a few % from 16 KiB up. The NIC model's grant gap was wrong too
  (charged at every drain; two NICs taking turns don't pay it):
  `pips-page-seq.py` now charges it only on a re-grant to the same input.
  Page v8 (Figures 3-6 redrawn: each device's own order instead of "as
  arrived", both designs' logs, FIFO 128/512 lines; TL;DR, Limits, bullets).
  Page v9 (after user review): why d1t0c1 is below strict alternation, and
  why the NICs' by-NIC and by-page lines coincide (§8 item 12). Page v10:
  the "ideal" is replaced by two reference lines the user asked for: a
  **floor** (the best any batcher could do holding D TLPs per device, free
  to reorder, no FIFO/time/link/ordering) and a flat **raw** line (the
  arrival order, unbatched; modelled until the hosts rerun).
  2026-10-20: the 10-19 analysis came back
  (`dualssd/1019/pips-analyze-ssd-20261019-1723/`, `dualnic/1019/pips-analyze-nic-20261019-1723/`).
  Payload or control by size: a size rule holds (drives: ring = 4 DW,
  RELIABLE on drive 0, 99.88% on drive 1, which also writes small payload
  pieces; NICs: ring = 16 DW, 100%), the same on 0x0A04 and 0x0A05. The drive
  page-order model failed: its waits ran to ~1,400 µs because the output's
  logged times lack the stalls inside packets on the Gen3 x8 uplink, which
  `pkt_wait` counts (§8 "0x0A04 results" item 11). Fixed in
  `pips-page-seq.py` (stalls put back, link rate fitted per log and
  calibrated per sweep, each input's order kept); rerun pending. The NIC run
  left out the 0x0A05 sweep (no manifest in `~`; `pips-analyze.sh` now also
  looks in `utils/logs/<sweep>/`). Page v7: Table 11 (payload or control by
  size, `report-gen/sizes.py`) and the drive-model caveat in the TL;DR and
  Limits.
  2026-10-19 (later): the model charges a 3-cycle grant gap
  per drain, the page's Figures 4/6 average each point's logs and draw an
  ideal line that only fits the window; one host script, `pips-analyze.sh`,
  reruns page order and payload-or-control by length on both designs (§8,
  "0x0A04 results" item 10, "Next" item 0).
  2026-10-19: the depth sweep ran on design **`0x0A05`**
  (`0x0A04` with 512-beat batching FIFOs): drives all eight settings, NICs
  stopped during `d24t255c1` when the switch stopped answering (§8, "0x0A05
  depth sweep"). Depth doesn't move throughput; the bigger FIFO triples the
  wait on a full link. The batcher model in `pips-page-seq.py` now holds its
  output to the uplink: it had sent the drives' TLPs at twice the Gen3 x8
  rate, which flattened its depth lines; page order needs a regrab on both
  hosts (§8, "Next" item 0). Report: "PIPS 0x0A04–0x0A05 Sweeps".
  2026-10-17: the **depth sweep** is set up (§8, "Depth
  sweep"): depths 1–64, cap on only, timeouts picked so depth can win
  (`pips-timeout-pick.py`); on `0x0A04` a FIFO can't reach depth > 18 (drives)
  / > 10 (NICs), so d24/d36/d64 (and d16 on the NICs) are capped by the full
  trigger. Every PIPS sweep now has a sweep ID and a manifest of its runs;
  log parsers read the manifest ([scripts/pips/SWEEP-LOGS.md](scripts/pips/SWEEP-LOGS.md)).
  2026-10-16: `pips-page-seq.py` rebuilds the arrival order
  and models the batcher on it; regrab pending (§8, "Next" item 0). Page order
  on the `0x0A04` logs, drives and
  NICs (§8, "0x0A04 results" item 8; the cap at depth 1 doubles page switches,
  misses don't move); first `0x0A04` sweeps, strict, drives and
  NICs (§8, "0x0A04 results"); the C/D "extra inbound writes" withdrawn as a
  `pcm-iio` undersampling artifact (§7). 2026-10-15: PIPS switch design `0x0A04` (drain depth cap,
  new TLP log format), the PIPS sweeps crossed with the cap, a dual-NIC PIPS
  sweep, and the design ID on every artifact (§8). 2026-10-11: dual-SSD sweeps
  on switch design D (§7, "Fifth result"). icx last updated 2026-10-04: the
  uncapped flow sweep (§4.1) and the IOMMU counters checked against Intel's
  Ice Lake event list (§4.3).
- **PIPS switch (§8):** the FPGA switch the drives (bigserver) and now the NICs
  sit behind. Its batcher setting and, from design `0x0A03`, its drain depth
  cap are swept on both testbeds with a TLP log in every run. Every result
  names the switch's design ID, which also picks the log decoder.
- **Headline:** IOMMU strict and IOMMU off give the same throughput in every
  configuration run so far. Reasons are speculated in §4.1; the experiments
  that would settle them are in §5.
- **Second testbed (2026-10-05):** the same experiment with two NVMe SSDs and
  fio on bigserver, a Skylake-SP host (§7). Strict vs off block-size sweep
  done: strict caps 4k reads at 40% of off (§7, "Third result"). Switch
  design D (2026-10-10) shares the uplink evenly where A and C starved
  drive 0; use it for IOMMU work (§7, "Fifth result").

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
no longer measures contention. Check which IOMMU unit each NIC is behind with
the command in §5 item 1.

---

## 4. Results so far

### 4.1 Flow sweep, IOMMU strict vs off (2026-09-29)

**Expected:** with the IOMMU on, throughput drops as flows increase (the
paper's flow experiment). **Observed:** no throughput difference between strict
and off at any flow count.

**What was run.** `dualnic_flow_sweep.sh` defaults, once per IOMMU boot setting:
NIC0 alone at 5 flows as a datapath check, then both NICs together at 5, 10,
15 and 30 flows per NIC. Uncapped, 3 repeats each, MTU 4000, ring 1024,
`tcp_rmem` fixed at 2 MB and `tcp_wmem` at 1 MB (autotuning off), DCTCP with
ECN on, 20 s measurement window.

- strict: `intel_iommu=on iommu.strict=1`, NIC domain type `DMA`; one pass
- off: `intel_iommu=off`; two passes

Result files are on icx in `~/`: `dualnic-flowsweep-strict-3`, `-off-1`,
`-off-2` (`.jsonl` + `.txt`). A local copy may sit in the git-ignored `dualnic/`. **`strict-1` and `strict-2` are invalid**: two
sweeps ran at once and killed each other's traffic. The runner now refuses a
second copy (§2).

**Means over 3 repeats** (throughput in Gbps; per-NIC split in brackets):

| Flows/NIC | NICs | Tput strict | Tput off (pass 1 / 2) | PCIe wr strict | CPU % strict | CPU % off (1 / 2) | Misses/Gbps strict |
|---|---|---|---|---|---|---|---|
| 5 | NIC0 alone | 96.1 | 96.2 / 95.2 | 100.6 | 73.2 | 67.8 / 66.9 | 33,394 |
| 5 | both | 105.7 (41.4 + 64.3) | 105.7 / 105.7 | 110.5 | 62.7 | 62.3 / 62.4 | 34,791 |
| 10 | both | 105.7 (52.8 + 52.9) | 105.6 / 105.5 | 110.6 | 63.2 | 63.3 / 63.3 | 34,852 |
| 15 | both | 97.5 (48.7 + 48.7) | 94.9 ± 2.7 / 96.2 | 102.2 | 62.8 | 62.7 / 62.6 | 35,320 |
| 30 | both | 48.5 (24.2 + 24.2) | 48.5 / 48.4 | 50.6 | 61.4 | 55.9 / 56.0 | 36,324 |

Run-to-run standard deviation is ≤ 0.15 Gbps everywhere except off pass 1 at
15 flows. PCIe write with the IOMMU off matched strict within ~2 Gbps. CPU % is
the mean over the active NICs' receiver cores (5 per NIC).

#### Derived metrics

**IOMMU counters, strict.** Rates are per second (`pcm-iio` samples every 1 s).
"Per 4 KB written" divides by PCIe write traffic, which runs 4.5% above TCP
throughput in every configuration (headers, descriptors, completions).

| Flows/NIC | NICs | Lookups/s | Misses/s | Miss rate | Lookups per 4 KB written | Misses per 4 KB written | 4K PWC hits per miss | Upper-level PWC hits per miss | Mem accesses per miss |
|---|---|---|---|---|---|---|---|---|---|
| 5 | NIC0 alone | 28.2 M | 3.36 M | 11.9% | 9.2 | 1.09 | 1.02 | 0.005 | 4.1 |
| 5 | both | 31.1 M | 3.84 M | 12.4% | 9.2 | 1.14 | 1.05 | 0.016 | 5.2 |
| 10 | both | 31.2 M | 3.86 M | 12.4% | 9.2 | 1.14 | 1.07 | 0.025 | 5.4 |
| 15 | both | 28.9 M | 3.61 M | 12.5% | 9.3 | 1.16 | 1.08 | 0.028 | 5.5 |
| 30 | both | 14.4 M | 1.84 M | 12.7% | 9.4 | 1.19 | 1.05 | 0.022 | 5.6 |

PWC is the page-walk cache. "Upper-level" is the 2M, 1G and 512G PWC hits
combined. Lookups are *first* lookups: a transaction can look up the IOTLB more
than once, and the event counts only the first (§4.3).

**Receiver CPU cost:** cores busy per 100 Gbps, i.e. mean CPU % × active
cores ÷ throughput.

| Flows/NIC | NICs | strict | off (pass 1 / 2) |
|---|---|---|---|
| 5 | NIC0 alone | 3.8 | 3.5 / 3.5 |
| 5 | both | 5.9 | 5.9 / 5.9 |
| 10 | both | 6.0 | 6.0 / 6.0 |
| 15 | both | 6.4 | 6.6 / 6.5 |
| 30 | both | 12.7 | 11.5 / 11.6 |

- **The miss rate is flat at ~12%** (11.9% → 12.7%; run-to-run SD ≤ 0.03
  points). Flow count barely moves it.
- **About one miss per 4 KB page written (1.1–1.2), and ~9 lookups per page.**
  This fits each fresh receive page missing once, with its remaining writes
  hitting.
- **Walks are shallow.** 4K PWC hits about equal misses, and upper-level PWC
  hits are 0.5–2.8% of misses. That fits each walk needing only the final
  page-table read, which is the cheap case.
- **Memory accesses per miss is the one IOMMU counter that grows with flows:**
  4.1 → 5.6. Its meaning is unverified. It also reads 75–138 k/s with the IOMMU
  off, so it counts something besides translation.
- **Strict's CPU cost:** +8% alone, +10% at 30 flows, nothing at 5–15 flows with
  both NICs.
- **Two NICs cost 55–70% more receiver CPU per Gbps than one** (5.9 vs 3.5–3.8 at 5
  flows), with the IOMMU on or off.
- **Receiver CPU per Gbps doubles from 10 to 30 flows** in both modes (6.0 →
  11.5–12.7), while total receiver CPU stays flat or falls.

#### Observed

1. **Throughput is the same with the IOMMU strict and off**, at every flow
   count.
2. **Translation is active in strict mode, but misses look cheap.** At 5 flows
   with both NICs: ~31 M IOTLB lookups/s, ~3.8 M misses/s (~12%). Page-walk-cache
   4K hits (4.0 M/s) and context-cache hits (4.0 M/s) about equal the misses,
   so nearly every miss is served by the page-walk cache. Misses per Gbps rise
   only 4.4% from 5 to 30 flows. With the IOMMU off these counters read 0.
3. **The only visible cost of strict is CPU**, and only in two places: NIC0
   alone (+5 to 6 points) and 30 flows (+5.4 points, about +10% relative). At
   5–15 flows with both NICs there is no CPU difference.
4. **Both NICs at 5–10 flows sit at the shared-uplink ceiling:** 110.5 Gbps PCIe
   write, 105.7 Gbps throughput. At 5 flows the split is uneven (NIC1 ≈ 64,
   NIC0 ≈ 41) in both modes and all passes; at ≥ 10 flows it is even.
5. **Throughput falls off a cliff above 10 flows, identically in both modes:**
   97.5 at 15 flows, 48.5 at 30, each NIC exactly 24.2 at 30. PCIe write falls
   with it (50.6), so traffic really dropped; it is not a parsing artifact.
   From 15 flows up, per-NIC throughput × flows is constant (48.7 × 15 ≈
   24.2 × 30 ≈ 725–731), so each NIC's rate scales as 1/flows. The receiver
   cores are *less* busy at 30 flows than at 5.
6. **NIC0 alone at 5 flows runs at line rate in both modes.** 96 Gbps against a
   TCP maximum of ~97.8 Gbps on 100G at MTU 4000.

#### Speculated reasons (not established)

**A. No configuration was limited by the IOMMU.** Every point had another,
tighter limit:

| Configuration | Binding limit |
|---|---|
| NIC0 alone, 5 flows | the 100G port (line rate) |
| Both, 5–10 flows | the shared x8 Gen4 uplink |
| Both, 15–30 flows | the cliff (reason C), identical in both modes |

The IOMMU can only cost throughput when it is the tightest limit. The paper's
drop appears with **one NIC as flows increase**. That configuration was not run:
NIC0 alone was only run at 5 flows. *Confidence: high that this masks the
effect; it does not by itself explain the missing CPU cost at 5–15 flows.*

**B. The stock 6.8 kernel may already avoid the cost the paper measured.** The
paper's "IOMMU on" baseline is stock 6.0.3. Strict mode costs throughput when
receive buffers are mapped and unmapped constantly: each unmap invalidates the
IOTLB and page-walk caches, so later misses need slow walks to memory. Newer
mlx5 drivers are believed to recycle receive pages through `page_pool` while
keeping them DMA-mapped, which would make unmaps and invalidations rare. That
is believed, not verified, and it is not known in which kernel it landed.
Observation 2 fits this: misses are served from the page-walk cache, as if it
is rarely flushed. **Caveat:** `IOMMU_mem_access` is ~5 per miss (19.9 M/s
against 3.8 M/s), which does not fit walks ending in cache. Intel's description
of that counter does not settle what it counts (§4.3), so this evidence is
suggestive only. *Tests: §5 item 2 (hardware invalidation counts) and item 3
(map/unmap counts).*

**C. The 30-flow cliff is not the IOMMU and not the uplink.** It is identical
with the IOMMU off, and at ~50 Gbps the uplink is half idle. Both NICs land on
exactly the same number, which points at a resource each NIC has its own share
of:
- **Sender CPU** (prime suspect, never measured): at 30 flows styx runs 60
  iperf3 senders on 14 physical 2.0 GHz Broadwell cores, 4–5 per core.
- **Receiver per-core saturation:** each icx core runs 6 iperf3 servers. The
  10-core CPU average could hide one or two cores at 100%. Per-core numbers are
  in `cpu_util.rpt`, not in the JSON.
- **TCP behaviour** (losses, retransmits, ECN marks): not collected at all.

Receiver CPU per Gbps doubles at 30 flows (derived metrics). Two readings fit.
Either per-flow overhead on the receiver is the limit, with the 10-core average
hiding saturated cores. Or slower flows simply batch worse, with fewer bytes
per interrupt and per GRO merge, and the cost is an effect of the cliff rather
than its cause. Per-core CPU separates the two.

*Confidence: low on which one; high that it is not the IOMMU. Test: §5 item 6.*

**D. More flows barely grows the IOMMU working set here.** aRFS steers each
flow to the receive queue of the core its iperf3 server runs on. With 5 server
cores per NIC, only about 5 receive rings are active per NIC at any flow count.
Extra flows only add sockets holding up to 2 MB of received data each. If B
holds, those buffers stay mapped and do not churn. That would fit misses per
Gbps rising only 4.4% from 5 to 30 flows.

**E. The uneven 5-flow split** (NIC1 64 vs NIC0 41) is probably arbitration in
the PCIe switch or flow placement under uplink saturation. It is unexplained,
consistent across runs, and harmless to the totals.

**F. Two NICs cost 55–70% more receiver CPU per Gbps than one.** With both NICs
each core carries ~10.6 Gbps instead of ~19.2, so fixed per-interrupt and
per-wakeup costs are spread over fewer bytes. Backpressure from the saturated
uplink may add to it. Not investigated.

### 4.2 Earlier: capped at 30 Gbps per NIC, 8 flows (before 2026-09-29)

Ring 1024, MTU 4000, one run each:

| | tput | PCIe_wr | IOTLB misses | misses / Gbps |
|---|---|---|---|---|
| nic0 alone | 30.000 | 31.404 | 1,057,452 | 33,672 |
| nic1 alone | 30.000 | 31.466 | 1,057,468 | 33,606 |
| **both** | 60.000 | 62.687 | 2,167,475 | **34,576** |

**+2.8% IOTLB misses per Gbps with both NICs active, and no throughput loss** —
each NIC held exactly 30 Gbps. At 62.7/126 = 50% uplink utilization, neither the
link nor the Broadwell sender was binding, so this is attributable to the IOMMU.

The two baselines agree to 0.002%, which shows the NICs are symmetric. It does
**not** establish run-to-run variance — `--runs 1` was used. A 2.8% effect is not
defensible until repeated.

Uncapped, for reference: single NIC ~97 Gbps, both 105.7 Gbps at 110.5 Gbps PCIe
write (88% of the uplink). Link-bound, so throughput there says nothing about the
IOMMU. Normalized it showed +4.2%, but under backpressure.

In the `both` breakdown, `PWC_4K_hits` (2,207,682), `CTXT_cache_hits` (2,205,155)
and `IOTLB_misses` (2,167,475) are nearly equal while 512G/1G/2M hits are 3–4
orders smaller — essentially every miss resolves via a 4K page-walk-cache hit.
But `IOMMU_mem_access` is 10.3M, 4.7 per miss, which does not obviously fit
walks terminating in cache. Intel's event description does not settle what that
counter measures (§4.3).

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

## 5. Next experiments and open items

In order of what each one decides. Commands run on icx from
`~/F_S_Memory_Script`.

1. **Simpler switch design.** As of 2026-10-15 the NICs sit behind the PIPS
   switch (§8), whose batcher and drain cap are now swept with
   `dualnic_pips_sweep.sh`. The steps below still apply to the new placement.
   It removes the bias from the earlier topology: both NICs behind one PCIe
   switch with a single x8 Gen4 uplink, which capped every 2-NIC run at
   ~105.7 Gbps (§4.1 A).
   **Keep the IOMMU shared** if contention is still the question: NICs behind
   different IOMMU (DMAR) units have nothing to contend for (§1). With the
   IOMMU on, check which unit each NIC is behind:
   ```bash
   for d in 0000:99:00.0 0000:9a:00.0; do    # substitute the new addresses
       echo "$d -> $(basename "$(readlink -f /sys/bus/pci/devices/$d/iommu)")"
   done                                       # same dmarN = shared IOMMU
   ```
   Then re-run `discover-pcie-topology.sh`, update `PCIE_PATTERN` (§3), and
   check the new link widths with `sudo lspci -vv -s <addr> | grep -E 'LnkCap:|LnkSta:'`.

2. **Record the missing IOMMU events (§4.3) before the next sweep,** at least
   the invalidation counts and page-walker saturation. Add lines to
   `utils/opCode-6-106.txt`. Then update the column offsets in
   `record-host-metrics.sh`, which reads fixed CSV columns that new events
   shift, and add the new keys to `PCIE_KEYS` in `scripts/dualnic-results.py`.
   More events mean more time-sharing of `pcm-iio`'s 4 counters per stack, so
   check one run on icx before a sweep.

3. **Does 6.8 map and unmap per packet? (~5 min, booted strict. Tests §4.1 B.)**
   Needs `linux-tools-$(uname -r)` for `perf`.
   ```bash
   ./scripts/run-dualnic-experiment.sh -E diag-maps --nics 1 --nic-index 0 -S 5 -C 5 --uncapped > ~/diag-maps.log 2>&1 &
   sleep 60
   sudo perf stat -e iommu:map,iommu:unmap -a -- sleep 5
   ethtool -S enp153s0f0np0 | grep -E 'rx_pp_|cache_'
   wait
   ```
   At ~96 Gbps, receive data arrives at ~3 M 4 KB pages/s. If unmaps run near
   that rate, strict is churning as in the paper, and B is wrong. If they are
   far below it, pages are recycled while still mapped. Then the paper's effect
   will not reproduce on this kernel: do item 5.

4. **Single-NIC flow sweep, strict vs off, at the paper's flow counts. Tests
   §4.1 A.** Removes the shared uplink. Once per IOMMU setting:
   ```bash
   ./scripts/sosp24-experiments/dualnic_flow_sweep.sh "5 10 20 40" uncapped 3 nic0only
   ```

5. **Boot the paper's baseline kernel, stock 6.0.3,** if item 3 shows
   recycling. Build it per `README.md` (no patch is needed for the "IOMMU on"
   baseline) and re-run item 4. Only then compare against the F&S-patched
   kernel.

6. **Explain the 30-flow cliff. Tests §4.1 C.** It sits exactly where the
   paper's effect should appear, so it would hide an IOMMU drop even on the
   right kernel.
   ```bash
   ./scripts/run-dualnic-experiment.sh -E diag-f30 --nics 2 -S 30 -C 30 --uncapped > ~/diag-f30.log 2>&1 &
   sleep 60
   ssh yz69@192.17.100.255 'top -b -n 1 | head -25'   # sender cores at 100%?
   top -b -n 1 | head -25                              # receiver
   wait
   cat utils/reports/diag-f30-RUN-server-0/cpu_util.rpt   # per-core receiver CPU
   # NIC0 alone at 30 flows: ~24 again means a per-NIC limit, not a 2-NIC effect
   ./scripts/run-dualnic-experiment.sh -E diag-f30-nic0 --nics 1 --nic-index 0 -S 30 -C 30 --uncapped
   ```

7. **Make the IOMMU the tightest limit,** once items 2–6 say it can matter:
   - **Fewer receiver cores** (1–2 per NIC via `SERVER_CORES`). The CPU becomes
     the limit, so strict's CPU cost (§4.1 observation 3) turns into lost
     throughput.
   - **Ring-buffer sweep, 256 → 4096.** A larger working set is the mechanism
     F&S targets, and no dual-NIC ring sweep has been run.
   - **MTU 1500.** About 2.7× more packets per byte.
   - **Rate capped below the uplink** (e.g. 40 Gbps per NIC), so the link never
     binds.

**Still open from before**

- **`IOMMU_mem_access` semantics.** ~5 per miss (§4.1 B, §4.2), and non-zero
  with the IOMMU off. Intel's description does not explain either (§4.3).
  Compare it against `PWC_CACHE_FILLS` once that is recorded (item 2).
- **`Part0` is confirmed live** (non-zero misses that scale with load) but was
  never cross-checked against a traffic-carrying Part in `pcm-iio` directly.
- **Broadwell ceiling:** ~97 Gbps on one link. Whether it can drive two links
  near line rate is untested. styx's two ports are one Gen3 card, so they may
  share a ~126 Gbps slot as well.
- **The capped 8-flow result (§4.2) is still `--runs 1`.**

**Instrumentation gaps** (each limits what the numbers above can show)

- **Sender CPU is never recorded.**
- **Per-core CPU is only in `cpu_util.rpt`,** not in the JSON.
- **Retransmits are never collected.** The runner copies `retx.rpt` from styx,
  but styx never writes one.
- **`membw.rpt` had no values.** The old awk parser matched only older PCM's
  `NODE n` lines. `utils/parse_membw.py` (2026-10-10) also reads current PCM's
  `SKT n`, which should fill the `Node<N>_*_bw` fields in the dual-NIC JSON
  too. Not yet checked on icx.
- **Several IOMMU events are not programmed:** page-walk-cache lookups and
  misses, invalidations, and page-walker saturation (§4.3, item 2).

---

## 6. Traps

- **This kernel is not the paper's.** icx runs stock `6.8.0-110-generic`; the
  paper's baselines are on 6.0.3. The IOMMU cost may not reproduce (§4.1 B).
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

### First result: strict, 4k random reads (2026-10-05)

Means of 3 runs, iodepth 32 per instance. Mean latency is from Little's law
(I/Os in flight ÷ IOPS); fio's own latency is in `fio.rpt`.

| Instances per drive | 9100 PRO alone | 990 EVO Plus alone | Both | Both ÷ sum of alone | Both: CPU µs per I/O | Both: misses per I/O |
|---|---|---|---|---|---|---|
| 1 | 225K | 182K | 365K | 90% | 5.7 | 1.36 |
| 2 | 237K | 368K | 507K | 84% | 8.1 | 1.38 |
| 4 | 431K | 532K | 669K | 69% | 10.3 | 1.50 |
| 8 | 603K | 674K | 739K | 58% | 17.2 | 1.71 |

**Observed**

1. **More instances give more IOPS, with diminishing returns.** From 1 to 8
   instances: ×2.7 on the 9100 PRO, ×3.7 on the 990 EVO Plus, ×2.0 for both
   together. GB/s is IOPS × 4 KiB. The PCIe link is never the limit: 25 of
   63 Gbps at most.
2. **One instance is about one core:** 1.0–1.2 cores busy, ~5.2–5.5 µs of CPU
   per I/O, ~200K IOPS.
3. **CPU per I/O roughly doubles from 1 to 8 instances** on either drive, and
   triples in the 8-instance co-run (5.7 → 17.2 µs). Mean latency rises from
   ~140–175 µs to ~380–690 µs. Each I/O costs more as concurrency rises.
4. **The co-run at J instances per drive matches one drive at 2J**, on the 990
   EVO Plus. IOPS: 365K vs 368K, 507K vs 532K, 669K vs 674K. Misses per I/O
   and CPU per I/O match too: 1.50 vs 1.54 and 10.3 vs 10.2 µs at J = 4.
   Throughput follows the total instance count, not the number of drives; the
   second drive adds nothing a second set of instances on the first would not.
5. **The 9100 PRO does not scale from 1 to 2 instances** (225K → 237K) while
   using twice the CPU. The 990 EVO Plus doubles (182K → 368K).
6. **Misses per I/O rise only modestly with concurrency** (~1.1–1.2 → 1.4–1.7).
   CPU per I/O rises much faster.
7. **Both drives split node 2 into the same 4 NVMe hardware queues**:
   CPUs 36–40, 41–45, 46–49 and 50–53. Each queue has one interrupt, and in
   strict mode the unmap and invalidation run in that completion path. The
   `SSD_CORES` split puts the 9100 PRO's instances on fewer queues: at
   2 instances its cores 36 and 37 share one queue, while the 990 EVO Plus's
   45 and 46 use two. Number of queues used:

   | Instances | 9100 PRO (36–44) | 990 EVO Plus (45–53) |
   |---|---|---|
   | 1 | 1 | 1 |
   | 2 | 1 | 2 |
   | 4 | 1 | 2 |
   | 8 | 2 | 3 |
8. **In an 8-instance co-run, the interrupt CPUs of the queues in use are at
   100%; nothing else is.** `mpstat` and `/proc/irq/*/effective_affinity_list`,
   2026-10-05:

   | Queue (CPUs) | 9100 PRO interrupt CPU | 990 EVO Plus interrupt CPU |
   |---|---|---|
   | 36–40 | 38 | 40 |
   | 41–45 | 43 | 45 |
   | 46–49 | 47 | 48 |
   | 50–53 | 51 | 52 |

   The queues in use had interrupt CPUs 38 and 43 (9100 PRO) and 45, 48 and
   52 (990 EVO Plus): all five at 100%. The interrupt CPUs of unused queues
   (40, 47, 51) were 60–75% busy, like the other fio cores. The other fio
   cores sat 23–40% idle, most on the queue serving five instances (CPUs
   36–40, one interrupt CPU). `%irq` read 0 everywhere: this kernel counts
   interrupt time as `%sys`.

**Speculated reasons (not established)**

- **A host-side limit shared by both drives**, given 3 and 4. They share only
  `dmar7`: each drive has its own IOMMU domain, IOVA allocator and NVMe
  queues. In strict mode every unmap waits synchronously for an IOTLB
  invalidation through `dmar7`'s single invalidation queue, under a lock, so
  invalidations from every core serialize. The co-run plateaus near
  740K IOPS, about one invalidation every 1.35 µs. 6 fits: the cost is in
  keeping translations current, not in translating. **Tests:** the
  IOMMU-off sweep (it should scale with CPU per I/O roughly flat), lazy mode
  (`iommu.strict=0`, batched invalidations), and
  `sudo perf top -C 36-53` during an 8-instance co-run, looking for time in
  `qi_submit_sync` or spinlocks under the intel-iommu flush path.
- **A per-queue limit instead (favoured since 8; refuted by the second
  result, below).** Each queue's completions
  run on its one interrupt CPU. In strict mode that includes every unmap and
  its synchronous invalidation. At 8 instances those CPUs are saturated, and
  the fio cores wait on them. The plateau would then be set by how many
  queues, and so interrupt CPUs, a configuration uses, not by a limit shared
  through `dmar7`. Observation 4 may be the same effect, since the matched
  pairs used similar numbers of queues. **Test:** spread each drive's
  instances over all 4 queues and keep fio off the interrupt CPUs. IOPS
  rising well past ~740K means a per-queue limit; a ceiling near 740K means a
  global one. Then the IOMMU-off sweep with the same placement shows how much
  of the per-completion cost is the IOMMU.
- **Core placement, for 5 and 7.** The guess that the 9100 PRO has fewer
  queues was wrong (7). But its instances do sit on fewer queues, which fits
  5. A queue is not a hard cap, though: on one queue the 9100 PRO went from
  237K at 2 instances to 431K at 4. Where each queue's interrupt lands
  (`/proc/irq/<n>/effective_affinity_list`) and per-core CPU (`cpu_utils` in
  each `cpu_util.rpt`) should settle it. It also means the two drives'
  single-drive numbers are not comparable as run. With the interrupt CPUs of
  8, an order that gives each drive all 4 queues from 4 instances up, and
  keeps fio off every interrupt CPU up to 5 instances per drive, is
  `"36,41,46,50,37,40,45,48,52"` and `"39,42,49,53,44,38,43,47,51"`. From 6
  instances up, each drive's extra instances sit on the *other* drive's
  interrupt CPUs, which are idle in single-drive runs. Interrupt CPUs are
  assigned at boot and may move after the IOMMU reboot: re-check them first.

### Second result: strict, 4k, interrupt-aware placement (2026-10-05)

`dualssd-sweep-strict-4`, with `SSD_CORES` as recommended above: each drive
uses all 4 queues from 4 instances up, and fio stays off the interrupt CPUs up
to 5 instances. Means of 3 runs.

| Instances per drive | 9100 PRO alone | 990 EVO Plus alone | Both | Both ÷ sum of alone | Both: misses per I/O | Both: CPU µs per I/O | Both: latency µs |
|---|---|---|---|---|---|---|---|
| 1 | 226K | 227K | 366K | 81% | 1.26 | 6.4 | 175 |
| 2 | 377K | 374K | 597K | 80% | 1.43 | 7.1 | 214 |
| 4 | 562K | 589K | 605K | 53% | 1.76 | 13.4 | 422 |
| 8 | 564K | 596K | 713K | 61% | 1.84 | 20.6 | 718 |

**Expected ceilings at 4 KiB, if only the hardware limited:**

| Limit | 4 KiB IOPS | GB/s | `PCIe_wr` reads |
|---|---|---|---|
| Shared uplink, Gen3 x8 | ~1.55–1.7M total | ~6.4–7.0 | ~51–56 Gbps |
| Each drive's link, Gen4 x4 | ~1.6M per drive | ~6.4–7.0 | ~51–56 Gbps |
| 990 EVO Plus 1TB, rated | 850K | | |
| 9100 PRO 1TB, rated (on Gen5) | 1.85M | | |

How the link rows are derived:
- **Raw rate:** 8 GT/s × 8 lanes × 128/130 = 63 Gbps (7.88 GB/s).
- **Per-I/O traffic:** a 4 KiB read arrives as 16 PCIe writes of 256 B (32 of 128 B at a smaller max payload), each with ~26 B of header and framing. A command fetch and a completion entry add ~100 B.
- **Efficiency:** that leaves ~90% of the raw rate with 256 B max payload, ~83% with 128 B. The max payload in use is not yet checked.
- **`PCIe_wr` column:** it counts payload only, so link saturation reads ~51–56 Gbps there, not 63.

Both drives together should therefore reach ~1.5–1.6M IOPS, limited by the uplink. One drive alone should reach ~850K for the 990 EVO Plus (the drive's limit) and ~1.6M for the 9100 PRO (its link). Observed: 713K at most for both together, about 2.9 GB/s and 23.7 Gbps `PCIe_wr`, which is under half the uplink ceiling. Each drive alone plateaus at 560–600K.

**Observed**

1. **The earlier asymmetry between the drives was placement.** With the same
   placement, the drives match at 1 and 2 instances (226K/227K, 377K/374K).
2. **Each drive alone plateaus at ~560–600K from 4 instances.** From 4 to 8,
   IOPS stay flat while latency doubles (~220 → ~440 µs) and CPU per I/O rises
   from ~6 to ~10.5 µs.
3. **Both drives together barely exceed one drive** at 4 instances each:
   605K vs 562K and 589K, although the co-run has 8 queues and 8 separate
   interrupt CPUs. This fails the per-queue test set in "First result". The
   ceiling stays near 600–700K, so it is a limit shared by both drives.
4. **At equal total instances and IOPS, the co-run costs more than one drive.**
   Both at 4 each (8 total, 605K) vs one drive at 8 (564K, 596K): misses per
   I/O 1.76 vs 1.32 and 1.50 (+17–33%). CPU per I/O 13.4 vs 10.5 and 10.2 µs
   (+28–31%). Latency is about the same. This is the first sign of contention
   between the two drives in the IOMMU itself. Caveat: the single-drive run at
   8 puts instances on the other drive's interrupt CPUs, so the placements are
   not identical.

**Reading (not established).** Below half the link ceiling and below either
drive's rating, the shared limit is on the host side. The drives share
`dmar7`: its IOTLB, page walker and invalidation queue. The per-queue
explanation above is refuted. The IOMMU-off sweep with the same placement
decides it. If the IOMMU is the limit, the co-run should go well past 713K
toward the uplink ceiling (~1.5M, LINK BOUND), and the 990 EVO Plus alone
toward 850K. If the off sweep also stalls near 600–700K, look at the IIO
stack and the PCIe switch instead.

### Third result: block-size sweep, strict vs IOMMU off (2026-10-05)

`dualssd_bs_sweep.sh`: both drives, 4 instances each, means of 3 runs, once
per IOMMU boot setting.

| Block | Off: IOPS | Off: GB/s (fio) | Off: `PCIe_wr` | Strict: IOPS | Strict: GB/s | Strict: `PCIe_wr` | Strict ÷ off | Strict: misses per 4 KiB | CPU µs per I/O, off → strict |
|---|---|---|---|---|---|---|---|---|---|
| 4k | 1,644K | 6.73 | 54.8 | 652K | 2.67 | 22.1 | 40% | 1.63 | 4.35 → 12.69 |
| 16k | 418K | 6.86 | 55.7 | 400K | 6.56 | 53.3 | 96% | 1.40 | 9.82 → 10.23 |
| 64k | 69.8K | 4.58 | 53.2 | 69.1K | 4.53 | 52.8 | 99% | 1.21 | 25.0 → 27.9 |
| 256k | 20.8K | 5.46 | 54.4 | 20.8K | 5.44 | 54.3 | 100% | 1.15 | 46.5 → 53.5 |
| 1m | 6.1K | 6.44 | 55.6 | 6.1K | 6.43 | 55.6 | 100% | 1.10 | 129.6 → 161.4 |

**Observed**

1. **IOMMU off, 4k: 1.64M IOPS at 54.8 Gbps `PCIe_wr`,** the shared uplink's
   ceiling as predicted (1.55–1.7M IOPS, 51–56 Gbps). The link estimate holds.
2. **Strict, 4k: 652K, 40% of off.** Latency is 392 vs 156 µs, and CPU per
   I/O 2.9× (12.7 vs 4.35 µs). The ~600–700K ceiling of the earlier strict
   sweeps is the strict IOMMU.
3. **From 16k up, both modes sit at the link** (53–56 Gbps `PCIe_wr`) and
   match within 4%.
4. **The strict cost is per I/O, not per IOTLB miss.** At 16k, strict serves
   2.24M misses/s (400K × 5.6) at full link rate. At 4k it stops at
   1.06M misses/s (652K × 1.63). Misses per 4 KiB fall only slightly with block
   size, from 1.63 to 1.10.
5. **Strict's extra CPU per I/O grows with block size,** from +8 µs at 4k to
   +32 µs at 1 MiB, as more pages are unmapped per I/O. It no longer limits
   throughput above 4k.
6. **With the IOMMU off, `IOTLB Miss` still reads ~0.06–0.13 per I/O.** On icx
   it read 0. Treat it as this counter's floor on Skylake.
7. **Open: fio and `PCIe_wr` disagree from 64k up.** fio reports 4.5–6.4 GB/s
   where `PCIe_wr` says 6.6–6.95 GB/s, in both modes, with almost no
   run-to-run spread. Up to 16k they agree within 2%. Candidate causes:
   - throughput changing across the windows: fio's IOPS average all windows,
     while `PCIe_wr` covers only its own
   - thermal throttling of a drive
   - inbound writes that are not fio data

   The per-window IOPS in each `fio.rpt` test the first, and the per-second
   logs show throughput over time.

   **Checked 2026-10-05:** not time variation and not heat. Each drive's IOPS
   are the same in the CPU, PCIe and memory windows within 1%, and match
   fio's post-ramp figure. Both drives sit at 45–48 °C with zero
   thermal-throttle events. Split by drive (GB/s, IOMMU off; strict within 3%):

   | Block | 9100 PRO | 990 EVO Plus | fio total | `PCIe_wr` | PCIe − fio |
   |---|---|---|---|---|---|
   | 16k | 0.92 | 5.93 | 6.86 | 6.96 | +0.10 (+1%) |
   | 64k | 2.70 | 1.88 | 4.58 | 6.66 | +2.08 (+45%) |
   | 1m | 0.14 | 6.30 | 6.44 | 6.95 | +0.51 (+8%) |

   - **The saturated uplink is shared very unevenly,** and the split flips
     with block size. At 1 MiB the 9100 PRO completes 133 reads/s; with 128
     in flight, each waits ~1 s.
   - **Some inbound writes are never completed fio data:** 2.1 GB/s at 64k,
     the same in both IOMMU modes.
   - **None of this touches the 4k result.** There fio and `PCIe_wr` agree
     within 2%, and strict runs far below the link.

   **Resolved 2026-10-05 (`dualssd-bssweep-strict-2`, each drive alone,
   strict):** the extra writes come from the 990 EVO Plus. For each drive
   alone, `PCIe_wr` is that drive's traffic only:

   | Block | 9100 PRO: fio / `PCIe_wr` GB/s | 990 EVO Plus: fio / `PCIe_wr` GB/s |
   |---|---|---|
   | 16k | 4.86 / 4.95 (+2%) | 5.92 / 6.00 (+1%) |
   | 64k | 6.85 / 6.96 (+2%) | **1.89 / 3.94 (+108%)** |
   | 1m | 6.94 / 7.05 (+2%) | 6.40 / 6.92 (+8%) |

   `dmesg` at boot: `nvme nvme1: allocated 64 MiB host memory buffer`. The 990
   EVO Plus is DRAM-less and keeps its working cache in 64 MiB of host RAM. Its
   reads and writes of that buffer are DMA through the same root port and
   IOMMU. `PCIe_wr` counts them; fio does not. `dmesg` shows no I/O timeouts
   or link errors.

   That is the most likely explanation, not a proven one. `PCIe_rd_tput` in
   the same runs' `pcie.rpt` should show matching reads of host memory if the
   drive uses the buffer as a staging area.
   - **fio is the throughput measure.** `PCIe_wr` is the link load, including
     the 990 EVO Plus's buffer traffic from 64k up. LINK BOUND stays right
     because it is about the link.
   - **The 990 EVO Plus alone is slow at 64k:** 1.89 GB/s at 4.4 ms latency,
     the same with the IOMMU off. That is the drive, not the link or the
     IOMMU.
   - **Its buffer traffic is also translated by the IOMMU,** through long-lived
     mappings with no map/unmap churn, so it adds IOTLB lookups that are not
     fio's. At 64k its misses per 4 KiB are 1.17 vs the 9100 PRO's 1.10.
   - **Each drive alone reaches the link at 1 MiB** (6.9 and 6.4 GB/s).
     Together, the switch starves the 9100 PRO (above). Large-block co-runs
     show switch arbitration, not the IOMMU.
   - The buffer can be turned off with the kernel parameter
     `nvme.max_host_mem_size_mb=0`, which slows that drive. It needs a reboot
     on a shared machine; not done.

**Reading (not established).** The strict ceiling comes from the per-I/O
map, unmap and synchronous IOTLB invalidation, not from translating. That is
the cost F&S ideas 2 and 3 (§2.1 of KNOWLEDGE-MAP) target. **Test:** lazy mode
(`iommu.strict=0`, batched invalidations) at 4k. If lazy comes close to off,
the invalidation is the cost.

### Fourth result: cross sweeps on three switch designs (2026-10-06)

`dualssd_cross_sweep.sh --single` with `--membw 0`, one run per point: 4k–1m
× 1/2/4/8 instances, both drives and drive 0 alone. Six sweeps, three switch
designs (RTL), each strict and off. Full report with figures and every value,
now including design D (Fifth result):
https://claude.ai/artifact/AcYH8Ff2Drt5kon44un3gX (private; local copy
`dualssd/dualssd-xsweeps-report.html`, results in `dualssd/1006/`, both
ignored by git). **Do not pool sweeps across designs.**

| Design | strict | off |
|---|---|---|
| A | `dualssd-xsweep-strict-1` (00:07–00:42) | `dualssd-xsweep-off-1` (00:55–01:30) |
| B | `dualssd-xsweep-strict-2` (12:48–13:24) | `dualssd-xsweep-off-2` (10:23–10:58) |
| C | `dualssd-xsweep-strict-4` (14:11–14:46) | `dualssd-xsweep-off-3` (15:19–15:54) |

The mapping is inferred from order and numbering, not recorded; to be
confirmed. The data supports it for A and B (a design's strict and off sweeps
share the same link split from 16k up). For C it doesn't fully agree:
`off-3` matches `off-1` within 4.4% everywhere.

1. **Link sharing is the design difference.** With the link full, B splits it
   43–53% (drive 0 50% at 16k, 53% at 1m; 75% at 64k). A and C starve drive 0:
   12–18% at 16k, 2% at 1m on A (237 ms mean latency vs 9.4 ms on B), 1% at 8k
   off.
2. **B moves more at large blocks:** 5.26 vs 4.48–4.58 GB/s at 64k (+15%),
   6.70 vs 6.44–6.50 at 1m, in both IOMMU modes. It gives the 990 EVO Plus
   less of the link, and that drive's host-buffer traffic costs ~1.1 extra link
   bytes per byte read at 64k (~0.1 at 1m).
3. **The IOMMU ceiling does not depend on the design:** strict 724–735K IOPS
   at 4k/8 instances on all three, 44–45% of off (1,645K, link-bound). CPU/IO
   2.4–3.0×. p99 267–296 ms strict vs 0.5–1.8 ms off.
4. **C strict only:** at 4k/4–8 instances, 15.6/20.6 Gbps more inbound writes
   than read data (7.9/14.8 with drive 0 alone) and ~2× misses per 4 KiB
   (2.80/3.17 vs 1.58–1.89); drive 0 alone slower at J=1 (183K vs 227–236K at
   4k) and at 64k (97–99K vs 104–105K). Hypothesis: address width. With the
   IOMMU on, Linux gives the drives IOVAs below 4 GiB (3-DW TLP headers); off,
   physical addresses above 4 GiB (4-DW). Test: strict with `iommu.forcedac=1`.
   Repeat first (the four points ran back to back, 14:15–14:18). **Repeated
   on design D (Fifth result, item 4):** the extra writes come back, larger,
   on another day; the 64k slowness does not.
   **Withdrawn 2026-10-16 (§8, "0x0A04 results"):** the extra writes and
   ~2× misses are a `pcm-iio` artifact, not traffic. They appear only in runs
   where `pcm-iio` logged 1–5 one-second samples instead of 17, and every
   `pcm-iio` rate in such a run reads ~2× high. On 0x0A04 the switch's own
   log shows 1.01× fio's data at those points. C's records predate
   `pcie_samples`, but its extra writes sit at the same points.
5. Strict sweeps differ by up to 26% below the link limit (4k, 1–2 instances;
   B fastest, C slowest). Not attributed to the switch until repeated: one run,
   shared host.
6. The 990 EVO Plus has 1.6 GB written, so most of its random reads hit
   unwritten blocks (1.48M IOPS at 4k, above its 850K rating). It acts as a
   fast DMA source, not a loaded SSD.

### Fifth result: design D shares the link fairly (2026-10-10)

`dualssd_cross_sweep.sh --single --asy`, one run per point: 4k–1m × 1–32
instances per drive, drive 0 alone, and uneven co-runs (2/4/8 against 16/32,
both ways round). One switch design, D: the RTL in use on 2026-10-10. What
changed from A–C is not recorded here. Results in `dualssd/1010/`; the report
above now covers D too. The sweeps reuse the names `strict-1` and `off-2`, so
keep them apart from the 10-06 files of the same name.

| Design | strict | off |
|---|---|---|
| D | `dualssd-xsweep-strict-1` (10-10 18:48–22:19) | `dualssd-xsweep-off-2` (10-10 23:43 – 10-11 03:14) |

`dualssd-xsweep-off-1` stopped at the datapath check (no `pcm-iio` rows),
before `a268b81f7` kept such runs with the IOMMU off; `off-2` is the rerun.

1. **The starvation of A and C is gone.** Drive 0's share of the fio bytes,
   8 instances per drive:

   | Block | A off | C off | B off | D off | D strict |
   |---|---|---|---|---|---|
   | 4k | 10% | 10% | 52% | 48% | 55% (IOMMU-bound, link not full) |
   | 8k | 1% | 1% | 43% | 43% | 49% |
   | 16k | 13% | 14% | 50% | 51% | 47% |
   | 64k | 59% | 59% | 75% | 69% | 68% |
   | 1m | 2% | 2% | 53% | 49% | 49% |

   - It holds at 16 and 32 per drive (16k 47–51%, 1m 49%), in both IOMMU
     modes. Per-drive p99 at 1m, 8 instances: 119 / 123 ms on D, against
     2.9 s / 66 ms on A.
   - 8k at 43% is drive 0's own ceiling: alone it tops out at 360K at 8k
     (KEPT% 100).
   - 64k at 68–69% of fio bytes is about 50/50 on the link. `PCIe_wr` is
     53.8 Gbps (6.7 GB/s) against 4.97 GB/s of fio data; the extra ~1.7 GB/s is
     the 990 EVO Plus's host memory buffer. Each drive uses ~3.3–3.5 GB/s of
     the link.
2. **Uneven co-runs: fair from 16k up.** With the IOMMU off, the light drive
   keeps 91–100% of its even-run IOPS (`vsLOW`) at 16k and 100% at 64k and
   1m. Both orientations agree within a few percent.
3. **At 4–8k against 32 instances the light drive loses about half, from the
   core split, not the switch.**
   - 2+32 gives the light drive 1 core (1+17) and 4+32 gives it 2 (2+16):
     2 instances per core, against 1 in the even run `vsLOW` compares with.
   - Its IOPS match what that many cores give alone. Off, 4k: 252K on 1 core
     against 288K for 1 instance alone; 500K on 2 cores against 545K for 2.
     Against 16 it keeps its cores and 92–102% of its IOPS.
   - The link is not always full there. Off, 8k, 32+2 halves drive 1 (232K
     against 464K) at 39.6 Gbps `PCIe_wr`; off, 4k, 32+2 runs at 50.4.
   - Strict, 4k: the light drive also loses against 16 (`vsLOW` 70–89%). That
     is the shared IOMMU, the contention under study. The even run at 4 per
     drive is itself uneven (476K / 210K), so `vsLOW` over 100% there
     (120–123%) means nothing.
4. **Below the link, D strict matches design C.** This repeats C's 4k
   anomaly (Fourth result, item 4) on another day and another design.
   - Drive 0 / drive 1 at 4k: 159K / 203K at 1 instance (C: 158 / 208),
     476K / 210K at 4 (C: 469 / 218), 410K / 334K at 8 (C: 403 / 329).
   - Drive 0 alone at 1 instance: 186.5K (C: 183K; A, B: 227–236K).
   - Extra inbound writes at 4k: 22.3 / 27.9 / 23.8 Gbps with both drives at
     4 / 8 / 16 (C: 15.6 / 20.6), and 7.6 / 10.5 / 16.9 / 12.7 Gbps with
     drive 0 alone at 4 / 8 / 16 / 32. IOMMU off: 0.9–1.4 Gbps.
     **Not real (2026-10-16):** these are exactly D's 14 strict 4k runs with
     1–5 `pcm-iio` samples (inbound writes 1.38–2.43× fio); its 7 runs with
     17 samples read 1.02×. Same for the misses below (§8, "0x0A04 results").
   - Misses per 4 KiB at 4 and 8 instances: 2.65 and 3.60 (C: 2.80 and 3.17).
   - C's slow 64k with drive 0 alone (97–99K) does not recur: 103–105K.
   - **LINK BOUND misfires here.** The summary flags the 4k strict uneven rows
     4+16, 32+4 and 8+16 (`PCIe_wr` 54–60 Gbps) while fio moves ~3.07 GB/s
     (~25 Gbps). On C and D in strict mode at 4k, judge the link by fio's GB/s.
5. **The strict ceiling does not move with more instances.** 4k: 744K at 8 per
   drive, 753K at 16 (45% of off's 1,648K). 8k: 5.98 GB/s at 8, 5.92–5.96 at
   16–32. CPU per I/O at 4k rises from 18.2 to 20.1 µs and p99 at 16 per drive
   reaches 1.67 s / 1.08 s. The miss rate peaks at 8.6% at 8 and falls to 7.0%
   at 16.
6. **Missing points.** Strict, 4k: 32+32, 8+32 and 32+8 failed (`pcm-iio`
   logged no rows; exit 3, not recorded), so there is no strict 4k co-run at
   32 per drive. Off: the 4k co-runs at 1 and 2 per drive and the 8k co-run at
   1 were kept with `PCIe_wr` and IOMMU values `n/a`. 1m at 32 per drive ran in
   both modes, p99 ~0.45 s per drive; `dmesg` was not checked.

**Reading.** The switch fairness problem of A and C is fixed in D, and D is
the design to use for IOMMU work: its link split does not depend on the IOMMU
mode or the load. Its strict 4k anomaly is C's, so the address-width test
(Next, item 0) can run on D.

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

### Next on bigserver

0. **After the cross sweeps (2026-10-06 and 10-10), in this order** (commands
   in the report's "Next runs"):
   - **Address pattern, on design D.** (The extra-writes rationale below is
     withdrawn, see the Fourth result, item 4; the `forcedac` test no longer
     has a target. The IOVA tracing is partly covered by
     `pips-addr-pattern.py` on the PIPS logs, §8.) D repeats C's strict 4k anomaly
     (Fifth result, item 4), so C's planned repeat can run on D: strict at
     4k, 4/8 instances, 3 runs, for the run-to-run spread. Record the IOVAs
     the drives get with the `iommu:map`/`iommu:unmap` tracepoints (about
     0.5 s per point; tracing perturbs the run, so not during measurements):
     their width, spread and reuse distance, which should drive the miss
     rate. Then strict with `iommu.forcedac=1` (IOVAs above 4 GiB, 64-bit
     TLPs as with the IOMMU off) on D, with A or B as control.
   - **Uneven co-runs with the light drive at one core per instance.** The
     x+32 points at 4k/8k lose half the light drive's IOPS to the core split
     (Fifth result, item 3). Needs a change to the runner's split in
     `run-dualssd-experiment.sh`.
   - **More instances: done on D.** Strict stops gaining at 8 per drive at
     both 4k (744K, 753K at 16) and 8k (5.98 GB/s). `--iodepth 64` is the
     remaining way to add load.
   - **Why `pcm-iio` logged no rows** in 6 runs on 2026-10-10 (listed under
     "fio is checked against the measurement windows" above): look at those
     runs' `pcm-iio.out`.
1. **Lazy mode (`iommu.strict=0`):** the block-size sweep, or at least 4k.
   Then the instance sweep with `--single` in each mode, for the full
   strict / lazy / off comparison below the link (1–2 instances).
   `dualssd_cross_sweep.sh --single` covers both in one run per mode. Re-check
   the interrupt CPUs after each reboot. Each reboot and grub change affects
   everyone on the machine; agree on them with the other users first.
   PCIe max payload size, if still wanted:
   `for d in b0:00.0 b1:00.0 b3:00.0 b4:00.0; do echo "$d $(sudo lspci -vv -s $d | grep -A2 'DevCtl:' | grep -o 'MaxPayload [0-9]* bytes')"; done`
2. **What the CPU time goes to,** if needed: `perf` is not installed for this
   kernel (`linux-tools-5.15.0-177-generic`). `mpstat` cannot separate it,
   because interrupt time shows up as `%sys` here.
3. **Stay at 4k (or 8k) for IOMMU comparisons.** There the data is clean:
   fio and `PCIe_wr` agree, there is no buffer traffic from the 990 EVO Plus,
   and strict runs below the link.
4. **The PIPS sweep on design `0x0A04`:** strict done 2026-10-16; IOMMU off
   still to run (§8, "Next").

---

## 8. PIPS switch: batcher sweeps on the drives and the NICs

PIPS is the FPGA PCIe switch (VCK190, FPGA repo `pips_batch`,
`C:\Xilinx_Projects\pips_batch_new\Programmable-Intelligent-PCIe-Switch`)
whose batcher regroups the devices' upstream writes. The host reaches its
config, log DMA and TLP log through the upstream port's BAR0 (the PIO). How it
works, every register, and the log format:
[scripts/pips/PIO-MANUAL.md](scripts/pips/PIO-MANUAL.md); the tools and test
points: [scripts/pips/README.md](scripts/pips/README.md).

- **Drives:** bigserver, both NVMe drives behind PIPS (since 2026-10-11).
  The first PIPS sweeps ran 2026-10-13 on design `0x0A02`:
  `dualssd-pips-{off,strict}-1-{d1t0,d4t22,d8t22,d16t64}` (local copies in
  `dualssd/1013/`).
- **NICs:** behind PIPS as of 2026-10-15, one per downstream port. Run the NIC
  experiments on that server, as before on icx (§2); `run-dualnic-experiment.sh`
  finds the NICs below the switch by their PCI path.
- **Design `0x0A04`, 2026-10-15/16, strict only, cap off and on:** drives
  `dualssd-pips-strict-1-id0a04-{d1t0,d4t22,d8t22,d16t64}[c1]` (700 of 720
  runs; local copies in `dualssd/1016/`, with `traffic-ssd.txt`) and NICs
  `dualnic-pips-strict-1-id0a04-*` on icx (104 runs; `dualnic/1016/`, with
  `traffic-nic.txt`). Results below, "0x0A04 results".
- **Design `0x0A05`, 2026-10-17/18, the depth sweep (strict, cap on, depths
  1–64):** drives `dualssd-pips-strict-dsweep1-id0a05-*` (702 of 720 runs,
  all eight settings; `dualssd/1019/`), NICs
  `dualnic-pips-strict-dsweep1-id0a05-*` (22 of 32 points and the datapath
  check, then the switch stopped answering; `dualnic/1019/`, with the
  kernel log `jounalctl.txt` and the manifest). Results below, "0x0A05 depth
  sweep".
- **Reports (artifacts):** "PIPS Batcher Sweeps"
  (https://claude.ai/artifact/XsrLugEhsaMzY6vwARSLGU) is design 0x0A02 only
  (drives, IOMMU off and strict, page-order Figures 5–6); "PIPS 0x0A04–0x0A05
  Sweeps" (https://claude.ai/artifact/MbNxzaJ5KgmuM59PPC4NcA, was "PIPS
  0x0A04 Sweeps") is 0x0A04, drives and NICs, with what pcm logged on icx and
  the page order (Figures 3–6, Tables 6–7), the depth sweep's times (Figure
  7, Table 8) and 0x0A05's results (Figure 8, Tables 9–10, the NIC stop;
  generator `a05.py`). Both generators are in the git-ignored `dualssd/report-gen/` (README
  there: `py -3 build.py` for 0x0A02, `py -3 page4.py` for 0x0A04–0x0A05,
  from the local copies; Tables 6-7 come from `seq4.py` (first grab),
  Figures 3-6 from `seqarr.py` + `seqarr.js` reading the `pips-seq-grab.sh`
  output unpacked in `dualssd/1016/` and `dualnic/1016/`; every generator and
  input is listed in FILE-MAP §7).

### Switch designs (design ID)

Every build reports a design ID (`sudo scripts/pips/pips cfg`, `design_id=`).
Two changes since the 10-13 sweeps matter to the experiments:

| Design | FPGA repo | Change |
|---|---|---|
| `0x0A02` | `e389cca`, 10-11 | design ID register. The 10-13 sweeps |
| `0x0A03` | `2c6c3f5`, 10-14 | **drain depth cap** (regfile reg1, `pips cfg set cap=1`): a drain sends at most `depth_threshold` packets instead of the whole FIFO. Off (0) is the reset value and what `0x0A02` did |
| `0x0A04` | `591d854`, 10-15 | **TLP log format v2**: one record per TLP leaving the batcher, tagged with its input and its time in the batcher (`pkt_wait`); no separate input records. Same trailer, so only the design ID tells the formats apart |
| `0x0A05` | `64193c6`, 10-17 | **batching FIFOs of 512 beats** (`FIFO_DEPTH`, was 128; FIFO 2 too): an input stops at 493 beats and asks for a drain above 477, so a batch reaches 95 drive or 53 NIC TLPs (18 / 10 before). Nothing else changed. The depth sweep ran on it |

**Every artifact carries the design ID from now on**: raw logs in the name
(`pips-log-id0a04.bin.gz`), sweeps in the name (`<NAME>-id0a04-d8t22c1`), text
inside (`pips-cfg.txt`, `.rpt`, JSONL `pips_design_id`, summary first lines,
rows labelled `strict d8t22c1@0a04`). The decoders pick the log format by it:
`-id<XXXX>` in the name, else a `pips-cfg.txt` beside the log, else v1 (every
log from before). So the 10-13 logs still decode as before. Details:
[scripts/pips/README.md](scripts/pips/README.md), "Design IDs".

Settings are named `d<depth>t<time>[m1][c1]`: `d8t22c1` = depth 8, time 0x16,
drain cap on. A name without `c1` has the cap off, as every name from before.

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

### Depth sweep (set up 2026-10-17 for `0x0A04`; ran on `0x0A05`)

It ran on design `0x0A05`, whose 512-beat FIFOs lift the FIFO limit
described below; results in "0x0A05 depth sweep".

Changes from the 10-15/16 sweeps, nothing else: depths 1, 2, 4, 8, 16, 24, 36,
64; drain cap on only; NICs co-run only (no NIC-alone runs) with one datapath
check, before `d1t0c1`; names `dualssd-pips-strict-dsweep1` and
`dualnic-pips-strict-dsweep1`. Drives ~12 h (8 × 1.5 h), NICs ~1.5 h.

**Times.** On the 10-15/16 logs the timeout, not the depth, ended most batches
wherever the uplink had room: at 4 KiB 1 + 1, d4t22 and d8t22 waited alike
(0.14 / 0.16 µs) and d16t64 0.34 µs, because 22 or 64 cycles is shorter than D
TLPs take to arrive. A burst comes at about link rate: a drive's 256 B TLP
(Gen4 x4) or a NIC's 512 B TLP (the 512-bit datapath) every ~9 cycles of 4 ns.
The drives' recorded waits fit 9–14 cycles (`pips-timeout-pick.py
--validate`), so depth D needs about gap × (D − 1) plus the last TLP's beats,
and T = 14 (D − 1) + 8 is just past that for either gap: `2:22 4:50 8:106
16:218`; 255 (the 8-bit maximum, 1.02 µs) from depth 24. Modelled share of
drains the depth trigger asks for (`pips-timeout-pick.py --eval` on the 10-16
d1t0 records; synthetic arrivals, so estimates):

| Setting | Drives, light points (gap 9.2 / 14) | NICs, both at 30 flows | Same depth before |
|---|---|---|---|
| `d2t22c1` | 97 / 97% | 85% | – |
| `d4t50c1` | 86 / 86% | 71% | `d4t22c1`: 73 / 53%, NICs 44% |
| `d8t106c1` | 72 / 72% | 56% | `d8t22c1`: 32 / 4%, NICs 2% |
| `d16t218c1` | 55 / 53% | never (full trigger) | `d16t64c1`: 19 / 2% |
| `d24t255c1`, `d36t255c1`, `d64t255c1` | never (d24: 17–19% on a full uplink, drive 1's 144 B writes) | never | – |

Light points are those whose output is below 85% of the uplink (drives: 4 KiB,
and 8 KiB at 1 + 1; NICs: both at 30 flows). On a full uplink the FIFO backlog
meets any depth the FIFO can hold (drives ≥ 97%, NICs 89–98%). The rest time
out (a 4 KiB read is 16 data TLPs, its completion entry and an interrupt) or
are flushed by a read (0.8 per drive I/O).

**The FIFO caps the depth on `0x0A04`.** Each input FIFO holds 128 beats of
64 B; it stops taking packets at 109 and its full trigger asks for a drain
above 93 (`axi4_mwr_batch.v`: FIFO_DEPTH 128, MAX_PKT_BEATS 16). A 256 B TLP is
5 beats and a 512 B one 9, so a drive batch can't reach more than 18 packets
and a NIC batch more than 10. d24, d36 and d64 on the drives, and d16 up on the
NICs, are batches ended by the full trigger or the timeout, never by depth,
and their cap never binds. **d36 and d64 are the same setting in effect on
both testbeds, and d24 is too on the NICs.** The model on the NICs' real
arrivals agrees: d16t255, d32t255 and d64t255 came out identical at every
point (`dualnic/1016/seq-dualnic-0a04-arr`). Going deeper needs a build with a
larger FIFO_DEPTH; the time field also stops at 255 cycles.

After the sweep: page order and trigger shares on the real arrival order,
`bash scripts/pips/pips-seq-grab.sh --manifest ~/<sweep>.manifest.tsv -j 8`
(the model runs each log's own setting and the sweep's other seven;
`model[].triggers` in `seq.jsonl`).

Compare cap off against on per setting:

```bash
python3 scripts/dualssd-results.py summary ~/dualssd-pips-strict-2-id0a04-d8t22.jsonl \
    ~/dualssd-pips-strict-2-id0a04-d8t22c1.jsonl
python3 scripts/dualnic-results.py summary ~/dualnic-pips-strict-1-id0a04-*.jsonl
python3 scripts/pips/pips-mwr-sizes.py utils/logs/dualssd-pips-strict-2-id0a04-d8t22 \
    utils/logs/dualssd-pips-strict-2-id0a04-d8t22c1 --by cfg,bs
```

Can the switch tell payload from control writes (completion entries,
descriptor write-backs) by size? On every log on the host, drives or NICs, a
line per log as it goes, the verdict per kind and design at the end
([scripts/pips/README.md](scripts/pips/README.md), "Payload or control"):

```bash
python3 scripts/pips/pips-traffic.py --csv ~/traffic-sizes.csv --jsonl ~/traffic.jsonl | tee ~/traffic.txt
```

### 0x0A04 results (2026-10-15/16, strict)

The cap and the v2 log work on hardware: all 804 logs FULL, no drops,
`pkt_wait` plausible. Details and figures in the report (above).

1. **Drives, the cap moves a full link's split, not its total.** 4k/8k: median
   change per setting within ±0.6%. Link full: drive 0's share 47% → 53–56%
   at 16k (d1t0, d4t22, d8t22; d16t64c1 barely moves it), 49% → 46–48% at
   1m; at 64k drive 0 +8–11%, drive 1 −8–11%, total +3–4% at every point
   (drive 1's 64k reads cost ~2× link bytes).
2. **Drives, cap off repeats 0x0A02** within 2.4% (median) from 2 per drive,
   equal at 64k/1m. **Except drive 0 at 1 instance per drive:** 16–31% slower
   at 4–16k in all 8 settings (8k: 145–149K vs 195–206K); drive 1 unchanged.
   Build or boot, not batcher; untested which.
3. **Time in the batcher (v2 `pkt_wait`, out port, mean):** strict 4k 1+1:
   0.06 µs d1t0, 0.14 d4t22, 0.16 d8t22, 0.34 d16t64 (p99 0.6–0.9); the cap
   adds nothing there. Link full: 0.9–1.6 µs in every setting; the cap raises
   the p99 (64k: 3.0–3.2 vs 2.4 µs). 0x0A02's hold estimate for d16t64
   (0.66 µs) was ~2× high.
4. **`pcm-iio` undersampling (gotcha above).** 84 of 124 strict 4k runs have
   1–3 samples (same 12 points in every setting, from 4+4 up), and 20 more
   had none and were dropped (8+32 ×8, 32+32 ×7, 32+8 ×5). In those runs
   `pcm-iio` writes read 2.02× fio (median) while the switch's output reads
   1.01×. This withdraws the C/D extra-writes result (§7).
5. **NICs (icx):** one NIC 85–97 Gbps in every setting but d1t0c1, two NICs
   105–107 at 5–10 flows; IOTLB misses per Gbps within −1.1/+2.4% of d1t0.
   **d1t0c1 holds one NIC to 75–78 Gbps (−18 to −21%)** at every flow count
   (one TLP per drain); two NICs lose ≤1.5%. d16t64/c1: −5 to −11% for one
   NIC at 30 flows (ran last; drift not ruled out). Two NICs at 30 flows:
   48 Gbps in every setting, the §4.1 cliff. PIPS splits 5 flows evenly
   (53.5 + 53.5), where the direct path gave 41 + 64 (§4.1, item E).
6. **`traffic-ssd.txt` includes stale logs**: 16 `datapath-4k-j1` checks, the
   21 TLP logs of runs dropped for missing `pcm-iio` rows (1 on 0x0A02, 20
   on 0x0A04), and one 10-11 bring-up log (`pips-fio-20261011-225629`,
   design "none"). Its verdicts don't change, but per-sweep counts are 91
   logs, not 90. Move or delete the bring-up log on bigserver.
7. **What pcm logged on icx** (NIC records, means over 20 s): `pcm-iio`
   inbound PCIe writes/reads, IOTLB lookups and misses, context-cache hits,
   page-walk-cache hits at 4K/2M/1G/512G, IOMMU memory accesses; `pcm-memory`
   DRAM read/write per node. No sample count is kept, but writes are
   0.98–1.10× the switch's output and lookups 0.98–1.09 per switch TLP in all
   96 runs: no undersampling on icx. 9.2–9.4 lookups and 1.09–1.21 misses per
   4 KiB, miss rate 11.9–12.8%, 4.2–5.7 memory accesses per miss, as on 09-29
   (§4.1). Settings differ by ≤ 3% (misses/4K) and ≤ 7% (accesses/miss) per
   point; d1t0c1 is the high end. Node-0 DRAM writes (4.4–9.4 GB/s one NIC)
   stay below the ~12 GB/s DMA rate (likely DDIO).
8. **Page order (`pips-seq-grab.sh`, 7 drive + 5 NIC points × 8 settings,
   96 logs, all found; unpacked in `dualssd/1016/seq-dualssd-pips-strict-1-id0a04/`
   and `dualnic/1016/seq-dualnic-pips-strict-1-id0a04/`):**
   - Drives, cap off: d16t64 cuts page switches per 4 KiB page only at 4k
     (4.81–4.98 → 4.16–4.53), as on 0x0A02; link full (16k/64k/1m) all four
     settings give the same order.
   - **d1t0c1 alternates the drives TLP by TLP on a full link**: 1.10–1.36
     TLPs per run on out, page switches ×2.1–2.3 at 16k/1m, ×1.6 at 64k,
     ×1.4–1.7 at 4k. Cap at depth 4: +6–29%, 8: +1–15%, 16: −4/+6%. Each
     drive's own stream is unchanged (drive 0: 2 TLPs per run, two pages
     alternating, from 16k up).
   - **NICs:** a packet is 8 × 512 B TLPs (7 × 128 DW + 112 DW, 4032 B) into
     one page, then a 64 B completion; ~1.1 completion writes per packet (the
     sends' too). Cap off, both NICs: 2.6–3.1 page switches per packet, each
     NIC 86–97% of packets in one run. d1t0c1 with both: ×1.8–3.3.
     **NIC0 alone splits its own packets** (2–3 at once, a TLP each) when held
     0.37–0.48 µs (d1t0c1, d4t22c1 at 5 flows, d16t64/c1): 5.4–8.6 switches
     per packet vs 2.3–2.6 at 0.13–0.14 µs (d1t0). Both NICs at 24–54 Gbps
     each don't split at 0.2–0.8 µs, so the wait alone doesn't decide it.
   - **Misses don't follow the order:** pcm-iio misses per 4 KiB within 5%
     across the 8 settings at every point (16k: 1.50 for d1t0 and d1t0c1 at
     2.25× the switches; NIC0 alone: d4t22c1 splits like d1t0c1 at 95.5 Gbps
     and 1.095 misses vs d1t0's 1.096). The 64-entry simulated IOTLB agrees
     within 2% per point. Lookups per 4 KiB don't move (one per TLP).
   - Tool fix after the grab: `pips-page-seq.py --kind nic` now ends a packet's
     visit at its short last TLP, not at any completion of its NIC (which,
     with several queues in flight, closed pages early: false `gap` marks,
     open pages undercounted). Runs, visits, what-if and IOTLB sims were not
     affected; the report ignores the grab's NIC `gap` marks. Regrab only if
     NIC open-page counts are needed.
   - **The what-if baseline was wrong (user review):** it regrouped windows of
     the *output*, already shaped by the setting, and placed each setting at
     W = depth. A depth-D batcher groups at its inputs (D packets of one
     drive, or TIME cycles), about 2D+ output TLPs when both send, so the
     recorded diamonds beat the "by drive" line (4k 8+8: d4t22 4.47 vs 4.78
     at W = 4; d8t22 4.42 vs 4.55 at W = 8). Fixed in `pips-page-seq.py`:
     arrival order rebuilt from `pkt_wait` (stream `arr`) and `--model`, the
     `axi4_mwr_batch.v` batcher (triggers, snapshot drains, cap, round robin,
     reads behind their input's writes; output cycles per TLP measured from
     the log) run on it; `--model self` checks it against each log. Needs the
     regrab below; the 0x0A04 page's Figures 4 and 6 are still the old ones.

9. **Arrival order and the batcher model, NICs (regrab 10-16 21:45, repo
   2c5c8a367, `dualnic/1016/seq-dualnic-0a04-arr/`, 104 logs = 12 points +
   `f5-datapath` × 8; the grab filter now drops any name with "datapath"):**
   - Model vs recorded page switches: on each log's own arrival order −1% to
     +5% (single NIC exact: one input can't be reordered), except d1t0c1 at
     15/30 flows (+6%, +11%). From d1t0's arrival order, both NICs: every
     setting within −1%/+5%, d1t0c1 −3%/−8%.
   - **Model limit:** output cycles per TLP come from back-to-back same-input
     pairs; in d1t0c1 logs every drain is 1 TLP, so the pairs include the
     ~3-cycle gap before the RTL re-grants the same input (data/128 reads 12
     cycles, not 9) and the model backs up (absurd waits). Model waits also
     omit the fixed pipeline latency (up to 0.13 µs low). Fix if needed: model
     the re-grant gap and count a packet for the depth trigger at its EOP, then
     regrab. The page leaves d1t0c1 out as a starting order.
   - Both NICs arrive interleaved (4.4–5.8 page switches per packet in d1t0
     logs); d1t0 sends 2.8–3.1 (queueing on a full link groups them). Depth
     8 at time 255: −7% to −16% from depth 1; flat beyond (full trigger at ~10
     NIC TLPs); bound at 64: 2.62–2.68.
   - One NIC: arrival order = order sent in all 64 logs; d1t0 2.3–2.6, cap at
     depth 1/4 7.9–9.2, d8t22/d16t64 2.6–3.5 / 5.9–6.5 at 5 flows, 5.3–9.2
     from 10. NIC1 like NIC0. All of it is the NIC's own reaction.
   - Page "PIPS 0x0A04 Sweeps" v3 (2026-10-17): Figures 3–6 rebuilt from this
     (generator `dualssd/report-gen/seqarr.py` + `seqarr.js`; per-point data
     files `dualssd/seqdata/<kind>/<point>.json`, published beside the page as
     `seq/<kind>/<point>.json` via the Artifact `files` map). Drives pending.

10. **Drive regrab in, and the model's uplink (2026-10-19).** The 10-16
    drive regrab (`dualssd/1016/seq-dualssd-0a04-arr/`, 720 logs) is on the
    page (Figures 3–4, the bullets from `seqarr.drive_points()`). On it the
    model failed its own check: +21% page switches against the recorded
    ones (median of 630 logs, d1t0c1 left out; +35% at 8 and 16 KiB, +4% at
    64 KiB), waits 0.15–0.26 µs where d1t0's logs show 0.6–1.5 µs from 16
    KiB up. Cause: each TLP's output time was the median of back-to-back
    pairs within a drain, 5 cycles per 256 B TLP, the 512-bit datapath; the
    logs' output takes 9.2 cycles per TLP on a full link (Gen3 x8), with the
    link stalls between the pairs. In the model the FIFOs rarely filled, so
    drains stayed small and depth hardly mattered. Fixed: `--link` (default
    `gen3x8` drives, `gen4x8` NICs) holds each TLP to payload + 22 B at 96% of
    the raw link rate; the NICs' model doesn't change (the datapath is the
    slower). Also, and real: with the cap off a backlogged FIFO drains whole
    at any depth (recorded cap-off settings agree from 16 KiB); 0x0A04's FIFO
    stops at 18 drive TLPs; "by drive" can't undo drive 0's own two-page
    interleave (only the by-page line falls, 57–58% at 64 KiB / 1 MiB from
    depth 1 to 64). New model groups `sweepc1` (cap on, where depth sets the
    drain size) and FIFO-size suffixes (`sweepc1f512`, `d24t255c1f512`); the
    page's Figures 4/6 offer whichever sweeps a grab has. Figure 6 lists
    both-NIC points only: in all 64 one-NIC logs the by-NIC line is flat
    (one input can't be reordered); their by-page and bound lines fall up
    to 43% only where the NIC itself interleaved packets.
    Same day, after user review: (a) **grant gap**: the model now charges one
    cycle per 64-byte beat and 3 cycles per new drain (`--grant-gap`), not
    the measured pair median. d1t0c1 logs show the gap (drive 256 B TLPs 8-9
    cycles vs 5, NIC 512 B 12 vs 9) because every drain there is one TLP; the
    old model took 12 for every TLP when run from a d1t0c1 log (the "absurd
    waits") and 9 per one-TLP drain when predicting d1t0c1 from others. (b)
    **Depth 1 is round robin only with the cap on**: the plotted sweep is cap
    off (a grant drains the whole FIFO); at 16 KiB its depth 1 gives 5.05-8.56
    page switches per page vs 8.72-12.71 recorded with d1t0c1, the model's
    own d1t0c1 8.39-11.41 (rest: the uplink). The regrab's `sweepc1` starts
    at round robin. (c) **Ideal line = windows only**: the arrival order in
    windows of D TLPs per device (n x D in all), each grouped by page, no
    FIFO, time limit, link or ordering (from each log's `windows_arr`,
    `seqarr.window_ideal`); falls from as-arrived to 1.6-2.1 at 64. It can sit
    above the cap-off model at small D (a cap-off drain is the whole
    backlog). (d) **Lines averaged over every log of a point** (runs of the
    same flow); old-grab d1t0c1 logs count for as-arrived and the ideal only.
    (e) **NIC by-NIC = by-page is real**: with both NICs each NIC writes one
    packet at a time (own stream 7.1-7.7 TLPs per run, 86-97% of packets
    whole; listing `seq-d1t0-f10-both.txt`: offsets 000-e00 of one page, then
    its entry), except d1t0c1 at 5 flows (1.01 TLPs per run), where by-page
    falls below. Page v6.
11. **The 10-19 grab: the drive model ran away; the arrival rebuild lacked
    the uplink's stalls (2026-10-20).** `pips-analyze.sh` on both hosts
    (repo 8a00e1f74; `dualssd/1019/pips-analyze-ssd-20261019-1723/`, 1,440
    logs, both sweeps; `dualnic/1019/pips-analyze-nic-20261019-1723/`, the
    0x0A04 sweep only). NICs: the page-switch self check matched (median
    0.0% over all 12 points), but at 5 and 10 flows with both NICs its waits
    ran to 30-1,400 µs: the grant gap at every drain (item 12; an earlier
    note here said the waits matched, which held only for the median per
    setting over all points). Drives: every setting's
    model wait ~1,000-1,450 µs against 1.4-1.9 recorded, from a nominal load
    (model cycles over the log's true time per TLP) of 0.78 up, and
    page-switch self check +15% (0x0A04) / +18% (0x0A05) median. Cause: the
    output's times are rebuilt from `pkt_length` (beats) and `pkt_gap`, and a
    stall **inside** a packet is in neither (PIO-MANUAL §8.4), while
    `pkt_wait` counts it. On a Gen3 x8 uplink the 512-bit datapath stalls
    about a third of the time (synthetic: 35-42% at 80-97% load), so the
    logged output covers ~60% of the recording, in_sop = out_sop - wait came
    out early by the stalls of the packets that left during the wait, the
    arrivals ran faster than the link, and the model (now charging the link)
    never drained. The same error swapped one drive's TLPs: drive 1 "arrived"
    with ~480 open pages, sent with ~34 (`seq-d16t64c1-1m-j32-both.txt`,
    `arr` listing: offsets 300-200 of one page). The 10-16 grab had it too
    (its model, at the datapath rate, matched the compressed clock instead),
    so Figure 4's as-arrived/ideal start and Table 6's as-arrived numbers
    for the drives are inflated. Fix (`pips-page-seq.py`): put the stalls
    back (each packet holds the output for max(beats, link time), the
    model's rule; link rate fitted so the rebuilt output ends at the
    trailer's duration; `out_times()`, `fit_stalls()`), keep each input's
    output order (the batcher never reorders an input), and run the model at
    the fitted rate. Logs with saturated gaps would pull the fit slow (idle
    past the gap looks like stalls), so `pips-seq-grab.sh` first calibrates:
    `--calibrate` on every log, the median of the clean ones (one segment,
    >= 10% lost) is the floor `--link-rate` for all (`calibrate.txt`).
    Checked on synthetic logs written the way the hardware logs (stalls
    dropped): the fit recovers the link to 0.1%, the model's own setting
    matches the logged order (12.99 vs 13.00) and wait (0.73 vs 0.72 µs);
    the committed code gave 200-400 µs waits on the same logs
    (`test-sim.sh`, "stalls inside packets"). The NICs (Gen4 x8, ~no stalls)
    are not expected to change by this fix; their grant gap is (item 12).
12. **Recovered without the raw logs, and the grant gap (2026-10-20).**
    The 10-19 grab's listings (`seq-<setting>-<point>.txt`, 600 runs as sent
    from record 100,000, 600-3,500 TLPs) are exact, and the batcher never
    reorders an input, so each device's own arrival order is the listing
    filtered to it. `dualssd/report-gen/seqrec.py` (git-ignored) runs
    pips-page-seq's `batcher()` on it: each I/O (drive command, NIC packet,
    ending at its completion entry) arrives as a burst at the device's pace
    (9 cycles per 256 B drive TLP, 10 per 512 B NIC TLP), idle between I/Os
    so each device keeps its share of the log's true rate; I/Os over 64
    TLPs arrive evenly (credit-paced); the output's rate is fitted (from the
    raw link rate down) so the log's own setting waits as recorded; the
    listing runs twice (warm-up). Lines scaled to the whole log by recorded
    page switches. The check (own setting vs the log's own listing, not
    fitted): drives 0x0A04 median per setting -4.5% to +7.8% from 16 KiB up,
    -4% to +5% at 4-8 KiB; 0x0A05 depths 4-64 -3% to +4%; misses at 0x0A05
    d1t0c1/d2t22c1 at 8-16 KiB (+15% to +39%); NICs -10% to +15% at 5-15
    flows, +6% to +24% at 30. Evenly paced arrivals failed at 4 KiB (+73% to
    +97%): bursts matter. A pure full-backlog model (no time) worked on
    0x0A04 (FIFOs full) but not 0x0A05 (FIFOs half full). Findings (page v8,
    Figure 4 bullets from `seqarr.order_points()`): depth 1 is round robin
    only in the window ideal (16.6-17.5 page switches per page at 16 KiB);
    recorded d1t0c1 is 9.3-12.7 because each I/O's read flushes its drive's
    FIFO (a quarter of the TLPs at 16 KiB, 8 per drive, leave in such
    drains) and an idle input lets the other go on; the model's cap-on line
    follows the ideal to the FIFO's size (0x0A04: flat from 16 at 18 drive
    TLPs; 0x0A05 goes on), the recorded 0x0A05 settings lie near it; the
    model's waits (fixed arrival pace) don't reach 0x0A05's recorded
    4.2-4.7 µs. **Grant gap**: two NICs carry ~105 Gbps under d1t0c1, which
    12 cycles per 512 B TLP (85 Gbps max) can't, so the gap is hidden when
    the grant goes to the other input; one NIC alone pays it (80 Gbps).
    `batcher()` now charges it only for a new drain from the input served
    last (or the very first, or a pass-through packet); `test-sim.sh` asserts
    9 cycles alternating, 12 for one input.
    **After user review (v9).** (a) "Recorded is below the ideal at low
    depth": v8's ideal took windows of D TLPs per device from each device's
    own order, which at D = 1 is strict alternation (16.6-17.5 page switches
    per page at 16 KiB). Recorded d1t0c1 is 9.3-12.7 on 0x0A04 and 6.9-8.2 on
    0x0A05 (whole logs, not a sampling artifact): the RTL alternates only
    when both channels request at the packet boundary (round-robin
    tie-break, `axi4_mwr_batch.v` ~l.1561); otherwise the requesting channel
    gets the next drain, and a flush holds the grant. In d1t0c1's recorded
    order at 16 KiB, 8% of TLPs leave in a flush before a read and 49% in
    other one-drive stretches of one-TLP drains (0x0A05: 5% and 78%, which
    the model doesn't reproduce: +39%). The v8 bullet that said "a quarter
    of the TLPs leave in flush drains" came from one model run and was
    wrong. The ideal is now d1t0c1's recorded order regrouped in windows of
    2D TLPs (`windows` in `seq.jsonl`, ideal policy: whole log, exact),
    0x0A04's or 0x0A05's d1t0c1 by the FIFO selector: at 16 KiB 9.3-12.7 at
    1 (d1t0c1 itself), 2.5-2.9 at 16, 1.8-2.0 at 64. (b) "NICs should be more
    chaotic than drives, but by NIC = by page": with both NICs each NIC's
    own order has 6.8-7.7 TLPs per run, 85-97% of packets in one run (whole
    logs), so grouping a drain by page has nothing to undo; exception
    d1t0c1 at 5 flows (1.0 TLPs per run), where the recovered by-page line
    falls 9.18 -> 4.95 and by NIC stays 9.18. One NIC alone is chaotic
    (cap-on settings and d16t64: 1.0-1.9 TLPs per run, 0-49% whole), but
    single-NIC points are out of Figure 6 by request. Why alone and not
    together: item 13 (the NIC's packet rate on its wire; styx suspected,
    untested). Drives are the more
    interleaved: drive 0 always two pages at once, drive 1 at 64 KiB
    1.6-1.9 TLPs per run.
    **v10: floor and raw (user: "the ideal was supposed to represent the
    floor").** Floor(D) = per device, its own order (exact, from the
    listing) sent by a batcher holding the next D TLPs: stay on the current
    page while any held TLP has it, else start the oldest held TLP's page or
    the most-held page (the better of the two; an achievable floor, not a
    proven minimum); the two devices never interleave within a run.
    `seqrec.floor_runs()`, `raw_floor()`; cached in `rawfloor.json` by `py -3
    seqrec.py --rawfloor` (seconds, 8 processes). At 16 KiB: 3.4-5.2 page
    switches per page at depth 1 (each drive's own runs) to 1.1-1.4 at 64;
    NICs 2.3-3.1 to 1.3-1.5. Raw = the modelled arrival order (seqrec's
    I/O-burst arrivals merged by time), unbatched, averaged over the point's
    logs: drives 8.5-10.6 at 16 KiB, 17.9-18.6 at 64 KiB, 14.2-17.5 at 1 MiB;
    NICs 4.7-7.1. The user expected raw at or slightly above d1t0c1; that
    holds at 64 KiB and 1 MiB, but at 16 KiB recorded d1t0c1 (9.3-12.7) is
    above the modelled raw: with a queue, one TLP per drain splits each
    drive's I/O bursts. Per log (d1t0c1's own listing) raw was slightly above
    d1t0c1 everywhere (12.75 vs 12.35 at 16 KiB); the average over all 16
    logs is lower. The host rerun measures the arrival order and settles it.
13. **Why one NIC alone splits its packets and two together don't
    (2026-10-20).** From the 10-16 JSONL and the 10-19 grab's listings
    (`dualssd/report-gen/nicorder.py`, output `dualnic/1019/nicorder.txt`;
    no raw logs).
    - **The NIC's packet rate decides it, not the wait.** Alone (93-96
      Gbps) a NIC splits (1.0-1.9 TLPs per run, 0-49% of packets whole)
      where its wait is pinned, p50 about p99 (d4t22c1 0.46/0.48 µs, d16t64
      0.43/0.45, d1t0c1 0.60/0.63): its FIFO stays full and it is held TLP
      by TLP. Under d1t0 (0.12/0.29 µs) it writes whole packets. Together
      (49-54 Gbps each) the waits are longer (p50 0.68-0.88, p99 1.1-1.4 µs)
      and the FIFOs fill (on 0x0A05 the waits grow with the FIFO), the
      output never idles 1 µs (one segment, out gap 0.04 cycles per TLP at
      111 Gbps: the switch is the limit), yet each NIC writes whole packets
      (7.1-7.3 TLPs per run, 86-91% whole).
    - **One rule fits every point:** a NIC opens its next packet when the
      current one takes longer to get into the switch than the gap to the
      next packet on its wire. It then writes one TLP of each open packet
      in turn, one packet per receive queue (4-5 open; their completions go
      to different CQs), and stays split until the wire idles (alone logs
      have 27-225 output gaps of 1 µs or more; d4t22c1 f5 NIC0's 600-run
      sample is whole, 6.5 TLPs per run, its whole log 1.11). Alone the gap
      is one 100G frame time (4,038 B, 0.32 µs) and an unheld packet needs
      about 0.3 µs; together the gap is about 0.6 µs. The co-run exception
      fits: d1t0c1 at 5 flows splits (1.01), where a packet alternates TLP
      by TLP with the other NIC (about 16 slots, 0.6 µs, its gap). Where
      packets stay whole the share still follows the rate (d1t0: 83-87%
      alone, 86-91% at 49-54 Gbps, 95-96% at 24 Gbps).
    - **Styx's order is the same in both cases.** Each packet's completion
      address names its receive queue: at 5-10 flows consecutive packets on
      a wire come from different queues 92-99% of the time, alone and
      together (styx's card turns its send queues per packet). The
      difference is when styx's frames arrive, not their order.
    - **Suspect on styx (not tested):** both test ports are one dual-port
      card on one Gen3 link (width never checked), so one PCIe read path
      and TX engine feed both ports. Alone it sends one port back to back
      at 100G. Together it can't feed two ports at line rate (Gen3 x16 raw
      is 126 Gbps, the same as icx's uplink); turning send queues per
      packet across both ports, it puts a frame on each wire about every
      other frame time. Other styx-side candidates: pause frames (global
      pause left at the driver default on both hosts, PFC off; never
      counted), the sender CPU (14 cores busy together, 7 alone; the
      same-queue share rises to 0.18/0.34 at 15/30 flows together only),
      TCP (DCTCP with nothing marking ECN, fixed 1 MB send / 2 MB receive
      buffers). **Retransmits were never recorded:** client mode of
      `run-netapp-tput.sh` writes no `retx.rpt`, so the runner's copy-back
      fails silently in every dual-NIC run.
    - Tests: "Next" item 5.

### 0x0A05 depth sweep (2026-10-17/18, strict, cap on)

1. **Drives: depth doesn't move throughput where the link has room.** At 4
   and 8 KiB every depth 2–64 is within 0.4% of d1t0c1 (median per
   setting). d1t0c1 on 0x0A05 matches d1t0c1 on 0x0A04 within −0.9/+1.0%
   per block size.
2. **Full link: deeper drains move the split, the total follows.** Drive
   0's share of IOPS at 1 MiB: 34% (d1t0c1) → 57% (d64); 64 KiB 72 → 76%;
   16 KiB 50 → 41%. Uplink 52.8–55.2 Gbps in every setting. Total vs
   d1t0c1: −3.0% at 16 KiB, up to +2.5% at 64 KiB, +1.4% at 1 MiB (d64). On
   0x0A04 d1t0c1 gave drive 0 46% at 1 MiB: the FIFO size alone moves it.
3. **Time in the switch:** full link 4.2–4.7 µs mean, p99 9–16 µs in every
   setting (0x0A04: 1.5 µs, p99 2.4–3.2): the queue in front of the uplink
   is 4× longer. Light (4k 1+1): 0.07 µs at d1, 0.57 at d16, 0.90–0.93 µs
   from d24 (the 1.02 µs time limit ends the batches).
4. **Drive 0 at 1 per drive still slow:** 154–158K (4k), 146–148K (8k),
   136–138K (16k), as on 0x0A04 (0x0A02: 185–229K, 195–206K, 174–178K).
   `pcm-iio` < 10 samples in 110 runs at 4/8 KiB; 18 runs dropped at 4k with
   32 instances (no rows).
5. **NICs (both, 5–30 flows):** 107.1 Gbps at 5 flows in every setting but
   d1t0c1 (106.1), 105.4–105.6 at 10, 95.6–96.4 at 15, 48.4–48.9 at 30, as
   on 0x0A04; misses per 4 KiB 1.13–1.20. Waits at 5 flows 1.25–2.83 µs (p99
   3.0–7.2) vs 0.64–0.83 on 0x0A04. Datapath check (NIC0 alone, 5 flows,
   d1t0c1) 80.9 Gbps (78.2 on 0x0A04).
6. **Modelled trigger shares with 512 beats** (`pips-timeout-pick.py --fifo
   512`, synthetic arrivals; `dualssd/report-gen/deep/eval-*-f512.*`):
   depths 24–64 now reachable: depth asks for 84–96% of drains on a full
   drive uplink, but 0–28% at light points, where the 255-cycle time limit
   ends a batch at 16–20 drive / ≤ 12.6 NIC TLPs. A deeper light-load batch
   needs a wider time field.
7. **The NIC sweep's stop (icx, 10-17).** `d24t255c1` f10 finished 23:50:36
   (log FULL, normal throughput); its results were written 23:53:26 (usually
   ~75 s later). 23:51:39 the root port above PIPS (96:02.0) logged CmpltTO
   for a CPU read at BAR offset 0x230 of a NIC function (mlx5 health
   buffer); 23:52:07 a second (0x23c), and NIC 99:00.0 CmpltTO on its own
   17-DW DMA read (MRd32, RO) plus correctable Bad TLP, Bad DLLP, Replay
   Timer Timeout; more at 23:53:27, 23:56:07–10 (another function's BAR,
   +0x1000 = internal timer). f15 failed 23:56:12; setting d36 read PIPS's ID
   0xFFFFFFFF. So reads in both directions through the switch stopped, then
   its own BAR: the whole switch, not just the write path. Speculation, not
   established: (a) a hang in the batcher/output path that only the bigger
   FIFO reaches: a NIC's MRd and its completions enter only once its batching
   FIFO is empty and hold the input meanwhile; d24t255c1 is the first NIC
   setting deeper than 0x0A04 could hold (216 beats) and mostly time-ended at
   light load; drives ran d24–d64 for 4.5 h without a fault (5-beat TLPs,
   few completions); (b) the FPGA's link dropped: the NIC's replay timeouts
   mean the downstream port stopped ACKing, and the root port masks Surprise
   Down (AER mask 0x04101020), so a link drop would show only as these
   timeouts and all-ones reads; (c) the NIC alone: unlikely (two functions
   and PIPS's BAR failed). Next time, before reprogramming: `bash
   scripts/pips/pips-hang-snapshot.sh` (read-only: lspci -vvv up the chain,
   AER counters, `pips cfg`, kernel log, devlink health, sweep log), then
   XSCT `pips_cfg`/`pips_dma` and the board temperature.

### Next

0. **Rerun the analysis on both hosts with the stall rebuild and the new
   grant gap** (items 11-12; the 10-19 run is in
   `*/1019/pips-analyze-*-20261019-1723/`, its models unusable, its length
   verdicts fine; the page shows the listing-based recovery meanwhile). bigserver: `bash
   scripts/pips/pips-analyze.sh ssd --no-lengths -j 16 --tmux` (page order
   only: the lengths are in; calibration ~5 min per sweep, then ~3 h at -j
   16); icx: `bash scripts/pips/pips-analyze.sh nic --tmux` (both sweeps now
   that the 0x0A05 manifest is found under `utils/logs/`, and lengths for
   0x0A05; <1 h). Watch: `tmux attach -t pips-analyze-<kind>` or `tail
   ~/pips-analyze-<kind>-*/analyze.log`; check each sweep's `uplink rate ...
   median fit of N clean logs` line (bigserver: expect ~30-31 B/cycle, about
   98% of Gen3 x8's raw 31.5; icx: few or no clean logs, fine). Copy the
   tarballs back, unpack in `dualssd/1020/` and `dualnic/1020/`. Then:
   check the whole-log model against the recorded order (`seq.jsonl`:
   `model[]` own setting vs `recorded`; waits near the recorded 1.5 µs;
   `arrival.lost`, `arrival.held`, `link.fitted`) and against the
   listing-based recovery (`report-gen/seqrec.json`). If it holds, give
   `seqarr.py` a whole-log source (its `log_data()` now reads seqrec's
   lines; the whole-log grab has `model[]` and `windows_arr` per log),
   rebuild, publish; add the NICs' 0x0A05 `traffic.jsonl` to
   `sizes.FILES`.
0b. **Finish the NIC depth sweep** after reprogramming 0x0A05: first
   `--cfgs "24:255" --caps 1 --tag d24repro "10 15"` to see if the stop
   repeats (snapshot if it does), then `--cfgs "24:255 36:255 64:255" --caps
   1 --datapath-once --tag dsweep1b`.
   (The 10-16 regrab this replaces is in `*/1016/seq-*-0a04-arr/`; its
   model ran without the uplink limit and the grant gap: items 9-10.)
1. **IOMMU off on `0x0A04`** (or `0x0A05`), drives and NICs, cap off and on. Completes the
   comparison with 0x0A02, and tells whether drive 0's single-instance drop
   needs the IOMMU. Check first that both NICs are behind the same DMAR unit
   (§5 item 1).
2. **Build or boot for drive 0:** drive 0 alone and 1+1 at 4–16k, 1 instance,
   on the 0x0A04 and 0x0A02 bitstreams within one boot, then after a reboot.
3. **`pcm-iio` samples:** read `pcm-iio.out` and `pcie.csv` (every stack,
   every second) in a few-sample run folder, e.g.
   `utils/logs/dualssd-pips-strict-1-id0a04-d1t0/4k-j8-both-RUN-0/`; make
   the summaries flag runs with `pcie_samples` < 10.
4. **One input through d1t0c1:** one drive alone at 1m, d1t0 vs d1t0c1, to
   see whether the per-drain limit that holds one NIC to 78 Gbps binds a drive.
5. **Styx and the NICs' packet splitting** (§8 item 13). All on a cap-on
   setting where one NIC splits (d4t22c1), 5 flows:
   - Read-only, styx (user confirmed 10-20: both icx NICs are cabled to
     the one dual-port card): `bash scripts/nic-host-snapshot.sh ens1f0np0
     ens1f1np1` (PCIe path with link, MPS/MRRS, the kernel's bandwidth
     line; pause, offloads, rings, coalescing, mlnx_qos, qdisc; TCP
     sysctls; counters). Run it again around a NIC0-alone and a both run
     for the pause/retransmit deltas; on icx the same for
     `tx_pause_ctrl_phy`, `rx_discards_phy`, `rx_out_of_buffer`. Styx
     reached 96 Gbps on one port, so its card can't be Gen3 x8 (63 Gbps
     raw); Gen3 x16 (126 raw) feeds about one port, not two.
   - Decisive: NIC0 alone while styx loads its other port without touching
     PIPS (pktgen or UDP on `ens1f0np0` to a MAC icx's NIC1 filters in
     hardware). If NIC0's rate drops and its packets turn whole, the shared
     card spaces the frames. Second: NIC0 alone held to ~53 Gbps by a
     hardware shaper on styx's port (`mlnx_qos --ratelimit`, even frame
     spacing) vs `iperf3 -b` at the same rate (bursts).
   - Fix the harness: write `retx.rpt` on the client (`nstat` delta per run).
   - Proposed with the user (10-20), now that page order is the topic: cap
     each NIC so alone and together run at the same per-NIC rate (about
     45-50 Gbps: two together under the switch's 107 and styx's card), so
     alone vs together differs only by the other NIC. The cap has to space
     frames the way the card does in co-run. `iperf3 -b` (the runner's
     `--bandwidth`) paces in bursts, with frames back to back at 100G
     inside each; `--fq-rate` with the fq qdisc spaces 64 KB TSO bursts,
     not frames; a hardware shaper on styx's port (`mlnx_qos -r`) may space
     frames (untested). Check first: one NIC0-alone run per method at the
     cap, grab its order, look for 7+ TLPs per run. The uncapped sweeps
     stay as the full-link case.
