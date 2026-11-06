# Archive: PIPS design 0x0A07 campaigns (2026-10-28 to 11-02)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The minimal rerun on 0x0A07 (drives 10-28, NICs 10-30) and the paper campaign (four IOMMU legs, 11-01/02). The verdict (10-30) stays in HANDOFF.md, and so does a copy of the IOMMU leg table.

- Artifact: https://claude.ai/artifact/3iQfW7DoaUFDhcwMx2wfqn
- Report pages: "PIPS 0x0A07 Campaign" https://claude.ai/artifact/91VNbNGeJVyfuLLH8acGvY; "PIPS TLP Patterns" v6 https://claude.ai/artifact/Ni2PkBjsera7xFxx6wJdF2
- Data: `dualssd/1028/`, `1101/`, `dualnic/1028/`, `1101/`; tables `c1028.py`, `floor7.py`, `c1101.py`, `agg1101.py`, `floor11.py`

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From HANDOFF.md §8, "0x0A07 minimal rerun", "0x0A07 drive results", "0x0A07 NIC results"**

### 0x0A07 minimal rerun (set up and ran 2026-10-28; results below)

Why rerun: 0x0A07 changes the read flush, which acts with `page_batch_en`
0 too (`axi4_mwr_batch_pp`'s arbiter serves both modes). On 0x0A06 a read
waiting at either input preempted the other input's drain episode; on the
drives (reads waiting on both ports nearly always on a full link) the two
devices left interleaved packet by packet. That is the likeliest cause of
result 10's "0x0A06 pb0 sends more page switches than arrived" (twice the
model at 16k, from the same arrival order as 0x0A05), ahead of `wrr_en`. So
every 0x0A06 page-order number that involves both drives is suspect; the
miss and throughput results (1, 2, 4) are unlikely to move (strict mode).

`bash scripts/pips/pips-campaign.sh ssd --minimal --tmux` (bigserver) and
`... nic --minimal --tmux` (icx); `--dry-run` shows the commands. The
switch must report 0x0a07 (the campaign takes the design it finds at the
start and refuses a change). Phases:
- drives `mini`: depths 1, 4, 16, 64 (d1t0, d4t50, d16t218, d64t255) x
  `page_batch_en` 0/1, cap on, w31; 4k/16k/64k/1m x 1/4/16 per drive +
  2+16: 129 runs, ~2h15, then ~35 min analysis.
- NICs (user, 10-28: the Ethernet cap and/or the FPGA rate cap instead of
  iperf3 pacing, a few representative points, not the full sweep); 59 runs,
  ~2h35, then ~20 min analysis:
  - `rcap`, links at 100G: the FPGA rate cap on both inputs (`--set
    rcap=N`), NIC0 alone and both, 5 flows uncapped. At d1t0 (no hold) rcap
    0 / 214 / 169 / 113 (~off / 95 / 75 / 50 Gb/s of NIC writes: a 512-byte
    write is 9 beats, so rcap ≈ 2.25 x Gb/s); at d16t218c1 pb 0/1 rcap 113.
    Tests result 6's prediction that a rate limiter on a NIC port causes
    splitting (it holds the NIC's writes, so its receive buffer backs up);
    `pips_stat_cap_hold_frac_*` shows where the cap binds.
  - `uneven`: NIC0's link forced to 50G at both ends, NIC1 at 100G: both
    NICs, 5 and 5:30 flows, d1t0c1 and d16t218c1, pb 0/1. The uneven load
    the arbiter never had on 0x0A06 (result 4).
  - `wire50`: both links at 50G (the matched alone-vs-together condition of
    result 6, 100 Gb/s together under the uplink's ~107): NIC0 alone and
    both, 5 and 30 flows, d1t0c1, d4t50c1, d16t218c1, d64t255c1 x pb 0/1
    (d64 last). The NIC counterpart of the drives' `mini`.
  - The links are put back as found after the phases (also on exit);
    `--no-wire` leaves out `uneven` and `wire50`.
- Rate caps are written by every sweep setting (0 unless `--set rcap`; the
  original goes back at the end). No knob phases (no effect on 0x0A06,
  result 4), no pending 0x0A04/0x0A05 analysis (`--pending`).
- New in every run: `pips-bp.tsv` (the counters every 2 s; a sample is
  skipped when `pips log-wait` holds the BAR0 lock, gaps stay well under the
  17 s wrap) and in the `.rpt`/JSONL `pips_stat_bp_frac_0/1` (refused share of
  the run's cycles, setup included), `pips_stat_cap_hold_frac_*`,
  `pips_stat_bp_valid`, `pips_stat_bp_max_gap_s`. `pips-status-table.py` and
  the summaries' status tables print REFUSED_% per input.
- Analysis runs the batcher model on the new logs (`PIPS_PB_MODEL`, default
  `self,sweepc1,sweepc1f512`): on pb0 logs `self` is the log's setting without
  `w31` (`pips-page-seq.py` now strips the page batcher fields; on 0x0A06 logs
  `--model self` used to fail to parse), so `seq.jsonl` has the own-setting
  check that result 10 (a) asked for. pb1 logs get the sweep lines only
  (meaningless there: arrival not measurable).

Before it: program 0x0A07 on both boards, `sudo bash
scripts/pips/pips-bringup.sh` (hwtest now checks reg4 and the counters), and
`make -C scripts/pips check` on one host (the 0x0A07 tests in `test-sim.sh`
are new and have not run). Check after: `status.txt` (stuck, spills, MRd
wait: the new flush lets a read wait for the other input's episode too, and
0x0A06 already reached 262 us on the drives), then compare pb0 page switches
per packet with the arrival order and the model (result 10's numbers: d64
16k/64k/1m 0x0A06 pb0 10.3/14.1/10.1, arrival 7.0/13.1/9.2, 0x0A05 model
5.1/11.0/6.5); on the NICs, TLPs per run of NIC0 (whole packets ≈ 7-8)
against the rcap level, REFUSED_% and the cap's share, and pause frames.

### 0x0A07 drive results (2026-10-28, strict, cap on)

`bigserver` `c10281318`, 129 runs in 2h24 (repo `58e001439`), switch
answered to the end, stuck 0. Data `dualssd/1028/pips-campaign-ssd-c10281318/`
(`results/`, `status.txt`, `analyze-new/seq-*/seq.jsonl` with the model);
tables `py -3 dualssd/report-gen/c1028.py` (saved `dualssd/1028/c1028-ssd.txt`),
against 0x0A05 (`1026/.../analyze-pending`, dsweep1) and 0x0A06 (`1026/...
main`) at the common points: depths 1/4/16/64, 4k/16k/64k/1m, 1/4/16 per drive
and 2+16, both drives. Page switches per 4 KiB page, marks scale.

1. **Result 10 is solved: the read flush was the cause.** pb0 sends below its
   measured arrival order again, as 0x0A05 does: sent / arrival median 0.85
   [0.69, 1.31] over the 16 depth x size cells (0x0A05 0.81 [0.63, 1.18],
   0x0A06 1.19 [0.78, 2.27]). d64 16k / 64k / 1m: 0x0A07 5.2 / 10.9 / 7.1,
   0x0A05 4.5 / 10.9 / 6.7, 0x0A06 9.9 / 14.1 / 10.1. The arrival order is the
   same on all three (16k 6.2-7.6). `wrr_en` (still tied 1) is not needed to
   explain it.
2. **The model fits 0x0A07 pb0 as it fits 0x0A05** (own setting vs log,
   median per cell): within 2% at d16-64 at every size; at d1-4 it
   overcounts as on 0x0A05 (16k d1 +58% vs 0x0A05 +52%; 64k/1m d1-4 +8 to
   +19%, 0x0A05 +2 to +11%). Result 10 (a) for the drives is answered by
   0x0A07; the 0x0A06 logs need no model rerun.
3. **Page batching (pb1) now groups pages much better**: d64 16k / 64k / 1m
   2.6 / 3.4 / 3.5 (0x0A06 8.3 / 9.1 / 5.9, -68 / -62 / -41%); d16 2.7 / 4.1
   / 3.7. 16k d64 is at the old by-page line (2.7, result 9) and under pb0's
   5.2 by half. 4k hardly changes (3.3 vs pb0 3.7). At d1 pb1 ≈ pb0.
4. **Throughput and IOTLB misses don't move** (128 points, 0x0A07 / 0x0A06):
   Gb/s median 1.008 [0.964, 1.148], misses per 4 KiB 0.982 [0.875, 1.206]
   (16k and 64k -2 to -7%, 1m 0). Strict mode: every page visit misses
   anyway (result 1), so the better grouping doesn't show in the counters.
5. **Status:** stuck 0 everywhere. pb1 spills as on 0x0A06 (64k/1m saturate
   the 16-bit count at 65535; result 3). MRd wait > 25 us at 25 of 128
   points (0x0A06 60 of the same 134 setting-point rows), max 136 us (d4t50c1
   64k 4 per drive, pb0; 0x0A06 262 us), median 21 us (0x0A06 24): the new
   flush did not lengthen read waits. Refused cycles (new counters): 0.2-3%
   at 4k, 30% at 16k with 1 job per drive, 50-70% per input from 16k with
   more load and at 64k/1m, i.e. the Gen3 x8 uplink is full (53 Gb/s at
   1m); cap share 0 (no rate cap set).

So for the drives 0x0A07 replaces 0x0A06: the 0x0A06 page's drive page-order
figures (6-9) and the summary page's 0x0A06 lines are superseded by these.

6. **Legal floor (10-30, `report-gen/floor7.py` → `floor7.json`).** The
   floor (seqrec.floor_runs: hold a device's next D TLPs, free to reorder)
   ignores the switch's completion rule: a completion leaves as soon as its
   older data has and seals every older open batch (`axi4_page_batch_ch.v`
   header, "urgent"; `ctrl_push` only decides whether it also pulls the
   batches ahead of it). The legal floor cuts each device's order at its
   completions and groups only the data between them. From the 0x0A07 pb0
   listings, d64: 4k 2.74 (floor 1.11), 16k 1.86 (1.22), 64k 1.49 (1.32), 1m
   1.25 (1.22). pb1 d64 against it: 4k 3.29 (x1.20), 16k 2.61 (x1.40), 64k
   3.43 (x2.30), 1m 3.46 (x2.77). Every pb1 64k/1m run saturates the spill
   count (65535 per input), 4k/16k spill hundreds to thousands: the 64k/1m
   gap is page-segment capacity (8 per device; a spilled drive goes to
   arrival order until its overflow is granted).

### 0x0A07 NIC results (2026-10-30, strict)

`icx` `c10281317`, 59 runs, 4h01 (sweeps 3h50, an hour over the estimate),
switch answered, stuck 0, links put back to 100G (NIC1's read "Unknown" once,
then 100G). Data `dualnic/1028/pips-campaign-nic-c10281317/`; tables `py -3
dualssd/report-gen/c1028.py nic` (saved `dualnic/1028/c1028-nic.txt`, with
0x0A06 reference rows). Page switches per packet, marks scale.

1. **The FPGA rate cap splits NIC0's packets, as 0x0A06 result 6
   predicted.** NIC0 alone, 100G link, d1t0: uncapped 95.1 Gb/s, 6.42 TLPs
   per run (84% of packets in one run), no pauses; rcap 214 / 169 / 113
   (~95 / 75 / 50G): 88.2 / 69.3 / 46.9 Gb/s (93% of the intended level, so
   rcap ≈ 2.25 x Gb/s holds), 1.10 / 1.07 / 1.14 TLPs per run, cap held
   12.7 / 27.3 / 46.3% of cycles, ~91-97k pause frames, 1.3-1.4M discards,
   retransmits 0.46-0.80%. d16t218c1 rcap 113: the same (pb1 2.51 TLPs per
   run, still split). Both NICs: rcap 214/169 whole (7.2, 7.1; cap 0.4/4.3%,
   each NIC's 53.5 is below the cap), rcap 113 split (1.11, 164k pauses,
   2.4M discards). The rate cap cannot stand in for a slower NIC; the wire
   speed can.
2. **Uneven links (NIC0 50G, NIC1 100G):** the arbiter gives NIC1 what NIC0
   leaves (48.8 / 55.9-58.3 Gb/s), not an even split. d1t0c1 (write-by-write
   alternation) holds the 100G NIC: NIC1 split (1.04 pb0, 1.01 pb1), 50-64k
   pauses, 0.6-1.1M discards, 8.5-8.8 page switches per packet. d16t218c1
   pb0: NIC1 partly split (4.95), no pauses, 2.90; pb1 both whole (7.16 /
   7.11), 2.46. 5:30 flows: uplink not full (95 Gb/s), nothing splits.
3. **Both links at 50G (`wire50`): no splitting anywhere** (7.1-7.7 TLPs per
   run, 88-97% one-run, zero pauses and discards, alone and both, every
   depth, pb0 and pb1). Page switches per packet, both NICs, 5 flows, d1 / 4
   / 16 / 64: pb0 7.91 / 3.53 / 2.66 / 2.37, pb1 6.83 / 2.94 / 2.29 / 2.29;
   one NIC alone 2.23-2.27; arrival 5.6; floor 2.30 / 2.27 / 1.69 / 1.32;
   **legal floor 2.28 from d4**. 30 flows: pb0 4.98 / 3.14 / 2.68 / 2.51, pb1
   4.50 / 2.76 / 2.47 / 2.46, alone 2.37-2.40, legal 2.07. 0x0A06 at the same
   50 Gb/s by iperf3 pacing on 100G links: pb0 3.57-4.87, pb1 3.02-3.08 at
   d16-64 (split packets). **From d16 two NICs send what one alone does, and
   pb1 sits on the legal floor.** Each packet is 8 writes to its own page
   then a 16 DW completion to a completion-queue page (listing), so 2 per
   packet is the minimum while completions leave at once.
4. **Model** (own setting vs recorded, pb0): wire50 within 0.5-0.8% at
   d16-64, 2% at d4, 6-9% at d1; rate-cap runs within 1%; uneven d16 <1%, d1
   +6-8%.
5. **Status:** stuck 0; MRd wait max 14 us; refused 0.2-10.5% at 50G, the
   cap's share dominating on capped runs; pb1 spills ≤ 2k per run at 50G
   (0x0A06 by pacing: saturated), 65535 at uneven d1t0c1p1. Counter sampler
   valid in all runs (max gap 3.4 s). Sizes: completions 16 DW, RELIABLE.


> **From HANDOFF.md §8, "0x0A07 paper campaign" and "0x0A07 paper campaign results"**

### 0x0A07 paper campaign (set up 2026-10-31, ran 11-01; results below)

The user's experiment list for the paper (10-31), on 0x0A07. **No reboot and
no GRUB change inside a campaign** (user rule: reboots and kernel
command-line changes are the user's). In scope: E1, E2, E5-E14 minus the
ones below; out of scope (user, 10-31): E2b (F&S kernel), E3 (commodity
switch), E4 (data integrity), E15 (more page segments).

**One IOMMU leg per launch** (user, 10-31, second version: no runtime IOMMU
change at all). `--paper` reads the mode the host booted with from the
devices behind the switch (`pips-iommu.sh mode`: strict = `DMA`, lazy =
`DMA-FQ`, pt = `identity`, off = no IOMMU group) and runs that leg; the
sweeps name themselves by it (`dual<kind>-pips-<mode>-<stamp>...`). The user
reboots between legs. `--leg M` refuses to start unless the devices are M
(catches a missed reboot); with `--dry-run` it plans leg M on any machine.
`--runs N` sets the runs per point of head, g100 and e8 (default 3).

**Trap (icx, 11-01):** a command line with `intel_iommu_on` (underscore, a
typo) is ignored: the kernel boots with the IOMMU off and `--leg lazy` is
refused ("the devices ... are off"). It must be `intel_iommu=on`. icx was
booted `6.12.43-vanilla` (since at least 10-26; the 6.8 in §1-6 is older): every leg must
run on the same kernel (compare `cmdline.txt` in the tarballs), and a
vanilla kernel has no `linux-tools-$(uname -r)` package (`perf` from its
source tree, `make -C tools/perf`, or the ops sweeps are skipped).

| Leg | Kernel command line (iommu tokens in `GRUB_CMDLINE_LINUX_DEFAULT`) | Group type |
|---|---|---|
| strict (the hosts' boot now) | `intel_iommu=on iommu.strict=1` | `DMA` |
| lazy | `intel_iommu=on iommu.strict=0` | `DMA-FQ` |
| pt | `intel_iommu=on iommu=pt` (no `iommu.strict`) | `identity` |
| off (optional) | `intel_iommu=off` | no group |

```bash
bash scripts/pips/pips-campaign.sh ssd --paper --leg strict --dry-run   # plan, ETA, commands
bash scripts/pips/pips-campaign.sh ssd --paper --leg strict --tmux      # bigserver
bash scripts/pips/pips-campaign.sh nic --paper --leg strict --tmux      # icx
# reboot with the lazy line, then --leg lazy; reboot with the pt line, then --leg pt;
# reboot back to the strict line at the end
```

| Phase | Experiment | What runs (per leg) | Runs |
|---|---|---|---|
| `pcie` | E6 | `pips-pcie-caps.sh`: lspci of root port, switch ports, devices: MPS, MRRS, RO, NoSnoop, tags, IDO, completion timeout ranges and value, ACS, IOMMU group/mode → `pcie/caps.txt`; `cmdline.txt` | 0 |
| `head` (drives) | E1, E2, E5, E10, E13 | d1t0c1 pb0 (batching off) vs d16t218c1 and d64t255c1 pb 0/1; 4k/16k/64k/1m x 4/16 per drive. Results carry Gb/s, CPU, misses by walk level (L1/L2/L3), fio p99, pkt_wait p50/p99 | 122 |
| `g100` (NICs) | E1, E2, E5, E9, E10 | the same settings, both NICs, 5 and 30 flows, uncapped, 100G links. E9's d16/d64 page switches come from its logs | 32 |
| `e8` (NICs) | E8 | NIC0 alone, 5/10/15/30 flows, d1t0c1 (strict leg vs pt leg = E8) | 13 |
| `rcap0` (NICs, strict leg only) | E11 | both NICs, 5 flows, d1t0, rate cap on input 0 (NIC0) only: `rcap0` 113/90/68 (~47/37/28 Gb/s: 113 held NIC0 at 46.9 on 10-28) | 6 |
| `ops` | E7 | the runner's `--iommu-ops 1`: `perf stat` of `iommu:map`, `iommu:unmap`, `intel_iommu:qi_submit` beside the pcm-iio window, with the drives' reads or the NICs' rx packets of the same seconds → `iommu_ops_*_per_io`, `_unmap_per_4k`, `_qi_per_unmap`. Software counts (no VT-d invalidation PMU on either CPU); pt and off should read ~0 | 4 / 3 |

ETA per leg (estimates: 1.05 min per drive run, 2.6 per NIC run, analysis at
-j 16): drives every leg ~2h12 sweeps, ~2h50 packed; NICs strict ~2h21
sweeps, ~2h40 packed; NICs lazy/pt/off ~2h05, ~2h25. `--dry-run` prints the
clock times.

E12 (write sizes) comes from the analysis (`analyze-new`, lengths) of the
same sweeps; E14 (bubble remover) is model code, not a run, not written.

Before each leg: `git pull`; `perf` must run (`sudo apt install
linux-tools-$(uname -r)`, per kernel; else the ops sweeps are skipped with a
note); the switch must report design 0x0a07 (refused otherwise). After a
reboot also §3 "Check after a reboot" (icx) and, on bigserver, `bash
scripts/ssd-irq-placement.sh` (the interrupt layout is per boot: the strict
leg refuses an unsafe one; other legs note it and go on, since the 10-25
livelock needs strict's synchronous invalidations).

`scripts/pips/pips-iommu.sh` (`show|mode|check|set`) can still change a
group's type at runtime by hand; the campaign only reads (`mode`, `show`).
Kernel rule if ever used: before 6.4 (bigserver's 5.15) a group changes only
if it holds one device, bridges included.

Check after each leg: `README.txt` (the leg and command line), `notes.txt`,
`iommu-at-start.txt` / `iommu-at-end.txt` (same mode), the mode in every
sweep's name; ops runs' `iommu-ops.rpt` (`iommu_ops_map/_unmap/_qi`, -1 =
tracepoint missing). Analysis to write when the tarballs are back (local,
like `c1028.py`): E1/E10 mean and spread per point, E2 misses per I/O
strict/lazy/pt x pb0/pb1, E5 pkt_wait percentiles, E7 per-I/O counts per
mode, E8 NIC0 alone strict vs pt, E9 page switches at 100G against the
floors, E11 NIC0/NIC1 Gb/s per rcap0, E13 walk-level misses pb0 vs pb1.

### 0x0A07 paper campaign results (2026-11-02)

Tarballs in `dualssd/1101/1101/`, `dualnic/1101/1101/` (unpacked beside
them; FILE-MAP §7). Tables `py -3 dualssd/report-gen/c1101.py [ssd|nic]`,
aggregates `agg1101.py`, floors `floor11.py`. Page: "PIPS 0x0A07 Campaign" v2
https://claude.ai/artifact/91VNbNGeJVyfuLLH8acGvY (results per experiment and
an experiment status table with the unavailable ones marked); the summary
"PIPS TLP Patterns" v6 adds 0x0A07.

What ran: drives lazy `c11011320`, pt `c11011925`, off `c11020003` (head,
122 runs each, 3 per point); NICs strict `c11010108` (g100, e8, rcap0), lazy
`c11011329`, pt `c11011926`, off `c11020003` (g100, e8). **Drives strict
`c11010137` refused at start** (that boot put drive 0's interrupts on fio
cores 37, 42); per the user (11-02) the **10-28 rerun stands in** for it
(same kernel, cores, build, grid; 1 run per point). Checked: at 64k/1m it
agrees with the three new legs within 1% (Gb/s), 2% (page switches), 5%
(wait). **ops (E7) skipped in all 8 legs: `perf` runs on neither kernel**
(bigserver 5.15.0-177-generic, icx 6.12.43-vanilla; icx has been on 6.12
since at least 10-26, the "6.8" in §1-6 is older). Switch fine, stuck 0, no
soft lockups.

Results (page has the tables):
1. **Batching costs the hosts nothing measurable (E1, E5).** d64 + page
   batching vs d1t0c1, median over 8 drive points: Gb/s -0.8..-2.1%, CPU
   +-0.2 points, fio p99 within 1.2%, every mode. Switch wait p99 4-26 us,
   under 3% of the lowest fio mean latency (155 us, 4k).
2. **Page order is the switch's, not the IOMMU's (E2, E9).** From 16k up page
   switches per page agree within +-3% across the 4 modes at every setting;
   d64 + page batching 1.3-1.5x legal floor at 4k/16k, 2.4-2.8x at 64k/1m
   (segments run out, spill counter saturated) in every mode.
3. **Page order doesn't move IOTLB misses (E2, E13).** pb1/pb0 drive misses
   x1.000 strict, x0.995 lazy; NIC misses per Gb/s within ~2%. Misses ~1 per
   4 KiB page in strict and lazy (compulsory). Walk-level misses unchanged.
4. **Strict is the host cost, only at 4k (E2).** Drives 4k j4: strict 16.2,
   lazy 46.2, pt 54.0, off 53.9 Gb/s. Strict: L1/L2 walk misses ~0.7 per 4 KiB
   (lazy 0.002). 16k strict -7%; 64k/1m equal. Lazy cuts misses 22% at 4k
   only.
5. **NICs: IOMMU mode doesn't matter (E1, E8).** Both NICs within 0.3% across
   modes. NIC0 alone (d1t0c1 splits its packets in every mode, ~80 Gb/s):
   strict -1.7% at 30 flows, +1..+7 CPU points. NIC lazy misses = strict's
   (mlx5 page pool keeps pages mapped).
6. **100G (E9):** 5 flows, d64 + page batching 2.31 per packet vs legal floor
   2.28; d1 and d64 without page batching split every packet (8.9-9.0, ~140k
   pause frames, 2.2M discards per run). 30 flows host-limited at ~48.6 Gb/s
   (as on 0x0A06).
7. **E11:** rcap0 113/90/68 -> NIC0 40.6/33.7/26.8 Gb/s (86-96% of intent),
   NIC1 takes the rest (total 105-106), NIC0 splits with pauses.
8. **E12:** drive completions 4 DW, data 64 DW (drive 1 also 36 DW, 18-19%);
   NIC completions 16 DW, data 128 DW 87% / 112 DW 12%; rules hold
   99.04-100% / 99.999-100%, every mode. **E6:** identical PCIe settings in
   every boot (MPS 256 bigserver / 512 icx, RO and NoSnoop on below the root
   port, PIPS ports without ACS but each device in its own group with its
   downstream port).
9. **Confounded cell:** drives 4k j16 are CPU-bound and depend on each boot's
   interrupt placement: pt (drive 0 completing on its own fio cores) 53.9 vs
   off 46.4 Gb/s. Compare modes at 4k on j4. A fair j16 comparison needs a
   rerun with `SSD_CORES` that avoid the interrupt CPUs in every boot.

**Not available (write around it):** E2b, E3, E4, E15 (out of scope), E7
(no perf), E14 (not written), NIC latency for E1 (iperf3 has none). Partly:
E10 (drive strict 1 run; E11 1 run per cap).

