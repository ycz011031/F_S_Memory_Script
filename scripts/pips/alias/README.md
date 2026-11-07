# In-house aliasing load: alias-nvme, alias-rdma

The alias campaign replaces fio and iperf3 with two small generators. In
each, the device under test writes into host memory at **fixed pages chosen
by the test**, mapped **once**, so the IOTLB misses come from the access
pattern, not from the kernel mapping and unmapping buffers. The
generators are adapted from the RDMA READ experiment in `rdma_script/` (a
git-ignored local copy), which only aimed at conflict misses. Here one
pattern also gives capacity misses.

| Tool | Host | Device writes into host memory by | Mapping |
|---|---|---|---|
| `alias-nvme` | bigserver (drives behind PIPS) | NVMe Read through VFIO, polled queues, one PRP entry per 4 KiB page | the region mapped once at IOVA `--iova-base` (default `0x4000000000`) |
| `alias-rdma` | icx client (NICs behind PIPS), styx server | one-sided RDMA READ: icx's NIC writes the responses, one scatter entry per 4 KiB page | one MR, registered once; the kernel size-aligns its IOVA range |

Data moves the same way as in the fio/iperf3 campaigns: the device behind
the switch writes into the host under test (MWr upstream through PIPS).

## The pattern: conflict and capacity misses from one plane

The device writes into pages `first + i*stride` (i < `ws`) of a region,
visited `cyclic`, `shuffle` (one fixed random order, cycled) or `random`.
The region's IOVA base is aligned at least to its size, so region page k is
IOVA page base + k, with k in the low bits, which an IOTLB set index is built
from.

- **Capacity misses:** `--stride 1`, `--ws` larger than the IOTLB's entry
  count. Cyclic order over more pages than the IOTLB holds misses on every
  access under LRU. The knee of the miss curve over ws is the entry count.
- **Conflict misses:** a `--stride` that is a multiple of the set count
  puts every page in one set, so `--ws` just above the ways misses although
  the pages fit in the IOTLB as a whole. 4096 pages (16 MiB) is a multiple
  of any power-of-two set count up to 4096.
- **Geometry:** Intel doesn't publish the VT-d IOTLB's size or
  associativity. The campaign's `ageom` phase measures both: the capacity
  curve (stride 1, ws 16 to 65536) and the conflict curve (ws 32, stride 2
  to 8192). The stride at which ws 32 starts to miss tells the set count.
- `--page-list FILE` gives the pages outright (whitespace or commas, `#`
  comments).

Both kinds of miss are aliasing: pages competing for the same entries.
With two devices behind the switch they compete with each other too, which
is the case the switch's page batching targets.

**Backing:** at a large stride the span is huge (ws 32 × stride 8192 = 1 GiB
of IOVA). The IOTLB keys on IOVA, not on the physical page, so the region
repeats `--backing-pages` physical pages (default the span, at most 65536 =
256 MiB): every IOVA page is mapped and DMA-able, but only that many are
distinct in memory.

## Running

Through the runners, which keep everything else the same (PIPS config, TLP
log, pcm-iio windows, results JSONL):

```
# drives (bigserver): --gen alias; -J = queues per drive, --iodepth per queue
bash scripts/run-dualssd-experiment.sh -E t1 --ssds 2 -J 4 --bs 4k --membw 0 \
     --gen alias --ws 32 --stride 4096
# NICs (icx): --gen alias; -S = QPs per NIC; line rate only
bash scripts/run-dualnic-experiment.sh -E t1 --nics 2 -S 4 -C 4 -b uncapped \
     --gen alias --ws 4096 --stride 1 --depth 16 --rdma-bs 4096
```

The campaign (one sweep per pattern point; HANDOFF §8 "Alias campaign"):

```
bash scripts/pips/pips-campaign.sh ssd --alias --dry-run      # plan, ETA, commands
bash scripts/pips/pips-campaign.sh ssd --alias --tmux         # bigserver, ~1h50
bash scripts/pips/pips-campaign.sh nic --alias --tmux         # icx, ~2h30
```

By hand (build as the user first; `alias-run.sh` builds into
`build/<host>/` on first use):

```
bash scripts/pips/alias/alias-run.sh --build alias-nvme
sudo bash scripts/pips/alias/alias-vfio.sh bind 0000:65:00.0     # leaves nvme
sudo $(bash scripts/pips/alias/alias-run.sh --path alias-nvme) --dev 0000:65:00.0=/tmp/a \
     --queues 4 --qd 32 --bs 4k --ws 64 --stride 1 --warm 5 --seconds 20
sudo bash scripts/pips/alias/alias-vfio.sh restore              # back on nvme
```

Every tool prints a heartbeat (`--heartbeat`, default 5-10 s) with kIOPS
and bandwidth. Per instance it writes what fio would have written:
`<prefix>.json` (jobs[0].read: iops, bw_bytes, io_bytes, total_ios, runtime,
lat_ns.mean, clat_ns.percentile, job_start) and `<prefix>_iops.1.log`
(epoch_ms, iops, 0, bs, 0 per second), both from the end of the warm-up on.
The runners read them with `dualssd-results.py fio-sum` unchanged. The NIC
runner writes each NIC's Gb/s over the windows to `iperf.bw.rpt` as
`Avg_iperf_tput`.

## Options added 11-06 (alias campaign 2)

- `alias-rdma --sge-bytes B`: each scatter entry writes B bytes at the start of
  the next pattern page, so a 4 KiB READ with `--sge-bytes 512` touches 8 pages
  (small, scattered writes at the READ rate of 4 KiB READs). `--mtu B` caps the
  RoCE path MTU (256-4096): a page then arrives in more packets, which the NIC
  interleaves across QPs. Runner: `--sge-bytes`, `--rdma-mtu`.
- Per device patterns: `alias-nvme --ws1 --stride1 --first1 --order1
  --page-list1` (drive 1; each drive maps its own region in its own domain);
  the NIC runner's `--ws1 ...` the same for NIC 1 (each NIC has its own MR).
  Drive 1 and NIC 1 get seed + 1 (their shuffle order differs).
- `alias-nvme --cursor shared`: one cursor per drive, so the drive visits its
  pages in strict pattern order. The default (`queue`) gives each queue its own
  cursor, started 1/nq of the way apart; their phases drift, so a page comes
  back after a spread of visits (bigserver's soft knee on 11-05).
- Sparse patterns (a page list, or a span over 64 times the pages used) are
  mapped page by page: only the pattern's pages exist in the domain.
- Hold mode: the load command takes `KEY=VALUE` extras after the ready file:
  `first= list= ws1= stride1= order1= first1= list1= cursor=queue|shared
  seed=`; state reads `ready <pid> v2`.

## Safety

- **Read-only drives.** `alias-nvme` builds only Identify, Set Features
  (number of queues), Create/Delete I/O SQ/CQ and Read. `sqe_check` aborts
  on any other opcode. Disabling the controller (CC.EN=0) is a reset, not a
  data change.
- **Drive binding.** `alias-vfio.sh bind` refuses a drive that is mounted,
  swapped on, held (md/LVM/dm) or open by any process (another user's fio
  on shared bigserver). It records the original driver in `/run/alias-vfio/`.
  The runner restores at exit, and at its next start if a run died. A
  drive on vfio-pci has no block device: other users of the host lose it
  for the run's duration.
- **IOMMU groups.** VFIO needs every endpoint of a group on vfio-pci. If the
  switch's ports lack ACS, both drives share a group, so the runner binds
  the idle drive too (bridges may stay). `alias-vfio.sh status` lists the
  group.
- **No reboot, no GRUB** (the campaign rule): binding is runtime and put back.

## Caveats

- **Which IOMMU modes.** strict, lazy and pt differ only in the *default*
  domain the kernel gives each device for its own DMA API: a paging domain
  that flushes on every unmap (strict), one that flushes in batches (lazy),
  or identity, IOVA = physical (pt). In all three the IOMMU hardware is on
  (`intel_iommu=on`). Binding a drive to vfio-pci and attaching its group to
  a container makes VFIO allocate its **own** paging domain and switch the
  device's context entry to it, replacing the default domain whatever it
  was. From then on every DMA is translated through VFIO's page table and
  the IOTLB, even in pt (which is why pt is the usual setting for VFIO
  passthrough). alias-nvme never unmaps during a run, so strict vs lazy
  doesn't matter either: **for the drives the three legs are the same
  experiment, and one boot is enough.** Off (`intel_iommu=off`) has no
  DMAR unit, so there are no groups and VFIO can't start.
  The NICs' MR lives in the kernel's default domain: strict and lazy
  translate it (and since it is mapped once, they should agree), while pt
  is identity and off has no IOMMU, so no IOTLB to alias. The campaign
  refuses pt and off for the NICs.
- **Releasing the drives (bigserver, 11-05).** Closing a drive makes vfio-pci
  reset it (FLR), restore its config space and put it in D3hot. The 990 EVO
  Plus (b4:00.0) claims Immediate Readiness (PCI Status bit 0), so kernel 5.15
  skips the 100 ms wait after that FLR and writes its config straight away;
  with that release the host froze 3 times out of 3 (no log, no pstore; once
  PIPS and the drives did not come back at the host reboot until the
  FPGA was reprogrammed: the drives' PERST# is a constant, so only a
  reconfiguration resets them). Resetting it first the way open does
  (`VFIO_DEVICE_RESET`: command register cleared, FLR, restore) and then
  closing released both drives cleanly once, but the next time b4 froze the
  host in that reset itself (~10 s after alias-nvme's abrupt CC.EN=0). b4's
  resets at open, after the nvme driver's normal shutdown, never froze. So
  alias-nvme now shuts each drive down the same way (CC.SHN, wait for
  CSTS.SHST), waits `--exit-settle S` (default 10 s), and then gives the
  drives back step by step with that reset first (`--exit-steps S`, default
  1 s between steps; ~30 s in all), also resetting first on an error exit;
  `--exit-unsafe` is the old way. Not enough: b4's reset froze the host
  after the shutdown and settle too (5 of 6 resets after a load froze; 0 of
  ~7 at open). Hence **hold mode** (`alias-nvme --hold DIR`): open the drives
  once, run every load on command, never release them, and end with an
  immediate reboot (`sync; systemctl reboot -ff`: no process is stopped, so
  nothing is released). Never `kill` the holder: its exit is the release.
  `alias-stability.sh` tested it (14 of 14 loads, 11-05). The drive campaign
  uses it: `pips-campaign.sh ssd --alias` starts one holder, the runner sends
  each run's load to it (`ALIAS_HOLD=<dir>`: no bind, no restore, no block
  device; -J 4, qd 32, bs 4k fixed), the guard reboots a hung host, and the
  campaign ends with the reboot. A holder command `map NAME MASK WS STRIDE
  ORDER [KEY=VALUE ...]` (11-07, state `v2 map`) maps a load's patterns again
  on fresh backings without I/O, so every page holds its tag again: the
  switch's read engine checks data against it (`pips-rid-live.sh`); a
  load's reads overwrite the tags. The runner waits 120 s for a one-shot
  alias-nvme after SIGINT before it would KILL. Never
  `kill -9` alias-nvme by hand. `alias-hangtest.sh` is the tool for this.
- **Interrupt remapping:** VFIO type1 refuses to attach a group on a host
  without interrupt remapping (EPERM at `VFIO_SET_IOMMU`) unless
  `vfio_iommu_type1 allow_unsafe_interrupts=1`. alias-nvme uses no
  interrupts, so that setting is safe here; the error message says how.
- **NIC side:** mlx5 translates the MR's virtual addresses itself (MTT). At
  large spans its own MTT cache misses add small MRd reads of MTT entries.
  Those go through the IOMMU too and add to the capacity misses. The drives
  have no such layer: PRP entries are IOVAs.
- **Page-walk caches:** a stride of 512 pages or more puts every page in
  its own 2 MiB region, so misses there also miss the PDE cache. pcm-iio's
  walk-level counters (PWC_*) show it.
- **Superpages:** the backing uses 4 KiB pages (memfd, no THP). If the
  kernel ever handed out 512 physically contiguous aligned pages, a VFIO
  mapping could use a 2 MiB IOMMU page. pcm-iio's `2M_HITS` would show it.
- **Measurement:** IOTLB lookups and misses come from pcm-iio as in every
  campaign (the runners' `pcie.rpt`, events 0x40/0x01 and 0x40/0x20). The
  VT-d PMU through `perf` (rdma_script's README) is on hold (HANDOFF §8
  "Alias campaign", open items).

## Files

| File | Role |
|---|---|
| `alias_common.h` | the pattern, the backing, stats, fio-format output, signals |
| `alias-nvme.c` | VFIO NVMe read generator (pthread per queue) |
| `alias-rdma.c` | RDMA READ generator: `--role client` (host under test), `--role server` (styx) |
| `alias-run.sh` | builds for this host when needed, then runs (`--build`, `--path`) |
| `alias-vfio.sh` | `bind`, `restore`, `status`: nvme ↔ vfio-pci |
| `alias-guard.sh` | `arm DIR HOLD [TIMEOUT]` / `disarm DIR` / `status DIR`: the BMC IPMI watchdog (hard reset when not petted for TIMEOUT s), a root petter that pets it while the holder's heartbeat is fresh, and the kernel's panic on lockup with `kernel.panic=10`; used by `pips-campaign.sh ssd --alias` (same boot: keeps the running petter) |
| `alias-stability.sh` | ~20 min test of the hold design on bigserver: one `alias-nvme --hold` keeps both drives for the whole test and runs 14 loads (patterns, one drive or both, PIPS batcher setting changed in the pauses, pcm-iio in half of them); BMC watchdog (hard reset when the host freezes or the holder's heartbeat is stale), panic-on-lockup with `kernel.panic=10`; ends with `sync; systemctl reboot -ff` (`--no-reboot`, `--no-wd`, `--dry-run`) |
| `alias-hangtest.sh` | one drive load by hand with the kernel log, its heartbeat and a 1 Hz tick fsynced to the host's own disk, optional pcm-iio at a set second and `--panic` (lockup → pstore); `--show` after a reboot (the 11-05 bigserver hang bisect) |
| `alias-postmortem.sh` | after a host died in a run: the previous boot's kernel log, panic and BMC records, the runner's output, the drives and the switch now (read only) |
| `Makefile` | `make nvme`, `make rdma` → `build/<host>/` (git-ignored) |
