# PIPS PIO manual

Everything known about reaching PIPS from the host it is plugged into: BAR0,
the AXI window behind it, the batcher/logger config register, the log DMA,
and the TLP log in FPGA DDR. It covers what the hardware does, how to drive
it, what has been measured, and what can go wrong.

This is a local copy, so the test hosts have it without the Windows-side
repos. It collects and summarises:

- the FPGA repo's `PIO_KNOWLEDGE_MAP.md`, `sw_handoff/README.md`,
  `BRINGUP_HANDOFF.md` and `pips.tcl`;
- the AXI4-switch repo's `telemetry_dma_format.md`, `axi4_telemetry_decode.md`
  and `axi4_mwr_batch.v`;
- the standalone PIO repo's `MVP_MAP.md`;
- the hardware runs on bigserver on 2026-10-11.

Section 16 lists where each part came from. **If this file and those disagree,
those win.** Update this file when they change.

As of 2026-10-15: FPGA repo `pips_batch` at `591d854`, design ID `0x0A04`,
BAR0 map v2.1. Since `0x0A02` (2026-10-12) two things changed that the host
sees: the batcher's **drain depth cap** (regfile reg1, from `0x0A03`, §6) and
the **TLP log record format v2** (from `0x0A04`, §8). Logs and results from
before keep their old meaning; the design ID tells them apart (§6, "Design
ID"). "PIO" means programmed I/O: host loads and stores to a BAR. The tools
are described in [README.md](README.md).

---

## 1. At a glance

| | |
|---|---|
| Path | Host → upstream port BAR0 (`10ee:b048`) → PIO in the FPGA → registers, 2 KB BRAM, and a 16 KB window onto an AXI4-Lite bus |
| Behind the window | `0xA400_0000` regfile (batcher/logger config, drain config, design ID), `0xA401_0000` log DMA registers, `0x0000_0000–0x7FFF_FFFF` DDR4 |
| BAR0 | 64-bit, non-prefetchable, **32 KB**. The IP is set to "1 MB" to get this (§11.1) |
| Identity | BAR0 `+0x800` reads `0x5049_5053` ("PIPS"); `+0x804` reads `0x0002_0001` (map v2.1); regfile `+0x20` reads the design ID (`0x0A04` now) |
| TLP log | 16-byte records, 4 MiB region at DDR `0x0` = 262,143 records + trailer. v2 (design `0x0A04` on): one record per TLP sent to the host, tagged with its input and its time in the batcher. v1 (before): records for 3 ports (in0, in1, out). Under full load it fills in ~4.4 ms (v1) |
| No | interrupts, host DMA, or bulk data path. Everything is polled, one TLP at a time |
| Status | Working on hardware: bring-up, regfile, DMA, DDR, error path, and a full recording under fio (bigserver, 2026-10-11) |

---

## 2. What the host sees

PIPS enumerates as a PCIe switch: one upstream port (USP) with two downstream
ports (DSPs) below it. All are vendor `0x10EE`, class `0x060400` (PCI bridge).

| Function | Device ID | Notes |
|---|---|---|
| Upstream port | `0xB048`, subsystem `0x0007` | owns BAR0: everything in this manual |
| Downstream port zero | `0xB148` | no BAR; log port **in1** |
| Downstream port one | `0xB348` | no BAR; log port **in0** |

None of these IDs differs between builds, so config space cannot tell an
image with the PIO from one without. Only the `ID` register at BAR0+0x800
does, and the design ID behind the window.

On bigserver (2026-10-11):

```
b0:00.0 root port (Gen3 x16) ── b1:00.0 USP (Gen3 x8: the root port's limit)
                                  ├─ b2:00.0 DSP one  (b348) ── b3:00.0 Samsung 9100 PRO   nvme0  Gen4 x4
                                  └─ b2:01.0 DSP zero (b148) ── b4:00.0 Samsung 990 EVO Plus nvme1 Gen4 x4
```

Both drives sit behind the Gen3 x8 uplink, ~63 Gbps raw and ~54 Gbps of
write payload. The BDFs can change with a rebuild or re-enumeration; find
the USP with `lspci -D -d 10ee:b048`.

**Mapping BAR0.** Use `/sys/bus/pci/devices/<USP>/resource0`:
`open(O_RDWR | O_SYNC)`, then `mmap(0x8000, PROT_READ|PROT_WRITE, MAP_SHARED)`.
This is an uncached mapping; never use `resource0_wc`. It needs root. The
`pcieport` driver bound to the USP does not claim the BAR.

- `Mem-` in `lspci`: `setpci -s <USP> COMMAND=0x02:0x02`.
- Region 0 `<unassigned>`: boot with `pci=realloc`.

**After re-programming the FPGA**, the kernel must enumerate the switch again.
The `[size=…]` `lspci` prints is what the kernel measured at enumeration, not
a live read. Two ways:

- **Preferred:** reboot the host with the FPGA kept powered and programmed, so
  the firmware assigns space.
- Remove the USP and rescan:
  `echo 1 > /sys/bus/pci/devices/<USP>/remove; echo 1 > /sys/bus/pci/rescan`.
  This detaches the drives behind the switch, and a bigger BAR may not fit
  where a smaller one sat (dmesg `no space`). Then reboot or use `pci=realloc`.

The FPGA follows a moved BAR by itself within ~16 µs (§9.1).

**Driver hazard.** `lspci` lists `qdma_pf` as a possible driver for `10ee:b048`,
because b048 is Xilinx's default Gen4 x8 ID. `pcieport` owns it today. If
`qdma_pf` were ever loaded and bound first, it would take the switch. A
PIPS-specific device ID would avoid this, and would need `pips_regs.h` and the
tools' ID check updated.

---

## 3. BAR0 map (v2.1)

| Offset | What |
|---|---|
| `0x0000–0x07FF` | BRAM, 2 KB scratch memory (link tests) |
| `0x0800–0x087F` | registers (below) |
| `0x0880–0x0FFF` | read 0, writes ignored |
| `0x1000–0x3FFF` | aliases of `0x0000–0x0FFF` (do not use) |
| `0x4000–0x7FFF` | **AXI window**: AXI address = `WIN_BASE + (offset − 0x4000)` |

Offset bit 14 selects the window; below it, bit 11 selects BRAM (0) or
registers (1), and bits 13:12 are ignored (hence the aliases).

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `0x800` | `ID` | RO | `0x5049_5053` ("PIPS"). Check first |
| `0x804` | `VERSION` | RO | `0x0002_0001`: `[31:16]` major 2, `[15:0]` minor 1. Refuse another major; `LOG_*` need minor ≥ 1 |
| `0x808` | `SCRATCH` | RW | free |
| `0x80C` | `BUS_NUM` | RO | `[7:0]` primary, `[15:8]` secondary, `[23:16]` subordinate bus, as the switch's routing table captured them. Must match the USP's config space (`0x18–0x1A`) |
| `0x810` | `CQ_SPLIT` | RO | debug, §9.2: `[5:0]` aperture, `[10:8]` BAR ID of the last BAR0 TLP, `[15]` seen; `[21:16]`, `[26:24]` the same for the last memory TLP forwarded to the drives, `[31]` seen |
| `0x814` | `MWR_COUNT` | RO | BAR0 writes received (wraps) |
| `0x818` | `MRD_COUNT` | RO | BAR0 reads received, including the read that returns it |
| `0x81C` | `PIO_STATUS` | RO | `[0]` completion FIFO overflow, sticky. Must stay 0 |
| `0x820`, `0x824` | `MEM_BASE`, `MEM_LIMIT` | RO | downstream port one's memory window, as the routing table holds it (debug) |
| `0x828–0x834` | `PF_BASE_LO/HI`, `PF_LIMIT_LO/HI` | RO | its prefetchable window (debug) |
| `0x840–0x85C` | `CTRL0–CTRL7` | RW | general purpose, **not connected to anything yet** |
| `0x860`, `0x864` | `WIN_BASE_LO`, `_HI` | RW | AXI address of BAR0+0x4000. `LO[1:0]` read 0 |
| `0x868` | `WIN_STATUS` | RW1C | sticky, write 1 to clear: `[0]` AXI read error, `[1]` AXI write error, `[2]` AXI timeout, `[3]` read past its 64-byte block, `[4]` access dropped (AXI busy after a timeout). Live: `[8]` AXI busy |
| `0x86C`, `0x870` | `WIN_ERR_LO`, `_HI` | RO | AXI address of the last failed window access |
| `0x874`, `0x878` | `LOG_BASE_LO`, `_HI` | RO | DDR address of the log region (build constant; `_HI` = 0) |
| `0x87C` | `LOG_BYTES` | RO | log region size (4 MiB as built); 0 = this build has no log region |

All registers return to their reset values on every upstream link reset (hot
reset, link down): the PIO runs on the upstream port's `user_reset`.

Values on bigserver, 2026-10-11: `BUS_NUM 0x00b4b2b1` matched config space;
`MEM_BASE 0xe0c00000`, `MEM_LIMIT 0xe0c0ffff`.

---

## 4. Access rules

These come from bugs in the PIO engines (§9.3) and from how the window works.

1. **Only single, naturally aligned 4- or 8-byte `volatile` loads and stores.**
   4-byte is the safe default everywhere.
2. **No `memcpy`, `memset`, string functions, SIMD, or loops the compiler may
   vectorise on the mapping.** Below `0x4000`, one store larger than 48 bytes
   is silently corrupted (F2): a 16-DW write lands DW 12–15 on DW 3–6.
   Write-combining mappings and AVX-512 64-byte stores hit this.
3. **Keep each access inside one region:** never across `0x7FF/0x800` or
   `0x3FFF/0x4000`. The region is decided once per TLP.
4. **Window reads stay inside one aligned 64-byte block.** Aligned 4/8-byte
   loads always do. A longer read sets `WIN_STATUS[3]`, and the extra DWORDs
   read 0.
5. **An 8-byte access through the window is two separate 32-bit AXI
   transfers**, not atomic. Use 4-byte accesses for registers behind the window.
6. Reads are ordered behind earlier writes, so a read after a write to the
   same address returns the new value. `volatile` on x86 UC memory needs no
   other barrier.
7. **`0xFFFFFFFF` from a read** means one of two things:
   - the PCIe read failed (BAR wrong, link down, FPGA not programmed, image
     without the PIO); `ID` then also reads `0xFFFFFFFF`;
   - or a window access failed; `WIN_STATUS` is then non-zero.
8. **One user at a time.** `WIN_BASE` is shared state, and the FPGA handles one
   TLP at a time. Do not multi-thread BAR0 without a lock (the `pips` tool
   holds `/tmp/pips-bar0.lock`).
9. Reads that cross a 64-byte boundary below `0x4000` take an engine path with
   a malformed completion end flag (F4). Aligned loads never do.

---

## 5. The AXI window

To reach AXI address `A`:

1. Write `WIN_BASE_LO` = `A & ~0x3FFF` (any 4-byte-aligned base works, but a
   16 KB-aligned page is simplest), and `WIN_BASE_HI` = `A >> 32`.
2. Access BAR0 `0x4000 + (A − WIN_BASE)`.
3. Read `WIN_STATUS`: 0 means every window access since the last clear
   succeeded. Clear it with `0x1F`. On an error, `WIN_ERR_HI:LO` holds the
   failing address.

Rewrite `WIN_BASE` only when the 16 KB page changes.

| AXI address | Size | Target |
|---|---|---|
| `0xA400_0000` | 64 KB | `axil4_regfile_0` (§6) |
| `0xA401_0000` | 64 KB | `axi_dma_log`, AXI DMA register space, S2MM only (§7) |
| `0x0000_0000` | 2 GB | DDR4 through the NoC (`C0_DDR_LOW0`); the log is at `0x0` |
| anything else | | DECERR: reads return `0xFFFFFFFF`, `WIN_STATUS[0]` or `[1]` is set, `WIN_ERR` = the address |

These are the same addresses the Versal PS and XSCT use for the regfile and
DMA, so an address means the same from the host and over JTAG.

**Errors and hangs never wedge the PIO.** An AXI error response is recorded and
answered with `0xFFFFFFFF`.

If no response comes within 2^13 cycles (32.8 µs), the access is given up
(`WIN_STATUS[2]`, data `0xFFFFFFFF`). AXI cannot cancel a transfer, so the PIO
keeps waiting for the late response and discards it when it arrives.
Meanwhile further window accesses are dropped at once (`[4]`, with `[8]` busy).
BRAM and registers keep answering throughout, so the host can always diagnose.

**Cost.** Each 32-bit window access is one PCIe round trip plus one AXI transfer.
Measured on bigserver into DDR: 0.16 µs per write (posted) and 0.89 µs per read.
Zeroing the 4 MiB log region took 0.18 s, and reading it back 0.83 s.

**Side effect.** While the PIO holds a TLP, host-to-device requests for the
drives wait behind it for a few cycles (head-of-line, D7). Negligible for
occasional register access. The sweep keeps all BAR0 traffic out of its
measurement windows anyway.

---

## 6. The regfile at `0xA400_0000`

`axil4_regfile_0`: 16 registers in a 64-byte aperture. Only its low 6
address bits reach it, so the 64 bytes repeat every `0x40` through the 64 KB
segment (`0xA400_0060` is the design ID again). No address in the segment
returns DECERR.

| Offset | Access | Content |
|---|---|---|
| `0x00` | RW | **batcher/logger config** (reg0, below) |
| `0x04` | RW | **batcher drain config** (reg1, below), from design `0x0A03`. Before: reserved, reads 0, ignores writes |
| `0x08–0x1C` | RO | reserved, read 0. Can become read/write in a later build (`REG_RW_MASK`) |
| `0x20` | RO | **design ID**: `[15:0]` build identifier, `[31:16]` 0 |
| `0x24–0x3C` | RO | reserved, read 0 |

Writes to read-only registers are ignored with an OKAY response
(`WIN_STATUS` stays 0).

**Design ID.**
- Set in `pips.tcl` (`pips_design_id`), `0x0A02` first, +1 with every FPGA
  design update. Read it at startup and record it with every result: it is
  the only way to know which build is loaded, and it picks the log decoder.
- Builds older than `0x0A02` answer `+0x20` with DECERR (`0xFFFFFFFF`,
  `WIN_STATUS[0]`).
- XSCT reads the same value at `mrd 0xA4000020`. It is also ILA probe3 of
  `pips_control_plane/axis_ila_0` (probe4 is reg1).

| Design ID | FPGA repo | Change the host sees |
|---|---|---|
| none | before `e389cca` | no DESIGN_ID (DECERR); log v1 |
| `0x0A02` | `e389cca`, 10-11 | DESIGN_ID; log v1. The 10-13 dual-SSD PIPS sweeps ran on it |
| `0x0A03` | `2c6c3f5`, 10-14 | reg1 `drain_depth_cap`; log v1 |
| `0x0A04` | `591d854`, 10-15 | log record format v2 (§8.3) |

Every artifact the tools write carries the design ID: in the name for raw logs
(`pips-log-id0a04.bin.gz`) and sweeps (`<NAME>-id0a04-<setting>`), inside for
text (`design_id=` / `design_id:` lines, JSON fields). See
[README.md](README.md), "Design IDs".

**Config register (reg0).** Reset value `0x0000_0001`. Each field sits on its
own byte, and fields are always written with read-modify-write.

| Bits | Field | Meaning (from `axi4_mwr_batch.v`) |
|---|---|---|
| `[7:0]` | `depth_threshold` | release a batch once a batching FIFO holds this many **complete packets** (at least one) |
| `[15:8]` | `time_threshold` | ...or once the FIFO has been non-empty this many **clock cycles** (250 MHz, 4 ns each; 0–255 = 0–1.02 µs) |
| `[16]` | `batch_mrd` | 0: memory reads bypass batching (pass-through FIFO). 1: memory reads ride their channel's write FIFO, in order (`MRD_DEDICATED_FIFO` = 0 as built) |
| `[23:17]` | reserved | write 0 |
| `[24]` | `log_enable` | **a rising edge starts a TLP log recording**; low ends it (§8.5) |
| `[31:25]` | reserved | write 0 |

How the batcher uses it:
- Writes from each downstream port (in0, in1) go into that channel's batching
  FIFO.
- A FIFO drains when one of three triggers fires: the depth trigger, the
  timeout, or "full" (no room for another maximum-length packet).
- Requests of other types pass through a shared FIFO.
- The reset value (depth 1, time 0) releases every packet at once: no
  batching.
- How much one drain sends is reg1's `drain_depth_cap` (below).

**Drain config register (reg1, `0xA400_0004`), design `0x0A03` on.** Reset
value `0x0000_0000`. Same rule: read-modify-write, reserved bits written 0.

| Bits | Field | Meaning |
|---|---|---|
| `[0]` | `drain_depth_cap` | 0: a drain grant sends **every packet in the FIFO** when it starts (the snapshot), as every earlier build did. 1: a drain sends **at most `depth_threshold` packets** (a threshold of 0 counts as 1); the rest go in the next batch |
| `[31:1]` | reserved | write 0 |

- Safe to change at any time: a drain already running keeps the size it
  started with.
- Builds before `0x0A03` read 0 here and ignore writes, so check the design
  ID (or read the bit back) before relying on it. `pips cfg set cap=1` refuses
  on such a build; `pips cfg` prints `drain=none drain_depth_cap=0` there.
- With cap 1 and depth 1, each drain sends one packet: unlike cap 0, where a
  drain also takes whatever arrived while the previous one ran.
- Setting tags in result and sweep names add `c1` when it is on:
  `d8t22c1` = depth 8, time 0x16, cap on. No `c1` = cap off, which is also what
  every older tag (`d8t22`) meant.
- XSCT: `mwr 0xA4000004 1`.

**Old layout.** XSCT notes from before 2026-10-10 use an older layout, where
`batch_mrd` and `log_enable` sat inside `time_threshold`. The old `0x1608`
(depth 8, time 0x16, log on) is `0x0100_1608` now. XSCT and the host write the
same register; the last writer wins.

---

## 7. The log DMA at `0xA401_0000`

`axi_dma_log`, AXI DMA 7.1 (PG021). Build settings:
- direct register mode, no scatter-gather;
- S2MM (stream to memory) only;
- 32-bit addresses; buffer length field 26 bits; S2MM burst 256.

It writes the logger's 128-bit stream to DDR through the NoC. Its address
range is narrowed to exactly the log region, so a destination outside it ends
in a decode error, never a stray write.

| Offset | Register | Bits used |
|---|---|---|
| `0x30` | `S2MM_DMACR` | `[0]` RS run/stop, `[2]` soft reset (resets the whole DMA; clears itself) |
| `0x34` | `S2MM_DMASR` | `[0]` halted, `[1]` idle, `[3]` SG included (0 here), `[4]` internal error, `[5]` slave error, `[6]` decode error, `[12]` IOC (transfer complete, write 1 to clear), `[13]` delay IRQ, `[14]` error IRQ |
| `0x48` | `S2MM_DA` | destination: write `LOG_BASE_LO` |
| `0x58` | `S2MM_LENGTH` | write the region size: **this starts the transfer**. After completion it reads the bytes actually written |

These offsets are confirmed on hardware (2026-10-11). The `S2MM_DA` round trip,
the status bits and a full recording all behaved as PG021 says. After reset:
`DMACR = 0x0001_0002`, `DMASR = 0x0000_0001` (halted).

| DMASR | State |
|---|---|
| halted | reset or stopped: arm it with RS = 1 |
| not halted, not idle | a transfer is programmed and waits for stream data |
| idle + IOC | the transfer finished; `S2MM_LENGTH` = bytes written |
| `[6:4]` set | error: soft reset, then re-arm |

---

## 8. The TLP log

### 8.1 What it records

**v2, design `0x0A04` on.** One tap, on the batched output, through
`axi4_telemetry_logger`: one 16-byte record per TLP **as it left the batcher
toward the host**, in the order they left. Each record names the input the
TLP came in on (`port`) and how long it waited inside the batcher
(`pkt_wait`):

| Port | Input | On bigserver |
|---|---|---|
| `in0` (0) | requests from downstream port **one** (`b348`) | 9100 PRO, nvme0 |
| `in1` (1) | requests from downstream port **zero** (`b148`) | 990 EVO Plus, nvme1 |

There is no port 2. Each input's arrival order can be rebuilt from the same
records (§8.4), so nothing is lost by dropping the input taps, and the region
holds twice as many TLPs.

**v1, before `0x0A04`.** Three taps on the batcher, merged into one timeline:
`in0` (0) and `in1` (1) as above, and `out` (2), the batched stream sent up to
the host. Each TLP appears twice: once on its input, once on `out`.

Either way it sees the requests the devices behind the switch send towards
the host:
- memory writes: read data, NVMe completion-queue entries, interrupts (a
  NIC's receive data, descriptors and interrupts);
- memory reads: command fetches.

It records one 16-byte record per TLP, at the TLP's last beat. It does not see
host-to-device traffic (doorbells, the host's completions to the devices'
reads) or BAR0 accesses to the PIO.

### 8.2 The region

- Build constants in `pips.tcl`: `pips_log_ddr_base 0x0`,
  `pips_log_region_bytes 4194304` (4 MiB).
- Reported at BAR0 `LOG_BASE_*` and `LOG_BYTES`. Read them; never hard-code.
- 4 MiB = 262,144 slots of 16 bytes; one is kept for the trailer, so a
  recording holds at most **262,143 records**.
- Nothing else writes DDR: the PS has no DDR path in this design.
- The size can grow to about 64 MiB (the DMA's 26-bit length field) with a
  rebuild.

### 8.3 Record format (16 bytes, little-endian)

**Which format a log is in follows from the design ID of the build that wrote
it, and only from that**: the info byte and the trailer are the same in both,
so a v1 decoder reads a v2 log without error but with wrong tags. The tools
take the ID from the log's file name (`-id0a04`), else from a `pips cfg`
readout next to it, else read it as v1 (README, "Design IDs").

The info byte at offset `0x0E` is in every record:

| Bits | Field | Values |
|---|---|---|
| `[7]` | written | always 1; never-written memory reads 0 here |
| `[3:2]` | kind | 0 TLP, 1 dropped TLP, 2 trailer, 3 pad |
| `[1:0]` | port | 0 in0, 1 in1; v1 also 2 out (0 for trailer and pad) |

So TLP records have info `0x80–0x81` (v1 also `0x82`), dropped ones
`0x84–0x85` (`0x86`), the trailer `0x88`, and pads `0x8C`.

**TLP record, v2 (design `0x0A04` on):**

| Offset | Size | Field | Meaning |
|---|---|---|---|
| `0x00` | 8 | `pkt_addr` | byte address = descriptor `Address[61:0] << 2` |
| `0x08` | 1 | `pkt_length` | TLP length in 512-bit beats on the output, start to end; 1–255, 255 = ≥ 255 |
| `0x09` | 1 | `pkt_gap` | cycles between the previous TLP's end **on the output** and this one's start; 255 = ≥ 255 |
| `0x0A` | 1 | `pkt_type` | `[3:0]` PCIe request type: 0 MRd, 1 MWr, 2 IORd, 3 IOWr, 4 FetchAdd, 5 Swap, 6 CAS, 7 LockedRd, 8–B config, C Msg, D VendorMsg, E ATSMsg. `[5:4]` AT: 0 untranslated, 1 translation request, 2 translated |
| `0x0B` | 1 | `payload_dw` | MWr only: payload DWORDs, clamped at 255 (= ≥ 1020 B); 0 otherwise |
| `0x0C` | 2 | `pkt_wait` | u16: cycles from the TLP's start being accepted on its input to its start being accepted on the output, i.e. its time in the batcher; 65535 = ≥ 65535. Never 0 (at least ~4: FIFO and arbitration latency) |
| `0x0E` | 1 | info | `0x80` + port (its input) |
| `0x0F` | 1 | `pkt_tag` | descriptor tag |

**TLP record, v1 (before `0x0A04`):** the same up to `0x0B`, except `pkt_gap`
counts idle cycles **on this record's port** and `pkt_type` holds only the
type. Then `0x0C` `pkt_tag` (u8), `0x0D` `addr_type` (low 2 bits = AT), `0x0E`
info, `0x0F` always 0. No `pkt_wait`.

**Dropped-TLP record:** all bytes but the info byte are zero, info `0x84 | port`
(v2: the TLP's input). It takes the slot of a TLP whose record was lost.

**Pad record:** all zero except info `0x8C`. It appears only with a stream wider
than 128 bits; never as built.

**Trailer**, always the last record of a recording, in the last 16 bytes of the
DMA transfer:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | `n_records`: TLP + dropped records (not pads or the trailer) |
| `0x04` | 4 | `n_dropped` |
| `0x08` | 4 | `duration`: clock cycles from arm to stop, saturating (250 MHz) |
| `0x0C` | 1 | `stop_reason`: **1 = `log_enable` went low, 2 = region full** |
| `0x0E` | 1 | info `0x88` |

```c
typedef struct __attribute__((packed, aligned(16))) {      /* v2, design 0x0A04 on */
    uint64_t pkt_addr; uint8_t pkt_length, pkt_gap, pkt_type, payload_dw;
    uint16_t pkt_wait; uint8_t info, pkt_tag;
} tel_rec_t;
typedef struct __attribute__((packed, aligned(16))) {      /* v1, before 0x0A04 */
    uint64_t pkt_addr; uint8_t pkt_length, pkt_gap, pkt_type, payload_dw, pkt_tag, addr_type, info, rsvd;
} tel_rec_v1_t;
typedef struct __attribute__((packed, aligned(16))) {
    uint32_t n_records, n_dropped, duration; uint8_t stop_reason, rsvd0, info, rsvd1;
} tel_trailer_t;
#define TEL_KIND(r) (((r)->info >> 2) & 3)
#define TEL_PORT(r) ((r)->info & 3)
```

### 8.4 Reading the fields

- **Saturation.** `pkt_length`, `pkt_gap` and `payload_dw` clamp at 255,
  `pkt_wait` at 65535. Treat those as "at least", and leave such samples out
  of means and percentiles.
- **No timestamps.** v1: time within a port can only be estimated as the
  running sum of `pkt_gap + pkt_length`. That is a lower bound: stalls in the
  middle of a packet are counted by neither field, and a saturated gap breaks
  it. v2 (`telemetry_dma_format.md` §4.3), on the output, from the first
  record's start = 0:
  `out_sop[n] = out_eop[n-1] + 1 + pkt_gap[n]`,
  `out_eop[n] = out_sop[n] + pkt_length[n] - 1`, and
  `in_sop[n] = out_sop[n] - pkt_wait[n]`. Sorting one input's TLPs by
  `in_sop` gives its arrival order. Exact while there is no saturated gap or
  wait, no dropped record, and no stall inside a packet on the output; after
  any of those later times are lower bounds. `pips-log-decode.py --csv` writes
  `out_sop`, `in_sop` and a segment number that goes up at each break.
- **`pkt_wait`** covers everything between the two ports: waiting in the
  batching FIFO for its trigger, for the other input's drain, behind the
  packets ahead of it, and output backpressure. With `drain_depth_cap` on, a
  FIFO drains in pieces, which shows here.
- **`pkt_gap` includes backpressure** that delays the next packet's start, not
  just idle time.
- **`pkt_addr`** is meaningful for memory, I/O and atomic requests only. Its
  low 2 bits are always 0.
- **`payload_dw`** cannot exceed the link's Max Payload Size in practice:
  64 DW at MPS 256 B, which is what bigserver runs. A value of 255 is
  unreachable there.
- **Tags** show little variety on these requester-side buses, and that is
  expected. Posted writes don't use tags for matching, and the core may
  assign its own for reads.
- **Payload size.** At 512 bits per beat, payload bytes ≈ `pkt_length × 64 − 16`.

### 8.5 How a recording starts and stops

- **Edge-armed.** A recording starts only on a 0→1 edge of `log_enable` seen
  while the logger is idle. Holding it high does not start another. An edge
  during the end of a previous recording is ignored. To record again, take it
  low, then high.
- It records every TLP that ends on any port from about 4 cycles after the
  edge.
- **Region full** (`stop_reason` 2): recording stops when the 262,143rd slot is
  claimed. The trailer fills the last slot, so exactly 4 MiB is written, with
  `log_enable` still 1.
- **Enable low** (`stop_reason` 1): the trailer follows the last record, and the
  transfer is shorter than the region.
- If both happen in the same cycle, region full wins.
- A pulse with no traffic writes just a trailer (`n_records` 0).
- The stream always ends with the trailer and `tlast`, so the DMA transfer
  completes and nothing beyond the region is touched.

### 8.6 Order and drops

- v2: records are in **output order**: the order the TLPs left the batcher.
  Per input that is its arrival order within each FIFO (memory reads have
  their own unless `batch_mrd`).
- v1: records appear in **end-of-packet order across all three ports**. TLPs
  that end in the same cycle are ordered in0, in1, out.
- The logger drains one record per clock through a 512-entry FIFO (one entry
  per cycle in which any port ended a TLP).
- **Drops.** When the FIFO is full, that cycle's records are dropped, but each
  still takes its slot as a dropped record.
- **Per port the order is exact** (v1): the n-th record of a port is the n-th
  TLP that ended there. Across ports, dropped records are only roughly placed.
  `n_dropped` counts them all. In v2 a dropped record keeps its place in the
  output order and names its input.
- Causes: the DMA not running when `log_enable` rises (which is why it is
  armed first), DDR or interconnect stalls longer than the FIFO covers, or
  (v1) more than one TLP end per cycle summed over the three ports for long
  stretches. v2 has one tap, at most one record per cycle.
- None were seen at 1.62M IOPS.

### 8.7 Recording procedure

The `pips` tool does this (`log-start`, `log-wait`/`log-stop`, `log-dump`), and
so does XSCT `pips_log_start`/`pips_log_stop`.

1. Read `LOG_BASE_LO` and `LOG_BYTES`. If `log_enable` is 1, write it 0.
2. If the DMA has errors, or still waits for data from an earlier arm, soft
   reset it.
3. Clear the IRQ bits (`DMASR` ← `0x7000`). Set `DMACR` = RS and wait until it
   is no longer halted.
4. Write `S2MM_DA` = `LOG_BASE_LO`, then `S2MM_LENGTH` = `LOG_BYTES`. **Do this
   before step 5**, or records are dropped.
5. After ~2 ms, check `DMASR`. If it is already idle, the DMA took a **stale
   tail**: the logger still held the end of an earlier recording, whose DMA had
   been stopped. Note the bytes, clear IOC and repeat step 4.
6. Read-modify-write `log_enable` = 1. Recording starts on the edge.
7. Run the workload. Wait for `DMASR` idle or IOC (region full), or write
   `log_enable` = 0 to end it early.
8. Check `DMASR[6:4]` for errors. `S2MM_LENGTH` = bytes written. The trailer is
   at `LOG_BASE + bytes − 16` and must have info `0x88`.
9. Read `[LOG_BASE, + bytes)` through the window, 16 KB per `WIN_BASE` page,
   with 4-byte loads, then check `WIN_STATUS` = 0.
10. A region-full stop leaves `log_enable` at 1. Write it 0, so the next
    recording gets its edge.

### 8.8 Whole or cut

`pips-log-decode.py` classifies every dump on its first line, and the sweep
records the result per run in `pips-log.rpt`.

| Status | Meaning |
|---|---|
| `FULL` | it ran until the region filled: 262,143 records + trailer, exactly `LOG_BYTES` |
| `CUT` | it was ended (enable low) before the region filled |
| `+DROPS` | after either: records lost to FIFO overflow (holes, per port) |
| `NO_TRAILER` | the recording never closed: the DMA did not finish |
| `BAD` | the dump and its trailer disagree |
| `FAILED` | (sweep) no log at all |

A FULL log is a **snapshot**: the first 262,143 TLPs after the edge, about
4.4 ms under full load, not the whole run.

### 8.9 What a recording looks like

From bigserver, 2026-10-11: both drives, 4 jobs × iodepth 32 each, 4k random
reads, IOMMU off, 1.62M IOPS. Recording started 5 s into fio. A v1 log
(`e389cca`'s build, design `0x0A02`): each TLP is on its input and on `out`.
A v2 log of the same load would cover about twice the time, with `in0` +
`in1` = `out` by construction.

| | |
|---|---|
| Region | full in 4,368 µs (1,091,993 cycles), 262,143 records, 0 dropped |
| in0 | 65,932 TLPs: 1,299 MRd, 64,633 MWr, 27.1 Gbps of MWr payload |
| in1 | 65,142 TLPs: 1,310 MRd, 63,832 MWr, 26.8 Gbps |
| out | 131,069 TLPs (in0 + in1 = 131,074), 53.9 Gbps: the uplink's limit |
| Beats | 4.5 on average; 256 B MWr = 5 beats |

The counts fit about 18 writes per 4 KiB read: 16 × 256 B of data, one
completion entry and one interrupt. That puts drive 0 at ~820K IOPS, against
817K from fio. This is an inference from the counts.

---

## 9. Inside the FPGA

### 9.1 How a BAR0 access is handled

```
USP CQ ─► pcie_cq_bar_split ─┬─ everything else ─► routing_table ─► downstream ports
                             └─ BAR0 MRd/MWr ────► pips_pio ─► CC ─► host
                                                      └─ AXI4-Lite master ─► smartconnect_pio
                                                           ├─► smartconnect_0 ─► regfile, axi_dma_log
                                                           └─► axi_noc_0 S02 ─► DDR4
```

- **`pcie_cq_bar_split`** finds BAR0 hits **by address**. It reads the USP's
  own BAR0/BAR1 through the core's `cfg_mgmt` port every 2^12 cycles (16 µs),
  and compares `addr[63:15]`.
  - Until the BAR is assigned, nothing goes to the PIO. A reassigned BAR is
    picked up within one poll.
  - The descriptor's BAR ID and aperture cannot be used instead (§9.2).
- Only MRd and MWr go to the PIO. Locked reads, I/O, atomics and messages keep
  their old path.
- **`pips_pio`** wraps the standalone PIO engines, which are copied verbatim and
  never patched. It handles one TLP at a time, and works around engine bugs F1
  and F3 at their ports (§9.3).
  - Completions go through a 128-deep FIFO, admitted only when it is empty, so
    it cannot overflow. `PIO_STATUS[0]` would flag it.
  - Window writes are taken off the request stream by the wrapper itself, one
    AXI write per DWORD, so they have no 48-byte limit.
  - Window reads fetch the 64-byte block first; then the engines build the
    completion.
- **Completion arbitration:** the PIO is the third input of the upstream
  completion interconnect, arbitrated per packet, so completions never
  interleave.
- **The map is a build constant:** bump `PIO_VERSION` in `pips_pio.v` whenever
  it changes.

**Builds without the PIO** (before `af165d6`) do not terminate BAR0 TLPs. They
fall into the routing table's default route and are forwarded to the device on
downstream port one. So a BAR0 access on such an image goes to the 9100 PRO
and fails there. Know which image is loaded (§6, design ID) before the first
access.

### 9.2 `CQ_SPLIT`: what the core reports (decision D4, settled)

On bigserver `CQ_SPLIT` read `0x8014_8014`. BAR0 hits and memory TLPs forwarded
to the drives both reported **BAR ID 0, aperture 20**.

- The descriptor cannot tell the two apart, so the split by address stays.
- Aperture 20 is log2 of 1 MB: the core reports the IP setting (§11.1), not the
  32 KB on the wire.

### 9.3 PIO engine findings (`MVP_MAP.md`)

| ID | Problem | Effect in PIPS |
|---|---|---|
| F1 | The receive FSM samples `tlast` on a beat it has not accepted; with the next TLP already on the bus it swallows it. A lost MRd is a completion timeout on the host (`0xFFFFFFFF`, or an MCE on some servers) | Worked around in `pips_pio` (it shows the engine only beats it accepted). Proven necessary in sim |
| F2 | Payload shifting uses the current beat's data as an address: writes > 12 DW (48 B) in one TLP are corrupted | **Host rule 2.** Window writes are unaffected |
| F3 | The completion FSM decides on `tready` before its beat is on the bus; it can drop or repeat completions and wedge | Worked around: the engine sees `tready` = 1, and a FIFO does the real handshake |
| F4 | A single-beat completion for a read crossing 64 B ends with a wrong end flag | Host rule 9 |
| F5–F7 | The engine's trigger registers, request path and interrupts are unreachable or wrong | Not used: no interrupts, no host DMA |
| F11 | `pci_mem.c` (the generic peek/poke tool): undefined `%lX` with 128-bit values, uninitialised write type, negative length, always reads before writing | Use `pips`, or wrap `pci_mem` carefully. Its read-before-write shows "Data Mismatch" on `WIN_STATUS` (W1C) and `WIN_BASE_LO[1:0]`: expected |
| F12 | `phase0_hwtest.sh` targets a different design (TARDIS) | **Never run it against PIPS** |

### 9.4 Decisions, in short (`PIO_KNOWLEDGE_MAP.md` §2)

| | |
|---|---|
| D1 | Scope: registers + BRAM over BAR0, plus the AXI bridge. No host DMA, no interrupts |
| D2 | `src/pio/` mirrors the standalone repo byte for byte; PIPS glue lives in `src/pio_pips/` and `src/switch/` |
| D3 | F1 and F3 are worked around outside the engines |
| D4 | BAR0 hits are found by address (§9.2) |
| D5 | The split sits in front of `routing_table`, which rewrites descriptor bits the PIO needs |
| D6 | BAR0 TLPs are now answered by the PIO; before, they went to downstream port one |
| D7 | One TLP at a time; host-to-device requests wait behind a PIO access for a few cycles |
| D9 | The completion engine's client-tag option is off, so each completion carries its request's tag |
| D13 | A paged 16 KB window, not a bigger BAR (a BAR mapping DDR would need a prefetchable 64-bit BAR) |
| D14 | One AXI4-Lite master; address decode in the block design, copied from the PS view |
| D15 | Window reads prefetch one 64-byte block; window writes bypass the engines |
| D16 | AXI errors and timeouts never wedge the PIO |
| D17 | `MWR_COUNT`/`MRD_COUNT` count every BAR0 TLP, including window ones |
| D18 | Config register: one field per byte (§6) |
| D19 | The log region is a build constant, enforced by the DMA's address range and reported in BAR0 |
| D20 | Regfile: 16 registers, read-only range `0x20–0x3F`, design ID |
| D21 | Upstream port IP set to "1 MB" to get a 32 KB BAR0 (§11.1) |

---

## 10. XSCT (JTAG): the same targets without the host

```tcl
connect -url TCP:192.17.103.45:3121
targets 1
configparams force-mem-access 1
mrd 0xA4000000          ;# config register
mrd 0xA4000004          ;# drain config (design 0x0A03 on)
mrd 0xA4000020          ;# design ID
mwr 0xA4000000 0x01001608   ;# depth 8, time 0x16, log on (new layout)
mwr 0xA4000004 1            ;# drain depth cap on
```

`scripts/pips/pips-xsct.tcl` wraps the config (`pips_cfg_set ... cap 1`),
design ID (`pips_design`), DMA and log procedures. DDR is read through the
PS's NoC port, at JTAG speed. XSCT cannot reach BAR0 registers, so the log
region is hard-coded there (`0x0`, 4 MiB). Change it there too if `pips.tcl`
changes. Name a dump with the design ID (`log-id0a04.bin`) so the decoder
picks the right format.

---

## 11. Build facts (`pips.tcl`)

### 11.1 The upstream port's BAR0 size (D21)

- **Symptom.** With the IP set to "32 KB" the hardware enumerated a **1 KB**
  BAR0. That was the case for the remote build, a local build, and every
  earlier build.
- **Cause.** The PCIe IP writes an aperture code n to the hard block. The block
  decodes n as 2^(n+7) bytes on an endpoint (Type 0 header), but as 2^(n+2) on
  a bridge (Type 1 header). The IP corrects for that only for
  `Root_Port_of_PCI_Express_Root_Complex`, not for `Switch_Port_Upstream`. So
  "32 KB" gives n = 8, which the block decodes as 2^10 = 1 KB. Found in Vivado
  2021.2's `pcie_versal_v1_0/xgui/pcie_versal_v1_0.tcl`,
  `calc_Aperture_Size_for_PF_Bars`; Vivado 2025.1 computes the same.
- **Fix.** `pf0_bar0_scale Megabytes`, `pf0_bar0_size 1` gives n = 13, decoded
  as 2^15 = 32 KB. Confirmed on hardware: `[size=32K]`.
- **Keep.** `pcie_cq_bar_split BAR_APERTURE_LOG2 15`, the real size.
- **Re-check** if the IP version changes.
- **One trace remains:** the core reports aperture 20 (1 MB) in descriptors
  (§9.2).

### 11.2 Other constants and settings

| Setting | Value | Where |
|---|---|---|
| `pips_design_id` | `0x0A04` (+1 per design update; `0x0A02` first) | regfile `+0x20` |
| `pips_log_ddr_base`, `pips_log_region_bytes` | `0x0`, 4 MiB | BAR0 `LOG_*`; the DMA's address range |
| `axi4_mwr_batch_top_0` | `DMA_LOG 1`, `DMA_REGION_BYTES` = region, `LOG_TDATA_WIDTH 128`; others default (`LOG_FIFO_DEPTH 512`, `MRD_DEDICATED_FIFO 0`, 8-bit thresholds); `drain_depth_cap` from `xlslice_4` (reg1 bit 0) | §6, §8 |
| `axil4_regfile_0` | `NUM_REGS 16`, `C_S_AXI_ADDR_WIDTH 6`, `REG_RW_MASK 00000011` (reg0, reg1 have storage) | §6 |
| `axi_dma_log` | `c_include_sg 0`, `c_addr_width 32`, `c_sg_length_width 26`, `c_s2mm_burst_size 256` | §7 |
| Clocks | upstream `user_clk` 250 MHz for the PIO, batcher, logger, regfile and DMA | |

**Open:** the narrowed DMA address range (D19) builds with
`CRITICAL WARNING [BD 41-1266]`. It reports the DMA's 4 MB range against the
PIO's 2 GB range of the same DDR segment. Hardware recordings land where
expected. Still to decide: keep it and check that the warning is benign, or
widen the DMA back to 2 GB and keep the constants.

**Machines.**
- Bitstreams are built on `yz69@csl227-desktop` (Vivado 2021.2, repo
  `~/pips_batch/Programmable-Intelligent-PCIe-Switch`).
- The host under test is `bigserver` (`~/F_S_Memory_Script`).
- The Windows copy holds sources, simulation and docs.

---

## 12. Hardware results so far (bigserver, 2026-10-11)

- **First run:** BAR0 1 KB, which led to §11.1. After the fix (build with
  `e389cca`'s changes), `pips-bringup.sh` passed every step:
  - registers, counters and `BUS_NUM`;
  - BRAM at the F1 offsets, with 8-byte and byte writes;
  - regfile write/read-back and restore;
  - DMA registers;
  - DDR 4 KB and page switching;
  - the window error path (`0xB000_0000`: DECERR, `WIN_ERR` correct, clears);
  - an empty recording (16 bytes, trailer, stop enable_low).
- **fio** with a recording (§8.9): 1.62M IOPS, 6.64 GB/s, the uplink's limit.
  Before the PIO build, HANDOFF §7 measured 1.64M with the IOMMU off. No new
  kernel errors, no link or error-bit changes, `PIO_STATUS` and `WIN_STATUS` 0.
- **Window cost** as in §5.
- **Sticky error bits** on the USP and both drives (`CorrErr+ UnsupReq+`,
  `AdvNonFatalErr+`) were present before the run and unchanged by it.

---

## 13. Tools (details in [README.md](README.md))

| Tool | Use |
|---|---|
| `pips` (C, `make`) | `info`, `rd`/`wr`, `axi-rd`/`axi-wr`, `cfg [set depth= time= mrd= log= raw= cap=]` (prints `drain=`, `design_id=`, `log_format=`), `dma`, `dma-reset`, `log-clear`, `log-start`, `log-wait`/`log-stop`, `log-dump`, `ddr-dump`, `hwtest [steps]`, `soak` |
| `pips-bringup.sh` | enumeration, links, kernel log, `hwtest`, an empty recording (`log-smoke-id<XXXX>.bin`); logs in `utils/logs/pips-bringup-*` |
| `pips-fio-log.sh` | one read-only fio run with a recording (`log-id<XXXX>.bin`), before/after readouts |
| `dualssd_pips_sweep.sh`, `dualnic_pips_sweep.sh` | the dual-SSD cross sweep with uneven co-runs / the dual-NIC flow sweep, once per batcher setting with the drain cap off and on, a recording per run checked FULL/CUT; names carry the design ID |
| `pips-log-decode.py` | dump → status, per-port summary, CSV, JSON, `.rpt`; reads `.gz`; v1 or v2 by design ID |
| `pips-xsct.tcl` | the same over JTAG |
| `make check` | all of it against a software model of BAR0 (`pips_sim.c`), no hardware |

The tools refuse a BAR0 that is not 32 KB without touching it. They check
`ID`/`VERSION` before anything else, hold `/tmp/pips-bar0.lock` (scripts also
hold `/tmp/pips-run.lock`), and keep every BAR0 access single, aligned and
volatile.

---

## 14. Troubleshooting

| Symptom | Likely cause | Do |
|---|---|---|
| No `10ee:b048` in `lspci` | FPGA not programmed, link down, not enumerated | program, then reboot with the FPGA powered, or rescan |
| `[size=1K]` (or any size ≠ 32K) | IP BAR setting (§11.1); or the kernel has not re-enumerated since programming | check the build has the "1 MB" setting; re-enumerate |
| Region 0 `<unassigned>` | no space for the BAR | reboot, or `pci=realloc` |
| `Mem-` on the USP | memory decode off | `setpci -s <USP> COMMAND=0x02:0x02` |
| `ID` reads `0xFFFFFFFF` | no completion: link down, BAR moved, image without the PIO | re-enumerate; check the image (design ID over XSCT) |
| `ID` reads something else | not a PIPS image with the PIO | load the right image |
| `LOG_BYTES` reads 0 | `pips_pio_0` lacks its CONFIG: project not re-created from `pips.tcl` | rebuild from `pips.tcl` |
| Window read `0xFFFFFFFF`, `WIN_STATUS[0]` | DECERR: unmapped AXI address, or design ID on an old build | check the address; `WIN_ERR` holds it |
| `WIN_STATUS[2]`, then `[4]`/`[8]` | an AXI target did not answer in 33 µs; further window accesses dropped until it does | report to the FPGA side; BRAM and registers still work |
| `WIN_STATUS[3]` | a window read crossed its 64-byte block | aligned 4/8-byte loads only |
| `PIO_STATUS[0]` = 1 | completion FIFO overflow | should be impossible; report |
| BRAM data wrong after a big store | F2: store > 48 B | no memcpy/SIMD/WC on the mapping |
| DMA stays halted after RS = 1 | wrong offsets, or the DMA's clock/reset | check `pips dma`; `dma-reset` |
| DMA `dec_err` right after arming | `S2MM_DA` outside the log region | use `LOG_BASE_LO` |
| log-start: "took N stale bytes" | the logger held the end of an earlier recording | handled: it re-arms |
| Recording never completes (`log-wait` timeout) | open recording (enable still high), or no traffic and no stop | `log-stop`; `NO_TRAILER` means dump the whole region with `--scan` |
| `+DROPS` | DMA armed late, DDR stalls, too many TLP ends per cycle | arm the DMA first; check traffic |
| `CUT` where FULL was expected | traffic too light to fill 4 MiB within the wait | longer wait, or accept CUT |
| Config register reads an odd value | XSCT wrote the old layout (`0x1608`) | new layout `0x01001608` |
| `qdma_pf` bound to the switch | default Xilinx device ID | unbind; long term a PIPS device ID |

---

## 15. Open items

- Design `0x0A04` on hardware: the drain cap (reg1) and v2 logs have only run
  against the software model (`make check`). First run: `pips-bringup.sh`
  (the regfile step flips reg1), then one `pips-fio-log.sh` and a look at
  `pkt_wait` and `in0 + in1 = out` in its decode.
- D19's narrowed DMA address range: `BD 41-1266` critical warning; decide
  (§11.2).
- `CTRL0–7` are not connected to anything. The regfile is reachable from the
  host, so new knobs go in regfile registers 2–7 (reg1 is the drain config).
- A PIPS-specific USP device ID, to rule out `qdma_pf` (§2).
- `Linux_QRH.txt` still has the old XSCT layout (`mwr 0xA4000000 0x1608` →
  `0x01001608`).
- If DWORD-at-a-time reads become too slow (bigger log regions), the window
  could burst a whole 64-byte block per read, or a real host DMA could be
  added. A DMA needs a merge point on the upstream request stream, which the
  batcher already owns.
- Longer log coverage needs a bigger region (`pips_log_region_bytes`, up to
  ~64 MiB) or several recordings per run.

---

## 16. Sources

| Topic | Source |
|---|---|
| BAR0 map, window, access rules, host procedure, drain config, record format by design ID | FPGA repo `pips_batch` (`C:\Xilinx_Projects\pips_batch_new\Programmable-Intelligent-PCIe-Switch`): `src/pio_pips/pips_pio.v` (header), `sw_handoff/README.md` §6–§7, `sw_handoff/pips_regs.h` (copied here as `pips_regs.h`, 2026-10-15). `sw_handoff/` is git-ignored there |
| Design decisions D1–D21, verification, limits | FPGA repo `PIO_KNOWLEDGE_MAP.md` (gitignored, Windows dev copy) |
| Rebuild and enumeration steps, machines | FPGA repo `BRINGUP_HANDOFF.md` (gitignored) |
| AXI map, log constants, regfile, DMA, IP settings | FPGA repo `pips.tcl` |
| Log format, lifecycle, drops, DMA sequence | AXI4-switch repo `telemetry_dma_format.md` §1–§8 |
| Field meanings and caveats | AXI4-switch repo `axi4_telemetry_decode.md` §4, §8 |
| Batcher thresholds | AXI4-switch repo `SRC/sources_1/axi4_mwr_batch.v` |
| PIO engine findings F1–F13 | standalone PIO repo `PCIe_PIO/MVP_MAP.md` |
| BAR aperture encoding | Vivado 2021.2 `data/ip/xilinx/pcie_versal_v1_0/xgui/pcie_versal_v1_0.tcl` |
| AXI DMA registers | PG021, AXI DMA v7.1 |
| Hardware results | `utils/logs/pips-bringup-20261011-225550/`, `utils/logs/pips-fio-20261011-225629/` on bigserver |
