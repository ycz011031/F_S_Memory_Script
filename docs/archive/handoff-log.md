# Archive: HANDOFF changelog and old "Next" lists (2026-09-29 to 11-05)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The "Last updated" entries from 11-05 back to the first one, the three overview bullets that followed them, the statuses of §8 "Next" from 11-02 back to 10-20, and its numbered item lists (0-5 from 10-19/20, the 10-26 software and hardware lists). Also HANDOFF's former title and opening lines.

- Artifact: https://claude.ai/artifact/RV2WxMKKri8YBcBSJMssSZ

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From HANDOFF.md, its former title and opening lines (before 11-06)**

# Handoff — dual-NIC IOMMU contention on icx

Everything needed to run this testbed, plus what is known, unknown and broken.
Companion docs: [FILE-MAP.md](FILE-MAP.md) for which script does what and
calls what, [KNOWLEDGE-MAP.md](KNOWLEDGE-MAP.md) for how the repo fits
together, [LOCAL-SETUP.md](LOCAL-SETUP.md) for first-time provisioning,
[QRH.md](QRH.md) for every script option on one page (keep it in step when

> **From HANDOFF.md, the header's entries after "Last updated" and 2026-11-06**

- **2026-11-05:** new `scripts/pips/pips-id.sh`: one
  read-only command for both hosts that says whether the FPGA is our PIPS
  switch, its design ID (with the FPGA commit) and the setup (ssd / nic)
  from what is below it. Tested here only on a fake sysfs tree with a stub
  `pips` (NIC, drive, other bitstream, hung, wrong ID); not yet on a host.
- **2026-11-05:** **alias campaign set up, not run** (§8
  "Alias campaign"): in-house generators replace fio and iperf3 (drives:
  `alias-nvme` over VFIO; NICs: `alias-rdma` READs), fixed pages mapped
  once in a (ws, stride) pattern that gives conflict or capacity misses;
  runners `--gen alias`, `pips-campaign.sh ssd|nic --alias`. perf/VT-d PMU
  on hold (user); misses from pcm-iio. Untested on the hosts.
- **2026-11-02:** **the 0x0A07 paper campaign is in and
  analysed** (§8 "0x0A07 paper campaign results"; page "PIPS 0x0A07
  Campaign" v2): drives lazy/pt/off + the 10-28 rerun as strict, NICs all
  four modes; E7 has no data (no perf). 2026-10-31: set up
  (§8 "0x0A07 paper campaign"): `pips-campaign.sh ssd|nic --paper
  --leg <mode> --tmux`, the user's experiment list E1, E2, E5-E13 (E2b, E3,
  E4, E15 out of scope), one IOMMU leg per launch: the campaign runs the leg
  of the mode the host booted with (strict, lazy, pt, off) and never changes
  it; the user reboots between legs (~2h50 per leg per host). New:
  `pips-pcie-caps.sh` (E6), `utils/iommu-ops.sh` + the runners'
  `--iommu-ops 1` (E7). Untested on the hosts.
- **2026-10-30:** **the 0x0A07 NIC rerun is in; verdict: the
  switch study is done** (§8 "0x0A07 NIC results" and "Verdict"; report page
  "PIPS 0x0A07 Campaign" https://claude.ai/artifact/91VNbNGeJVyfuLLH8acGvY,
  hand-written `dualssd/dualssd-pips-0a07-report.html`). Measure: page
  switches as the writes leave the switch (user, 10-30: misses and bandwidth
  don't matter, the testbed's IOMMU is clean, unlike production). NICs at
  the **legal floor** (completions leave at once: 2.29 per packet vs 2.28,
  one NIC alone 2.24); drives 4k/16k within 20-40% of it; the only gap left
  is drives at 64k/1m (2.3-2.8x, spills saturate: 8 page segments too few).
  The FPGA rate cap splits a NIC's packets (R6's prediction confirmed). One
  optional build (more segments) only if large drive I/Os matter.
- **2026-10-28 (evening):** **the 0x0A07 drive rerun is in and
  result 10 is solved** (§8 "0x0A07 drive results"): with page batching off
  the drives' page switches are back to 0x0A05's level (sent / measured
  arrival median 0.85, 0x0A05 0.81, 0x0A06 1.19; d64 16k 5.2 against 0x0A06's
  9.9) and the model at the log's own setting fits within 2% at d16-64; with
  page batching on, d64 16k / 64k / 1m fall from 8.3 / 9.1 / 5.9 to 2.6 / 3.4
  / 3.5. Throughput and IOTLB misses unchanged (+0.8%, -1.8% median; strict
  mode). Data `dualssd/1028/`, tables `report-gen/c1028.py`. The NIC rerun is
  not back yet.
- **Earlier 2026-10-28:** **FPGA design 0x0A07 is built** (FPGA repo
  `28ff5b6`): rate caps on both inputs and the output (regfile reg4), counters
  of the cycles each input was refused (and the rate cap's part), and a
  **changed read flush** (no longer preempts the other input's drain: on
  0x0A06 it interleaved the two devices packet by packet, the likely cause of
  0x0A06 result 10's excess page switches). Tools support it (`pips cfg set
  rcap=`, `pips counters`, counters sampled every 2 s per run into
  `pips-bp.tsv`, `pips_stat_bp_frac_*`; sweeps `--set rcap0=`, tag
  `r<a>x<b>x<c>`; hwtest checks reg4). **To run: the minimal rerun of the
  0x0A06 campaign on 0x0A07,** `pips-campaign.sh ssd|nic --minimal --tmux`
  (§8 "0x0A07 minimal rerun": drives as the 0x0A06 main sweep at 4 depths;
  NICs with the Ethernet and the FPGA rate cap at representative points);
  `make check` not run yet (no Linux here). Open items: §8 "Next", status
  10-28; items 0b and 1 canceled.
- **2026-10-26: the 0x0A06 campaign ran on both hosts**
  (bigserver `c10251425`, 18h11, 828 points; icx `c10251157`, 22h27, 332
  points; switch answered throughout, no soft lockups, no stuck). Results in
  §8 "0x0A06 campaign results"; data in `dualssd/1026/`, `dualnic/1026/`
  (local, git-ignored; FILE-MAP §7), tables from
  `dualssd/report-gen/c1026.py`. Headlines: page batching groups pages
  (runs per I/O -28% drives, -50% NICs at depth 64) but IOTLB misses and
  throughput don't move (strict mode: every visit misses anyway); it ends
  the NICs' pause frames; the NIC splitting is the NIC's receive backlog,
  decided by frame spacing on its wire (Ethernet forced to 50G: whole
  packets alone at every setting). Report page "PIPS 0x0A06 Campaign"
  (https://claude.ai/artifact/L3U8deVtMb4nHmb91AscK3, hand-written
  `dualssd/dualssd-pips-0a06-report.html`), with the next steps (§8 "Next").
- **2026-10-25:** the campaign script
  (`bash scripts/pips/pips-campaign.sh ssd|nic --tmux`, §8 "0x0A06
  campaign"); FPGA design **0x0A06** (the page batcher,
  `9673e37` + `d44fdd0`) supported by the tools (`pips cfg set pb= pushoff=
  quantum= thr=`, `pips status`, tags `p1 o1 q<N> w<N>`); the sweeps take
  `--pbs`/`--set`; NIC runs take uneven flows (`5:30`), hardware pacing
  (`hw50`) and record retransmits and pause/discard counters; the campaign
  script. `make check` passed on bigserver (10-25, after `693c60a5f`).
- **2026-10-20 (NIC splitting):** why one NIC alone splits its packets and
  two together don't is in §8 item 13: the gap between a NIC's packets on
  its wire decides it; styx's shared dual-port card is the suspect
  (untested; tests in §8 "Next" item 5). Dual-NIC runs never recorded
  retransmits.
- **Earlier, 2026-10-20 (later):** page order **recovered from the
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


> **From HANDOFF.md §8 "Next", from "Status 11-02" to the end**

Status 11-02: the paper campaign is in and analysed (results above); the only open run is optional (item 9: drives 4k j16 per mode with interrupt-safe cores).
Status 10-31: the paper campaign above is set up (not run): one IOMMU leg per boot, the user reboots between legs.
Status 10-30: both reruns are in; **verdict: the study is done** (above).
The items below are kept for reference; none is needed. The only one still
worth a build is more page segments (drives 64k/1m), and only if large drive
I/Os matter. Status 10-28 evening: the drive rerun is in (above, result 10
solved). Status 10-28 (0x0A07 built): first
the minimal rerun above. From the
hardware list below, 0x0A07 delivered the per-input refused-cycle counter
and the rate limiter; still not built: a 32-bit overflow count (`0x28`
still saturates at 65535), FIFO occupancy high-water, MRd wait mean or
histogram, hold only when the other input waits, the FIFO limit register,
`wrr_en` in a register (result 10 (c)). The rate cap is now usable as the
test knob below: NIC writes of 512 bytes take 9 beats, so `rcap0` ≈ 2.25 x
the NIC's payload Gb/s (50G ≈ 113, 95G ≈ 214; calibrate on d1t0 first, the
counters' cap share shows when it binds). Result 10 (a) is in the rerun's
analysis for 0x0A07; for the 0x0A06 logs it needs `PIPS_PB_MODEL="self,sweepc1,sweepc1f512"
bash scripts/pips/pips-analyze.sh <kind> --sweeps "" --manifest <each main
sweep's manifest>` on the hosts. (b), redrawing the 0x0A04-0x0A05 page's
Figures 3-6 and the 0x0A06 page's Figures 6-9 from `seq.jsonl`, is still
open; the 0x0A06 drive figures may be superseded by 0x0A07's.

Status 10-26 (from the 0x0A06 campaign, results above): item 0 ran (NICs
match; drives: waits 3x low, link fit 35.5 B/cycle, open: result 8); item
3 answered (no run under 10 samples after the placement fix); item 4
answered (result 7: -2.3% at 1m); item 5's decisive question answered by
the `wire` phase (result 6). New, in order of use:
The question to settle first: can page order move IOTLB misses on these
hosts at all? In strict mode no (result 1). Software and runs, in order:
- **Count maps and unmaps (no reboot, ~5 min, §5 item 3, never run):**
  `sudo perf stat -e iommu:map,iommu:unmap -a -- sleep 5` during a 5-flow
  NIC run and a 4k drive run; unmaps per 4 KiB written. ~1 = compulsory
  misses (strict invalidation); far fewer (mlx5 `page_pool` keeping pages
  mapped) = capacity misses from a working set far beyond the IOTLB, where
  the lever is the ring size (`ethtool -G ... rx`), not the switch.
- **Lazy mode without a reboot (decisive for the page batcher):**
  `echo DMA-FQ | sudo tee /sys/kernel/iommu_groups/<g>/type` per group.
  Check first: that 5.15 (bigserver) / 6.8 (icx) accept it (may need the
  driver unbound), that the devices behind PIPS have groups of their own
  and no boot or RAID disk shares one. Back to strict needs the driver
  unbound or a reboot. Then pb0 vs pb1 on a small set (drives d8/d64 at
  4k, 16k, 1m; NICs 5 flows). Misses falling with pb1 = the page batcher
  has its case; if not, order isn't the lever on these IOMMUs.
- **Superpage probe:** fio 2 MiB blocks on hugepage buffers
  (`--iomem=mmaphuge`) on one drive; misses per 4 KiB well below 1 means
  2 MiB IOMMU mappings work (may be stopped by `max_hw_sectors_kb` or IOVA
  alignment).
- **Uneven load for the arbiter:** NIC0's link at 25G or 50G, NIC1 at 100G,
  so `grant_quantum` has unequal inputs (result 4). Link speed, not pacing
  (result 6).
- **Latency in the summaries:** fio completion latency p50/p99, pb0 vs pb1,
  to see result 5's read waits at the application.
- **Drive model waits** (result 8): find the ~30% of each drive log's time
  the output timing lacks before trusting modelled drive waits.

Hardware (PIPS), in order:
- **Counters:** 32-bit overflow (`0x28` saturates, result 3); per-input
  cycles refused while the device had data (measures result 6's
  backpressure); per-input FIFO occupancy high-water; MRd wait mean or
  histogram, not only the maximum.
- **Hold only when another input is waiting:** a lone NIC at 100G has ~50 ns
  slack per frame, so any hold costs it (result 2's single-NIC table) and
  there is nothing to batch against; pass a lone input through as d1t0
  does.
- **A FIFO limit register** (rows per input, 128-1536): bigger FIFOs added
  time in the switch (0x0A05) and read waits (0x0A06, result 5) without
  uplink throughput; sweeping it gives read wait against throughput.
- **The rate limiter:** fine on drive ports; on NIC ports predicted to split
  packets and cause pause frames (result 6). Build it with the
  refused-cycles counter. For alone-vs-together NIC comparisons use link
  speed. As a test knob: step it 95G -> 50G on a 100G link at d1t0 to find
  where splitting starts.
- **More page segments,** only if lazy mode shows misses moving: a segment
  holds one page, a NIC packet fills one, so 8 segments = 8 packets in
  flight; 64-row segments (one 4 KiB page) would double the count in the
  same memory.

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
0b. **CANCELED, closed 10-28 (user):** finish the NIC depth sweep on 0x0A05
   (d24 repro, `dsweep1b`). Superseded: 0x0A06 ran d24-d64 on the NICs
   without a stop, and 0x0A07 is the build now.
1. **CANCELED, closed 10-28 (user):** IOMMU off on `0x0A04`/`0x0A05`.
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
