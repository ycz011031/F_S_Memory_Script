# PIPS host bring-up

Test points for PIPS, the VCK190 PCIe switch, run from the host it is plugged
into. Everything goes through the switch's upstream port BAR0 (`10ee:b048`):
the BAR0 registers and BRAM, and an AXI window behind them that reaches the
batcher/logger config register (the regfile), the log DMA and the FPGA DDR
where the DMA writes the TLP log.

Everything known about the hardware side, from the BAR0 map and the batcher
register to the log format, findings and troubleshooting, is collected in
[PIO-MANUAL.md](PIO-MANUAL.md). This file is about the tools.

The tools work on hardware (bigserver, 2026-10-11). They are also tested
against a software model of BAR0 (`make check`, below).

## Which bitstream

These tests need a build with the host register block (the PIO): FPGA repo
`pips_batch` at `af165d6` or later. Nothing in config space tells it from an
older build: device `10ee:b048`, subsystem `0007` and the 32 KB BAR0 are the
same in every build. Only the `ID` register at BAR0+0x800 does, and the tools
read it first. On a build without the PIO that first read is forwarded to the
device on downstream port one (PIO_KNOWLEDGE_MAP D6) and fails. So know which
image is loaded before running.

## Design IDs: what each build changes, and how artifacts carry the ID

From `e389cca` on, every build reports a design ID (regfile +0x20, `pips cfg`
prints `design_id=`, `pips info` a `DESIGN_ID` line). It goes up by one with
every FPGA design update (`pips.tcl` `pips_design_id`).

| Design ID | FPGA repo | What the host sees |
|---|---|---|
| none | before `e389cca` | +0x20 answers DECERR; `pips cfg` prints `design_id=none` |
| `0x0a02` | `e389cca` (10-11) | DESIGN_ID register; the 10-13 dual-SSD PIPS sweeps ran on it |
| `0x0a03` | `2c6c3f5` (10-14) | **drain config register**, regfile reg1 (`0xA4000004`) bit 0 `drain_depth_cap`: 0 = one drain sends every packet in the FIFO (reset value, and what older builds always did), 1 = at most `depth_threshold` packets (0 counts as 1), the rest in the next batch. Safe to change at any time. Older builds read 0 there and ignore writes |
| `0x0a04` | `591d854` (10-15) | **log record format v2**: one record per TLP leaving the batcher, in output order; `port` = the input it came in on; new `pkt_wait` (u16 at 0x0C, cycles in the batcher); `pkt_tag` moved 0x0C → 0x0F; AT moved from byte 0x0D into `pkt_type[5:4]`. No more separate in0/in1/out records |

The trailer is the same in both log formats, so **a log cannot tell its own
format**: a v1 decoder reads a v2 log without an error but with wrong tags.
The design ID picks the decoder, so from now on every artifact carries it:

- **Raw TLP logs** have it in the name: `pips-log-id0a04.bin.gz` (runners),
  `log-id0a04.bin` (`pips-fio-log.sh`), `log-smoke-id0a04.bin`
  (`pips-bringup.sh`). A header would change the raw DDR dump.
- **Text** has it inside: `pips cfg` readouts (`pips-cfg.txt`,
  `cfg-before.txt`, ...: `design_id=`, `log_format=`), the decode
  (`log-summary.txt` second line, JSON `design_id`/`log_format`, CSV first
  line `# design_id=0x0a04 log_format=v2`), the `.rpt` (`design_id:`), the
  results JSONL (`pips_design_id`), and the sweep summaries (`design_id=` line,
  `PIPS design ID:` line, rows labelled `off d8t22c1@0a04`).
- **Sweep names** have it too: `<NAME>-id0a04-d8t22c1` per setting.

A build without a design ID writes names and files as before (no `-id`).

The decoders find the ID in this order: `--design-id`; `-id<XXXX>` in the log's
file name; a `design_id=` line in a `pips cfg` readout in the same folder
(`pips-cfg.txt`, `cfg-before.txt`, `cfg-run.txt`, `cfg.txt`). With none of
those the log is from before IDs were recorded and is read as v1, exactly as
before. So the 10-13 sweep logs (`pips-log.bin.gz` next to a `pips-cfg.txt`
saying `0x0a02`) decode as v1, and so would any older dump on its own.

## BAR0 size

The PIO needs a 64-bit, 32 KB BAR0 on the upstream port: registers at 0x800,
the AXI window at 0x4000, and `pcie_cq_bar_split` claims 32 KB from the BAR
base (`BAR_APERTURE_LOG2 15`). `lspci` must show:

```bash
lspci -vv -d 10ee:b048 | grep 'Region 0'     # ... (64-bit, non-prefetchable) [size=32K]
```

**`pf0_bar0_size 32` (Kilobytes) does not give that: it gives 1 KB.** This was
seen on bigserver on 2026-10-11, with the switch freshly enumerated (kernel
log at 172 s: `pci 0000:b1:00.0: BAR 0: assigned [mem 0xe0e00000-0xe0e003ff 64bit]`).
It is the PCIe IP's BAR encoding, as read from Vivado 2021.2's
`pcie_versal_v1_0/xgui/pcie_versal_v1_0.tcl` (`calc_Aperture_Size_for_PF_Bars`):

- The IP writes an aperture code n to the hard block. For an endpoint (Type 0
  header) the block decodes it as 2^(n+7) bytes.
- For a root port the IP adds 5 to n, and for byte sizes uses n = log2(size) − 2.
  That means a bridge (Type 1 header) decodes n as 2^(n+2) bytes.
- The upstream switch port is a Type 1 header too (class 0604), but the IP adds
  the 5 only for `Root_Port_of_PCI_Express_Root_Complex`. So 32 KB becomes
  n = 8 (`PF0_BAR0_APERTURE_SIZE 6'h08` in the generated netlist), which the
  block decodes as 2^(8+2) = 1 KB. Every size is 32 times too small.

The fix, in `pips.tcl` since `e389cca`: on `pcie_versal_upstream_port`, ask for
1 MB to get 32 KB, i.e. n = 13 (2^(13+2) = 32 KB). It gave `[size=32K]` on
bigserver on 2026-10-11.

```tcl
   CONFIG.pf0_bar0_scale {Megabytes} \
   CONFIG.pf0_bar0_size {1} \
```

On a build without it the tools stop at the size check without touching BAR0.
A 1 KB mapping covers only BRAM 0x000–0x3FF, not the registers. One trace of
the 1 MB setting remains: the CQ descriptor reports BAR aperture 20 (1 MB), not
15 (test point 8).

The BAR0 size in `lspci` and sysfs is what the kernel measured when it last
enumerated the switch. When it looks wrong, check when that was, and what it
measured:

```bash
uptime -s                                                   # host boot
sudo dmesg | grep -E 'b1:00.0: (\[10ee|reg 0x10|BAR 0)'      # 32 KB: [mem 0x...-0x...7fff 64bit]
```

## Order of work

```bash
# 0. FPGA programmed with a PIO build; the switch enumerated with BAR0 32K (above)
lspci -vv -d 10ee:b048 | grep 'Region 0'

# 1. Bring-up: enumeration, links, registers, BRAM, regfile, DMA, DDR, error path, empty log
sudo bash scripts/pips/pips-bringup.sh                 # [--soak 1000000] [--enable-mem]

# 2. One fio run on the NVMe drive(s) behind PIPS, with the TLP log recorded and collected
sudo bash scripts/pips/pips-fio-log.sh                 # [--dev /dev/nvme1n1] [-d 20] [--log-at 5]

# Single test points, by hand
cd scripts/pips && make                                # builds ./pips (the scripts do it too)
sudo ./pips info
sudo ./pips hwtest regfile                             # regfile write/read-back only
sudo ./pips cfg                                        # setting, drain cap, design_id, log_format
sudo ./pips cfg set depth=8 time=0x16                  # batcher config, read-modify-write
sudo ./pips cfg set cap=1                              # drain depth cap on (design 0x0a03 on)
sudo ./pips log-start; sleep 1; sudo ./pips log-stop; sudo ./pips log-dump log-id0a04.bin
python3 pips-log-decode.py log-id0a04.bin --csv log.csv   # the -id0a04 picks the v2 decoder
```

Both scripts keep everything in a new `utils/logs/<name>/` folder and never
overwrite one. Only one runs at a time (`/tmp/pips-run.lock`).

## Test points

| # | Test point | Command | Pass means |
|---|---|---|---|
| 1 | Enumeration | `pips-bringup.sh` §1 | USP `10ee:b048` with BAR0 32 KB and Mem+; both downstream ports (`b148`, `b348`); no link DEGRADED, i.e. below what both of its ends support (a Gen4 switch on a Gen3 root port is normal); one MaxPayload across the tree. Error bits are sticky since boot: compare before and after, as `pips-fio-log.sh` does |
| 2 | BAR0 registers | `pips hwtest regs` | `ID` = `0x50495053`, `VERSION` = `0x00020001`, `PIO_STATUS` 0, `SCRATCH` round trips, `MWR_COUNT`/`MRD_COUNT` count exactly, `BUS_NUM` matches config space |
| 3 | BAR0 BRAM | `pips hwtest bram`, `pips soak N` | 4/8/1-byte round trips at the PIO's known-bad offsets, aliases, unmapped reads 0; soak: no mismatch |
| 4 | Regfile R/W | `pips hwtest regfile`, `pips cfg [set ...]` | `WIN_BASE` round trip; reg0 at `0xA4000000` reads what XSCT `mrd 0xA4000000` reads; two patterns over every field write and read back, original restored; `DESIGN_ID` at +0x20 identifies the build (≥ 0x0A02, also printed by `pips cfg` with its log format) and ignores writes; from 0x0A03, reg1 (+0x04, drain config) takes `drain_depth_cap` flipped and back; the other registers read 0 (0x04–0x1C before 0x0A03, 0x08–0x1C from it); +0x40 repeats reg0 |
| 5 | Log DMA registers | `pips hwtest dma`, `pips dma` | registers answer; SGIncld 0; halted agrees with run/stop; `S2MM_DA` round trip (this is what confirms the PG021 offsets) |
| 6 | DDR | `pips hwtest ddr` | 4 KB at `0x10000000` (outside the log region) written and read back; alternating 16 KB pages; prints µs per access |
| 7 | Window errors | `pips hwtest err` | unmapped `0xB0000000`: `0xFFFFFFFF`, `WIN_STATUS` rd_err/wr_err, `WIN_ERR` = the address, clears with `0x1F`, window works afterwards |
| 8 | CQ split | `pips hwtest split`, `pips info` | BAR0 hits recorded. Whether forwarded TLPs report a different BAR ID or aperture decides PIO_KNOWLEDGE_MAP D4: on 2026-10-11 both reported BAR ID 0, aperture 20, so the split by address stays |
| 9 | Log smoke | `pips hwtest log` | an empty recording: DMA finishes, trailer at the end, `bytes = 16 × records + 16` |
| 10 | fio + log | `pips-fio-log.sh` | fio runs read-only; the recording closes (region full or log-stop); `log-id<XXXX>.bin` decodes, in its build's format, with no unexpected records; `PIO_STATUS` and `WIN_STATUS` stay 0; no new AER/DMAR lines |

`pips hwtest` runs 2–9 in order and stops at the first failing step. Steps
can be named to run alone or in any subset, e.g. `pips hwtest regs regfile`.

## The pips tool

`sudo ./pips [-s BDF] <command>`. The upstream port is found by ID unless
`-s` or `$PIPS_BDF` names it. The full command list is in the header of
[pips.c](pips.c). Lines `key=value` are for scripts and lines starting `#` are
notes. Exit status: 0 ok, 1 failed, 2 usage, 3 timeout.

| Command | What |
|---|---|
| `info` | every BAR0 register, decoded, then the build's `DESIGN_ID` and log format |
| `rd OFF [N]`, `wr OFF VAL` | raw BAR0, 32-bit |
| `axi-rd ADDR [N]`, `axi-wr ADDR VAL` | through the window; non-zero exit on an AXI error |
| `cfg`, `cfg set depth= time= mrd= log= raw= cap=` | the batcher/logger config register (`0xA4000000`) and, from design 0x0a03, the drain config (`0xA4000004`, `cap=` = `drain_depth_cap`; refused on older builds). Prints `cfg=...`, `drain=... drain_depth_cap=N` (`drain=none` before 0x0a03), `design_id=0x....` (or `none`), `log_format=v1\|v2` |
| `dma`, `dma-reset` | the log DMA's S2MM registers (`0xA4010000`) |
| `log-clear` | zero the log region, so later reads show where the DMA wrote |
| `log-start` | `log_enable` off, DMA (reset if needed) armed on `LOG_BASE`/`LOG_BYTES`, then `log_enable` on |
| `log-stop [MS]` | `log_enable` off, wait for the DMA, print the trailer |
| `log-wait [MS]` | wait for the DMA with the recording left on (region full) |
| `log-dump FILE [BYTES]` | the bytes the DMA wrote (`S2MM_LENGTH`), or `BYTES` of the region as it is |
| `ddr-dump ADDR BYTES FILE` | any DDR range |

It follows the access rules in the FPGA repo's `sw_handoff/README.md` §4. Every
access is a single aligned volatile 4- or 8-byte load or store, never memcpy.
`WIN_BASE` is rewritten only when the 16 KB page changes. A file lock
(`/tmp/pips-bar0.lock`) keeps two pips processes from fighting over
`WIN_BASE`.

**Recording sequence** (`log-start` / `log-stop`, from
`telemetry_dma_format.md` §7). The DMA is armed before `log_enable` rises, or
records are dropped. Recording starts on the edge, so `log-start` takes
`log_enable` low first. If the logger still holds the end of an earlier
recording, a freshly armed DMA takes it at once. `log-start` sees that,
reports the stale bytes and re-arms. Under fio load the 4 MiB region (262,143
TLPs) fills within milliseconds, so `pips-fio-log.sh` waits 5 s (`--log-at`)
to catch steady state.

## Decoding

`pips-log-decode.py log.bin [--csv F] [--json F] [--rpt F] [--scan] [--design-id ID]`,
Python 3 with the standard library only. It picks the record format from the
design ID (section "Design IDs" above) and says which and where from on its
second line. It prints per port (`in0` = downstream port one / `b348`, `in1` =
downstream port zero / `b148`, `out` = batched stream to the host) the TLP and
drop counts, the MRd/MWr split, MWr bytes and Gbps over the recording, TLPs
per µs, beats, and gap statistics. Saturated values (255) are counted apart.
Then the types, AT, payload sizes and address ranges.

- v1 (before 0x0a04): each port's own records; gaps per port; the CSV's `t_lb`
  is a per-port lower bound on time.
- v2 (0x0a04 on): every record is a TLP sent to the host. `in0`/`in1` are each
  input's TLPs as they left and `out` is all of them, so out = in0 + in1;
  gaps are the output's. Also the time each TLP spent in the batcher
  (`pkt_wait`: mean/p50/p99/max cycles and µs, saturated at 65535 counted
  apart), in the summary, the JSON and the `.rpt` (`pips_<port>_wait_*`). The
  CSV adds `wait`, `out_sop`, `in_sop` (the timeline of
  `telemetry_dma_format.md` §4.3, from the first record's output SOP = 0) and
  `seg`, which goes up after each saturated gap or dropped record, where later
  times become lower bounds.

A v1 log read as v2 comes out BAD (it has port-2 records); a v2 log read as v1
shows no `out` records and a NOTE saying so. `--scan` reads a region whose DMA
never finished: no trailer, so it walks the records until one was never
written. The fio script dumps the whole region and uses it when a recording
does not close.

Its first line says whether the recording is whole:

| Status | Meaning |
|---|---|
| `FULL` | it ran until the region filled: 262,143 TLPs and the trailer, exactly `LOG_BYTES` |
| `CUT` | it was ended (log_enable low) before the region filled |
| `+DROPS` | after either: TLPs lost to logger FIFO overflow, kept as empty records |
| `NO_TRAILER` | the recording never closed (the DMA did not finish) |
| `BAD` | the dump and its trailer disagree (exit status 1) |

All three analysis tools below read logs with the decoder's loader, so they
take either format, find the design ID the same way, take `--design-id` to
override it, and name it in their output (a `design` column, JSON
`design_id`/`log_format`, CSV first line). In folders they find
`pips-log.bin(.gz)` and `pips-log-id<XXXX>.bin(.gz)`.

**Address pattern.** `pips-addr-pattern.py LOG|FOLDER ... [--match GLOB] [--jsonl F]`
reads dumps, or every log under sweep log folders. Per log: each drive's TLPs
by class (data, completion entry, interrupt, read) and per I/O; the share of
addresses at or above 4 GiB; distinct 4 KiB pages and 2 MiB / 1 GiB regions;
IOVA reuse; which drive each `out` TLP came from, runs of one drive and how
long a TLP was held in the batcher; LRU reuse distance on `out` and the IOTLB
misses per I/O it predicts for sizes 16–1024. In a v1 log each `out` TLP is
matched to its `in` record by per-channel order and the hold is the records in
between; in a v2 log the record names its drive and the hold is its
`pkt_wait`. Tested on synthetic logs only so far.

```bash
python3 scripts/pips/pips-addr-pattern.py utils/logs/dualssd-pips-strict-1-d1t0 \
    utils/logs/dualssd-pips-strict-1-d16t64 --match '4k-j*' --jsonl ~/addr.jsonl
```

**Page sequence and batching what-if.** `pips-page-seq.py LOG` takes one dump
and shows the order in which pages are asked for. First, per stream (`in0`,
`in1`: each drive as it sends; `out`: what the IOMMU sees), how a page's
writes are spread: TLPs per run of one page, the share of page visits written
in one run, and how many pages a drive writes at once. Then a what-if on
`out`: cut into windows of W TLPs and regrouped by drive (what a per-drive
batcher can do), by page between completion entries (needs relaxed ordering),
or by page ignoring ordering (the bound). It gives runs per I/O, distinct pages
per window and the wait each W costs. `--iotlb 1x64,16x4 --strict` adds
simulated IOTLB misses per I/O for those geometries (sets x ways; the real
one is not published). `--show N --from REC --port out` prints the sequence
run by run; `--csv` writes every TLP. Use a d1t0 log for the unbatched order.
In a v2 log `in0`/`in1` are each drive's TLPs in the order they left, which is
the order it sent them within each batching FIFO. `--kind nic` (the default
when the path contains `dualnic`) reads a NIC log: writes of up to 16 DW (the
NIC's 64-byte completions) are the I/Os instead of 4 DW NVMe completion
entries, and a packet's page visit ends at its NIC's next completion, since a
4,032-byte packet (7 × 128 DW + 112 DW) never fills its 4 KiB page. Tested on
synthetic logs (`make check`).

```bash
python3 scripts/pips/pips-page-seq.py \
    utils/logs/dualssd-pips-strict-1-d1t0/4k-j8-both-RUN-0/pips-log.bin.gz \
    --iotlb 1x64,16x4,64x1 --strict --show 200 --from 100000
```

**Page order for a whole sweep.** `pips-seq-grab.sh ssd|nic` runs
`pips-page-seq.py --json --show 600 --from 100000 --iotlb 1x64,16x4,64x1`
(plus `--strict` on strict sweeps) on one log per point and batcher setting,
4 at a time, and packs the reports, one JSON line per log and a manifest into
`~/seq-<sweep>.tar.gz`: what the report's page-sequence and batching what-if
figures are built from. Defaults are the 0x0A04 sweeps' eight settings and 7
drive points (4k at j8, j16, j32; 16k, 64k, 1m at j8; 1m at j16) or 5 NIC
points (both NICs at f5, f15, f30; NIC0 alone at f5, f30); `--sweep`,
`--sets`, `--points` choose others, e.g. the 0x0A02 sweeps. A 4k point whose
run was dropped for missing `pcm-iio` rows still has its log and is used.

```bash
bash scripts/pips/pips-seq-grab.sh ssd          # bigserver, ~/seq-dualssd-pips-strict-1-id0a04.tar.gz
bash scripts/pips/pips-seq-grab.sh nic          # icx, ~/seq-dualnic-pips-strict-1-id0a04.tar.gz
bash scripts/pips/pips-seq-grab.sh ssd --sweep dualssd-pips-strict-1 --sets "d1t0 d16t64" --points 4k-j8-both
```

**Write sizes: can a completion entry be told by its size?**
`pips-mwr-sizes.py LOG|FOLDER ... [--match GLOB] [--by iommu,bs] [--detail] [--csv F]`
maps every drive write by payload DWORDs, per drive. The other two tools call a
non-MSI write of at most 4 DW a completion entry, and this checks that rule
without using the size: per size, whether `payload_dw` agrees with the beats,
alignment, distinct pages, whether those pages also take writes from the other
side of the limit (`mixed`: a completion queue page should take only entries),
and how often an interrupt follows directly. Per drive and log: data bytes per
completion entry against the block size, interrupts per entry, odd sizes.
Each log is labelled with its IOMMU mode (`sweep.log`), batcher setting with
`c1` for the drain cap, and design ID (`pips-cfg.txt`, else the sweep name).
`--by` also takes `design`. `--show N --port in1` prints one log's sizes in
order, run-length coded (`64x16 4 1i` = a 4 KiB page, its entry, its
interrupt). Tested on synthetic logs only so far.

```bash
python3 scripts/pips/pips-mwr-sizes.py utils/logs/dualssd-pips-off-1-d1t0 \
    utils/logs/dualssd-pips-strict-1-d1t0 --by iommu,bs --csv ~/mwr-sizes.csv
python3 scripts/pips/pips-mwr-sizes.py utils/logs/dualssd-pips-strict-2-id0a04-d8t22 \
    utils/logs/dualssd-pips-strict-2-id0a04-d8t22c1 --by cfg,bs     # cap off against on
```

**Payload or control, by size? On every log.** `pips-traffic.py [PATH ...]`
(default: everything under `utils/logs`) reads every sweep and fio-log trace,
both formats, both drives and NICs, and prints a line as each log is done. Per
device it classes each write by address behaviour: `ring` (a page written as a
ring of fixed-size entries, a few per visit, each visit continuing where the
last ended: completion entries, descriptor write-backs), `payload` (pages
filled in multi-write bursts), `msi`, or `unclear`. It then finds the size
threshold that best splits ring from payload and how often size and address
agree (RELIABLE at ≥ 99.9%). It also reports the length pattern: the payload
sent before each group of ring writes, run-length coded (`64x16 -> 1` = 4 KiB
then one NVMe entry, `64x15 40 -> 1` = a 4000 B packet then one entry), bytes,
interrupts and reads per ring write, and on v2 logs the time each class spent
in the batcher. End tables are summed `--by kind,design,iommu,cfg` (also
`load`, `mode`, `sweep`, `run`, `all`), then a verdict per kind and design.
`--csv`/`--jsonl` keep every log's numbers; `-j N` decodes N logs at a time
(default 4). Doorbells are host-to-device writes and are never in the log, so
"control" here means what the devices write to signal the host. Unlike
`pips-mwr-sizes.py` it assumes no sizes, so it works for NICs too. Tested on
synthetic NVMe and NIC traffic only so far.

```bash
python3 scripts/pips/pips-traffic.py --csv ~/traffic-sizes.csv --jsonl ~/traffic.jsonl | tee ~/traffic.txt
python3 scripts/pips/pips-traffic.py --format v2 --by kind,design,iommu,cfg,load    # new logs, per load
python3 scripts/pips/pips-traffic.py utils/logs/dualnic-pips-strict-1-id0a04-d8t22c1-uncapped-f5-both-RUN-server-0 --detail
```

## Sweeps with the log: one sweep per batcher setting, cap off and on

```bash
sudo -v
# drives: the dual-SSD cross sweep per setting (bigserver)
DUALSSD_ARGS="--membw 0" ./scripts/sosp24-experiments/dualssd_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64" --tmux
# NICs: the dual-NIC flow sweep per setting (the server whose NICs are behind PIPS)
./scripts/sosp24-experiments/dualnic_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64" --single --tmux
```

For each `DEPTH:TIME[:MRD]` setting, in order, and each `--caps` value (default
`"0 1"`: drain depth cap off, then on, which doubles the runs), it sets the
batcher through BAR0. It then runs the whole sweep: for the drives the dual-SSD
cross sweep with the uneven co-runs (`--asy`), for the NICs the dual-NIC flow
sweep (flows x rates x modes). Each is named `<NAME>-id<XXXX>-d<DEPTH>t<TIME>[m1][c1]`,
e.g. `dualssd-pips-strict-2-id0a04-d8t22c1`. At the end it puts the original
setting and cap back. Cap 1 needs design 0x0a03 or later: on an older build
the sweep refuses to start unless given `--caps 0`.

Every run records a TLP log (`run-dualssd-experiment.sh` /
`run-dualnic-experiment.sh --pips-log 1`):
- the log region is zeroed before the load starts;
- the recording starts once the load is steady (after fio's warm-up, or once
  the iperf3 senders run) and runs until the region fills, milliseconds under
  load, cut after 5 s;
- it is dumped after the measurement windows. No BAR0 access overlaps a
  measurement window.

Each run's folder keeps `pips-log-id<XXXX>.bin.gz` (the whole recording),
`pips-log-summary.txt/.json` and `pips-cfg.txt`. Its report folder keeps
`pips-log.rpt` with the status above, or `FAILED` when there is no log.

`~/<NAME>.txt` starts with `design_id=`, then has every setting side by side,
rows labelled `off d8t22c1@0a04` and so on, and the PIPS log table with the
time in the batcher (v2 logs). It flags each configuration whose runs were not
all `FULL` and counts each status. The sweep ends by printing that check again.
Results from other settings or builds never mix: `dualssd-results.py` and
`dualnic-results.py` group by IOMMU mode plus setting plus design ID.

Runs whose drives or NICs are behind PIPS record the design ID and setting
even without `--pips-log` (`pips-cfg.txt` per run, `pips_design_id` and
`pips_batch` in the JSONL).

## Without the host path: XSCT

`pips-xsct.tcl` has the same config, DMA and log procedures over JTAG
(`pips_connect`, `pips_cfg`, `pips_cfg_set` with `cap`, `pips_design`,
`pips_dma`, `pips_log_start`, `pips_log_stop`, `pips_log_dump`). `pips_cfg`
prints the same `drain=`, `design_id=` and `log_format=` lines as `pips cfg`;
`pips_log_dump` reminds you to name the file `*-id<XXXX>.bin` (or pass
`--design-id` to the decoder). Use it when BAR0 does not answer, or to
cross-check the host. The log region is hard-coded there (XSCT cannot read
BAR0), so keep it in step with `pips.tcl`. Not run since the cap and design
ID procedures were added.

## Testing without hardware

```bash
cd scripts/pips && make check
```

Builds `pips-sim`, which is `pips.c` linked against [pips_sim.c](pips_sim.c),
a model of BAR0. The model covers the registers, BRAM and aliases, the window
and its errors, the regfile with the drain config, the DMA in direct register
mode, DDR, and a logger. `PIPS_SIM_DESIGN` picks the build it plays (default
`0x0a04`; `0x0a02`, `0x0a03`, `none`): its design ID, whether reg1 exists, and
the record format it logs. [test-sim.sh](test-sim.sh) then drives every
command, including region-full, stale-tail and DMA-error recovery, on the
current build and the older ones; runs the decoder and the three analysis
tools on v1 and v2 logs, with the design ID found from the file name, a
`pips-cfg.txt`, or nowhere; `pips-traffic.py` on synthetic NVMe and NIC
traffic (entries posted singly and back to back, packets' data interleaved,
a v1 log, a cut `.gz`); the runners' PIPS hooks (`pips-lib.sh`); both
results scripts; `pips-fio-log.sh` with a stand-in fio; and both PIPS sweeps
with stand-in sweeps under them. The model does not cover timing, AXI timeouts
or the PIO's own limits.

## Sources of truth

| What | Where |
|---|---|
| BAR0 map, window, access rules | FPGA repo `sw_handoff/README.md`, `src/pio_pips/pips_pio.v` |
| [pips_regs.h](pips_regs.h) | verbatim copy of the FPGA repo's `sw_handoff/pips_regs.h`: re-copy it when the map changes (last: 10-15, design 0x0a04). `sw_handoff/` is git-ignored in the FPGA repo, so check its file dates, not its log |
| Log region, regfile bit fields, DMA config, design ID | FPGA repo `pips.tcl` (`pips_log_*`, `xlslice_0..3`, `axi_dma_log`, `pips_design_id`); drain config: `sw_handoff/README.md` §6 |
| Log record format, recording lifecycle | AXI4-switch repo `telemetry_dma_format.md` §4–§7 (v2; the v1 differences are its §4.2 note "Changed from the earlier format") |
| What each logged field means | AXI4-switch repo `axi4_telemetry_decode.md` §4, §8 |

## First hardware run (bigserver, 2026-10-11)

The build had `e389cca`'s 32 KB BAR0 and 16-register regfile (its design ID
was not yet printed). IOMMU off, both drives behind PIPS.

- `pips-bringup.sh`: every step passed. The S2MM register offsets (PG021) held:
  the `S2MM_DA` round trip, DMASR bits, and a recording end to end.
- Window cost: 0.16 µs per 32-bit write, 0.89 µs per read (DDR). `log-clear`
  took 0.18 s and a full 4 MiB `log-dump` 0.83 s.
- `pips-fio-log.sh` with the defaults: 1.62M IOPS, 6.64 GB/s, the shared Gen3 x8
  uplink's ceiling (HANDOFF §7: 1.64M with the IOMMU off). The region filled
  in 4.4 ms: 262,143 records, none dropped. `out` carried 53.9 Gbps of MWr
  payload, in0 and in1 about half each.
