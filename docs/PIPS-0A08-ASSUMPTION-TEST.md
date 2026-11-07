# PIPS design 0x0A08: the assumption-test build

Status: **built** (FPGA repo `5fe3bda`, 2026-11-06: P1-P3, everything in §3;
the FPGA side's decisions H1-H16, e.g. a START state and config errors 11/12,
in that repo's `0A08_UPGRADE_PLAN.md` §2 and `sw_handoff/README.md` §12).
Host tools for the live tests written 2026-11-07 (§5.2): `pips bg`,
`scripts/pips/pips-rid-live.sh`, `pips_bg_pages.ko`. **First run on
bigserver 2026-11-07 (§4, "First run"): T2/T3 pass, so F0 holds; T4 found
that the engine's tags must stay out of the devices' tags (A11). Second
run (01:37, engine tags 128-255): T0-T5 and T9 pass, 32 M reads clean under
load; T7 separable at 2.6% error; T8 inconclusive, and the IOTLB looks
reuse-protected (§4 "Second run"); T8 rewritten.**

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
| A11 | (found in the first run, 11-07) The core tracks outstanding requests by tag alone, and device tags pass through to it unchanged, so engine tags must be disjoint from every device's tags even under a port's ID | no | T0 census sets the engine's window; T4 (`CPL_MALFORMED`, `WIN_HITS`) |
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

### First run: bigserver, 2026-11-07 01:04 (`dualssd/1106/rid-live/`)

T0-T3 PASS, T4 FAIL, T5 PASS, T6 no data. Stopped after T4 (3 min).

- **T2, T3: F0 holds.** A read under in0's port ID (`b2:00.0`) returned
  drive 0's page tag (page 5: `0x5`; 64 reads, all SC, no data mismatch, mean
  1033 ns); in1's port returned drive 1's (tag 7; 16 reads). Page 32, mapped
  only in drive 0's domain, read SC with tag 32 through in0's port and UR
  through in1's. No DMAR line, no AER change. The host check (`pips-rid-check.sh`)
  agreed.
- **T1:** the upstream port's ID read: UR, as expected (nothing mapped).
- **T0/T5:** no straddle on RC or RQ, idle or under load. TFC present,
  NPH/NPD 15.
- **T4: every train (32 of 32) stopped within 1-4 ms**, after 6-769 reads,
  on one `CPL_MALFORMED` and the matching timeout (2 and 2 in four trains).
  No leak, no unexpected completion, `CPL_SC = ISSUED` (the malformed
  completion is SC). The devices' load ended clean.
  - In the RTL a completion is malformed when it is SC and its byte count is
    not `4*READ_DW` or the core's "request completed" bit (RC descriptor
    bit 30) is clear. With the bit clear the tag is not freed, so it times
    out 1 ms later.
  - **Cause: the engine's tags collide with the devices' tags in the core.**
    `cq_to_rq_converter` passes each device's tag to the upstream core
    unchanged (client tags on), and the core tracks its outstanding requests
    by tag alone. The census under load: drive 0 uses tags 0-127, drive 1
    0-63, none uses 128-255. In the 12 trains whose malformed completion was
    the last one (`last_cpl_tag` is its tag) the tag was 7-111 every time,
    inside drive 0's range (p = 1/4096 by chance). The 80 reads of T2/T3,
    idle, had none.
  - In0 and in1 already share tags 0-63 in the core; the devices don't care,
    since the router passes completions by requester ID and never reads
    bit 30.
- **A11 (new):** the engine's tags must be disjoint from every device's tags
  even under port IDs (F0): the requester ID keeps the sink and the router
  right, but the core's own completion tracking is per tag.
- **Next:** a fresh run, `pips-rid-live.sh --start-holder --reboot --tmux`.
- **Fixed in the script (11-07):** every engine run from T1 on uses
  `tagwin=` = the largest range no device used in T0's census (here
  128-255), MAX_OUT capped at its size (T4's 256 becomes 128); T4 fails on
  `CPL_MALFORMED` or `WIN_HITS` > 0; a run with a malformed completion or a
  timeout saves `pips bg capture 64` (now with `req_done=`), so the next run
  shows which field the core sets.
- **For 0x0A09:** the tag window should default to the upper half (or be
  required), and the hardware agent should know that 8-bit device tags pass
  through to the core: a device that uses all 256 tags leaves the engine
  none.

### Second run: bigserver, 2026-11-07 01:37 (`dualssd/1106/rid-live/pips-rid-live-bigserver-1107-013752/`)

Engine tags 128-255 (T0's census). T0-T5 PASS, T6 no data, T7 "FAIL" (see
below; a pass under the revised rule), T8 no conclusion, T9 PASS. 6 min.

- **T2/T3 again PASS** (F0), **T4 PASS: 32 trains, 32 M reads, every one
  SC**: no malformed completion, no timeout, no leak, `WIN_HITS` 0 (no
  device tag entered 128-255). A11 holds with the window.
  - Rates: the engine-first trains reach the limit set by the outstanding
    reads, up to 97 M reads/s at MAX_OUT 128 (128 / 1.25 µs; latency
    1.25 µs there vs ~0.95 µs at low depth). Idle-fill trains reach at most
    0.68 M reads/s: the drives' traffic leaves few idle cycles. With
    INTERVAL 1000 (4 µs) both give 0.2-0.25 M/s.
  - Each train issued `count=1000000` and so ended in 0.04-5 s, not 20 s:
    the drives' IOPS windows were empty for the fast ones, and T6 had no
    data. Where windows had data (the slow trains) the drives stayed at
    865/789 kIOPS (baselines 860-876 / 782-788). Fixed: `count=0`, 20 s each.
- **T5 PASS:** no straddle over 32 M reads.
- **T7: hit and miss separate by median, not by tail.** ws 8 (hits): p50
  688 ns, p99 972; ws 4096 (misses, page-walk cache hits): p50 1076, p1 892.
  At 832 ns 2.6% are misclassified. A 2 MB stride (s512) gives 1436 ns, a
  1 GB stride 1592 ns: each walk level adds ~0.2-0.4 µs. Counting misses as
  fractions works, one-by-one with ~3% error. The rule is now: a pass when
  <= 5% are misclassified.
- **T8: no conclusion, and a new observation about the IOTLB's
  replacement.** The test read P twice, then N filler pages (the same
  ones every round), then P. In the drive-0-only control the filler
  missed more and more with N (N = 32/64/96/128/256: 2/51/67/75/88%), yet
  P hit every time. Pages 0-15 (read three times a round) even hit on
  their first read in every later run, after thousands of misses in
  between. The likely reading is that **an entry used more than once is
  protected from single-use misses** (segmented-LRU-like), and the miss
  rate rises gradually instead of as an LRU cliff. If so, an evictor's
  one-shot reads cannot displace a device's hot entries; it would have to
  reuse its own pages. Cross (drive 1's pages) missed less than the control
  at every N (16/44/58/79% at 64-256), which a shared cache wouldn't show
  unless the leftovers differ.
  - **T8 rewritten:** every run starts from a flushed IOTLB (the holder's
    `map` unmaps and maps both regions), reads only fresh pages, and has
    three cases per N (32-512): `once` (P, N drive-0 pages, P: the capacity
    C), `cross` (N drive-1 pages through in1's port: A7), `twice` (P read
    twice: protection). On simulated caches the verdict reads shared LRU,
    shared + protection, and partitioned correctly.
- **T9 PASS:** over 2 min of load, drive 0 used tags 0-127, drive 1 0-63.
- **Next:** the same command again, a fresh holder (`--start-holder
  --reboot --tmux`), ~25 min: T4 with 20 s trains (T6's IOPS), T8 v2.

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

### 5.2 With the bitstream (written, 2026-11-07)

As written (the plan that follows below it is kept for the record):

- **`pips bg`** (`pips.c`, registers `PIPS_BG_*` in `pips_regs.h`, copied
  from the FPGA repo's `sw_handoff/pips_regs.h`): `info`, `set K=V...`,
  `start`, `stop`, `wait`, `run [K=V...] [secs=S]`, `counters`, `clear
  [twice]`, `hist`, `trace FILE`, `capture [N]`, `census [clear|freeze|thaw]`,
  `facts [clear]`, `table load FILE | show`. RIDs by name (`in0`, `in1`,
  `usp`, `dev0`, `dev1`) from `BG_BUS`. `bg run` stops the engine on every
  exit path (signals, leak, clash, errors); every CTRL write that is not a
  start or stop keeps RUN as it is and undoes a start it caused by a race.
  `pips bg help` lists the keys.
- **`scripts/pips/pips-rid-live.sh`:** T0-T9, T10/T11 with `--fallbacks`
  (or `--t10`, `--t11`), T12 with `--t12`; `--help`. bigserver through the
  alias-nvme holder (a running one, or `--start-holder`), whose new `map`
  command re-tags the regions before each data check; icx with
  `--load-cmd` and pages from a TLP log. `summary.txt` per test: pass
  condition, numbers, DMAR lines per BDF, AER deltas, verdict; then the
  decision of the tree above.
- **`scripts/pips/ridcheck/pips_bg_pages.c`** (§5.3): written; T11 builds
  it (`make MODS=pips_bg_pages`).
- **Not done:** `pips_sim.c` has no model of the engine (no `make check`
  coverage of `pips bg`). Nothing has run on hardware; the C was only
  syntax-checked on Windows and the script's Python parts on synthetic
  data.

The plan, as written before the build:

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

### 5.3 Only if T2 fails: `pips_bg_pages.ko` (F3 helper; written 11-07)

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
