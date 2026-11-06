# Archive: PIPS design 0x0A06, the page batcher campaign (2026-10-23 to 10-26)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The 0x0A06 campaign as set up (phases, the 10-25 soft lockups and their fix) and its results R1-R10, including the methodology correction (page-order lines from the measured arrival order).

- Artifact: https://claude.ai/artifact/HW13EiQXS5414G5ASfyZna
- Report page: "PIPS 0x0A06 Campaign" https://claude.ai/artifact/L3U8deVtMb4nHmb91AscK3
- Data: `dualssd/1026/`, `dualnic/1026/`; tables `py -3 dualssd/report-gen/c1026.py [ssd|nic]`

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From HANDOFF.md §8, "0x0A06 campaign" and "0x0A06 campaign results"**

### 0x0A06 campaign (set up 2026-10-25, ran 10-25/26; results below)

`scripts/pips/pips-campaign.sh ssd|nic` (`--dry-run` for the exact commands).
Design 0x0A06 only; no reboot (IOMMU as booted, strict), no PCIe retrain.
Decisions, with the user (10-25):

- **Completion threshold 31 DW on both inputs (`w31`) in every phase but
  `thr`.** Erring high is safe (data taken for a completion only costs
  batching and adds a fence); a completion taken for data loses the fence.
  0x0A04/0x0A05 logs (`*/1019/pips-analyze-*/traffic.txt`): drive completions
  4 DW, mlx5 16 DW; NIC data from 32 DW (69 writes) and 48 DW; drive 1 writes
  data of 4-32 DW (about 0.5% of its writes) and 36 DW (14%), so 31 keeps
  the 36s as data. `thr` runs the exact entry size (4 drives, 16 NICs).
- **Drives:** instances 1, 2, 4, 8, 16 (32 dropped: same as 16); uneven only
  2/4/8 on drive 0 + 16 on drive 1 (the heavy side moved little). `main` = 8
  depths x `page_batch_en` 0/1, cap on (640 runs); `cap0` d1/d8/d64 cap off;
  `push` o1; `quant` 64/256/1024 beats; `thr` 4 DW; `drv0` drive 0 alone and
  1+1, 16+16 at 4k-1m on d1t0 cap off/on (Next items 2, 4). Knob phases use a
  smaller grid: 4k/16k/1m x 1/4/16 + 2+16.
- **NICs:** flows 5, 10, 15, 30 and uneven 5:30, 30:10 (heavy side
  alternating), uncapped and **capped at 50 Gbps per NIC**, 100 together:
  under the weakest shared link (the switch's Gen4 x8 uplink, ~107 Gbps of
  payload measured; styx's one Gen3 x16 card, 126 raw). `mainlo` depths 1-16,
  `mainhi` 24-64 last of the switch phases (d24 stopped 0x0A05's sweep).
- **Packet splitting (§8 item 13):** `alone` NIC0 alone vs both, 5 flows,
  uncapped / 50 / 25 Gbps (iperf3 `-b`), at d1t0 (clean on 0x0A04), d16t64
  (split, cap off) and d4t22c1 (split), `page_batch_en` 0/1. On 0x0A06 with
  `page_batch_en` 0 the FIFO is 1536 rows, so a long hold no longer fills it:
  whole packets there would mean **backpressure (posted credits withheld by
  the FPGA's downstream port) causes the splitting**, not the wait itself.
  `hw` paces in styx's NIC (mlx5 `tx_maxrate`, even frame spacing) instead of
  iperf3's bursts. `wire` forces NIC0's link to 50G at both ends (Ethernet
  only; restored after): frames 0.64 us apart, the co-run spacing, alone.
  Every NIC run now records client retransmits and pause/discard deltas.
- **Hardware the user may add later (not in this run):** an ingress rate
  limiter on each of the three ports; per-input counts of cycles the
  batcher refused input while data waited (turns "probably credits" into a
  measurement); a register for the downstream link speed.
- **If the switch hangs:** snapshot at once, later switch phases skipped,
  loud warnings, analysis and packing go on.
- **2026-10-25, first run, bigserver: soft lockups.** About 1h40 in (stamp
  `c10251207`), right after the 80 clean `d1t0c1` runs (`page_batch_en` 0 and
  1), as `d2t22c1w31` (`page_batch_en` 0) began: CPUs 40 and 45 (fio cores,
  the drives' interrupt CPUs) stuck 22-150 s in `nvme_irq` → `nvme_unmap_data`
  → `iommu_dma_unmap_page` → `qi_flush_iotlb` → `qi_submit_sync` (strict
  mode's synchronous IOTLB invalidation, dmar7); an `awk` waiting on them in
  `smp_call_function_single`; `sar`, `pcm-iio` killed, fio outlived by the
  window, the point FAILED. 6 more lockups after 13:48. The switch's status
  over that run was clean (no stuck, no spill, MRd wait max 13.6/11.4 us), no
  AER, no NVMe timeouts, no DMAR faults; no profiler running (`sep5`,
  `socwatch2_16`, `vtsspp` loaded, 0 users). **Cause: interrupt placement,
  not the switch.** The lockups began with the campaign's first run (12:07,
  170 by 14:00; nearly every point FAILED, mostly "pcm-iio logged no rows":
  pcm-iio hangs behind the stuck CPUs), and d1t0c1 alone reproduces them. In
  this boot (11:49) both drives' blk-mq queues for CPUs 36-40 interrupt CPU
  40 and for 41-45 CPU 45 (nvme0 q4/q5, nvme1 q5/q6); only 46-49 and 50-53
  have separate ones (49/53 drive 0, 48/52 drive 1). `SSD_CORES` put both
  drives on 36-45 and fio on 40, 45, 48, 49, 52, 53, so CPUs 40/45 did every
  strict invalidation of both drives' completions (one dmar7 queue) while
  running fio: livelock. Fix (no reboot; managed IRQs can't move):
  `SSD_CORES=( "36,41,37,42,38,43" "46,50,47,51,49,53" )`,
  `SSD_SPLIT_CORES=0` (uneven runs no longer borrow the other drive's cores);
  `scripts/ssd-irq-placement.sh --check` verifies it and the drive campaign
  refuses to start without it. Every run now records `kernel_soft_lockups`
  (summaries flag them), and the campaign stops its sweeps on 2+ lockups in
  one heartbeat. Each drive now uses 2 queues (was 4 in §7's 10-05 layout):
  not directly comparable with the 0x0A04/0x0A05 drive sweeps. Likely also
  behind their "pcm-iio < 10 samples" runs (Next item 3).
- **2026-10-25, icx:** `retx.rpt` permission denied: `record-host-metrics.sh`
  (sudo, retransmits on by default) writes its own root-owned `retx.rpt`;
  the client's nstat count is now `retx-client.rpt` (fixed; earlier runs of
  this campaign have no client retransmits).
- **When the tarballs are back:** unpack in `dualssd/<MMDD>/`,
  `dualnic/<MMDD>/`; `results/` has the summaries (`~/<sweep>.txt`, with the
  status table), `status.txt` the stuck/spill/wait check, `analyze-new/` the
  page order (recorded and arrival, listings), `analyze-pending/` the
  0x0A04/0x0A05 model rerun (item 0's checks).

### 0x0A06 campaign results (2026-10-26)

Data: `dualssd/1026/pips-campaign-ssd-c10251425/` (bigserver, started 10-25
14:25 on `693c60a5f`, 18h11), `dualnic/1026/pips-campaign-nic-c10251157/`
(icx, started 10-25 11:57 on `9b36f3e6c`, 22h27). Tables:
`py -3 dualssd/report-gen/c1026.py [ssd|nic]`, saved as
`dualssd/1026/c1026-ssd.txt` and `dualnic/1026/c1026-nic.txt`. Every phase
ran; the switch answered to the end; no stuck flag, no soft lockup (the
placement fix held), no pcm-iio run under 10 samples; every page-order log
analysed (828 + 318). Each point ran once. Noise, from the points two phases
repeat (drv0 vs main, cap0 vs drv0, 14 pairs): Gb/s median 0.8% (max 3.5%),
IOTLB misses per 4 KiB median 2.1% (max 5.9%). The NIC campaign started
before the retransmit fix: its `retx_pct` is 0 for want of data, not a
measurement.

1. **Page batching regroups pages but changes neither misses nor
   throughput, on both hosts.** Drives (`main`, 40 points per setting):
   `page_batch_en` 1 cuts runs per I/O on the uplink by 2% at d1 up to 28%
   at d64 (44% at 1m), TLPs per run 2.4 → 3.5; IOTLB misses per 4 KiB
   (pcm-iio) change by -1.0 to +0.3% (noise), Gb/s by 0 to -1.1%. NICs (12
   points per setting): runs per I/O 4.9 → 2.5 at d64, TLPs per run 2.8 →
   5.5; misses per Gb 36.6k at every setting either way. The model's
   strict-mode IOTLB (1x64) agrees: about -1%. Reason: in strict mode every
   page visit is a miss (its entry was invalidated when the last I/O on it
   completed), so the floor is one miss per page; measured 1.09 per 4 KiB at
   1m, 1.25-1.4 at 4-16k. Regrouping removes only re-misses from thrashing,
   which a 64-entry IOTLB rarely sees with these open-page counts. Batching
   can only show in a non-strict (lazy) mode, which needs a reboot.
2. **Page batching ends the NICs' pause frames.** With `page_batch_en` 0,
   d1t0c1 and d16-d64 have NIC pause frames and receive discards (d1t0c1:
   45k pauses, 321k discards per run on average; d36/d64: 35k, 290k) and
   uncapped 5-flow both-NIC throughput drops to 104.7-106.4 Gbps; with 1,
   zero pauses at every depth and 107.1 Gbps everywhere. One NIC alone,
   uncapped: pb0 d16t64 93.8 Gbps, 58k pauses, 612k discards; pb1 95.3, none.
   d4t22c1: pb0 90.3, 100k pauses, 1.38M discards; pb1 95.5, none.
3. **Page batching runs out of page segments constantly.** Overflow
   (`0x28`) on almost every pb1 run: drives a few hundred to thousands per
   run at 4k, saturated (65535 per input) on many; NICs saturated on nearly
   all. The 16-bit counter hides how often; batching works between spills.
4. **Knobs (`cap0`, `push` o1, `quant` 64/256/1024, `thr` 4 DW / 16 DW):
   no effect beyond noise** on Gb/s or misses, either host. Cap off at depth
   1 regroups more (runs per I/O -38 to -65%) with the same misses. The
   uneven flows (5:30, 30:10) still give each NIC the same rate (48/48,
   42/42 Gbps): the arbiter (and the quantum) never had uneven load to
   divide. 30 flows per NIC: 48 Gbps total at every setting, as without the
   switch and with the IOMMU off on 10-01: a host limit.
5. **Read waits (`0x2C`).** Drives: an MRd waited up to 262 us (pb0) /
   219 us (pb1), median per run 104/63 us at 64k, 21-32 us at 4-8k, at every
   depth including d1t0c1: reads queue behind the input's writes in the
   1536-row FIFO when the Gen3 x8 uplink is full (bufferbloat, not the
   hold). No AER or timeouts seen. NICs: at most 12.8 us (pb0), 8.7 (pb1).
6. **NIC packet splitting (item 13) is the NIC's receive backlog; frame
   spacing on its wire decides it.** NIC0's own order (in0 TLPs per run, 8
   = whole 4000-byte packets, 1 = fully interleaved), pb0:
   - Ethernet forced to 50G (`wire`, 0.64 us per frame): **whole packets
     alone** at d16t64 (7.22) and d4t22c1 (7.24), where at 100G alone they
     split (1.03, 1.03, with pauses and discards). Both NICs: whole (7.20,
     7.24).
   - Paced at 50G on a 100G wire: split anyway. iperf3 `-b` alone: d16t64
     5.53, d4t22c1 2.06; styx's hardware shaper (`tx_maxrate`, `hw`) alone:
     3.13, 2.66; both NICs at 50G each: 4.08, 2.85 (iperf3), 7.17, 1.27
     (shaper). Pacing still sends line-rate bursts.
   - Uncapped, both NICs: whole at every setting (7.2-7.3); one alone at
     d1t0 (no hold): mostly whole (6.68, no pauses).
   So a NIC splits when frames arrive at 100G faster than the switch takes
   its writes at that setting (a hold, or two NICs' paced bursts at once):
   its receive buffer backs up (pause frames, discards) and it writes
   several packets at once. Styx's shared card matters only because, with
   both ports busy, it spaces each port's frames ~0.6 us apart. **An FPGA
   ingress rate limiter would slow the NIC's writes and so (predicted) cause
   splitting, not prevent it;** to match alone and together, slow the wire
   (`wire` phase: `ethtool -s ... speed 50000` both ends).
   **The rule (page R6):** a NIC keeps its packets whole while it writes
   each packet before the next frame arrives. At 100G a frame takes ~0.32
   us on the wire; the packet plus completion takes ~0.27 us up Gen4 x8 at
   the fitted 60.5 B/cycle: ~50 ns slack (estimate). NIC0 alone at 100G,
   mean `pips_in0_wait_mean`: d1t0 31-47 ns whole (6.7-6.9 TLPs per run),
   held settings with pb1 80-83 ns partly split (4.66, 3.30, no pauses),
   pb0 147-239 ns fully split with pauses; frames ~0.6 us apart (both NICs
   uncapped) stay whole at 200-345 ns. Splitting doesn't move misses
   (0x0A04 item 8).
7. **Drive 0 alone (`drv0`, Next items 2 and 4).** One drive at 1m: 55.3
   Gb/s at d1t0, 54.0 at d1t0c1 (-2.3% at j1 and j16): the per-drain cap's
   re-grant gap binds a drive slightly. Both drives at 1m: 53.4-53.7 total
   (alternating inputs costs ~3% of the Gen3 x8 uplink). Smaller sizes: no
   cap effect beyond noise.
8. **Pending model rerun (item 0).** NICs: the model on the arrival order
   matches the recorded order (runs per I/O ratio median 1.000 / 1.015,
   waits 0.39/0.39 and 0.85/0.86 us; link fit 60.5 B/cycle, Gen4 x8). Drives:
   runs match (1.04 / 1.01) but **waits come out 3x low** (0.40 vs 1.44 us
   on 0x0A04, 1.17 vs 3.57 on 0x0A05) and the uplink calibration fits 35.5
   B/cycle, above Gen3 x8's raw 31.5 (expected 30-31): about 30% of each
   log's time is missing and the fit hides it in a too-fast link. Open.
9. **Page order on 0x0A06 (page v2, Figures 6-9; `report-gen/seqrec6.py`,
   `page6.py`).** The 0x0A04-0x0A05 page's Figures 3-6 for the main sweeps
   (drives 40 points, NICs 12 two-NIC points, 8 depths, pb0 and pb1): the
   batcher model (0x0A05's rules, FIFO 1536 or 512) on each device's own
   order from the pb0 logs, floor, raw, recorded pb0/pb1 marks. NICs: the
   model fits (own setting within +-7%, median per depth and rate); pb0
   page switches per packet 9.0 (50G) / 8.0 (uncapped) at d1, 4.5 / 3.9 at
   d16, back up to 5.6 / 5.0 at d64 (the pause/splitting depths); pb1 at
   d64 2.9 / 2.5, below the by-page line (3.6 / 2.9), 1.8x the floor (1.6 /
   1.4). **Superseded by result 10** (the raw and model lines here are
   seqrec's synthetic arrivals, not the measured order). Drives, as first
   read: the model doesn't fit pb0 on a full link (own setting
   16-49% fewer page switches than recorded at 16k-1m; 4k within 12%, 8k
   within 10% to d8 then 19-30% low), where it fit 0x0A04 within a few %:
   likely `wrr_en` tied 1 (above), so pb0 is not 0x0A05's arbiter. pb0 at
   d16-64 sends about the raw order (16k 10.3 vs raw 10.8; 64k 14.1-14.3 vs
   18.2; 1m 10.1-10.4 vs 15.3); pb1 at d64 8.6 / 9.0 / 5.9 (16k/64k/1m),
   -16/-36/-41%, still 3-4x the by-page line (2.7 / 2.2 / 1.7) and far
   above the floor (1.2-1.4): consistent with the constant spills (result
   3). To check the arbiter: rerun a few drive points with wrr off, if a
   build allows it, or model the WRR in `pips-page-seq.py`'s batcher.
10. **Methodology correction: lines from the measured arrival order
   (10-26, summary page v5).** The model, floor and raw lines on all three
   page-order pages (0x0A04-0x0A05 v8-v10, 0x0A06 v2, summary v1-v4) come
   from `seqrec.py`/`seqrec6.py`: each device's own order with **synthetic**
   arrival times (I/O bursts at a fixed pace, link fitted to the recorded
   wait), the 10-20 stopgap (§8 item 12: "the host rerun measures the
   arrival order and settles it"). The rerun is in: every log of the
   campaign's analysis has the measured arrival order (`interleave.arr`,
   `windows_arr`: in_sop = out_sop - pkt_wait, stalls put back) and, for
   0x0A04/0x0A05 (`analyze-pending/`), the batcher model run on it
   (`model`: self, the sweep's settings, sweepc1 at both FIFOs);
   `pips-seq-grab.sh` runs no model on 0x0A06 sweeps. Measured arrivals are
   far less interleaved than the synthetic ones: raw (windows_arr w=1, on
   the marks' scale, pb0 logs) 4k 5.4, 8k 6.5, 16k 7.6, 64k 13.3, 1m 9.5,
   NICs 5.8, NICs 50G 7.1, against synthetic 6.2, 8.7, 10.5, 18.4, 15.6, 6.5,
   8.1. The arrival order hardly depends on the design (16k: 0x0A05 7.0,
   0x0A06 pb0 7.0; 0x0A04 8.4-9.1, its 128-row FIFO pushes back). The model
   on the measured order at each log's own setting: 0x0A05 within 1.5%
   (median, d16-64) at every block size and the NICs, 0x0A04 0-8% (cap off
   and on), up to +15% at d1-8 (8-16k). So: **0x0A04/0x0A05 batch below
   their arrival order as the model says** (0x0A05 d64 16k/64k/1m 4.7 /
   10.9 / 6.7; arrival 7.0 / 13.5 / 10.0; model 5.1 / 11.0 / 6.5), and
   **0x0A06 pb0 sends more page switches than arrived** (d64 10.3 / 14.1 /
   10.1 against its own arrival 7.0 / 13.1 / 9.2; 8k 6.2 vs 5.75; NICs 6.0
   vs 6.3, about arrival), twice the model at 16k, from the same arrival
   order as 0x0A05. Result 9's "pb0 sends about the raw order" and "the
   model doesn't fit pb0" were artifacts of the synthetic raw/model. The
   difference lies between arrival and the uplink (0x0A06's drains and
   input choice); known rule difference `wrr_en` tied 1 (open-page WRR per
   beat instead of round robin), plus 1536 rows and its pipeline; not
   confirmed. pb1: arrival not measurable (the rebuild holds each input to
   its output order, which pb1 breaks: its `arr` reads 3.6 at 16k against
   pb0's 6.3), so compare with pb0's: pb1 d64 16k 8.6 (above arrival 7.0),
   64k 9.0, 1m 5.9 (below), NICs 2.5 (at the model's by-page 2.5). To do:
   (a) rerun the 0x0A06 analysis on the hosts with `--model` (pips-seq-grab
   `--manifest ... --model self,deep,sweepc1,sweepc1f512` on the main
   sweeps, pb0 logs) for its own-setting check and 1536-row lines; (b) redo
   the 0x0A04-0x0A05 page's Figures 3-6 and the 0x0A06 page's Figures 6-9
   from `seq.jsonl` (model, windows_arr) instead of seqrec; (c) to test the
   arbiter, a build with `wrr_en` in a register. Summary page v5
   (`sumpage.py`) already uses the measured order: raw = windows_arr w=1
   (pb0 logs of every design), model = host model cap on t255 at depths
   1-64, FIFO 128/512 (0x0A04/0x0A05 logs), floor = seqrec's (each device's
   own order; needs no cross-device timing), checks = host model at own
   setting.

