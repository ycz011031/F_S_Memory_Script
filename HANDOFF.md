# Handoff — dual-NIC IOMMU contention on icx

Everything needed to run this testbed, plus what is known, unknown and broken.
Companion docs: [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md) for how the repo fits
together, [LOCAL-SETUP.md](LOCAL-SETUP.md) for first-time provisioning.

- **Branch:** `icx-dualnic` on `ycz011031/F_S_Memory_Script`
- **Upstream:** `host-architecture/Fast-and-Safe-IO-Memory-Protection` (remote `upstream`)
- `master` is a pristine mirror. `git diff master..icx-dualnic` is the whole delta.
- **Last updated:** 2026-09-29, after the uncapped flow sweep (§4.1).
- **Headline:** IOMMU strict and IOMMU off give the same throughput in every
  configuration run so far. Reasons are speculated in §4.1; the experiments
  that would settle them are in §5.

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
./scripts/sosp24-experiments/dualnic_flow_sweep.sh              # [-o name] [flows] [rates] [runs]

# single configuration
./scripts/run-dualnic-experiment.sh -E mytest --nics 2 --uncapped -S 8 --runs 3
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
# 1. IOMMU still on? If this is empty the experiment measures nothing.
cat /proc/cmdline | tr ' ' '\n' | grep -i iommu

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
`-off-2` (`.jsonl` + `.txt`). **`strict-1` and `strict-2` are invalid**: two
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
combined.

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
against 3.8 M/s), which does not fit walks ending in cache. Until that
counter's meaning is checked (§5), this evidence is suggestive only.
*Test: §5 item 2.*

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

*Confidence: low on which one; high that it is not the IOMMU. Test: §5 item 5.*

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
walks terminating in cache. **Verify that counter's semantics against the Ice
Lake uncore spec before building an argument on it.**

---

## 5. Next experiments and open items

In order of what each one decides. Commands run on icx from
`~/F_S_Memory_Script`.

1. **Simpler switch design (planned).** Removes the bias from the current
   topology: both NICs behind one PCIe switch with a single x8 Gen4 uplink,
   which capped every 2-NIC run at ~105.7 Gbps (§4.1 A).
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

2. **Does 6.8 map and unmap per packet? (~5 min, booted strict. Tests §4.1 B.)**
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
   will not reproduce on this kernel: do item 4.

3. **Single-NIC flow sweep, strict vs off, at the paper's flow counts. Tests
   §4.1 A.** Removes the shared uplink. Once per IOMMU setting:
   ```bash
   ./scripts/sosp24-experiments/dualnic_flow_sweep.sh "5 10 20 40" uncapped 3 nic0only
   ```

4. **Boot the paper's baseline kernel, stock 6.0.3,** if item 2 shows
   recycling. Build it per `README.md` (no patch is needed for the "IOMMU on"
   baseline) and re-run item 3. Only then compare against the F&S-patched
   kernel.

5. **Explain the 30-flow cliff. Tests §4.1 C.** It sits exactly where the
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

6. **Make the IOMMU the tightest limit,** once 2–5 say it can matter:
   - **Fewer receiver cores** (1–2 per NIC via `SERVER_CORES`). The CPU becomes
     the limit, so strict's CPU cost (§4.1 observation 3) turns into lost
     throughput.
   - **Ring-buffer sweep, 256 → 4096.** A larger working set is the mechanism
     F&S targets, and no dual-NIC ring sweep has been run.
   - **MTU 1500.** About 2.7× more packets per byte.
   - **Rate capped below the uplink** (e.g. 40 Gbps per NIC), so the link never
     binds.

**Still open from before**

- **`IOMMU_mem_access` semantics.** ~5 per miss (§4.1 B, §4.2). Check against
  the Ice Lake uncore spec before building any argument on it.
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
- **`membw.rpt` has no values.** The `pcm-memory` output is not parsed, so the
  JSON has no memory-bandwidth fields.

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
- **`collect_iio_occ` is Skylake-only** (hardcoded MSRs) and disabled. Its output
  was never parsed by anything.
