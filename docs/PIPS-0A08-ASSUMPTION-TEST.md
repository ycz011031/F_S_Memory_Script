# PIPS design 0x0A08: the assumption-test build

Status: **proposal, 2026-11-06. Nothing built.**

The background read engine ([PIPS-BG-READ-ENGINE.md](PIPS-BG-READ-ENGINE.md),
"the engine doc") rests on assumptions the host alone can't prove. The main
one is that a read carrying a switch port's own requester ID is translated
through the IOMMU domain of the device below that port. Design `0x0A08`
exists to test each assumption on the wire, and each fallback if one fails,
before anything is built on them.

`0x0A08` = **the engine core of the engine doc** (§4-§6, §8 there: issuer,
completion sink, mux, tags, timeouts, latency, counters, table) **plus the
test extensions below** (§3). If the assumptions hold, this build already runs
the engine experiments X0-X2, and X3 with idle-fill. A later build (`0x0A09`)
then adds only what the test results ask for.

Readers: the hardware agent (§2-§3, §6), and the software sessions that write
the test tools and run the tests (§4-§5).

---

## 1. The assumptions, and how each is tested

| # | Assumption | Host-only check now | Live test in 0x0A08 |
|---|---|---|---|
| A1 | A read with a downstream port's ID (`b2:00.0`) is translated through its device's domain (`b3:00.0`'s): same IOMMU group, so same domain | `scripts/pips/pips-rid-check.sh`: groups; the IOMMU's context/PASID entries (debugfs); the kernel's domain and `iova_to_phys` (module); under VFIO for drive 0 | T2, T3 |
| A2 | The root complex accepts and completes non-posted requests whose requester is a switch port (a Type-1 function) | no | T2 |
| A3 | Those completions come back on the upstream port's RC interface, the sink takes all of them, and none reaches a device | no | T2, T4 (leak monitor), AER |
| A4 | The core accepts the engine's RQ beat (Requester ID Enable, client tag, `is_eop0_ptr`) | no | T1 |
| A5 | The RC interface delivers at most one TLP start per beat (no straddle), under load | no | T5 (straddle counters) |
| A6 | NP credits are visible to user logic, or an engine read waiting for credits doesn't stall the devices' posted writes | no | T6 (credit and head-of-line counters) |
| A7 | One IOTLB serves all domains of a unit, so traffic in one domain evicts another's entries | no | T8 (cross-domain prime/probe by latency) |
| A8 | Per-read latency separates an IOTLB hit from a miss | no | T7 |
| A9 | Fallback F2 is viable: a device uses a known, bounded set of tags, so a disjoint window is free for engine reads under the device's own ID | no | T9 (tag census), T10 |
| A10 | Fallback F3 is viable: a port with its own DMA domain, with background pages mapped by a kernel helper, translates engine reads | partly (the module shows the port's domain type) | T11 |

## 2. Fallbacks, and what each needs

| | When | Requester ID | Pages | Needs |
|---|---|---|---|---|
| **F0** (primary) | A1-A3 hold | the device's downstream port | mapped in the device's domain by the host tool (alias-nvme's region, or the engine doc's background region) | nothing more |
| **F1** | only one port works | the other port | in that port's device's domain | nothing more. If A7 holds, evicting the other domain's entries still works for the target experiment X3 |
| **F2** | the ports are not in their devices' domains, or the root complex refuses a port as requester | **the device's own ID**, engine tags only from a window the device never uses (census, T9) | the device's own domain | `UNSAFE_KEY`, tag window, sink in RID+tag mode, the clash detector (§3.2). Only if T9 shows a large unused tag range and T10 passes |
| **F3** | a port has its own DMA domain (not attached to the device's) | the port (DSP or the upstream port) | mapped for the port's own `struct device` by a host kernel helper (`dma_map_page`, IOVAs exported) | the helper module `pips_bg_pages.ko` (§5.3). Useful for X3 only if A7 holds |
| **F4** | nothing above works | none | none | the engine can't evict entries from inside the switch. The study then stays with the device-generated patterns (alias campaigns) |

F2 is the riskiest. A clash, where the device reuses a window tag while an
engine read with that tag is outstanding, would hand one completion to the
wrong requester. §3.2 makes the hardware detect it and stop, and T10 runs F2
first with the device idle, then with the device under load.

## 3. Test extensions (on top of the engine core)

Same AXI segment as the engine, `0xA402_0000`, 64 KiB. **`BG_ID` reads
`0x5249_4450` ("RIDP")** on this build, so tools know the test build from the
engine (`0x4247_5244`). `BG_VERSION` `0x0001_0000`. Everything in the engine
doc's §7 keeps its offset and meaning except the table entry format (§3.1).
The extensions use offsets `0x200-0x2FF` and `0x1000-0x17FF`, unused in the
engine map.

### 3.1 Requester ID slots

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x018` | `RID` | RW | 0 | slot 0 (the engine doc's `RID`) |
| `0x204`, `0x208`, `0x20C` | `RID_SLOT1..3` | RW | 0 | slots 1-3 |

- **Pattern mode:** every read uses slot 0.
- **Table mode:** each entry picks its slot. A **table entry** is `[29:0]` the
  page index relative to `BASE`, `[31:30]` the RID slot. (The engine doc's
  §6.2 and §7.3 change the same way for `0x0A09`.)
- So a single table can interleave reads from different domains, in an exact
  order (T8's prime/probe).

**Start check (config error 1)** for every slot the run uses:
- **Allowed:** `{secondary, 0, 0}`, `{secondary, 1, 0}` (the downstream ports)
  and `{primary, 0, 0}` (the upstream port).
- **Device IDs** (bus in `secondary+1 .. subordinate`) are allowed only with
  all three of these:
  1. `UNSAFE_KEY` written;
  2. `TAG_WIN` enabled;
  3. sink mode RID+tag.
- **Anything else** is refused.

### 3.2 Tag window, device IDs, clash detector

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x210` | `TAG_WIN` | RW | 0 | `[7:0]` low tag, `[15:8]` high tag (inclusive), `[16]` enable: the engine takes tags only from the window (`MAX_OUT` ≤ window size, else config error 6) |
| `0x214` | `UNSAFE_KEY` | RW | 0 | write `0x5350_4F46` ("SPOF") to allow device IDs in slots; reads `[0]` = unlocked. Cleared by stop, `CLEAR` and reset |
| `0x218` | `CLASH` | RO | 0 | `[15:0]` count of **clashes**, `[23:16]` the last clashing tag, `[24]` its input (0 = in0) |

**Sink rule for a device-ID slot:** a completion is the engine's if its
requester ID equals the slot's ID **and** its tag is in the window **and**
the engine has that tag outstanding. Otherwise it passes to the device
untouched.

**Clash detector (hardware, always armed while a device ID is in use):** a
device MRd going upstream (in0 or in1, after `cq_to_rq_converter`) with that
device's ID and a tag the engine has outstanding in the window counts a
clash. It **stops the run at once** (`ERR_STOP`, whatever `STOP_ON_ERR`
says). A device MRd with a window tag while the engine does **not** hold
that tag is counted in the census (§3.4) as a window hit. Not a clash, but
the window isn't really free.

### 3.3 Leak monitor

| Offset | Name | Meaning |
|---|---|---|
| `0x220/224` | `LEAK_CPL` | completions seen **at the outputs of `pcie_axis_rc_route_0`** (either downstream path) that the sink should have taken: requester ID equal to an armed port-ID slot, or a device-ID slot with a tag the engine holds. **Must stay 0.** 64 bit |
| `0x228` | `LEAK_LAST` | `[15:0]` requester ID, `[23:16]` tag, `[24]` path (0 = dsp0) |

It watches the router's outputs, independent of the sink, so a sink bug
can't hide itself.

### 3.4 Census (passive, always on, no engine run needed)

Records what the devices themselves do. F2 needs it, and it's useful anyway.

| Offset | Name | Meaning |
|---|---|---|
| `0x240` | `CENSUS_CTRL` | write `[0]` = 1: clear everything below; `[1]` freeze (stop counting) |
| `0x244/248` | `IN0_MRD` | device MRds seen on in0 (64 bit) |
| `0x24C/250` | `IN1_MRD` | the same on in1 |
| `0x254` | `IN_TAG_MAX` | `[7:0]` the highest MRd tag seen on in0, `[15:8]` on in1 |
| `0x258` | `WIN_HITS` | device MRds with a tag inside `TAG_WIN` (any time; for F2) |
| `0x260-0x27C` | `IN0_TAGS` | 256-bit map: MRd tags in0 has used (bit t = tag t) |
| `0x280-0x29C` | `IN1_TAGS` | the same for in1 |
| `0x2A0-0x2BC` | `CPL0_TAGS` | tags of completions sent down path dsp0 |
| `0x2C0-0x2DC` | `CPL1_TAGS` | the same for dsp1 |

Tap points: the batcher inputs `s_axis_0` / `s_axis_1` (descriptor
`[78:75] = 0000` and `[103:96]`), and the router outputs.

### 3.5 Interface facts

| Offset | Name | Meaning |
|---|---|---|
| `0x2E0` | `RC_STRADDLE` | RC beats (at the sink's input) with a second TLP start (`is_sop[1]`) or a start not at DW0 (`is_sop0_ptr ≠ 0`). Must stay 0 (A5) |
| `0x2E4` | `RQ_STRADDLE` | the same on the batcher output (RQ straddle is configured off) |
| `0x2E8` | `TFC` | `[3:0]` `pcie_tfc_nph_av` live, `[7:4]` `npd_av` live, `[11:8]` the lowest `nph_av` since clear, `[31]` the port exists in this build (§13 Q3 of the engine doc) |
| `0x2EC/2F0` | `HOL_ENGINE` | cycles the upstream port's `s_axis_rq` had `tvalid & !tready` with an engine beat at the head |
| `0x2F4/2F8` | `HOL_DEVICE` | the same with a device beat at the head (the baseline) |
| `0x2FC` | `FC_CLEAR` | write 1: clear `0x2E0-0x2F8` |

### 3.6 Completion capture

A ring of the last 64 completions the sink took, for reading by hand.
`0x1000 + 32*i`, 8 words each:

| Word | Content |
|---|---|
| 0, 1, 2 | the three RC descriptor DWs |
| 3, 4 | the first two payload DWs |
| 5 | latency (cycles) |
| 6 | sequence number (low 32) |
| 7 | `[1:0]` RID slot, `[8]` timed out before it came |

`0x0FF0` `CAP_WPTR` holds the next write index (mod 64) and the count of
entries ever written (`[31:8]`). Cleared by `CLEAR`.

### 3.7 Priorities for the build

- **P1, needed for T1-T8:**
  - from the engine core: issuer, sink, mux (idle-fill and engine-first),
    tags, timeouts, counters, latency min/max/sum, trace, table with RID
    slots;
  - from the extensions: leak monitor, census, straddle counters, capture.
- **P2, needed for the fallback tests:** tag window, device IDs,
  `UNSAFE_KEY`, clash detector (F2, T9-T10); `TFC` and the head-of-line
  counters (T6; `TFC[31] = 0` if the core has no such port).
- **P3, the engine's own extras:** random order, histogram, data check. Build
  them now if they're cheap; X1-X3 use them.

Testbench: the engine doc's §9.1, plus these cases:
- slot mixing in table mode;
- device-ID mode with injected device MRds that use a window tag (expect a
  clash and a stop);
- device completions with window tags the engine doesn't hold (expect them
  passed through);
- a forced sink bypass (expect the leak monitor to count);
- straddled RC beats from the responder model (expect `RC_STRADDLE` to
  count).

## 4. The live tests (after the bitstream)

The order below is the order to run. Each test lists its pass condition and
what a failure means. "Region" means alias-nvme's mapped region (bigserver,
held drives, IOVA `0x40_0000_0000`, every page tagged with its backing
index), or the alias-rdma memory region (icx).

- **T0, before any engine read.** Do these:
  - `pips-rid-check.sh` (the host-only checks, already written; §5.1);
  - census on, with an alias load running;
  - read `RC_STRADDLE`, `RQ_STRADDLE`, `TFC`.

  Pass: zero straddle; census tag maps saved. This gives the baseline for T9.
- **T1, request accepted (A4).** One read, `count=1`, upstream-port ID
  (`{primary,0,0}`), region IOVA.
  - Expect a completion with UR or CA: the upstream port has no mapping. A
    DMAR fault line naming `b1:00.0` (bigserver) appears in dmesg.
  - Pass: one completion came back, so the core sent the request and the
    sink caught the reply.
  - No completion and `TIMEOUTS = 1`: the beat format is wrong (A4) or the
    root complex dropped it. Check the ILA capture.
- **T2, the main assumption (A1-A3).** `count=1`, slot 0 = drive 0's port
  (`b2:00.0`), region page 0.

  Pass, all three must hold:
  - status SC;
  - payload DW0 equals the page tag;
  - no new DMAR fault, `LEAK_CPL = 0`, drive AER counters unchanged.

  Then 64 reads over the region's pages; each SC returns its own page's tag.
  - UR/CA with a DMAR fault naming `b2:00.0`: A1 fails. Go to T11 (F3), then
    T9-T10 (F2).
  - No completion: A2 or A3 fails. Check the capture and the leak monitor,
    then go to F2.
- **T3, the domain is the device's (A1, isolation).** Give the two drives
  different regions. Holder `load` extras: drive 0 ws 64, drive 1 ws 16, so
  page 32 is mapped only in drive 0's domain.
  - Read page 32 through `b2:00.0`: expect SC and the tag.
  - Read page 32 through `b2:01.0`: expect UR/CA and a fault naming
    `b2:01.0`.

  Pass: both. This proves each port uses its own device's domain, not some
  shared one.
- **T4, no leak under load (A3).** Drive 0 and drive 1 under an alias load.
  Engine trains through `b2:00.0`: 10^6 reads at `INTERVAL` 1000, 100, 10, 1,
  `MAX_OUT` 1, 8, 64, 256, idle-fill and engine-first.

  Pass, all of these:
  - `LEAK_CPL = 0`, `CPL_UNEXPECTED = 0`;
  - no drive error: alias-nvme stays clean, AER counters unchanged;
  - `CPL_SC = ISSUED`.

  Record drive IOPS against engine rate, as a first look at X5.
- **T5, straddle under load (A5).** During T4: `RC_STRADDLE = 0`,
  `RQ_STRADDLE = 0`. If not, the sink and the router both need straddle
  handling before anything else.
- **T6, flow control (A6).** During T4 at the highest rates:
  - `TFC` (if present): the lowest `nph_av` seen;
  - `HOL_ENGINE` against `HOL_DEVICE`;
  - drive write throughput against the engine-free baseline.

  Pass: no drive throughput loss in idle-fill mode. If engine-first loses
  throughput and `TFC[31] = 0`, the engine needs `0x0A09` with credit gating,
  or stays at idle-fill.
- **T7, latency separates hit and miss (A8).** Engine alone, `MAX_OUT = 1`,
  `INTERVAL = 1000`, trace on.
  - Cyclic ws 8 (all hits) and ws 4096 (all misses), table of the region's
    pages.
  - Pass: the trace's two latency distributions don't overlap. That fixes
    the hit/miss threshold.
  - Then strides of 512 and 262,144 pages (directory and higher-level walk
    misses) give the further steps. This is X1 starting.
- **T8, one IOTLB for all domains (A7).** Table mode, `MAX_OUT = 1`, one
  read in flight at a time.
  1. Read page P through `b2:00.0` twice: the second is a hit.
  2. Read N distinct pages through `b2:01.0` (drive 1's domain), N = 32, 64,
     96, 128, 256.
  3. Read P through `b2:00.0` again.

  - P misses after N ≈ the IOTLB's capacity: the IOTLB is shared across
    domains.
  - P stays a hit at N far above capacity: entries are partitioned by domain.

  Control: the same with the N pages through `b2:00.0`.
- **T9, tag census (A9).** Census during each device's alias load (and on
  icx, the NICs'), several minutes. Read `IN*_TAGS`, `IN_TAG_MAX`.
  - Pass for F2: a contiguous range of ≥ 64 tags unused by that device, which
    becomes the window.
  - Repeat at the load the target experiment uses: a device's tag set may
    grow with queue depth.
- **T10, F2 trial (only if T2 failed and T9 passed).** Slot 0 = the drive's
  own ID (`b3:00.0`), `UNSAFE_KEY`, `TAG_WIN` = the free range, sink
  RID+tag.
  1. Drive idle (held, no load): the T2 checks again.
  2. Drive under load: T4's trains.

  Pass: `CLASH = 0`, `WIN_HITS = 0`, `LEAK_CPL = 0`, no drive error, and the
  data matches. Any clash: F2 is unusable at that load.
- **T11, F3 trial (if T2 failed with a fault naming the port).**
  `pips_bg_pages.ko` (§5.3) maps N pages for the port's (or the upstream
  port's) own device and prints their IOVAs. Load them into the table and read
  through that port's ID.
  - Pass: SC and the tags.
  - Then repeat T8 with these pages as the evictors. F3 serves X3 only if the
    drive's entries get evicted.
- **T12, soak.** The chosen mode (F0, F2 or F3) at the rate X3 needs, with
  both drives under load, 30 minutes. Same pass conditions as T4, and no
  host trouble.
  - bigserver: the guard (BMC watchdog) armed, hold mode, reboot at the end
    as in the alias campaigns.

### Decision after the tests

```
T2 pass, T3 pass           -> F0. T4-T8 decide rates, mux mode, credit gating -> 0x0A09 = engine extras only
T2 fail (fault, port named)-> T11 (F3); T8 decides if F3 can evict the drive's entries
T2 fail (no completion)    -> sink/route/root-complex problem: capture, leak, ILA; then F2
F3 not usable              -> T9/T10 (F2)
F2 clashes or no free tags -> F4: no in-switch evictor; the study keeps the alias campaigns
```

## 5. Software for the tests

### 5.1 Now: `scripts/pips/pips-rid-check.sh` (written, 2026-11-06)

Host-only checks of A1 (and the port's domain type, for A10), runnable today
on both hosts:

```
bash scripts/pips/pips-rid-check.sh --module --pt                 # icx, bigserver: as found
bash scripts/pips/pips-rid-check.sh --module --pt --vfio-drive0    # bigserver: also with drive 0 in VFIO
```

What it does:
- **Topology, groups and drivers:** groups, group types, drivers, Bus Master
  Enable bits.
- **Hardware tables:** the IOMMU's context entries, or scalable-mode PASID
  entries, for each port and its device (Intel debugfs, if the kernel has
  it).
- **Page tables:** the IOMMU page tables at given IOVAs.
- **Kernel view:** `ridcheck/pips_iommu_peek.ko`, read-only. It reports the
  same `iommu_domain`, and `iommu_iova_to_phys` through the port and through
  the device.
- **Drive 0 under VFIO:** with `--vfio-drive0`, the same again while drive 0
  alone is in VFIO for a 75 s alias-nvme run (the 9100 PRO; the 990 is
  refused).
- **Baselines:** DMAR fault lines and AER counters.

Verdict in `summary.txt`: HOLDS / FAILS / NOT DECIDED.

### 5.2 With the bitstream

- **`pips bg` (`pips.c`):** the engine doc's §10 S2, plus:
  - `rid1= rid2= rid3=`;
  - `tagwin=LO-HI`;
  - `unsafe` (writes the key);
  - `pips bg census [clear]`: tag maps as ranges, counts, the largest free
    tag range per input;
  - `pips bg leak`, `pips bg facts` (straddle, `TFC`, head-of-line);
  - `pips bg capture` (the ring, decoded);
  - `pips bg table load FILE` accepting `page[:slot]` lines.
- **`pips_sim.c`:** model the extensions: slots, window, clash on an
  injected device MRd, leak counter, census.
- **`scripts/pips/pips-rid-live.sh`:** runs T0-T9 (T10-T12 by flag) in
  order. For each test it states the pass condition and the result, keeps
  dmesg/DMAR/AER deltas around each test, and stops at the first failure
  with the fallback to take. It works with the holder on bigserver (region
  IOVAs from `hold/`; drive 1 ws 16 for T3) and with alias-rdma on icx (MR
  IOVA base from a short TLP log, the engine doc's S8). Heartbeat lines
  throughout.

### 5.3 Only if T2 fails: `pips_bg_pages.ko` (F3 helper)

A small kernel module:
- **Mapping:** allocates N pages (default 4096), writes each page's index
  into its first 8 bytes, and maps them with `dma_map_page(&port->dev, ...)`
  for a given port. That works only if the port's domain is a DMA-API domain;
  `pips-rid-check.sh` reports the type.
- **Export:** the IOVAs go out through a debugfs or sysfs file, which `pips bg
  table load` reads.
- **Unload:** unmaps and frees.

Read-only from the device's point of view: the engine only reads these
pages.

## 6. Build integration

As the engine doc's §9 (module references, mux before `m_axis_upstream_rq`,
sink before `pcie_axis_rc_route_0`, AXI segment `0xA402_0000` in both address
spaces, `pips_design_id` → `0x0A08`), plus:

- **Census taps:** `axi4_mwr_batch_top_0/s_axis_0` and `s_axis_1`
  (monitor-only branches of those AXIS nets).
- **Leak and completion-census taps:** `pcie_axis_rc_route_0/m_axis_rc_dsp0`
  and `m_axis_rc_dsp1` (monitor-only).
- **Head-of-line monitor:** the upstream port's `s_axis_rq`
  `tvalid/tready`, and the mux's "head is engine" flag.
- **Flow control:** `pcie_tfc_nph_av` / `npd_av` from
  `pcie_versal_upstream_port`, if the IP has them (engine doc §13 Q3).
- **ILA:** the sink decision, the leak monitor, the clash detector, the
  issue handshake.

Record the design in `PIO_KNOWLEDGE_MAP.md` §9, `sw_handoff/README.md` and
`pips_regs.h`. In this repo, `scripts/pips/PIO-MANUAL.md` §6 gets a row for
the design ID and a pointer to these two docs.
