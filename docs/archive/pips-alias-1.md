# Archive: alias campaign 1 (2026-11-05/06)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The first aliasing campaign (in-house generators alias-nvme and alias-rdma, fixed pages mapped once): its setup, results and the 11-06 follow-up, plus the 11-05 bring-up log from HANDOFF's "Next": the bigserver freeze at drive b4's reset, debugged step by step, and the NIC smoke tests. Alias campaign 2 (set up 11-06) stays in HANDOFF.md.

- Artifact: https://claude.ai/artifact/VJj7kKdHEfRyksGJ5zLeZM
- Report page: "PIPS Alias Campaign" https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q
- Tools: `scripts/pips/alias/README.md`
- Data: `dualssd/1105/`, `dualnic/1105/`; tables `c1105.py`, `geom1105.py`

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From HANDOFF.md §8, "Alias campaign" and "Alias campaign results"**

### Alias campaign (set up 2026-11-05, ran 11-05/06; results below)

**What and why (user, 11-05).** fio and iperf3 are replaced by in-house
generators (`scripts/pips/alias/`, its README) that control which pages the
devices write into: a fixed set mapped **once**, so the IOTLB misses are
aliasing by design, not map/unmap. The starting point was the user's RDMA
READ code (`rdma_script/`, local and git-ignored since 11-05), which pinned
pages for maximum aliasing (conflict misses). At the user's request (11-05)
the pattern also makes **capacity** misses: pages `first + i*stride`
(i < ws). Stride 1 with ws above the IOTLB's entries gives capacity
misses; a stride that is a multiple of the set count gives conflict
misses. Both are aliasing, and they make the case for the batcher.
- **Drives (user: VFIO, "regular DMA, manual fixed page assignment"):**
  `alias-nvme` is a polled userspace NVMe driver over VFIO. The drives
  are bound to vfio-pci for the runner's runs (`alias-vfio.sh`, put back
  at exit and at the next start). The region is mapped at IOVA
  `0x4000000000`, one PRP entry per 4 KiB page. **Read-only by
  construction** (opcode whitelist, aborts on anything else).
- **NICs (user: RDMA READ, data in the same direction as the campaigns):**
  icx runs `alias-rdma --role client` and posts READs to a server on styx
  (one per NIC, port `BASE_PORTS[i]+700`). icx's NIC writes the responses
  into one MR registered once, one scatter entry per page. Note:
  `rdma_script/common.c` set `max_rd_atomic = 1` (one READ in flight per
  QP) and `path_mtu` 1024. The new tool uses several QPs, the devices'
  rd_atom and the port MTU.
- **Plumbing:** the runners' `--gen alias` (drives: `-J` queues, `--iodepth`
  per queue; NICs: `-S` QPs, `--depth`, `--rdma-bs`; both: `--ws --stride
  --first --order --page-list --backing-pages`). The generators write fio's
  JSON and `_iops.1.log`, so `fio-sum`, the results, the sweeps, the TLP log
  and pcm-iio are unchanged (the NIC runner writes `iperf.bw.rpt` from
  them). The results add `gen`, `alias_*`.
- **Campaign:** `pips-campaign.sh ssd|nic --alias [--runs N] --tmux`, one
  sweep per pattern point. `ageom` (d1t0c1: capacity curve stride 1, ws
  16-65536; conflict curve ws 32, stride 2-8192; one device alone and
  both), `acap` (ws 256/4096/65536 stride 1) and `aconf` (ws 16/32/64,
  stride 4096), the last two both devices, d1t0c1 pb0 vs d16t218c1 pb 0/1.
  Drives bs 4k, 4 queues x qd 32; NICs 4 QPs x 16 READs of 4 KiB. 72 runs:
  ~1h50 drives, ~2h30 NICs. Needs the IOMMU translating (drives any mode
  but off; NICs strict or lazy), checked at start. **One boot, the current
  strict line, serves both** (11-05): for the drives strict/lazy/pt are the
  same experiment (vfio-pci attaches VFIO's own paging domain, replacing
  the default domain, identity in pt included; nothing is unmapped during a
  run). For the NICs the MR is mapped once, so strict and lazy should agree
  (lazy is an optional check); pt/off don't translate it. No irq-placement check
  for the drives (polled, no interrupts).
- **Measuring misses:** **pcm-iio, as always** (`pcie.rpt`: `IOTLB_lookups`
  0x40/0x01, `IOTLB_misses` 0x40/0x20, walk levels). The user asked (11-05)
  why not just PCM: that's the plan; rdma_script's README suggested the VT-d
  PMU through `perf`, which neither kernel has (E7).
- **Open items:** (1) VT-d PMU / `perf` counters **on hold** (user, 11-05:
  install perf later if the data is needed; skip for now). (2) Untested on
  the hosts: C syntax-checked here with MinGW and stub headers, the shared
  pattern/output code run natively and its output read by the real
  `fio-sum` (window IOPS right, covered); runners and campaign `bash -n`
  and `--dry-run`. First on the hosts: build on bigserver, icx, styx
  (`alias-run.sh --build`; libibverbs-dev for rdma), then one by-hand run
  each (README "By hand"), then the datapath sweeps. (3) bigserver is
  shared: a bound drive vanishes from the kernel for the run (bind refuses
  if anyone has it open). (4) The IOMMU groups behind PIPS decide whether
  the idle drive must go to vfio-pci too (runner handles it; `alias-vfio.sh
  status`). Checked 11-05 on bigserver: separate groups, b3:00.0 (nvme0,
  SSD 0) in group 236 with its PIPS downstream port b2:00.0, b4:00.0
  (nvme1, SSD 1) in 237 with b2:01.0 (the switch's ports have ACS), so each
  drive binds alone; the ports stay on pcieport. (5) NIC capacity points also count mlx5's MTT fetches (README
  caveats). Analysis: the page-order tools read the TLP logs as before.
  The miss curves come from the results JSONL (`IOTLB_misses` per I/O against
  ws and stride); no report generator yet.

### Alias campaign results (2026-11-06)

Tarballs in `dualssd/1105/`, `dualnic/1105/`, unpacked beside them
(`pips-campaign-ssd-c11052324/`, `pips-campaign-nic-c11051944/`). Tables `py -3
dualssd/report-gen/c1105.py [ssd|nic|json|floor]` (writes `dualssd/1105/c1105-ssd.txt`,
`dualnic/1105/c1105-nic.txt`, `c1105.json`, floors `floor1105.json`); IOTLB model
`geom1105.py` (`geom1105.json`); page `page1105-head.py` + `page1105.py`. Page "PIPS Alias
Campaign" (v1) https://claude.ai/artifact/E5bkPCsqik67LjPQnTDR2q.

What ran: both hosts strict, 72 runs each (52 points + 20 datapath runs; 1 run per
point): bigserver 11-05 23:24 -> 01:11 in hold mode (no freeze, rebooted at the end as
planned); icx 19:44 -> 23:20. Switch answered, stuck 0, no soft lockups; spill counts only
in pb1 runs. The datapath runs are real loads at the sweep's pattern (drives both, NICs
NIC0 alone): kept as geometry data (`dp` in c1105.json), not in batcher comparisons.

Results (page has the figures and tables):
1. **The pattern sets the misses:** 0 to ~1 per 4 KiB page, nothing mapped during a run.
   Lookups per page = TLPs per page (drives 17.6, NICs 9.1); a page misses at most once
   per visit (1.01-1.08 at the top). Skylake's `IOTLB_hits` excludes misses, Ice Lake's
   `IOTLB_lookups` includes them.
2. **icx (Ice Lake-SP): 256 entries, set-associative, LRU, fewer than 16 ways**, set index
   = low IOVA page bits. NIC0 alone ws 256 -> 0.09, 1024 -> 1.01; ws 32 misses from stride
   32 on; ws 16 at stride 4096 (one set) misses (0.99). 128x2, 64x4, 32x8 all fit the 34
   points (one cursor, strictly cyclic); 16x16 and fully associative don't.
3. **bigserver (Skylake-SP): ~96 entries, no set conflicts** (64 pages sharing their low
   bits fit at stride up to 8192). Soft knee (both ws 64 -> 0.32, alone 256 -> 0.63)
   explained by alias-nvme's per-queue cursors (`cursor_init(q, nq)`: 4 cursors drift);
   model 1x96 random/LRU with drifting cursors fits 31 points (Σ|err| 0.26-0.37).
4. **Two devices that fit alone thrash together:** icx ws 256 0.09 -> 1.03, ws 32 stride
   8 0.06 -> 1.00 (same sets); bigserver ws 64 0 -> 0.32.
5. **A miss costs nothing here:** Gb/s within -0.24..+0.15% of the no-miss mean (drives
   alone 37.1, both 54.3; NICs alone 81.8, both 103.9), drive latency unchanged; up to
   1.77 M misses/s drives, 3.43 M/s NICs; icx ~6 IOMMU memory accesses per miss when pages
   are >= 8 MiB apart (3.0 up to 2 MiB apart), still no effect. All runs link- or
   device-bound (drives both: refused 60/47%; NIC0 alone: d1t0c1 one-input limit).
6. **The batcher doesn't move aliasing misses:** d1/d16 x pb0/pb1, drives within 0.01
   per page (0.03 at aconf ws 64), NICs within 0.08 (d16 pb1 lowest at the conflict
   points, up to 5%, 1 run: repeat first). Misses depend on reuse distance (hundreds of
   page visits), the switch regroups within 1-2 open pages per device.
7. **Page order/cost as on the paper campaign:** d16 pb1 drives 4.0-4.2 page switches per
   page (legal floor 3.1-3.7), NICs 2.95 (2.7-3.1); drives -1.0% (pb1) / -1.6% (pb0) Gb/s
   at d16, NICs 0.

**Not available:** NIC READ latency (alias-rdma writes `lat_ns`, the NIC runner doesn't
copy it into the results, the pack leaves the JSON on icx); per-device misses (pcm-iio per
IOMMU unit). **Not usable:** the host analysis's IOTLB simulation (`pips-seq-grab.sh` passes
`--strict` for every "-strict-" sweep and `--iotlb 1x64,16x4,64x1`: wrong model for pages
mapped once, wrong geometries).

**Next (proposed on the page, nothing set up yet):** tools T1 (seq-grab: no `--strict` for
alias sweeps, `--iotlb` per host: icx 32x8,64x4,128x2, bigserver 1x96,1x64,1x128; rerun
`pips-analyze.sh` on the 11-05 manifests = the switch's measured ceiling on aliasing
misses), T2 (NIC READ latency into the results), T3 (per-device `--ws1 --stride1
--first1`, also in the holder's `load`), T4 (`alias-nvme --cursor shared`), T5 (many
patterns per sweep, one datapath run), T6 optional 2 MiB backing. Campaign (~148 runs,
icx ~2h40, bigserver ~55 min, one strict boot each): c-small (`--rdma-bs` 2048-256 x ws
64/4096: find a miss cost), c-walk (ws 32, stride 32-262144), c-lat (1 QP depth 1, T2),
g-ways/g-sets/g-fine (icx ways and sets; bigserver with T4), i-share/i-place (sharing
curve; NIC1 shifted by `--first1` into free sets, predicted 0 misses), s-quantum (grant
quantum 4095 on the thrashing pairs, predicted no change), r-rep (3 runs of the batcher
grid at 2 patterns per host). Decision gates on the page.

**Follow-up (11-06, with the user):** bigserver's drive 0 has `sgls : 0` (no NVMe SGL),
so a drive command can't scatter below a page: drives stay at <= 1 miss per 4 KiB and
~1.1 M commands/s per drive. pcm-iio lookups per page are identical at every switch
setting (drives 18.41/17.57, NICs 9.09-9.10, d1 vs d16 pb1): every TLP is looked up
whatever the order, so page switches can cost only through misses, i.e. when a page is
evicted between two of its own TLPs. At d1 a page comes back every ~40-150 ns; evicting it
from bigserver's ~96 LRU entries in that gap needs ~1 G misses/s from anything else
(random replacement: ~100 M/s for a 10% chance), beyond any uplink or walker. So an FPGA
MRd adversary (proposed by the user: 1-DW reads from the switch to keep the IOMMU busy)
can't by itself make 8 vs 4 page switches per I/O visible on bigserver. The case where
switches become misses is icx with the device's own rotation: all pages in one set (stride
4096), more open pages than ways (16-32 QPs per NIC, path MTU 512-1024: needs an
`alias-rdma --mtu` cap; QPs up to 64 already), then pb1 should cut misses. The listing
excerpt (aconf, ~4 pages open in one set, 1.03 misses/page) rules out 2 ways on icx (4 or
8 remain). Order proposed: icx rotation, icx `--rdma-bs 512/256` (walker capacity, no
code), then the MRd adversary only if misses follow switches but throughput stays flat
(as a calibrated walker load on icx, reads at ~28 B of uplink per miss, NIC RID spoofed
with reserved tags and a completion sink; hit-only control runs for the bandwidth it
takes).


> **From HANDOFF.md §8 "Next", the 11-05 statuses of the alias bring-up (drives)**

Status 11-05: the alias campaign (above) is set up, not run: build and one by-hand run per host first, then `pips-campaign.sh ssd|nic --alias --tmux`; perf on hold.

Status 11-05 (later): **bigserver died during the first drive smoke test** (`alias-smoke-ssd0` or `-both`; ssh lost, power cycled). Cause unknown until the logs are in: `bash scripts/pips/alias/alias-postmortem.sh` after the reboot (tarball `~/alias-postmortem-bigserver-*.tar.gz`). Suspects, all new with vfio-pci and never exercised through PIPS before: vfio-pci's reset of the drive when the device is opened and closed (FLR, or a secondary bus reset of the PIPS downstream port b2:00.0 if no FLR: `reset_method` in `now/summary.txt`); vfio-pci's idle D3hot and the bridge's runtime suspend below the FPGA (`power_state`); a fatal PCIe error through the switch escalated by the platform (BMC SEL, `Hardware Error` lines). The page batcher keeps the full 52-bit page number, so the 0x40_0000_0000 IOVA is not it. Do not rerun the drive smoke test before reading the logs. **Postmortem (11-05 19:32):** `alias-smoke-ssd0` (SSD 0 alone, ws 64 stride 1) ran clean to the end (522 kIOPS, 2.14 GB/s, mean 61 us; controllers disabled, restored). `alias-smoke-both` (ws 32 stride 4096, 496 MiB span) loaded both drives (b3 863 + b4 794 kIOPS = 6.8 GB/s, the Gen3 x8 uplink's limit) and the host died between its t=30 s and t=40 s heartbeats, ~19:13:30 = t~31 s = the start of the pcm-iio window (warm 10 + 1 s + CPU window 20 s). Kernel log: last line vfio-pci's config init of both drives (19:12:59, after its FLRs); then nothing (no lockup, AER, DMAR, MCE). BMC SEL: no entry for 11-05 (last 10-25; older Bus Uncorrectable / IERR entries Feb-Oct). No AER counters now; PIPS answers (`pips cfg` d1t0c1). Two things changed from the clean run at once: both drives (uplink saturated) and the conflict pattern (IOTLB miss per write). Next: bridge windows (`now/windows.txt`), how boot -2 ended (18:42:59), then bisect (both drives stride 1; one drive conflict; no pcm-iio) with netconsole to catch the last kernel lines. **Checked:** boot -2 ended in a clean reboot (systemd shutdown), so one hang only. The windows are clear: every bridge from root port b0:00.0 (ACS ReqRedir+ CmpltRedir+ UpstreamFwd+) through PIPS b1:00.0 to b2:00.0/b2:01.0 decodes only e0c00000-e0efffff (32-bit, no prefetchable window), nowhere near the IOVAs; 0x10000000 and 0x4000000000 are RAM in /proc/iomem, which doesn't matter in VFIO's own domain. The journal's very last entry is the sudo session opening `pcm-iio` (19:13:30.x), nothing after: the host died as pcm-iio started, with both drives under VFIO at 6.8 GB/s and a miss per page. In the clean ssd0 run pcm-iio started the same way (one drive, no misses: IOTLB_hits 9.4 M/s, misses 0). Bisect order: (1) the hung load by hand, no pcm-iio, 90 s; survives -> pcm-iio is part of it; (2) runner, both drives stride 1; (3) runner, drive 0 alone, conflict pattern; each with netconsole to icx. **Revised (user, 11-05): bigserver's bring-up must be self-contained** (icx runs its own campaign; no netconsole to it). Tool: `scripts/pips/alias/alias-hangtest.sh` (kernel log, heartbeat, 1 Hz tick fsynced to bigserver's disk; `--pcm-at 31` starts pcm-iio as the runner does; `--panic` arms lockup/stall/NMI panics so pstore keeps the backtraces; `--show` after a reboot). Steps: T1 `--panic` (the hung load, no pcm-iio); T2 `--pcm-at 31 --panic` (the hung case, should reproduce); T3 `--stride 1 --ws 64 --pcm-at 31 --panic` (both drives, no misses); T4 `--drives 0 --pcm-at 31 --panic` (one drive, misses). Stop at the first hang; after each power cycle `alias-hangtest.sh --show`. **T1 (11-05 19:49, kernel 5.15.0-177, pstore backend erst, nmi_watchdog 1):** the hung load ran its full 100 s clean (b3 862.6 kIOPS mean 148 us, b4 795.2 kIOPS mean 161 us, 6.8 GB/s steady), printed "controllers disabled" (19:51:17), and the host then appears to hang before the script's next 10 s check ("alias-nvme ended" never printed): i.e. at alias-nvme's exit (VFIO unmap/close: vfio-pci's release does an FLR and leaves the drive in D3hot) or the restore to nvme. So the load itself is fine; both hangs came at a PCIe config-space event with both drives under VFIO (pcm-iio's start scans every device's config space; vfio-pci release resets). The single-drive run did both (pcm-iio, release) without a hang. Waiting for `--show` after the power cycle (tick.txt pins the second, kmsg.txt the kernel's last lines). **`--show` (19:59):** last tick 19:51:16.846, "controllers disabled" 19:51:17.074, then nothing: the whole host froze within ~0.8 s of alias-nvme's exit (the 1 Hz tick on another CPU stopped too), no kernel line, no pstore record although lockup panics were armed with ERST. A platform-level freeze at vfio-pci's release of the two drives (per drive: FLR, config restore, D3hot; a bus reset through the PIPS port if the FLR fails; IOMMU domain detach). Next: T1 again with `--ftrace` (the release path's kernel functions, fsynced per line: the last one names the step), then the same with `--no-d3`. **T1 + `--ftrace` (20:06):** froze the same way ("controllers disabled" 20:08:14.955, then nothing), so the exit freeze reproduces (2 of 2 with both drives; 0 of 1 with one drive). The trace_pipe reader stalled after 27 lines (still in the open path, 20:06:34), so the release wasn't captured. It did show the open path working per drive: D3hot -> D0, FLR (`pcie_flr`), `pci_dev_wait` ~108 ms later, domain attach. After bind both drives sit in D3hot (vfio-pci idle), their bridges D0, reset_method `flr bus`. Changed: the trace is now polled from the buffer (appended and fsynced every 0.5 s), and `alias-nvme --exit-steps S` (`alias-hangtest.sh --exit-steps 3`) releases one step at a time with a synced line around each: bus master off, BAR unmap, device fd close (vfio-pci release: FLR, restore, D3hot), group detach (domain detach, unmap, unpin), container close. **`--exit-steps 3` (20:19):** froze again, but drive 0 (b3) was released cleanly first (bus master off, BAR unmap, close = FLR + restore + D3hot: `power_state D3hot` after). Drive 1 (b4): "bus master off done" 20:21:49.935, then nothing; the next step (3 s later) was BAR unmap + close of b4's device fd, whose announcement may not have reached disk (printed right before close(); the reader takes ms per line). So the freeze is in b4's release (most likely its FLR / ready wait / restore / D3hot), not in releasing two drives as such. Note b2:01.0 (b4's PIPS port) has an empty `reset_method`, b2:00.0 `bus`; the only clean single-drive run was drive 0. Changed: every announced step now waits 1 s before acting; `--exit-reverse` releases b4 first. Next: `--show` of 20:19 (tick.txt: alive at ~20:21:52.9?; ftrace.txt polled), then `--exit-steps 3 --exit-reverse --ftrace --panic` (b4 first: freezes -> b4-specific; b3 then freezes -> the second release). **`--show` of 20:19:** last tick 20:21:52.445, b4's close at ~20:21:52.94, no tick after: **the freeze is b4's release**, within 0.5 s (the trace poller caught nothing of it). The polled trace has b3's whole release: close -> D0 -> load saved state -> `pcie_flr` -> `pci_dev_wait` 105 ms later -> `pci_restore_state` -> `pci_disable_device` -> D3hot. **b4's FLR is never followed by `pci_dev_wait`, at open too (both traced runs): in 5.15 `pcie_flr` returns at once when the device has `imm_ready` (PCI Status bit 0, Immediate Readiness), so the kernel restores b4's config space right after the FLR, with no 100 ms wait.** b3 has no `imm_ready`. Lead: b4 (990 EVO Plus) claims Immediate Readiness, and the release path's FLR (device still enabled, after 100 s of load) followed at once by config writes through PIPS freezes the platform; the open path's FLR (`pci_try_reset_function`: command register cleared first, drive just out of D3hot) works. The clean single-drive run used b3. Turning b4's FLR off would make vfio-pci fall back to a bus reset through the PIPS port (worse). Test next: `--exit-steps 3 --exit-reset` (VFIO_DEVICE_RESET = the open path's FLR, before the close); the hang test now logs each drive's Immediate Readiness bit (`setpci STATUS`). **20:52: PIPS did not come back.** In the boot after the 20:21 freeze (up 20:29:09) the PIPS subtree did not enumerate: no b2:00.0, b3:00.0, b4:00.0 in `lspci`, only the four other drives (f1-f4) on nvme. The two earlier power cycles had brought PIPS back. So the freeze at b4's release leaves the FPGA switch wedged at least sometimes (it may be part of the freeze, not just the drive). Recovery: check the root port b0:00.0 link (`lspci -s b0:00.0 -vv`, `pips-id.sh`), reprogram 0x0A07 (user), reboot (user). Every further freeze test risks the switch needing a reprogram. **Recovered (user, 11-05 evening):** first read as a lost bitstream; corrected by the user later: the board never lost power and the FPGA stayed programmed (a fresh Vivado instance shows no bitstream property). The PCIe tree failed to come up at the host reboot; reprogramming plus another reboot brought it back. Reading of `pips.tcl` (FPGA `28ff5b6`): host PERST# (`sys_reset`, inverted) resets all three PCIe IPs, and the switch logic (batcher, regfile, PIO, routing) sits on `aresetn_upstream` from the IP's user_reset, so a host reboot should clear a jam in the pipeline. The drives' PERST# (`perst_0`/`perst_1`, pins BD23/AU21) are tied to a constant, and the drives run on board power: nothing but a reconfiguration (I/Os go to their configuration state) or a board power cycle gives them a fundamental reset. The user then added: no Xilinx function at all (`lspci | grep -i xilinx` empty), so the switch's own upstream port b1:00.0 was gone, not just the drive path; a stuck b4 cannot explain that (the upstream port is its own `pcie_versal` IP in `Switch_Port_Upstream` mode with its own GT quads, refclk and reset). Candidates: (1) the uplink did not train after the cold host power cycle (slot refclk and PERST# went away while the board stayed powered; GT relock vs the BIOS's training window; intermittent, the two earlier power cycles came back); (2) the BIOS hid root port b0:00.0 after an error; (3) upstream-side state that PERST# does not reset. Next time, try a warm `sudo reboot` before reprogramming (comes back = (1)); in Vivado's hardware manager `axis_ila_0` probe0 is the upstream port's user_reset (stuck asserted = the upstream IP never came out of reset). Before either: `lspci -s b0:00.0 -vv` (LnkSta, DLActive), `lspci -s b1:00.0`, and over JTAG `pips_cfg` plus the downstream ports' link state, to tell an untrained uplink from a dead downstream port. Next run: `alias-hangtest.sh --exit-steps 3 --exit-reset --ftrace --panic`. **21:30, `--exit-reset`: clean.** Immediate Readiness confirmed: b3 status 0x0010 (0), b4 0x0011 (1). Same load (845 + 812 kIOPS), then per drive bus master off, VFIO_DEVICE_RESET, close (D3hot after), groups detached, containers closed; both back on nvme. So the release freeze is vfio-pci's release FLR on b4 (Immediate Readiness: no 100 ms wait before the config restore), and the open path's reset first avoids it (n=1 clean vs 3/3 frozen). **Fix (default now):** alias-nvme always releases step by step with VFIO_DEVICE_RESET before each close (`--exit-steps S`, default 1 s, ~17 s per run), also on die() (atexit); `--exit-unsafe` = old. `run-dualssd-experiment.sh` `stop_fio` waits 120 s for alias-nvme after SIGINT (was 30) and warns before a KILL. README caveat "Releasing the drives". **Still open: the runner's freeze at pcm-iio's start** (19:13, during the load, both drives). Next: `alias-hangtest.sh --pcm-at 31 --ftrace --panic` (T2, with the safe exit), then the runner smoke test `alias-smoke-both2`. **21:38, T2: froze at b4's `VFIO_DEVICE_RESET`** (announced 21:40:50.927, reset at ~51.93, last tick 51.303): b3's whole release clean again; so b4's reset after the load can freeze the host by either path (release-path FLR 3/3, open-style reset 1 of 2). pcm-iio did not really run: it exited at once without `opCode-6-85.txt` (the hang test ran it from its own folder; the runner runs it from `utils/`), so the pcm-iio question is still open; while it ran it runtime-resumed/suspended some PCI device every ~0.5 s (device not named in the trace). Pattern: b4's ~6 resets at open (after the nvme driver's normal shutdown, idle) never froze; the exit resets came 0-12 s after alias-nvme's abrupt CC.EN=0 and froze 4 of 5 (the pass: 20 s after). **Changed:** alias-nvme's teardown now does a normal NVMe shutdown (CC.SHN=01, waits CSTS.SHST=10, limit RTD3E clamped 5-30 s), then CC.EN=0; the release waits `--exit-settle` 10 s before its steps (~30 s per exit; campaign estimate 1.6 min/run). Hang test: pcm-iio from `utils/`, trace adds the `rpm:rpm_resume`/`rpm_suspend` events (device names). Next: the same T2 (`--pcm-at 31 --ftrace --panic`); check PIPS enumerated first after each freeze. **21:56, T2 again: pcm-iio fine, b4's reset froze again.** pcm-iio ran its 20 s mid-load from `utils/` (1649 csv lines; 845 + 812 kIOPS throughout): the runner's 19:13 freeze at pcm-iio start did not reproduce (open, not blocking). Both drives shut down normally (5 / 6 ms), 10 s settle, b3 released fully, then the host froze at b4's `VFIO_DEVICE_RESET` (ssh dropped). Tally for b4's reset after an alias-nvme run: 5 freezes of 6 (release path 3/3, open-style 2/3), with or without a clean shutdown and settle; b4's ~7 resets at open: 0 freezes. Remaining difference: at open b4 comes out of D3hot (vfio-pci idle) right before its FLR; at exit it has been in D0 throughout. **Added `--exit-d3`** (alias-nvme and the hang test): D3hot then D0 through PMCSR before each drive's reset. If that also freezes: swap the two drives' slots (does the freeze follow the 990 EVO Plus or port b2:01.0?), or put a drive without Immediate Readiness behind b2:01.0. **Decision (user, 11-05 late): hold the drives instead of releasing them** ("if it's only the final release, I can accept removing the tree and rebooting at the end"). Built: `alias-nvme --hold DIR` (open and init once; loads on command through `DIR/cmd`; between loads queues kept, region remapped for a new pattern; heartbeat `DIR/alive`; SIGINT/TERM stop a load, SIGHUP ignored; a fatal error never exits: drives held, heartbeat stops) and `alias-stability.sh` (~20 min: 14 loads, PIPS cfg toggled in the pauses, pcm-iio in 7; BMC IPMI watchdog, hard reset after 120 s without a pet, petted by a root loop only while the holder's heartbeat is < 45 s old; panic-on-lockup + `kernel.panic=10`; ends `sync; systemctl reboot -ff`, user-approved for this test). Not used: the user's `echo 1 > .../0000:97:00.0/remove` (97:00.0 is icx's PIPS; bigserver's is b1:00.0): removing a device vfio-pci holds waits for the holder to release it, i.e. the reset that freezes. Why the whole host freezes (explained to the user): a CPU stuck in hardware on a PCIe access that never completes takes no interrupts, not even NMIs; the other CPUs then wait on it. Only C syntax (MinGW + stubs), `bash -n` and `--dry-run` checked here. **Stability test ran (11-05 late): 14 of 14 loads ok** in hold mode (base, conflict ws 16/32/64 at stride 4096, capacity ws 4096/65536, stride 512, shuffle, random, drive 0 only, drive 1 only; PIPS cfg toggled d1t0 pb0 / d16t218 pb1 in the pauses; pcm-iio 1649 rows in each of its 7 loads); no freeze; ended in the reboot. Next: put hold mode into the drive runner and the alias campaign (one holder per campaign, the runner sends `load` commands instead of binding and starting alias-nvme per run; campaign ends with the reboot). The stability test also ended cleanly: watchdog off, reboot -ff, the host back 22:54, PIPS there, both drives on nvme.

> **From HANDOFF.md §8 "Next", the 11-05 NIC smoke statuses**

Status 11-05 (NIC smoke): both hosts build alias-rdma (icx mlx5_2/mlx5_4, styx mlx5_1; RoCE GID 3, MTU 2048, rd_atom 16). `alias-smoke-nic0` failed at start: the server on styx listened on TCP 3700 but no connection arrived, and the client was stuck in its first `connect()` to 192.168.10.52:3700 (no "waiting" line), i.e. SYNs dropped, not refused. Suspect a firewall on styx: iperf3 only ever opened TCP styx -> icx (servers on icx), never icx -> styx. alias-rdma's connect now times out per attempt (2 s) and names the cause (no answer = firewall, refused = no server). Checks for the user: the TCP probe and styx's firewall rules (ufw / iptables / nft); if styx filters, open 3700 and 4700 from 192.168.10.0/24 and 192.168.100.0/24, or flip the hello so styx connects to icx.

Status 11-05 (NIC smoke passed): the TCP probe was open (the first failure was likely the stale styx copy, or a leftover server; not a firewall). `alias-smoke-nic0` (ws 64 stride 1, 4 QPs x 16 READs of 4 KiB): 95.9 Gb/s, 2.93 M pages/s, **0 IOTLB misses** (64 pages fit). `alias-smoke-nics` (both, ws 4096 stride 1 each = 8192 pages): 51.9 + 51.9 Gb/s (uplink-bound, 106 Gb/s PCIe write; equal split = round robin d1t0), 3.17 M pages/s, **3.28 M misses/s = ~1 per page** (capacity), PWC_4K hits ~= misses, ~3 IOMMU memory accesses per miss, ~9 lookups per 4 KiB page. The generator and the counters behave as designed. Next: `pips-campaign.sh nic --alias --tmux` on icx (72 runs, ~2h30). The drive side waits on bigserver's postmortem.
