# PIPS host bring-up

Test points for PIPS, the VCK190 PCIe switch, run from the host it is plugged
into. Everything goes through the switch's upstream port BAR0 (`10ee:b048`):
the BAR0 registers and BRAM, and an AXI window behind them that reaches the
batcher/logger config register (the regfile), the log DMA and the FPGA DDR
where the DMA writes the TLP log.

None of this has run on hardware yet. It is tested against a software model
of BAR0 (`make check`, below), so the first hardware run is also the first
check of the model's assumptions.

## Which bitstream

These tests need a build with the host register block (the PIO): FPGA repo
`pips_batch` at `af165d6` or later. Nothing in config space tells it from an
older build: device `10ee:b048`, subsystem `0007` and the 32 KB BAR0 are the
same in every build. Only the `ID` register at BAR0+0x800 does, and the tools
read it first. On a build without the PIO that first read is forwarded to the
device on downstream port one (PIO_KNOWLEDGE_MAP D6) and fails. So know which
image is loaded before running.

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
sudo ./pips cfg set depth=8 time=0x16                  # batcher config, read-modify-write
sudo ./pips log-start; sleep 1; sudo ./pips log-stop; sudo ./pips log-dump log.bin
python3 pips-log-decode.py log.bin --csv log.csv
```

Both scripts keep everything in a new `utils/logs/<name>/` folder and never
overwrite one. Only one runs at a time (`/tmp/pips-run.lock`).

## Test points

| # | Test point | Command | Pass means |
|---|---|---|---|
| 1 | Enumeration | `pips-bringup.sh` §1 | USP `10ee:b048` with BAR0 32 KB and Mem+; both downstream ports (`b148`, `b348`); no link DEGRADED, i.e. below what both of its ends support (a Gen4 switch on a Gen3 root port is normal); one MaxPayload across the tree. Error bits are sticky since boot: compare before and after, as `pips-fio-log.sh` does |
| 2 | BAR0 registers | `pips hwtest regs` | `ID` = `0x50495053`, `VERSION` = `0x00020001`, `PIO_STATUS` 0, `SCRATCH` round trips, `MWR_COUNT`/`MRD_COUNT` count exactly, `BUS_NUM` matches config space |
| 3 | BAR0 BRAM | `pips hwtest bram`, `pips soak N` | 4/8/1-byte round trips at the PIO's known-bad offsets, aliases, unmapped reads 0; soak: no mismatch |
| 4 | Regfile R/W | `pips hwtest regfile`, `pips cfg [set ...]` | `WIN_BASE` round trip; reg0 at `0xA4000000` reads what XSCT `mrd 0xA4000000` reads; two patterns over every field write and read back, original restored; `DESIGN_ID` at +0x20 identifies the build (≥ 0x0A02, also printed by `pips cfg`) and ignores writes; the other registers read 0; +0x40 repeats reg0 |
| 5 | Log DMA registers | `pips hwtest dma`, `pips dma` | registers answer; SGIncld 0; halted agrees with run/stop; `S2MM_DA` round trip (this is what confirms the PG021 offsets) |
| 6 | DDR | `pips hwtest ddr` | 4 KB at `0x10000000` (outside the log region) written and read back; alternating 16 KB pages; prints µs per access |
| 7 | Window errors | `pips hwtest err` | unmapped `0xB0000000`: `0xFFFFFFFF`, `WIN_STATUS` rd_err/wr_err, `WIN_ERR` = the address, clears with `0x1F`, window works afterwards |
| 8 | CQ split | `pips hwtest split`, `pips info` | BAR0 hits recorded. Whether forwarded TLPs report a different BAR ID or aperture decides PIO_KNOWLEDGE_MAP D4: on 2026-10-11 both reported BAR ID 0, aperture 20, so the split by address stays |
| 9 | Log smoke | `pips hwtest log` | an empty recording: DMA finishes, trailer at the end, `bytes = 16 × records + 16` |
| 10 | fio + log | `pips-fio-log.sh` | fio runs read-only; the recording closes (region full or log-stop); `log.bin` decodes with no unexpected records; `PIO_STATUS` and `WIN_STATUS` stay 0; no new AER/DMAR lines |

`pips hwtest` runs 2–9 in order and stops at the first failing step. Steps
can be named to run alone or in any subset, e.g. `pips hwtest regs regfile`.

## The pips tool

`sudo ./pips [-s BDF] <command>`. The upstream port is found by ID unless
`-s` or `$PIPS_BDF` names it. The full command list is in the header of
[pips.c](pips.c). Lines `key=value` are for scripts and lines starting `#` are
notes. Exit status: 0 ok, 1 failed, 2 usage, 3 timeout.

| Command | What |
|---|---|
| `info` | every BAR0 register, decoded |
| `rd OFF [N]`, `wr OFF VAL` | raw BAR0, 32-bit |
| `axi-rd ADDR [N]`, `axi-wr ADDR VAL` | through the window; non-zero exit on an AXI error |
| `cfg`, `cfg set depth= time= mrd= log= raw=` | the batcher/logger config register (`0xA4000000`) |
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

`pips-log-decode.py log.bin [--csv F] [--json F] [--scan]`, Python 3 with the
standard library only. It prints per port (`in0` = downstream port one /
`b348`, `in1` = downstream port zero / `b148`, `out` = batched stream to the
host) the TLP and drop counts, the MRd/MWr split, MWr bytes and Gbps over the
recording, TLPs per µs, beats, and gap statistics. Saturated values (255) are
counted apart. Then the types, AT, payload sizes and address ranges. `--scan`
reads a region whose DMA never finished: no trailer, so it walks the records
until one was never written. The fio script dumps the whole region and uses it
when a recording does not close.

Its first line says whether the recording is whole:

| Status | Meaning |
|---|---|
| `FULL` | it ran until the region filled: 262,143 TLPs and the trailer, exactly `LOG_BYTES` |
| `CUT` | it was ended (log_enable low) before the region filled |
| `+DROPS` | after either: TLPs lost to logger FIFO overflow, kept as empty records |
| `NO_TRAILER` | the recording never closed (the DMA did not finish) |
| `BAD` | the dump and its trailer disagree (exit status 1) |

## Sweeps with the log: one cross sweep per batcher setting

```bash
sudo -v
DUALSSD_ARGS="--membw 0" ./scripts/sosp24-experiments/dualssd_pips_sweep.sh --cfgs "1:0 4:22 8:22 16:64" --tmux
```

For each `DEPTH:TIME[:MRD]` setting, in order, it sets the batcher through
BAR0. It then runs the whole dual-SSD cross sweep with the uneven co-runs
(`--asy`), named `<NAME>-d<DEPTH>t<TIME>`. At the end it puts the original
setting back.

Every run records a TLP log (`run-dualssd-experiment.sh --pips-log 1`):
- the log region is zeroed before fio starts;
- the recording starts after the warm-up and runs until the region fills,
  milliseconds under load, cut after 5 s;
- it is dumped after fio stops. No BAR0 access overlaps a measurement window.

Each run's folder keeps `pips-log.bin.gz` (the whole recording),
`pips-log-summary.txt/.json` and `pips-cfg.txt`. Its report folder keeps
`pips-log.rpt` with the status above, or `FAILED` when there is no log.

`~/<NAME>.txt` has every setting side by side, rows labelled `off d8t22` and so
on, and the PIPS log table. It flags each configuration whose runs were not all
`FULL` and counts each status. The sweep ends by printing that check again.
Results from other settings never mix: `dualssd-results.py` groups by IOMMU
mode plus setting.

## Without the host path: XSCT

`pips-xsct.tcl` has the same config, DMA and log procedures over JTAG
(`pips_connect`, `pips_cfg`, `pips_cfg_set`, `pips_dma`, `pips_log_start`,
`pips_log_stop`, `pips_log_dump`). Use it when BAR0 does not answer, or to
cross-check the host. The log region is hard-coded there (XSCT cannot read
BAR0), so keep it in step with `pips.tcl`.

## Testing without hardware

```bash
cd scripts/pips && make check
```

Builds `pips-sim`, which is `pips.c` linked against [pips_sim.c](pips_sim.c),
a model of BAR0. The model covers the registers, BRAM and aliases, the window
and its errors, the regfile, the DMA in direct register mode, DDR, and a
logger. [test-sim.sh](test-sim.sh) then drives every command, including
region-full, stale-tail and DMA-error recovery, and runs the decoder and
`pips-fio-log.sh` with a stand-in fio. The model does not cover timing, AXI
timeouts or the PIO's own limits.

## Sources of truth

| What | Where |
|---|---|
| BAR0 map, window, access rules | FPGA repo `sw_handoff/README.md`, `src/pio_pips/pips_pio.v` |
| [pips_regs.h](pips_regs.h) | verbatim copy of the FPGA repo's `sw_handoff/pips_regs.h`: re-copy it when the map changes |
| Log region, regfile bit fields, DMA config | FPGA repo `pips.tcl` (`pips_log_*`, `xlslice_0..3`, `axi_dma_log`) |
| Log record format, recording lifecycle | AXI4-switch repo `telemetry_dma_format.md` §4–§7 |
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
