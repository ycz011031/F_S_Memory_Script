# Archive: CLAUDE.md state notes (2026-10-20 to 11-06)

Moved out of the live docs on 2026-11-06 to keep HANDOFF.md short. Everything
below the line is verbatim (headings and wording as they were); only this
header and the "From ..." markers are new.

The "State as of" sections of the local, git-ignored CLAUDE.md (orientation for Claude sessions on the Windows checkout). The gotchas that still apply were copied back into CLAUDE.md.

- Artifact: https://claude.ai/artifact/6sWcrEA4pqrrJTZQeoGAjD

References inside the text (§N, "item N", "result N", "above", "below") point
to HANDOFF.md as of 2026-11-06 (commit 634b53777, plus the QRH.md links). A moved section keeps its heading; HANDOFF.md's "Archive" table
names the file that holds it.

---

> **From CLAUDE.md, from "State as of 2026-11-06" to the end**

## State as of 2026-11-06
- **Alias campaign 2 set up, committed + pushed 11-06, not run** (HANDOFF §8 "Alias campaign
  2"): `pips-campaign.sh nic|ssd --alias2 --tmux`. Code: alias-rdma `--sge-bytes`
  `--mtu`; alias-nvme per-drive patterns, `--cursor shared`, holder v2 extras;
  runners, dualnic-results.py (NIC latency), pips-seq-grab.sh env overrides.
  Checked: MinGW `-fsyntax-only` with stubs in this session's scratchpad
  (`stub/`, copied from 35bea50b + fcntl/poll/getsockopt), `bash -n`, dry runs.
- **Alias campaign in and analysed** (HANDOFF §8 "Alias campaign results"):
  `dualssd/1105/`, `dualnic/1105/` (unpacked); `py -3 dualssd/report-gen/c1105.py`,
  `geom1105.py`, then `page1105-head.py` + `page1105.py` rebuild the page "PIPS Alias
  Campaign". icx IOTLB 256 entries set-assoc (<16 ways), bigserver ~96 no sets;
  interference shown; misses cost nothing; batcher doesn't move them. The next
  campaign (tools T1-T6, phases c/g/i/s/r) is only a proposal on the page; nothing
  set up. The host analysis's IOTLB sim used `--strict` (wrong for alias): T1.

## State as of 2026-11-05
- **bigserver freezes when drive b4 (990 EVO Plus, Immediate Readiness) is
  reset after an alias-nvme load** (5/6; never at open). Whole-host freeze, no
  logs; once the PCIe tree did not come back at the reboot (FPGA still
  programmed, but no Xilinx function enumerated: the uplink side, not the
  drive; reprogram + reboot fixed it; next time try a warm reboot first). Fix chosen by the user: hold the
  drives (`alias-nvme --hold`), never release, end with `sync; systemctl
  reboot -ff`. `alias-stability.sh` passed 14/14 (11-05). The drive alias
  campaign now runs in hold mode (`pips-campaign.sh ssd --alias --tmux`:
  holder + `alias-guard.sh`, runner `ALIAS_HOLD`, resume via
  `~/.pips-campaign-<kind>-<mode>.current` + `progress.tsv`, `DONE`, reboot
  at the end). Launched by the user 11-05 night; results to come back. Debug tools: `alias-hangtest.sh` (`--show`),
  `alias-postmortem.sh`. HANDOFF §8 "Next" has the whole log.
- **Alias campaign set up, committed (9ccd1d029), not run** (HANDOFF §8 "Alias
  campaign"): `scripts/pips/alias/` (alias-nvme over VFIO, alias-rdma READs,
  README there), runners `--gen alias`, `pips-campaign.sh ssd|nic --alias`.
  `rdma_script/` (the user's starting code) is git-ignored. perf / VT-d PMU
  on hold (user); misses from pcm-iio. Checked here only: MinGW
  `-fsyntax-only` with stub headers (kept in the session scratchpad, not the
  repo), the shared header run natively, its output read by the real
  `fio-sum`, `bash -n`, campaign `--dry-run`.

## State as of 2026-11-02
- **0x0A07 paper campaign in and analysed** (HANDOFF §8 "0x0A07 paper campaign
  results"): `dualssd/1101/`, `dualnic/1101/`; tables `py -3
  dualssd/report-gen/c1101.py [ssd|nic]`, `agg1101.py`, `floor11.py`. Drives'
  strict leg refused (irq layout) -> the 10-28 rerun stands in (user OK'd,
  consistent). E7 none (no perf on either kernel). Published: "PIPS 0x0A07
  Campaign" v2 (paper results + experiment status with "Not available"
  marks), "PIPS TLP Patterns" v6 (0x0A07 added). Optional rerun only: drives
  4k j16 per mode with SSD_CORES off the interrupt CPUs.

## State as of 2026-10-31
- **0x0A07 paper campaign set up, not run** (HANDOFF §8 "0x0A07 paper
  campaign"): `pips-campaign.sh ssd|nic --paper --leg <mode> --tmux`, the
  user's list E1, E2, E5-E13 (E2b, E3, E4, E15 out of scope). One IOMMU leg
  per launch (user, 10-31): the campaign reads the booted mode (strict, lazy,
  pt, off) and runs that leg, never changes it; the user reboots with the
  GRUB line per leg (table in HANDOFF). ~2h50 per leg per host. New
  `pips-pcie-caps.sh` (E6),
  `utils/iommu-ops.sh` + runners' `--iommu-ops 1` (E7, needs `perf`).
  Untested on hosts (only `bash -n`, dry runs, parser unit checks here).
  When the tarballs come back: unpack in `dualssd/<MMDD>/`, `dualnic/<MMDD>/`
  and write the local tables (list at the end of that HANDOFF section).

## State as of 2026-10-30
- **Both 0x0A07 reruns analysed; verdict: the switch study is done** (HANDOFF
  §8 "0x0A07 NIC results", "Verdict"). Page "PIPS 0x0A07 Campaign" (v1)
  https://claude.ai/artifact/91VNbNGeJVyfuLLH8acGvY, hand-written
  `dualssd/dualssd-pips-0a07-report.html`. User rule (10-30): judge on page
  order only, not IOTLB misses or bandwidth (clean testbed, production IOMMU
  is aliased by other devices). New `report-gen/floor7.py` (floor + legal
  floor with the completion rule) and `c1028.py nic`. Only open option: one
  build with more page segments (drives 64k/1m), if the user wants it.
- Importing `seqrec` rewrites the tracked
  `scripts/pips/__pycache__/pips-page-seq.cpython-313.pyc`: `git checkout`
  it before committing.

## State as of 2026-10-28 (evening)
- **0x0A07 drive rerun back and analysed** (`dualssd/1028/`, tables `py -3
  dualssd/report-gen/c1028.py`, HANDOFF §8 "0x0A07 drive results"): result 10
  solved (pb0 back to 0x0A05's page switches, model within 2% at d16-64; pb1
  d64 16k 8.3 -> 2.6), Gb/s and misses unchanged. NIC tarball not back yet:
  unpack in `dualnic/<MMDD>/` and check NIC0 TLPs per run vs rcap level,
  REFUSED_%/cap share, pause frames. No report page for 0x0A07 yet.

## State as of 2026-10-28
- **Design 0x0A07 built** (FPGA `28ff5b6`): rate caps reg4, refused-cycle
  counters 0x30-0x3C, read flush no longer preempts (likely cause of 0x0A06
  result 10). Tools committed and pushed 10-28: `pips cfg set rcap=`,
  `pips counters`, per-run sampler `pips-bp.tsv`, sweeps `--set rcap0=`,
  campaign `--minimal` (drives 129 runs ~3 h; NICs 59 runs ~3 h: `rcap`
  FPGA rate cap levels, `uneven` NIC0 link 50G, `wire50` both links 50G;
  analysis with `PIPS_PB_MODEL=self,sweepc1,sweepc1f512`). HANDOFF Next
  items 0b and 1 canceled by the user. Python edit scripts: open files with
  `encoding="utf-8"` (cp1252 default broke a `§` once). HANDOFF §8 "0x0A07 minimal
  rerun" and "Next" status 10-28. `test-sim.sh` 0x0A07 tests untested (needs
  Linux: `make -C scripts/pips check` on a host first).

## State as of 2026-10-26
- **Methodology fix (HANDOFF 0x0A06 result 10):** page-order lines must come
  from the measured arrival order in `seq.jsonl` (`windows_arr`, `model`),
  not `seqrec.py`'s synthetic arrivals. Summary page v5 does; the
  0x0A04-0x0A05 page (Figs 3-6) and the 0x0A06 page (Figs 6-9) still don't.
  0x0A06 logs have no host model yet (rerun with `--model`).

- **The 0x0A06 campaign is back** (both hosts, every phase, switch fine, no
  lockups): `dualssd/1026/`, `dualnic/1026/`; tables `py -3
  dualssd/report-gen/c1026.py [ssd|nic]` (saved `c1026-*.txt` beside the
  data); findings HANDOFF §8 "0x0A06 campaign results" (8 items). In short:
  page batching regroups pages but strict mode's misses don't move; it ends
  the NIC pause frames; NIC splitting = receive backlog, fixed by a 50G wire.
  Report page "PIPS 0x0A06 Campaign" (v1, 10-26) has R1-R8, the splitting
  rule (~50 ns slack per frame at 100G) and the next steps, mirrored in
  HANDOFF §8 "Next" (map/unmap counts, lazy mode via sysfs DMA-FQ without
  a reboot, counters, hold-only-when-contended, FIFO limit register).

## State as of 2026-10-25

- **Design 0x0A06 (page batcher, FPGA `9673e37` + `d44fdd0`) is the only build
  now.** Tools support it (`pips cfg set pb= pushoff= quantum= thr=`, `pips
  status`, tags `p1 o1 q<N> w<N>`); the campaign `scripts/pips/pips-campaign.sh
  ssd|nic --tmux` runs every sweep plus the pending 0x0A04/0x0A05 analysis and
  leaves `~/pips-campaign-<kind>-<stamp>.tar.gz` (HANDOFF §8 "0x0A06
  campaign"). Not run yet; `make check` not run (no Linux here: C only
  syntax-checked with `C:\Xilinx\2025.1\tps\mingw\10.0.0\win64.o\nt\bin\gcc.exe
  -fsyntax-only` and stub POSIX headers; its `PRIx64` warnings are MinGW's).
- When the tarballs arrive: unpack in `dualssd/<MMDD>/`, `dualnic/<MMDD>/`;
  page-order and status data for the next report.

## State as of 2026-10-20 (details: HANDOFF §8 "Next", items 11-12)

- **Page v10 (10-20):** floor and raw lines replace the ideal (`seqrec.py
  --rawfloor` caches `rawfloor.json`; run it after `--write` when the
  listings change). HANDOFF §8 item 12 "v10".
- **Page v9 (10-20):** the ideal line starts from d1t0c1's recorded order
  (whole-log windows); NIC by-NIC = by-page explained (each NIC writes whole
  packets when both run). HANDOFF §8 item 12, "After user review".
- **Page v8: page order recovered without the raw logs.** `report-gen/seqrec.py`
  runs the batcher model on each device's own order (exact: the 10-19
  listings as sent, filtered per device) with I/O bursts and an output rate
  fitted to each log's recorded wait; `seqrec.json` caches it (`py -3
  seqrec.py --write`, ~15 min). `seqarr.py`/`.js` were rewritten for it (v6
  code in `report-gen/old/`). The grant gap in `pips-page-seq.py` is now
  charged only on a re-grant to the same input (two NICs taking turns don't
  pay it).

- **NIC splitting alone vs together (10-20, HANDOFF §8 item 13):** decided by
  the gap between a NIC's packets on its wire (alone 0.32 µs at 100G,
  together ~0.6 µs), not by the switch's wait; styx's order is the same in
  both. Suspect: styx's one dual-port card on one Gen3 link. Untested; the
  tests are in HANDOFF §8 "Next" item 5 (`report-gen/nicorder.py`).
- **The 10-19 `pips-analyze` run is in** (`dualssd/1019/pips-analyze-ssd-20261019-1723/`,
  `dualnic/1019/pips-analyze-nic-20261019-1723/`). Its length verdicts are on
  the page (v7, Table 11, `report-gen/sizes.py`). Its drive page-order model
  ran away (waits ~1,400 µs): the log's output times lack the stalls inside
  packets on the Gen3 x8 uplink. Fixed in `pips-page-seq.py` (8f778206d:
  stalls put back, link fitted and calibrated per sweep, per-input order
  kept); synthetic check in `test-sim.sh`.
- **To run next (user), with the new grant gap:** `pips-analyze.sh ssd --no-lengths -j 16 --tmux` on
  bigserver, `pips-analyze.sh nic --tmux` on icx (now finds the 0x0A05
  manifest under `utils/logs/`). When the tarballs arrive: unpack in
  `dualssd/1020/`, `dualnic/1020/`, run `py -3 seqarr.py`. The model's own
  setting should now come within a few % of the logs, with waits near
  1.5 µs. Then point `seqarr.DIRS` at the new `seq-*`, add the 0x0A05 grabs,
  redo the drive arrival/ideal lines, add the NIC 0x0A05 `traffic.jsonl` to
  `sizes.FILES`, rebuild, publish.
- **Quick check of a raw-log question without the hosts:** the synthetic
  generators in `test-sim.sh` (`synthb.py`, `synths.py`: stalls dropped as
  the hardware does) reproduce model behaviour locally.
- **Open:** the NIC depth sweep on 0x0A05 stopped at d24t255c1 (switch
  stopped answering; HANDOFF §8 item 7, `pips-hang-snapshot.sh` next time);
  d24 f15/f30, d36, d64 not run (`--tag dsweep1b`).
- Figure rules the user set (also in auto-memory): ideal line = window fit
  only; average each point's logs; depth 1 = round robin (cap on); no
  single-device points in the what-if figure.


> **From CLAUDE.md, the lines replaced on 2026-11-06 (orientation)**

file instead of scanning. Updated 2026-10-19.

1. `HANDOFF.md` — "Last updated" at the top, then §8 (PIPS switch): designs,
   results per design, the model's history (§8 "0x0A04 results" items 8-10),
   "0x0A05 depth sweep", and **"Next"** (what is running and what to do with
   it). §1-6 are the dual-NIC testbed (icx), §7 dual-SSD (bigserver).

| Artifacts | "PIPS Alias Campaign"
