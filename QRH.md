# QRH: quick reference for the PIPS scripts

What each script's options do, on one page per tool. The scripts' own
headers (`--help` or `-h`) are the full reference; this summarises them.
Background and results are in [HANDOFF.md](HANDOFF.md) §8. Which script calls
which is in [FILE-MAP.md](FILE-MAP.md). Updated 2026-11-06 (alias campaign 2).

Hosts: **bigserver** has the drives behind PIPS (`ssd`). **icx** has the NICs
behind PIPS (`nic`), and **styx** is the client/sender. Run everything from
the repo root on the host, as user `yz69`. The scripts call sudo themselves.

---

## 1. Options shared across scripts

| Option | Where | What it does |
|---|---|---|
| `--tmux` | campaign, sweeps, runners, `pips-analyze.sh` | Relaunches the same command in a new tmux session (campaign: `pips-campaign-<n>`, analysis: `pips-analyze-<kind>`). Asks for the sudo password **inside** tmux and survives a dropped ssh. Detach with `Ctrl-b d`, re-attach with `tmux attach -t <name>`. The window stays open when the run ends and prints its exit status. |
| `--dry-run` | campaign, `alias-stability.sh` | Prints the plan (phases, points, ETA as clock times) and every command it would run. Runs nothing and touches no device. Use it before every launch. |
| `-h`, `--help` | all | Prints the script's header comment, which is its manual. |
| `-j N` | campaign, `pips-analyze.sh`, `pips-seq-grab.sh` | How many TLP logs to analyse in parallel. |
| `-o NAME/DIR` | sweeps, analysis, snapshots | Names the output. Every script refuses to overwrite an existing output. |
| `--tag LABEL` | sweeps | Names the sweep `dual<kind>-pips-<iommu>-<LABEL>`. Refused if that name already has results. |
| `HEARTBEAT=s` | campaign (default 300), analysis (60), seq-grab (60) | Seconds between liveness lines. |
| `RESULTS_DIR` | campaign, sweeps | Where `~/<sweep>.jsonl/.txt/.manifest.tsv` go (default `~`). |

Hard rules every campaign follows. It never reboots or touches GRUB (the one
exception is the bigserver alias campaigns, below). It never changes the
IOMMU mode. It puts every switch setting and link speed back at the end.

---

## 2. `scripts/pips/pips-campaign.sh ssd|nic [mode] [options]`

One command runs a whole campaign: the sweeps, then the analysis, then
**one tarball** `~/pips-campaign-<kind>-<stamp>.tar.gz` to copy back. The
raw TLP logs stay on the host.

### Modes (pick one; no mode = the full 0x0A06 campaign)

| Mode | What it runs | Time |
|---|---|---|
| *(none)* | The full 0x0A06/0x0A07 set. Drives: `main cap0 push quant thr drv0`. NICs: `mainlo mainhi cap0 push quant thr alone hw wire`. Then the pending 0x0A04/0x0A05 analysis. | ssd ~18 h, nic ~16 h |
| `--minimal` | The short 0x0A07 rerun. Drives: depths 1/4/16/64 × pb 0/1, cap on, w31. NICs: `rcap`, `uneven` (NIC0 link 50G), `wire50` (both links 50G). No knob phases and no pending analysis. | ssd ~3 h, nic ~4 h |
| `--paper` | The paper list (E1, E2, E5-E13), **one IOMMU leg per launch**. The leg is the mode the host booted with. Phases: `pcie`, drives `head`, NICs `g100 e8 rcap0` (rcap0 on the strict leg only), `ops` (needs `perf`). | ~2h50 per leg |
| `--alias` | The aliasing campaign 1: fio/iperf3 are replaced by `alias-nvme`/`alias-rdma`. Phases `ageom acap aconf`. | ssd ~1h55 + reboot, nic ~2h30 |
| `--bg` | The 0x0A08 stress campaign (11-07, IOMMU strict, design 0x0a08): the switch's read engine as IOMMU stressor. **ssd:** native half (drives on nvme, module region): `nprep nalone nstress nseq nheavy ncross ndeep nend` (fio random 4k/8k/16k/64k/1m, sequential 4k/8k/1m, iodepth 128/512 with its own tag census); then vfio half (holder, `bgmap` region): `vprep valone vstress vcross`. Levels `off h16 m1 m4 m16 c16 v16 d16 h50 m50 hx mx`. Reboots at the end only if the vfio half started. **nic** (icx, NICs stay on mlx5, no reboot): `iprep ialone irepl itcp irdma icross iend` (iperf3 5/30 flows; alias-rdma fits / one-set rotation / capacity; replacement-policy tables); levels as ssd without d16. No analysis. | ssd ~44 h 30, nic ~33 h |
| `--alias2` | The aliasing campaign 2 (11-06): everything `--alias` does, with new phases. icx: `n2ways n2sets n2rot n2small n2sge n2place n2share n2walk n2cap n2lat n2quant n2rep`. bigserver: `s2cap s2probe s2place s2order s2walk s2rep`. It also reanalyses the 11-05 sweeps (`analyze-1105/`). | nic ~19h30, ssd ~5 h + reboot |

### Modifiers

| Option | What it does |
|---|---|
| `--only "P ..."` / `--skip "P ..."` | Runs only these phases, or leaves them out. `--dry-run` lists the phase names. |
| `--leg strict\|lazy\|pt\|off` | With `--paper`: refuses to start unless the devices really are in that mode, which catches a missed reboot. With `--dry-run`: plans that leg on any host. |
| `--runs N` | Runs per point. `--paper` default 3 (head, g100, e8), `--alias` 1, `--alias2` 2 (the comparison points). |
| `--pending` / `--no-pending` | Adds or removes the pending 0x0A04/0x0A05 analysis (`--minimal` and `--paper` leave it out by default). |
| `--no-analysis` | Runs the sweeps and packs the results, with no page-order or length analysis. |
| `--no-wire` | NICs: leaves out every phase that changes link speed (`wire`, `uneven`, `wire50`). |
| `--no-hw` | NICs: leaves out the phase paced in styx's NIC hardware. |
| `--stamp S` | The label prefix for this campaign's sweeps (default `c<MMDDhhmm>`). |
| `--fresh` | Starts a new campaign even if a half-done one is there. The old one is left as it is. |
| `--levels "L ..."` | With `--bg`: only these engine levels in the stress sweeps (the cross phases keep theirs); e.g. `pips-icx-finish.sh`. | |
| `--smoke` | With `--bg`: every step once, small (levels off/m16/mx, 1 run, 4k, two settings, 6 T8b tables, ndeep qd 512, nseq 4k; nic 5 flows, patterns f/r). ssd ~1 h 45 with both halves; `--only "nprep nalone nstress nseq nheavy ncross ndeep nend"` = native only, ~1 h 05, no reboot. nic ~2 h 25. |
| `--no-reboot` | `ssd --alias/--alias2/--bg`: at the end the drives stay held, and you run the reboot yourself (`sync; sudo systemctl reboot -ff`). |
| `--retire S` | Runs nothing. Moves campaign S's results, run folders and TLP logs into `~/pips-retired/S/`. Nothing is deleted. |

### Resume (automatic)

Each launch reads `~/.pips-campaign-<kind>-<mode>.current`. If that campaign
has no `DONE` file yet, the launch picks it up:

- Sweeps listed as done in `progress.tsv` are skipped.
- A sweep that was cut short runs again as `<label>r<n>`.
- The analysis then runs over all of them.

After a crash or a reboot, relaunch with **the same command**. Use `--fresh`
to start over instead.

### Environment

| Variable | Default | What it does |
|---|---|---|
| `DUALSSD_ARGS` | `--membw 0` | Extra runner options for the drive sweeps. |
| `PIPS_PB_MODEL` | `self,sweepc1,sweepc1f512` | The batcher model run on the new logs. `""` = none. |
| `LOCKUP_STOP` | 2 | This many kernel soft lockups within one heartbeat stop the sweeps. The campaign still analyses and packs. |
| `PIPS_SEQ_STRICT`, `PIPS_SEQ_IOTLB` | set by `--alias*` | The IOTLB simulation the analysis runs (see §5). |

### Safety behaviour you'll see

- **The switch stops answering** (the design ID changes, or BAR0 reads
  `0xFFFFFFFF`). The campaign takes `pips-hang-snapshot.sh` at once, skips
  the remaining switch phases with a large warning, and still analyses and
  packs.
- **The design must stay as found** (0x0a06 or 0x0a07). Rate caps are 0, w31
  is set, and the IOMMU stays as booted.
- **`ssd --alias*` (bigserver):**
  1. Binds both drives and starts **one** `alias-nvme --hold` for the whole
     campaign. Releasing drive b4 freezes the host.
  2. Arms `alias-guard.sh` (BMC watchdog 120 s, panic on lockup).
  3. **Ends with `sync; systemctl reboot -ff`.**
  4. If the BMC resets a hung host, relaunch the same command to resume.

### Launch lines

```bash
bash scripts/pips/pips-campaign.sh nic --alias2 --dry-run     # always first
bash scripts/pips/pips-campaign.sh nic --alias2 --tmux        # icx
bash scripts/pips/pips-campaign.sh ssd --alias2 --tmux        # bigserver (reboots at the end)
bash scripts/pips/pips-campaign.sh ssd --bg --smoke --only "nprep nalone nstress nseq nheavy ncross ndeep nend" --tmux   # 0x0A08, native smoke
bash scripts/pips/pips-campaign.sh ssd --bg --tmux            # 0x0A08 stress, ~44 h 30 (reboots at the end)
bash scripts/pips/pips-campaign.sh nic --bg --tmux            # 0x0A08 stress on icx, ~33 h (no reboot)
bash scripts/pips/pips-campaign.sh ssd --paper --leg strict --tmux
bash scripts/pips/pips-campaign.sh ssd --minimal --tmux
bash scripts/pips/pips-campaign.sh ssd --retire c11051830     # move a failed campaign aside
```

Output folder `~/pips-campaign-<kind>-<stamp>/`:

- `campaign.log` and `plan.txt`
- `notes.txt`: warnings and skips; check it first
- `results/`, `sweeplogs/`, `runs/`
- `status.txt`
- `analyze-new/`, `analyze-pending/`, `analyze-1105/`
- `snapshots/` (NICs), `pcie/` (`--paper`)
- `iommu-at-start.txt`, `iommu-at-end.txt`, `cmdline.txt`

---

## 3. Sweeps: `dualssd_pips_sweep.sh` / `dualnic_pips_sweep.sh`

These are in `scripts/sosp24-experiments/`. Each runs one cross sweep (drives)
or flow sweep (NICs) per batcher setting, with the TLP log recorded in every
run. The campaign calls them, and you can also run them by hand.

| Option | What it does |
|---|---|
| `--cfgs "D:T[:M] ..."` | Batcher settings: depth threshold D, time threshold T (0-255), and batch_mrd M (no effect on 0x0a06 and later). Default `"1:0 8:22"`. |
| `--caps "0 1"` | Drain depth cap values to run with every setting. 1 = at most D packets per drain. Default runs both, which doubles the runs. |
| `--pbs "0 1"` | `page_batch_en` values (0x0a06 and later; default `0`). 1 = per-page batching, tag `p1`. |
| `--set "K=V ..."` | Page batcher fields for every setting: `pushoff=` (`o1`), `quantum=` (`q<N>`), `thr=`/`thr0=`/`thr1=` (`w<N>`). On 0x0a07 also the rate caps `rcap= rcap0= rcap1= rcapout=` (beats per 256 cycles, 0.5 Gb/s each; `r<a>x<b>x<c>`). Fields you don't give are written 0. |
| `--single` | Drives: also drive 0 alone. NICs: also each NIC alone (needed for CONTENTION). |
| `--single-ssd N` | Drives: run drive N alone instead. |
| `--modes "..."` | NICs: the modes outright (`nic0only nic1only both`). |
| `--no-asy`, `--asy-low`, `--asy-high`, `--no-swap` | Drives: control the uneven co-runs (default low 2/4/8 against high 16/32, both ways). |
| `--datapath-once` | Runs the datapath check only before the first setting. |
| positional | Drives: `"block sizes" "instances" runs`. NICs: `"flows" "rates" runs`. A flow entry `A:B` is an uneven co-run, and a rate `hw<N>` paces in styx's NIC. |

How to read a setting name such as `d16t218c1p1w31`: depth 16, time 218,
cap on, page batching on, completion threshold 31 DW. Sweep folders are
named `<NAME>-id0a07-<setting>`.

To stop a sweep cleanly (Ctrl-C works too; both put the batcher setting
back):

```bash
pkill -f 'dualssd_pips_swee[p]'; pkill -f 'dualssd_swee[p]'; pkill -f 'run-dualssd-experimen[t]'
pkill -f 'dualnic_pips_swee[p]'; pkill -f 'dualnic_flow_swee[p]'; pkill -f 'run-dualnic-experimen[t]'
```

Read a sweep only through its `~/<NAME>.manifest.tsv`
([scripts/pips/SWEEP-LOGS.md](scripts/pips/SWEEP-LOGS.md)).

---

## 4. Runners: `run-dualssd-experiment.sh` / `run-dualnic-experiment.sh`

The runners measure one configuration. `-E NAME` names it, and an existing
name is refused. Exit 3 means the configuration could not be measured;
sweeps log that and go on.

### Common flags

| Drives (bigserver) | NICs (icx) | What it does |
|---|---|---|
| `--ssds 1\|2`, `--ssd-index i` | `--nics 1\|2`, `--nic-index i` | One device or both. |
| `-J n` or `-J n0,n1` | `-S n -C n`, `--flows-nic1 N` | fio instances per drive / iperf3 flows per NIC. The second form gives the two devices uneven counts. |
| `--bs --iodepth --rw --ioengine` | `-M MTU`, `-b RATE`, `--uncapped`, `--cca`, `--buf` | Load shape. The drives are read-only: `randread` and `read` only. |
| `-d s`, `--warm s`, `--runs N` | `-d s`, `--runs N` | Window length (default 20 s) and repeats. |
| `--membw 0` | | Skips pcm-memory (saves ~50 s per run). |
| | `--client-hw-rate 50g` | Paces styx's ports in NIC hardware (even frame spacing). |
| | `--sync-client` | Syncs styx's checkout first. |
| `--pips-log 1` | `--pips-log 1` | Records the switch's TLP log in every run. `PIPS_LOG_GZIP=0` keeps the `.bin` uncompressed. |
| `--iommu-ops 1` | `--iommu-ops 1` | Counts map, unmap and VT-d invalidations with perf (E7). This costs CPU, so use it only for counting runs. |
| `--results FILE` | `--results FILE` | The JSONL to append to. |

### `--gen alias`: the in-house generators instead of fio or iperf3

Each device writes 4 KiB pages `first + i*stride` (i < ws) of a region mapped
**once**. The IOTLB misses therefore come from the pattern, not from map and
unmap.

| Flag | What it does |
|---|---|
| `--ws N --stride N` | The pattern (default 64, 1). Stride 1 with a large ws gives capacity misses. A stride that is a multiple of the set count (4096) puts every page in one set, which gives conflict misses. |
| `--first N`, `--order cyclic\|shuffle\|random`, `--page-list PATH`, `--backing-pages N` | Where the pattern starts, the visit order, an explicit page list, and how many physical pages back the IOVA span. |
| `--ws1 --stride1 --first1 --order1 --page-list1` | **New 11-06.** Device 1's own pattern (default: device 0's). |
| `--cursor queue\|shared` | Drives, **new 11-06.** `shared` = one cursor per drive (strict pattern order). The default per-queue cursors drift. |
| `--lba rand\|seq` | Drives: where on the namespace to read. |
| `--depth N`, `--rdma-bs B` | NICs: READs in flight per QP (16) and bytes per READ (4096). |
| `--sge-bytes B` | NICs, **new 11-06.** Bytes per scatter entry, each written into the next pattern page. For example, 4096/512 = 8 pages per READ. |
| `--rdma-mtu B` | NICs, **new 11-06.** Caps the RoCE path MTU (256-4096). |
| `ALIAS_HOLD=<dir>` | Drives, set by the campaign. Sends the load to the running holder instead of binding the drives. `-J 4`, qd 32 and bs 4k must match the holder. |

IOMMU modes:

- **Drives:** any mode but off. VFIO puts the drives in its own paging domain,
  so strict, lazy and pt are the same experiment for them.
- **NICs:** strict or lazy only. With pt or off the MR is not translated.

The NIC runner runs at line rate only.

---

## 5. Analysis on the host

| Tool | Main options |
|---|---|
| `pips-analyze.sh ssd\|nic` | `--sweeps "a04 dsweep1"` (the default sweeps), `--manifest FILE` (repeatable), `--no-lengths` (page order only), `-j N` (default 8), `-o DIR`, `--tmux`. `PIPS_LINK=gen3x8` overrides the model's uplink. Output: `DIR.tar.gz`. |
| `pips-seq-grab.sh` | `--manifest FILE` (preferred), `--sweep`, `--sets`, `--points`, `--model LIST` (`""` = none), `--show N`, `--logs DIR`, `-j N`, `-o DIR`. |
| `pips-status-table.py MANIFEST... [--tsv OUT]` | Per run: spills, stuck, longest MRd wait, refused-cycle share. |
| `dualssd-results.py` / `dualnic-results.py` | `summary FILES`, `grid` (drives), `dump`, `fio-sum`. |

Environment variables for the analysis:

| Variable | What it does |
|---|---|
| `PIPS_SEQ_STRICT=0\|1` | Overrides the rule that a sweep with "-strict-" in its name means every new page visit misses. Use 0 for the alias sweeps. |
| `PIPS_SEQ_IOTLB=SETSxWAYS,...` | The simulated geometries. The campaign uses `32x8,64x4,128x2,1x256` on icx and `1x96,1x64,1x128,1x256` on bigserver. |
| `PIPS_LINK_RATE` | Skips the uplink calibration pass. |

---

## 6. Host checks and switch tools (read-only unless noted)

| Command | When to use it |
|---|---|
| `bash scripts/pips/pips-id.sh [-q]` | Is the FPGA our switch, and which design? The last line ends in `verdict=pips/not-pips/no-fpga/no-answer/no-access`. Exit 0 = ok. |
| `bash scripts/pips/pips-iommu.sh show\|mode` | The IOMMU groups and mode behind the switch. `set strict\|lazy\|pt` changes them at runtime (by hand only; it unbinds and rebinds the drivers). |
| `bash scripts/pips/pips-rid-live.sh [--start-holder] [--hold DIR] [--fallbacks] [--t10] [--t11] [--t12] [--quick] [--only T7,T8] [--load-cmd CMD] [--tmux] [--dry-run]` | Design 0x0A08's live tests (docs/PIPS-0A08-ASSUMPTION-TEST.md §4) with the switch's read engine: T0 baselines, T1 usp read, T2 the main assumption (port ID reads in the device's domain), T3 isolation, T4-T6 trains under load (leak, straddle, flow control, drive IOPS), T7 hit/miss latency, T8 one IOTLB for all domains, T9 tag census; T10 F2, T11 F3 (`--fallbacks`: when T2 fails), T12 soak (`--soak-min 30 --soak-interval 100 --soak-maxout 64`). Stops at the first failure with the fallback to take; a leak or clash stops the engine for good. bigserver needs the alias-nvme holder (`--start-holder`: drives held until a reboot, BMC guard armed; `--reboot` at the end); icx: no holder, pages from `pips_bg_region.ko` in each NIC's domain, a built-in alias-rdma load against styx (`--load-cmd CMD` replaces it); IOMMU strict or lazy. `--tmux`: in a new tmux session (sudo password there), as a campaign. Engine tags: the largest range free in T0's census (`--tagwin LO-HI|off`). Also `--keep-going --f3-port in0\|in1\|usp --no-ridcheck --out DIR`. `~/pips-rid-live-<host>-<time>/summary.txt` + tarball. Exit 0 all passed, 1 a test failed, 5 leak/clash. |
| `sudo scripts/pips/pips bg help\|info\|set\|run\|counters\|census\|facts\|trace\|capture\|table ...` | The read engine by hand (design 0x0A08): scripts/pips/README.md, "The pips tool". `pips bg run rid=in0 base=0x4000000000 ws=64 count=64 dcheck=1 backing=64` = 64 reads through in0's port of the holder's region. |
| `bash scripts/pips/pips-rid-check.sh [--module] [--pt] [--vfio-drive0] [--iova A,...] [--out DIR]` | Host-only check of the background read engine's main assumption: does each PIPS downstream port's own requester ID translate through the IOMMU domain of the device below it? Groups, the IOMMU's context/PASID entries (debugfs), `--pt` page tables at `--iova`, `--module` the kernel's domains and `iova_to_phys` (read-only module built here; needs `linux-headers-$(uname -r)`), `--vfio-drive0` all again with drive 0 in VFIO for 75 s (bigserver; refuses the 990s and a running holder). `~/pips-rid-check-<host>-<time>/summary.txt` + tarball. Exit 0 holds, 1 fails, 3 not decided. |
| `bash scripts/pips/pips-pcie-caps.sh` | MPS, MRRS, relaxed ordering, tags, ACS and completion timeout along the path (E6). |
| `bash scripts/ssd-irq-placement.sh [--check]` | bigserver, **after every reboot**: are the drives' interrupt CPUs safe for strict mode? |
| `bash utils/iommu-mode.sh <iface\|nvmeXnY\|BDF>` | The mode the kernel actually applied to one device. |
| `sudo bash utils/iommu-ops.sh --dur 10 -o F -r R` | Map, unmap and invalidation counts over a window (needs perf). |
| `bash scripts/nic-host-snapshot.sh [IFACE...]` | A NIC host's PCIe path, pacing settings and counters. Run it before and after a run to get deltas. |
| `bash scripts/pips/pips-hang-snapshot.sh` | The switch stopped answering: run this **before** you reprogram or rescan. |
| `sudo bash scripts/pips/pips-bringup.sh` | After programming the FPGA: enumeration, registers, DMA, an empty log (`--soak N`, `--enable-mem`). |
| `sudo bash scripts/pips/pips-fio-log.sh` | One fio run with a TLP log, by hand (`--cfg "depth=8 time=0x16 cap=1"`). |

### The `pips` CLI

Build it with `cd scripts/pips && make`, then run `sudo ./pips <cmd>`.

| Command | What it does |
|---|---|
| `cfg` | Prints the setting, drain cap, `design_id` and log format. |
| `cfg set depth= time= cap= pb= pushoff= quantum= thr= thr0= thr1= rcap= rcap0= rcap1= rcapout=` | Read-modify-write of the batcher registers. |
| `status` | Page batcher status: overflow, stuck, MRd wait. **Reading clears it.** |
| `counters` | Refused and rate-cap-held cycles (0x0a07). Free-running, so take differences. |
| `info`, `hwtest`, `log-start`/`log-stop`/`log-dump` | Bring-up and manual logs. |

---

## 7. Alias tools (`scripts/pips/alias/`)

| Command | What it does |
|---|---|
| `alias-run.sh --build alias-nvme\|alias-rdma` | Builds into `build/<host>/`. Build as the user first; a first build under sudo leaves `build/` owned by root. `--path` prints the binary's path. |
| `sudo alias-vfio.sh bind\|restore\|status BDF...` | Moves drives between nvme and vfio-pci, at runtime only. bind refuses a drive that is mounted or open. |
| `alias-guard.sh arm DIR HOLD [T]` / `disarm DIR` / `status DIR` | BMC watchdog plus panic on lockup while the holder's heartbeat is fresh. The campaign uses it. |
| `alias-stability.sh [--loads N --secs N --wd-timeout S --no-wd --no-reboot --dry-run]` | ~20 min test of hold mode on bigserver. **It ends with a reboot.** |
| `alias-hangtest.sh [...]` / `--show [DIR]` | One drive load with fsynced traces, for bisecting a freeze. Options: `--panic`, `--ftrace`, `--pcm-at S`, `--exit-steps S`, `--exit-reset`, `--exit-d3`, `--no-d3`. |
| `alias-postmortem.sh [--hours N]` | After a host died: what the previous boot left behind, plus the drives and switch now. |

**Never `kill` (and never `kill -9`) a running `alias-nvme --hold`.** Its exit
releases b4, and that release freezes bigserver.

---

## 8. When things go wrong

| Situation | Do this |
|---|---|
| ssh dropped during a run | Nothing is lost if you used `--tmux`. Run `tmux ls`, then `tmux attach -t <name>`. |
| Campaign crashed, or the host rebooted mid-campaign | Relaunch the identical command; it resumes. `--fresh` starts over instead. |
| Switch reads `0xFFFFFFFF` | `pips-hang-snapshot.sh` (the campaign runs it for you). Then use JTAG (`pips-xsct.tcl`), and reprogram only after that. |
| bigserver froze | After the reboot run `alias-postmortem.sh`. If PIPS doesn't enumerate, try a warm `sudo reboot` before you reprogram. |
| `--leg` refused | The host didn't boot the mode you expected. Check `cat /proc/cmdline`: it must say `intel_iommu=on`, not `intel_iommu_on`. |
| A failed campaign is cluttering `~` | `pips-campaign.sh <kind> --retire <stamp>`. |
| Tarball is back | Unpack it in `dualssd/<MMDD>/` or `dualnic/<MMDD>/` on the analysis machine (HANDOFF §8). |
