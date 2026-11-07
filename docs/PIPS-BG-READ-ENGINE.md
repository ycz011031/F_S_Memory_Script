# PIPS background read engine (`pips_bg_rd`): design and plan

Status: **proposal, 2026-11-06; the core is built in `0x0A08`** (FPGA repo
`5fe3bda`, 11-06; not yet run on hardware; host tools: the test doc §5.2). The engine core (issuer,
sink, mux, tags, latency, counters, table) is built first in design `0x0A08`
together with the tests of its assumptions and fallbacks:
[PIPS-0A08-ASSUMPTION-TEST.md](PIPS-0A08-ASSUMPTION-TEST.md). What this file
adds beyond that core becomes `0x0A09`, shaped by 0x0A08's results. Base:
`0x0A07`, FPGA repo `28ff5b6`. This file is the hand-off to the
hardware work (sections 1-9) and the plan for the host software and the
experiments (sections 10-12). Section 13 lists the open questions the
hardware side must settle before or during the build.

Readers: the hardware agent working in the FPGA repo
(`C:\Xilinx_Projects\pips_batch_new\Programmable-Intelligent-PCIe-Switch`),
and later software sessions in this repo. File and signal names below are the
FPGA repo's as of `28ff5b6`.

---

## 1. Why

The switch study judges PIPS on page order: how many page switches per 4 KiB
page the switch sends (about 8.6 with batching off, about 4 with depth 16
and page batching on). On these hosts the IOMMU is idle enough that page
order never shows up in the IOTLB miss count:

- bigserver's IOTLB (Skylake-SP, ~96 entries, no set conflicts found) keeps
  every page a drive is writing. A page misses once per visit, whatever the
  order of its writes (alias campaign 1, HANDOFF §8).
- The drives can't make more misses: each NVMe command writes whole pages
  (no SGL support, `sgls : 0`), and one drive tops out at ~1.1 M commands/s.

Order matters only if a page's translation is **evicted between two of its own
writes**. Then every return to the page misses, and misses per page follow
page switches per page, so the switch's regrouping becomes visible. Evicting
an entry from a ~96-entry LRU IOTLB inside the gap between two writes of the
same page takes on the order of 100 other translations in that gap. Nothing
on the host can produce that. A requester inside the switch can: memory reads
to many distinct pinned pages, issued from the FPGA at up to one per clock.

The engine also gives a direct, per-read measurement of IOMMU translation
latency. That is useful on its own: the IOTLB size and associativity, and
the replacement policy, can be read from latencies instead of being fitted
to pcm-iio counts.

## 2. What it does, in one paragraph

`pips_bg_rd` issues PCIe memory reads (MRd, 1-16 DW, default 1 DW) to host
IOVAs taken from a page pattern (`base + (first + i*stride) * 4096 + offset`,
cyclic or random) or from a page table the host loads. It issues them under
the **requester ID of one of the switch's own ports** (normally the downstream
port above the target device, which shares that device's IOMMU group and
therefore its IOMMU domain). It interleaves them into the upstream request
stream behind the batcher, and catches every completion addressed to that
requester ID before the completion router. Completions never reach a device.
It counts and timestamps everything: reads issued, completions by status,
latency sum/min/max, a latency histogram, a per-read latency trace, and a
data check against the page tags the host wrote. It never writes, never
touches config space, and never resets anything.

## 3. Where it sits

All inside the `pips_control_plane` hierarchy, clock `aclk_upstream`
(250 MHz, 4 ns), reset `aresetn_upstream` (the upstream port's `user_reset`,
like the regfile: a link reset stops the engine and clears its registers).

```
 dowstream_path_one/m_axis_upstream_rq --> s_axis_0 \
                                                     axi4_mwr_batch_top_0 (batcher, logger tap, out cap)
 dowstream_path_zero/m_axis_upstream_rq -> s_axis_1 /           |
                                                                m_axis
                                                                 |
                                    pips_bg_rd/m_axis_rq --> [axis_rq_mux2] --> m_axis_upstream_rq --> pcie_versal_upstream_port/s_axis_rq
                                         ^       |
              AXI-Lite 0xA402_0000 ------+       | completion events (tag, status, data DW0)
                                                 |
 pcie_versal_upstream_port/m_axis_rc --> axis_data_fifo_usp_rc --> [pips_bg_cpl_sink] --> pcie_axis_rc_route_0/s_axis_rc
                                                                     (consumes TLPs with requester ID == engine RID;
                                                                      passes every other beat through unchanged)
```

New RTL (suggested files, `src/switch/`):

| Module | Role |
|---|---|
| `pips_bg_rd.v` | the engine: AXI-Lite slave, config latch, address generator, tag manager, issue logic, stats (counters, histogram, trace), timeout scan |
| `pips_bg_cpl_sink.v` | on the upstream RC stream, between `axis_data_fifo_usp_rc` and `pcie_axis_rc_route_0`: matches the requester ID, consumes those TLPs, reports one event per completion |
| `axis_rq_mux2.v` | 2:1 packet-atomic arbiter in front of the upstream port's `s_axis_rq` (batcher output = input A, engine = input B) |

Consequences of this placement (intended):

- **The rate caps don't apply to the engine.** `rate_cap_0/1` sit at the
  batcher inputs, `rate_cap_out` inside `axi4_mwr_batch_top` before `m_axis`.
  The engine is injected after all of them, so `rcap0/1/out` can throttle the
  drives while the engine runs free (the user's request, 11-06).
- **The TLP log does not record engine reads.** The logger taps the batcher
  output before the out cap. Page-order analysis of the devices' traffic is
  unchanged. Recording engine reads is the optional extension O1 (§9).
- **No ordering interaction with the devices.** Engine reads never enter the
  batcher, and they carry another requester ID. The mux keeps packets whole,
  so nothing passes anything inside a stream.

## 4. PCIe details the RTL must get right

### 4.1 The request (RQ) beat

Upstream port settings (from `pips.tcl`): 512-bit AXIS, **RQ straddle off**
(`AXISTEN_IF_EXT_512_RQ_STRADDLE false`), **client tags on**
(`axisten_if_enable_client_tag true`). The devices' requests reach the port
through `cq_to_rq_converter.v`, which forces descriptor bit 120 (Requester ID
Enable) so each device's own requester ID goes upstream. The engine does the
same with its own ID.

One MRd = one beat, `tlast = 1`, `tkeep = 16'h000F` (the 4-DW descriptor, no
payload). Descriptor (PG343 RQ descriptor layout, `tdata[127:0]`):

| Bits | Field | Engine value |
|---|---|---|
| `[1:0]` | Address Type | `2'b00` (untranslated: the IOMMU must translate it) |
| `[63:2]` | Address[63:2] | the read address (§6) |
| `[74:64]` | Dword Count | `READ_DW` (1-16) |
| `[78:75]` | Request Type | `4'b0000` (memory read) |
| `[79]` | Poisoned | 0 |
| `[95:80]` | Requester ID | `RID` register |
| `[103:96]` | Tag | from the engine's tag pool (8 bit) |
| `[119:104]` | Completer ID | 0 |
| `[120]` | Requester ID Enable | **1** |
| `[123:121]` | TC | 0 |
| `[126:124]` | Attr (NS, RO, IDO) | 0 |
| `[127]` | Force ECRC | 0 |

`tuser` (183 bits for 512-bit RQ, the field list `cq_to_rq_converter.v`
builds): `first_be[3:0] = 4'hF`, `first_be[7:4] = 0`; `last_be[11:8] = 4'hF`
if `READ_DW > 1` else `4'h0`; `addr_offset = 0`; `is_sop[21:20] = 2'b01`;
`is_sop0_ptr = 0`; `is_eop[27:26] = 2'b01`; `is_eop0_ptr[31:28] = 4'd3` (the
last DW of the 4-DW descriptor); `discontinue = 0`; sequence numbers 0;
parity 0 (as the converter does). The hardware agent should confirm the
`is_eop0_ptr` convention for a payload-less request against PG343 and the
existing batcher output (an ILA capture of a device MRd going upstream is the
reference).

The address is 64-bit. The core picks the 4-DW header for addresses at or
above 4 GiB (IOVA `0x80_0000_0000` and up in the plan).

### 4.2 The completion (RC) side

The RC descriptor as `pcie_axis_rc_route.v` reads it (one TLP starts at DW0
of a beat; the route has no straddle handling, so the sink assumes the same,
see §13 Q2):

| Bits | Field | Engine use |
|---|---|---|
| `[15:12]` | Error Code | recorded in `LAST_CPL` |
| `[28:16]` | Byte Count | checked (= `4*READ_DW` for a one-completion read) |
| `[30]` | Request Completed | must be 1 (one completion per read, §4.3) |
| `[42:32]` | Dword Count | payload DWs |
| `[45:43]` | Completion Status | 0 SC, 1 UR, 2 CRS, 4 CA, others reserved |
| `[46]` | Poisoned | counted |
| `[63:48]` | Requester ID | **the match field** |
| `[71:64]` | Tag | returns the tag |
| `[87:72]` | Completer ID | ignored |
| `[127:96]` | first payload DW (descriptor is 3 DW) | data check, `LAST_DATA` |

**Why the sink is mandatory.** `pcie_axis_rc_route` sends a completion to
DSP0's path if the requester is on the secondary bus with device number ≠ 0,
or on bus secondary+2, and **everything else to DSP1's path**. A completion
for `b2:00.0` (device number 0) or for the upstream port `b1:00.0` would
therefore go down to drive b3 as an unexpected completion. The sink must
consume every TLP whose requester ID equals the engine's `RID`, whole (until
`tlast`), and must never assert backpressure on those beats.

The sink matches on the **latched RID while the engine is in RUN, DRAIN or
the quarantine after a timeout** (§5.4), not on the live register. A host write
to `RID` mid-run must not open a window where the engine's completions leak.
Simplest rule: the sink matches whenever `RID_LATCHED` is non-zero, and
`RID_LATCHED` is cleared only by `CLEAR` in IDLE with no tag quarantined.

### 4.3 One completion per read

A read that stays inside one 64-byte block gets exactly one completion (the
host's RCB is 64 B). The engine enforces `(OFFSET mod 64) + 4*READ_DW ≤ 64`
at start (config error 5 otherwise). It never has to reassemble split
completions. Byte Count must equal `4*READ_DW` and Request Completed must be
1, otherwise it's counted as `CPL_MALFORMED`.

### 4.4 Which requester ID

The IOMMU picks the translation context (the domain) by requester ID. The
engine's reads must use an ID whose context entry points at the domain that
maps the background pages.

- On both hosts each device sits in **its own IOMMU group together with its
  PIPS downstream port** (bigserver 11-05: group 236 = `b2:00.0` + `b3:00.0`,
  group 237 = `b2:01.0` + `b4:00.0`; icx: the same shape, paper campaign E6).
  Linux attaches every device of a group to the group's domain. For VFIO
  (bigserver) that is the container's paging domain, so `b2:00.0` translates
  through drive 0's VFIO domain. For the kernel's DMA domain (icx), `b2:00.0`
  translates through the NIC's default domain. **The engine therefore uses the
  downstream port's own ID.** No device ever uses that ID, so there is no tag
  clash with any device, and matching the ID alone identifies the engine's
  completions. This attach behaviour is the main assumption: bring-up test X0
  (§12) proves or disproves it on each host before anything else runs.
- **Allowed IDs (hardware-enforced at start):** `{secondary_bus, 5'd0, 3'd0}`
  (DSP one, above in0 / drive 0), `{secondary_bus, 5'd1, 3'd0}` (DSP zero,
  above in1 / drive 1), `{primary_bus, 5'd0, 3'd0}` (the upstream port itself:
  no domain maps anything for it, so its reads fault; a negative control
  only). Any other value is refused with config error 1. This rules out
  spoofing a real device's ID, whose own reads would clash with engine tags.
  `primary_bus` and `secondary_bus` come from `routing_table_0` (already wired
  into the control plane). The check uses their values at start.

### 4.5 Flow control: don't block the devices

The upstream port's `s_axis_rq` carries the devices' writes (posted) and
reads (non-posted) in one stream. If the engine's MRd sits at the head and
the core has no non-posted header credit, the core holds `tready` low and
every device write behind it waits.

- **Required:** gate issue on the core's transmit flow-control outputs
  (`pcie_tfc_nph_av` / `pcie_tfc_npd_av` in the UltraScale+ / Versal PCIe
  cores; not connected anywhere in `28ff5b6`). Issue only while
  `nph_av > NPH_RESERVE` (register, default 2), leaving credits for the
  devices' own reads (NVMe SQ fetches, PRP lists; mlx5 WQE fetches). See
  §13 Q3 if the port doesn't exist on `pcie_versal`.
- `MAX_OUT` bounds the engine's own outstanding reads (≤ 256 tags).

### 4.6 Rates the link allows

| Path | Per read | Ceiling |
|---|---|---|
| Upstream, Gen3 x8 (bigserver, 7.88 GB/s) | MRd: 16 B header + ~8 B framing/LCRC ≈ 24 B | ~300 M reads/s, if nothing else uses the link |
| Downstream, Gen3 x8 | CplD 1 DW: 12 B + 4 B + ~8 B ≈ 24 B | ~300 M/s (this direction is nearly idle under drive writes) |
| Upstream, Gen4 x8 (icx) | same | ~600 M/s |
| Engine | 1 MRd per cycle | 250 M/s |
| Tags | 256 outstanding / round trip (~1 µs hit) | ~250 M/s; less while walks lengthen the round trip |

The practical limit will be the root complex and the IOMMU walker. Measuring
that limit is experiment X2. For scale: the drives make ~30 M IOTLB lookups/s
and ~1.7 M misses/s today.

## 5. Behaviour

### 5.1 States

```
IDLE --(CTRL.RUN 0->1, config valid)--> RUN
IDLE --(CTRL.RUN 0->1, config invalid)--> IDLE, STATUS.CFG_ERR + code
RUN  --(CTRL.RUN 1->0 | COUNT reached)--> DRAIN
RUN  --(error with STOP_ON_ERR)--> DRAIN, STATUS.ERR_STOP
DRAIN --(outstanding == 0, or every outstanding tag timed out)--> IDLE
```

- **RUN:** issues reads (§5.2) and takes completions.
- **DRAIN:** issues nothing and takes completions until none are outstanding.
  Timed-out tags count as returned for this purpose (§5.4).
- **IDLE:** issues nothing. The sink keeps matching `RID_LATCHED` (§4.2).
- Start latches every configuration register except the **live** ones
  (`INTERVAL`, `MAX_OUT`, `NPH_RESERVE`, `CTRL.ARB`), which take effect at once.
  A lower `MAX_OUT` takes effect as tags return.
- `CTRL.CLEAR_ON_START` (default 1) clears counters, histogram, trace and
  sticky flags at each start.

### 5.2 Issue

A read is issued in a cycle when all of these hold:

- the state is RUN;
- the interval counter has expired: cycles since the last issue ≥ `INTERVAL`
  (0 and 1 both mean every cycle);
- `outstanding < MAX_OUT` and a tag is free (not in use, not quarantined);
- `nph_av > NPH_RESERVE` (§4.5);
- `COUNT` is 0, or fewer than `COUNT` reads have been issued;
- the output register toward the mux is free.

The engine pre-computes the next address, so with the mux granting it can
issue every cycle. Stall counters record why it didn't (§7).

The issue timestamp is taken when the beat is accepted at the upstream
port's `s_axis_rq` (the mux output handshake), so latency excludes the
engine's own wait for the mux. Per tag the engine keeps: the timestamp
(32 bit), its sequence number (issue order since start, for the trace) and
its page index (for the data check).

### 5.3 Completion

For each completion event from the sink:

- **Outstanding tag:** free it (unless quarantined, §5.4). Latency =
  `now - ts[tag]` in cycles. Update the counter for the completion status,
  the latency sum, min and max, the histogram bin, and the trace (if the
  sequence number is in the trace window). Run the data check if enabled
  (§6.4).
- **Status other than SC (UR, CA, CRS, reserved), poisoned, or malformed:**
  count it; record it in `LAST_CPL` / `LAST_ERR_*`; with `STOP_ON_ERR`, go to
  DRAIN and set `ERR_STOP`.
- **Tag not outstanding:** count `CPL_UNEXPECTED` and drop. This is not an
  error stop: it is a late completion after a timeout reclaim. It frees a
  quarantined tag if that tag was quarantined.

### 5.4 Timeouts

A scan visits one tag per cycle (256 cycles per sweep). An outstanding tag
older than `TIMEOUT` cycles (default 65,536 = 262 µs; the root complex's
completion timeout should answer CA well before) is reclaimed:

- counted in `TIMEOUTS`, marked in the trace;
- the tag is **quarantined**: never reused until its late completion
  arrives or the host writes `CLEAR` in IDLE;
- `STOP_ON_ERR` treats it as an error.

Quarantine prevents a late completion from being credited to a new read.

### 5.5 What the host must never see

- An engine completion forwarded to a device (sink guarantees; the
  testbench checks it explicitly).
- A device completion altered or dropped (the sink passes non-matching beats
  bit-exact; testbench check).
- An engine request with `Requester ID Enable` 0, an Address Type other than
  00, a request type other than memory read, or a payload.

## 6. Address generation

`addr = BASE + (page << 12) + OFFSET`. BASE is 4 KiB aligned (`BASE_LO[11:0]`
read 0) and OFFSET is DW aligned.

### 6.1 Pattern mode (`CTRL.SRC = 0`)

`page = FIRST + i * STRIDE`, i in `[0, WS)`.

- **Cyclic** (`CTRL.ORDER = 0`): `i = 0, 1, ..., WS-1, 0, ...`. Implement with
  an adder: `page += STRIDE`, and `page = FIRST` when i wraps. No multiplier.
- **Random** (`CTRL.ORDER = 1`): `i = lfsr & (WS-1)`. Needs `WS` a power of
  two (config error 3). Use a 32-bit maximal LFSR seeded with `SEED` (≠ 0) and
  a pipelined DSP multiply for `i * STRIDE`.
- Limit: `FIRST + (WS-1)*STRIDE < 2^40` pages, checked once at start (config
  error 9). The IOVA width (48 bit with 4-level tables) is the host's concern.

### 6.2 Table mode (`CTRL.SRC = 1`)

`page = TABLE[i]`, i cyclic over `[0, WS)`, or `lfsr & (WS-1)` for random.

- `TABLE` is `TABLE_DEPTH` (8192) 32-bit entries. `[29:0]` is a page index
  relative to `BASE`; `[31:30]` is a requester-ID slot (0x0A08: `RID` and
  `RID_SLOT1..3`, see the test doc §3.1; 0 when there is one `RID`). It is
  BRAM mapped at segment offset `0x8000` (§7).
- `WS ≤ TABLE_DEPTH` (config error 4).
- Writes while not IDLE are ignored and set `STATUS.TABLE_WR_RUN`.

Table mode serves the exact eviction sequences of experiment X1 (prime and
probe lists), and arbitrary scattered pages.

### 6.3 Offset

`OFFSET` is fixed for the run (default 0, the page's first DW, where the host
writes the page tag). Varying the offset inside a page changes nothing for
the IOTLB.

### 6.4 Data check (`CTRL.DATA_CHECK`)

The host backs the background region with `BACKING` distinct physical pages
(a power of two), repeated over the IOVA span: IOVA page k uses backing page
`k mod BACKING`. It writes each backing page's index into the page's first
8 bytes (as `alias_common.h` `backing_create` does today). With `OFFSET = 0`,
an SC completion's first DW must equal `page & (BACKING-1)` (low 32 bits).
`BACKING = 0` disables the compare.

A mismatch counts `DATA_MISMATCH`, records `LAST_ERR_PAGE`, and with
`STOP_ON_ERR` stops the run. This proves the reads land on the intended
pages through the intended domain.

## 7. Register map

New AXI-Lite slave, **segment `0xA402_0000`, 64 KiB**, 32-bit registers,
little-endian. Same addresses from the host (BAR0 window, `WIN_BASE`) and
from XSCT. Reads of unused offsets return 0, writes to read-only registers
are ignored with OKAY (as the regfile does), and nothing in the segment
returns DECERR. Reset values are given for every RW field; all are restored
by `aresetn_upstream`.

### 7.1 Control and configuration

| Offset | Name | Access | Reset | Fields |
|---|---|---|---|---|
| `0x000` | `BG_ID` | RO | `0x4247_5244` | "BGRD" |
| `0x004` | `BG_VERSION` | RO | `0x0001_0000` | `[31:16]` major 1, `[15:0]` minor 0 |
| `0x008` | `BG_CAPS` | RO | build | `[9:0]` max tags (256), `[19:16]` log2 table depth (13), `[23:20]` log2 trace depth (12), `[29:24]` histogram bins (64), `[30]` tfc gating present, `[31]` log tap present (O1) |
| `0x00C` | `BG_BUS` | RO | live | `[7:0]` primary bus, `[15:8]` secondary bus (as `routing_table_0` holds them; for building RIDs) |
| `0x010` | `CTRL` | RW | `0x0000_0404` | `[0]` `RUN` (write 1 to start from IDLE, 0 to stop; reads back the request); `[1]` `CLEAR` (write 1, self-clearing: counters, histogram, trace, sticky flags, quarantine, `RID_LATCHED`; histogram and trace only in IDLE, else ignored and flagged); `[2]` `STOP_ON_ERR` (1); `[3]` `SNAPSHOT` (write 1, self-clearing: latch every counter of §7.2 at once); `[5:4]` `ARB`: 0 idle-fill, 1 round robin, 2 engine first (live); `[6]` `SRC`: 0 pattern, 1 table; `[7]` `ORDER`: 0 cyclic, 1 random; `[8]` `DATA_CHECK`; `[10]` `CLEAR_ON_START` (1); `[11]` `TRACE_EN`; others reserved, write 0 |
| `0x014` | `STATUS` | RO | 0 | `[1:0]` state: 0 IDLE, 1 RUN, 2 DRAIN; `[8]` `ERR_STOP` (sticky); `[9]` timeout seen; `[10]` unexpected completion seen; `[11]` `CFG_ERR` (the last start was refused); `[15:12]` config error code (below); `[16]` clearing in progress; `[17]` data mismatch seen; `[18]` `COUNT` reached; `[19]` `TABLE_WR_RUN` (table write ignored, not IDLE); `[20]` `CLEAR` refused (not IDLE); `[21]` sink match active (`RID_LATCHED != 0`); `[31:24]` quarantined tags (saturating) |
| `0x018` | `RID` | RW | 0 | `[15:0]` requester ID for the next start. `[31:16]` RO: `RID_LATCHED` |
| `0x01C` | `BASE_LO` | RW | 0 | `[31:12]` IOVA base bits 31:12; `[11:0]` read 0 |
| `0x020` | `BASE_HI` | RW | 0 | IOVA base bits 63:32 |
| `0x024` | `FIRST` | RW | 0 | first page index (pattern) |
| `0x028` | `STRIDE` | RW | 1 | pages between pattern pages (≥ 1) |
| `0x02C` | `WS` | RW | 1 | pages in the pattern / table entries used (≥ 1; random order: a power of two) |
| `0x030` | `SEED` | RW | 1 | LFSR seed (≠ 0) |
| `0x034` | `OFFSET` | RW | 0 | `[11:2]` byte offset in the page, DW aligned; `[1:0]` read 0 |
| `0x038` | `READ_DW` | RW | 1 | `[4:0]` DWs per read, 1-16, inside one 64-byte block with `OFFSET` |
| `0x03C` | `INTERVAL` | RW, live | 0 | `[15:0]` minimum cycles between issues (0, 1 = every cycle) |
| `0x040` | `MAX_OUT` | RW, live | 1 | `[9:0]` outstanding reads, 1 to max tags |
| `0x044` | `NPH_RESERVE` | RW, live | 2 | `[3:0]` issue only while the core's NP header credits exceed this |
| `0x048` | `COUNT_LO` | RW | 0 | reads to issue, then DRAIN (0 = no limit), bits 31:0 |
| `0x04C` | `COUNT_HI` | RW | 0 | bits 63:32 |
| `0x050` | `TIMEOUT` | RW | `0x0001_0000` | cycles before an outstanding tag is reclaimed (≥ 256) |
| `0x054` | `BACKING` | RW | 0 | data check: backing pages, a power of two; 0 = no compare |
| `0x058` | `HIST_SHIFT` | RW | 3 | `[3:0]` histogram bin = min(latency >> shift, 63); shift 3 = 32 ns bins up to 2 µs |
| `0x05C` | `TRACE_SKIP` | RW | 0 | the trace records reads with sequence number `TRACE_SKIP` to `TRACE_SKIP + 4095` |

Config error codes (`STATUS[15:12]`):

| Code | Meaning |
|---|---|
| 1 | `RID` not one of the three allowed IDs (§4.4) |
| 2 | `WS` or `STRIDE` is 0 |
| 3 | random order with `WS` not a power of two |
| 4 | table mode with `WS > TABLE_DEPTH` |
| 5 | `OFFSET` + `READ_DW` crosses a 64-byte block, or `READ_DW` is 0 or > 16 |
| 6 | `MAX_OUT` is 0 or > max tags |
| 7 | `SEED` is 0 with random order |
| 8 | data check on with `BACKING` not a power of two, or `OFFSET` ≠ 0 |
| 9 | the pattern's last page ≥ 2^40 |
| 10 | start while not IDLE (ignored) |

### 7.2 Counters

All 64-bit counters are split LO/HI. Reads return the **snapshot** taken by
the last `CTRL.SNAPSHOT`, so one snapshot gives a consistent set. Live
values never tear. Counters marked live are read directly.

| Offset | Name | Meaning |
|---|---|---|
| `0x100/104` | `CYCLES` | free-running cycle counter (snapshot): the time base for rates |
| `0x108/10C` | `RUN_CYCLES` | cycles in RUN or DRAIN |
| `0x110/114` | `ISSUED` | reads accepted by the upstream port |
| `0x118/11C` | `CPL_SC` | successful completions |
| `0x120/124` | `CPL_UR` | Unsupported Request (e.g. an unmapped IOVA: the IOMMU blocked it) |
| `0x128/12C` | `CPL_CA` | Completer Abort |
| `0x130/134` | `CPL_OTHER` | CRS and reserved statuses |
| `0x138/13C` | `CPL_POISONED` | poisoned completions (any status) |
| `0x140/144` | `CPL_MALFORMED` | byte count ≠ `4*READ_DW` or Request Completed 0 |
| `0x148/14C` | `CPL_UNEXPECTED` | requester ID matched, tag not outstanding |
| `0x150/154` | `TIMEOUTS` | tags reclaimed by the timeout scan |
| `0x158/15C` | `LAT_SUM` | sum of latencies (cycles) over completed reads |
| `0x160` | `LAT_MIN` | cycles, since clear |
| `0x164` | `LAT_MAX` | cycles, since clear |
| `0x168/16C` | `STALL_ARB` | cycles a read was ready and the mux didn't take it |
| `0x170/174` | `STALL_TAGS` | cycles RUN waited for a tag (`MAX_OUT` or none free) |
| `0x178/17C` | `STALL_FC` | cycles RUN waited for NP credits (`NPH_RESERVE`) |
| `0x180/184` | `DATA_MISMATCH` | data check failures |
| `0x188` | `OUTSTANDING` | live: reads in flight now |
| `0x18C` | `OUT_MAX` | highest `OUTSTANDING` since clear |
| `0x190` | `LAST_CPL` | live: the last completion's `[7:0]` tag, `[10:8]` status, `[11]` poisoned, `[15:12]` error code, `[28:16]` byte count |
| `0x194` | `LAST_DATA` | live: first DW of the last SC completion |
| `0x198` | `LAST_ERR_PAGE` | live: page index of the last failed or mismatched read |
| `0x19C` | `LAST_ERR_SEQ` | live: its sequence number (low 32 bits) |

### 7.3 Memories in the segment

| Offset | Size | Content | Access |
|---|---|---|---|
| `0x0400-0x04FF` | 64 × 32 bit | **latency histogram**: bin b counts completed reads with `min(latency >> HIST_SHIFT, 63) == b`; saturating | RO; cleared by `CLEAR` in IDLE |
| `0x4000-0x7FFF` | 4096 × 32 bit | **latency trace**, indexed by sequence number − `TRACE_SKIP`: `[15:0]` latency cycles (saturating at `0xFFFF`), `[18:16]` completion status, `[19]` poisoned, `[20]` timed out, `[21]` data mismatch, `[31]` valid | RO; written at completion when `TRACE_EN`; cleared by `CLEAR` in IDLE |
| `0x8000-0xFFFF` | 8192 × 32 bit | **page table**: `[29:0]` page index relative to `BASE`, `[31:30]` requester-ID slot | RW in IDLE; writes otherwise ignored (`STATUS[19]`) |

The trace window is exactly one 16 KiB BAR0 window page (`WIN_BASE =
0xA402_4000`), the table two (`0xA402_8000`, `0xA402_C000`).

## 8. Implementation notes

- **Tag pool:** a 256-bit in-use bitmap plus a 256-bit quarantine bitmap, and
  a priority encoder or a free-tag FIFO initialised with 0..255. Per-tag
  LUTRAM: timestamp 32 bit, sequence 32 bit (low bits suffice for the trace;
  keep 32 for `LAST_ERR_SEQ`), page index 40 bit.
- **Histogram:** BRAM read-modify-write, one completion per cycle at most.
  Forward the pending increment when consecutive completions hit the same
  bin.
- **Completion rate:** completions arrive at most one per beat (no RC
  straddle, §13 Q2). The sink delivers one event per cycle; no FIFO needed
  beyond a register stage.
- **Sink:** a one-beat decision at SOP (`requester_id == RID_LATCHED`), held
  until `tlast`. Non-matching beats pass with their `tvalid/tready`
  unchanged. Matching beats get `tready = 1` toward the FIFO and
  `tvalid = 0` toward the router. Watch `tready` combinational paths into
  `axis_data_fifo_usp_rc`: register the decision if timing needs it.
- **Mux:** packet-atomic. It switches only after a beat with `tlast` (RQ
  straddle is off, so one TLP ends per `tlast` beat).
  - **Idle-fill (`ARB = 0`):** grant the engine when input A has no beat
    valid and no packet in progress.
  - **Round robin (`ARB = 1`):** alternate per packet when both are valid.
  - **Engine first (`ARB = 2`):** grant the engine at each packet boundary
    when it has a read.

  `STALL_ARB` counts engine-ready cycles not granted.
- **Resources (estimate):** < 3k LUTs, ~2.5k FFs; BRAM: table 32 KiB, trace
  16 KiB, histogram 256 B (~13 BRAM36 in all); 1-2 DSP for the random-order
  multiply. Everything runs at 250 MHz.
- **ILA:** a few probes on the existing `axis_ila_*` or a new small ILA:
  state, issue handshake, sink match, outstanding count, last status.
- **Reset:** `aresetn_upstream` stops everything and clears all registers
  and `RID_LATCHED`. After a link reset no engine completion can be in
  flight (the host lost the link), so nothing leaks.

## 9. Build integration (`pips.tcl`, design `0x0A08`)

1. Add the three modules as BD module references inside
   `pips_control_plane`, on `aclk_upstream` / `aresetn_upstream`.
2. Reconnect the upstream request path. Today
   `axi4_mwr_batch_top_0/m_axis` → hier pin `m_axis_upstream_rq` (line ~1580);
   new: `axi4_mwr_batch_top_0/m_axis` → `axis_rq_mux2/s_axis_a`,
   `pips_bg_rd/m_axis_rq` → `axis_rq_mux2/s_axis_b`,
   `axis_rq_mux2/m_axis` → `m_axis_upstream_rq`.
3. Reconnect the upstream completion path. Today
   `axis_data_fifo_usp_rc/M_AXIS` → `pcie_axis_rc_route_0/s_axis_rc` (line
   ~1582); new: `axis_data_fifo_usp_rc/M_AXIS` → `pips_bg_cpl_sink/s_axis` →
   `pcie_axis_rc_route_0/s_axis_rc`; `pips_bg_cpl_sink` event outputs →
   `pips_bg_rd`; `RID_LATCHED` → sink.
4. Bus numbers: `routing_table_0/primary_bus`, `secondary_bus` →
   `pips_bg_rd`.
5. Flow control: bring `pcie_tfc_nph_av` (and `npd_av`) of
   `pcie_versal_upstream_port` out to `pips_control_plane` and into
   `pips_bg_rd` (§4.5, §13 Q3).
6. AXI-Lite. Add a slave pin `s_axi_bg` on `pips_control_plane` and set
   `smartconnect_0` `NUM_MI` 2 → 3, with `M02_AXI` → `pips_control_plane/s_axi_bg`.
   Add `assign_bd_address -offset 0xA4020000 -range 0x00010000` in **both**
   address spaces: `versal_cips_0/M_AXI_FPD` (XSCT) and
   `pips_control_plane/pips_pio_0/m_axi` (the host through BAR0, via
   `smartconnect_pio` M00 → `smartconnect_0` S01).
7. `pips_design_id` → `0x0A08`; record it in `PIO_KNOWLEDGE_MAP.md` §9, the
   decision notes in the BD body (as for D24-D26), `sw_handoff/README.md` and
   `sw_handoff/pips_regs.h` (the `BG_*` offsets of §7). (In practice the
   first build is `0x0A08`, the core of this design with the test extensions of
   PIPS-0A08-ASSUMPTION-TEST.md; this file's remaining parts follow as `0x0A09`.)
8. Optional **O1, log tap:** feed engine requests into the TLP logger as a
   third input (`info = 0x82`), so a recording shows where engine reads fall
   between device writes. Record format v2 already has the port field. Off by
   default; worth it only if X3's results need the exact interleaving.

### 9.1 Testbench (before any bitstream)

A simulation of `pips_control_plane`'s new path with:

- an RC responder model: random latency 200-3000 cycles, out-of-order
  completions, configurable UR/CA/poisoned/malformed injection, dropped
  completions (for timeouts), late completions after a reclaim;
- a batcher-output stream generator: random MWr/MRd packets, with and
  without gaps;
- device completions with other requester IDs interleaved with the
  engine's.

Checks:

- no engine completion ever appears at the router's outputs;
- every device completion arrives at the router bit-exact and in order;
- every engine RQ beat is legal (§4.1);
- tags are never reused while outstanding or quarantined;
- counters, histogram and trace match a scoreboard;
- stop and drain behave as specified;
- each config error code fires;
- `CLEAR` and the table guard work in and out of IDLE;
- AXI-Lite reads and writes reach every register and memory.

## 10. Host software plan

Built after the register map is frozen. Most of it can be written and
checked against `pips_sim.c` before the bitstream exists.

| # | Piece | What |
|---|---|---|
| S1 | `scripts/pips/pips_regs.h` | `BG_*` offsets and fields of §7 (copied into the FPGA repo's `sw_handoff/` too) |
| S2 | `pips bg` in `pips.c` | `pips bg [status]`: decoded state, flags, counters, rates since the last snapshot. `pips bg set key=val ...`: `target=<device BDF>` (the tool resolves the device's parent bridge, checks it is a PIPS DSP and in the device's IOMMU group, and builds the RID), or `rid=dsp0|dsp1|usp|<BDF>`; `base= first= stride= ws= order= seed= src= offset= dw= interval= out= nph= count= timeout= backing= check= hshift= arb= trace= tskip=`. `pips bg table load FILE` and `table dump`. `pips bg start`, `stop [--wait S]`, `clear`, `snapshot`. `pips bg probe --target BDF --iova A`: one read, then status, data and latency. `pips bg hist` (bins, p50/p90/p99). `pips bg trace [N] [--raw]`. `pips bg sample PERIOD FILE`: a TSV line per period, for the runners (like `pips counters`) |
| S3 | `pips_sim.c` | model of the segment: registers, config checks, an instant-completion responder with a fixed latency and an error-injection knob, histogram, trace, table: so `make check` covers S2 |
| S4 | background region in `alias-nvme` (bigserver) | holder options `--bg-pages N` (IOVA span per drive domain, default 1,048,576 = 4 GiB), `--bg-iova A` (default `0x80_0000_0000`, away from the alias region at `0x40_0000_0000`), `--bg-backing P` (default 65536, a power of two, page-tagged). Mapped once at holder start in each drive's domain and never touched by loads. Written to `hold/bg` (`drive iova pages backing`) |
| S5 | runner `--bg SPEC` (`run-dualssd-experiment.sh`; NIC runner later) | Before the warm-up: `pips bg set` from SPEC (`target=` defaults to the active drive's DSP), `clear`, `start`, and a sampler to `pips-bg.tsv` every 2 s. After the window: `stop --wait`, `pips bg status > pips-bg.txt`, `hist`, `trace` if on. Trap: `pips bg stop` on every exit path. Results add `bg_*`: spec fields, reads/s over the window, completions by status, latency mean/p50/p99 (from the histogram), stalls, and an `bg_err` flag. A run with any `bg_err` is marked not clean |
| S6 | `pips-campaign.sh --bg` | the experiments of §12 as phases (one boot, strict; bigserver in hold mode with the guard armed) |
| S7 | analysis | device misses per page = (`IOTLB_misses` − engine misses) / device pages. Engine misses come from an engine-alone run of the same spec, or from its latency histogram (miss share = mass above the hit/miss threshold). Page switches per page from the TLP log as before. Report generator `report-gen/c<MMDD>.py` |
| S8 | icx support (later) | the NIC MR's IOVA base from a short TLP log of the alias-rdma load (the MR's IOVA range is contiguous and size-aligned, so one logged write of a known pattern page gives the base): `pips-bg-base.py`. Then the same `pips bg` runs with `target=` the NIC |

Safety in software:

- The engine runs only while a runner or `pips bg` owns it. Every script
  ends with `pips bg stop`.
- First runs on bigserver go with `alias-guard.sh` armed (BMC watchdog).
- Never point `base` at an unmapped range on purpose except in X0's negative
  test, which uses `count=1`.

## 11. Risks and how each is contained

| Risk | Containment |
|---|---|
| The DSP's ID is not attached to the device's domain (the main assumption, §4.4) | X0 tests it first: a mapped page must answer SC with the right tag; an unmapped one UR/CA with one DMAR fault line. If the positive test fails, stop and rethink (§13 Q1) |
| An engine completion reaches a drive (unexpected completion, AER) | the sink; testbench check; X0 checks AER counters and `dmesg` |
| Engine MRds block device writes at the head of `s_axis_rq` | NP-credit gating (§4.5), `MAX_OUT`, `ARB = 0` by default; `STALL_FC` shows it |
| DMAR fault storm from a wrong base | `STOP_ON_ERR` (default on): at most `MAX_OUT` faulting reads; Linux rate-limits the fault messages |
| A completion never returns | timeout scan, quarantine, `TIMEOUTS`; the run is flagged |
| Host platform hang (bigserver's history) | engine reads touch only host RAM, never config space or MMIO; no resets. First runs low-rate with the BMC watchdog armed |
| Data read from the wrong page | data check (§6.4) |
| Timing at 250 MHz | small logic; register the sink decision; the mux is one level |

## 12. Experiments it enables

All on bigserver first (drives held, strict boot), then icx with S8.

**X0, bring-up (minutes).**
- `pips bg probe --target b3:00.0 --iova <bg base>`: expect SC and the page
  tag as data.
- Same at `<bg base> + <unmapped>`: expect UR or CA and one DMAR fault.
- `rid=b3:00.0`: expect config error 1.
- Drive 0 under an alias load with the engine at 1 M reads/s:
  - no AER and no unexpected completions on the drive;
  - drive IOPS unchanged;
  - `CPL_SC == ISSUED`.

**X1, IOTLB geometry by latency (engine alone, drives idle in hold).**
- Setup: `MAX_OUT=1`, `INTERVAL=1000`, trace on: each read's latency, one at
  a time. A hit and a miss differ by at least one memory access, so the trace
  is bimodal.
- Cyclic ws 16-256 in steps of 8: the capacity knee, exact.
- Table-mode prime/probe lists (fill A1..An, touch B, re-probe A1..An): the
  replacement order (LRU, pseudo-LRU, random) and, with strides, the set
  structure.
- Settles bigserver's "~96" and icx's 4 vs 8 ways without pcm-iio.
- Strides of 512 and more show the page-walk-cache levels as more latency
  steps.

**X2, walker throughput.**
- ws 8 (all hits) against ws 65,536 (all misses), and stride 512 (directory
  misses).
- Sweep `MAX_OUT` 1-256 and `INTERVAL`: reads/s and latency.
- Gives the IOMMU's translation throughput and miss service time: what a
  busy IOMMU costs.

**X3, the target: page order becomes misses.**
- Drive 0 alias load, ws 8, strict cyclic. The out cap shapes its writes into
  one burst per 1.024 µs window: `rcapout` 80 = 16 writes = one drive page per
  window, 32 Gb/s.
- Engine in drive 0's domain, idle-fill (`ARB = 0`), cyclic ws 65,536.
  ~176 idle cycles per window give up to ~170 engine pages per gap, more than
  the ~96 entries.
- Within a burst no engine read interleaves, so a run of writes to one page
  hits. Across windows the page is evicted.
- Prediction: drive misses per page ≈ runs per page that cross a window.
  That is ~8.6 at d1t0c1, and near 1-2 with depth 16 and page batching.
- Sweeps:
  - engine rate (`INTERVAL`), against the eviction threshold;
  - out cap 40-160 beats;
  - d1, d16 × pb 0/1;
  - one drive and both.
- Read the drive's latency and IOPS for the cost.

**X4, across domains.**
- As X3 with the engine in drive 1's domain (`target=b4:00.0`) while only
  drive 0 runs.
- If drive 0's misses rise the same way, the IOTLB is shared across domains:
  any device's traffic evicts any other's. That is the production case.

**X5, device latency under IOMMU load.**
- Drive alias loads with no cap, the engine at 0-200 M misses/s in round
  robin: completion latency and IOPS against engine load.
- This is the "IOMMU busy" cost at the application.

## 13. Open questions for the hardware side

1. **Is the bridge's ID attached to the device's domain?** Settled on the host
   by X0, not in RTL. If not, the fallbacks are:
   - a device ID with an engine tag window: unsafe, since the device's own tag
     use is unknown, so not proposed;
   - letting the engine read the device's own pages under the device's ID
     only while that device is idle;
   - a host-side kernel helper that maps the background region for the
     bridge.
2. **RC straddle.** `pips.tcl` sets RQ straddle off but doesn't set the
   512-bit RC straddle option. `pcie_axis_rc_route.v` reads one descriptor at
   DW0 per beat, so the current build must deliver at most one TLP start per
   beat. Confirm the IP default (`AXISTEN_IF_RC_STRADDLE` or equivalent). The
   sink inherits the same assumption.
3. **NP credit outputs on `pcie_versal`.** Does the Versal core expose
   `pcie_tfc_nph_av` / `npd_av` (or an equivalent) in Switch_Port_Upstream
   mode? If not:
   - keep `MAX_OUT` small, default `ARB = 0`;
   - measure device write throughput with the engine at rising rates (X0,
     X5);
   - report `STALL_ARB` instead of `STALL_FC` (`BG_CAPS[30] = 0`).
4. **10-bit tags.** 256 tags bound the engine at ~250 M/s with a 1 µs round
   trip. 10-bit tags (if the core and the root port allow them) would give
   1024. Not needed for X0-X4.
5. **The `is_eop0_ptr` value** for a payload-less request (§4.1): check
   against a captured device MRd.
6. **Throughput of `axis_data_fifo_usp_rc` + the sink at one completion per
   cycle** while the drives' own completions (SQ fetches) pass: confirm no new
   bottleneck at the route.
