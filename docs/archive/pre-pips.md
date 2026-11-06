# Archive: icx and bigserver before PIPS (2026-09-29 to 10-11)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The dual-NIC results on icx with the NICs on the board's own PCIe switch, the next steps planned then, the dual-SSD results on bigserver (direct, then switch designs A-D), the next steps on bigserver, and KNOWLEDGE-MAP's old status section.

- Artifact: https://claude.ai/artifact/G5s7nD5CRPLV646Jq6QrhT
- Report page: "Dual-SSD Cross Sweeps" (designs A-D) https://claude.ai/artifact/AcYH8Ff2Drt5kon44un3gX
- Data: `dualnic/1001/`, `dualssd/1006/`, `dualssd/1010/` (local, git-ignored; FILE-MAP §7)

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From HANDOFF.md §4, without §4.3 (still in HANDOFF)**

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


> **From HANDOFF.md §5**

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


> **From HANDOFF.md §7, the five results**

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


> **From HANDOFF.md §7, "Next on bigserver"**

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


> **From KNOWLEDGE-MAP.md §6**

## 6. Status

The live status is [HANDOFF.md](HANDOFF.md) ("Last updated", and §8 "Next").
As of 2026-10-19: strict and off give the same throughput everywhere so far
(icx, bigserver); the PIPS switch's batcher (designs 0x0A02-0x0A05, depth up
to 64 with a 512-beat FIFO on 0x0A05) changes how a full link is shared and
the page order the IOMMU sees, not the throughput or the IOTLB misses; the
page-order model is being rerun on the hosts with its uplink and grant-gap
fixes (`pips-analyze.sh`).

The early-October plan below is kept for its history; its items 1-4 are done
(HANDOFF §2-4).

**Done (early October)**

- Fork created, `master` pushed as a pristine mirror, `local-setup` pushed
- Minimal traffic path written; all five scripts syntax-checked, error paths tested
- Testbed config written for the 192.168.10.0/24 link
- LF endings pinned so scripts survive a Windows-authored round trip

**Next (as planned then)**

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
