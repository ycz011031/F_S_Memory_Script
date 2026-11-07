/*
 * pips_regs.h - PIPS host register map, BAR0 map v2.1
 *
 * Source of truth (FPGA repo Programmable-Intelligent-PCIe-Switch):
 *   BAR0 map and WIN_* semantics : src/pio_pips/pips_pio.v (header comment)
 *   AXI address map              : pips.tcl, assign_bd_address lines for pips_pio_0/m_axi
 *   Batcher config bit fields    : pips.tcl, comment above "Create instance: xlslice_0"
 *   Page batcher reg2/reg3/status: src/switch/pips_batch_ctrl.v (header), design 0x0A06 on
 *   Telemetry log format         : AXI4-switch repo, telemetry_dma_format.md
 * If one of those changes, this file must change with it.
 */
#ifndef PIPS_REGS_H
#define PIPS_REGS_H

#include <stdint.h>

/* ------------------------------------------------------------------ PCI identity */
#define PIPS_VENDOR_ID          0x10EEu
#define PIPS_USP_DEVICE_ID      0xB048u   /* upstream switch port: owns BAR0 */
#define PIPS_DSP0_DEVICE_ID     0xB148u   /* downstream port zero */
#define PIPS_DSP1_DEVICE_ID     0xB348u   /* downstream port one */
#define PIPS_BAR0_SIZE          0x8000u   /* 32 KB, 64-bit, non-prefetchable */

/* ------------------------------------------------------------------ BAR0 regions */
#define PIPS_BRAM_OFF           0x0000u   /* 2 KB scratch memory */
#define PIPS_BRAM_SIZE          0x0800u
#define PIPS_REG_BLOCK_OFF      0x0800u   /* registers below */
#define PIPS_WIN_OFF            0x4000u   /* AXI window: AXI addr = WIN_BASE + (off - 0x4000) */
#define PIPS_WIN_SIZE           0x4000u   /* 16 KB */

/* ------------------------------------------------------------------ BAR0 registers (32-bit) */
#define PIPS_REG_ID             0x800u    /* RO  PIPS_ID_VALUE */
#define PIPS_REG_VERSION        0x804u    /* RO  [31:16] major, [15:0] minor */
#define PIPS_REG_SCRATCH        0x808u    /* RW */
#define PIPS_REG_BUS_NUM        0x80Cu    /* RO  routing_table bus numbers */
#define PIPS_REG_CQ_SPLIT       0x810u    /* RO  BAR-hit descriptor debug */
#define PIPS_REG_MWR_COUNT      0x814u    /* RO  BAR0 writes received (wraps) */
#define PIPS_REG_MRD_COUNT      0x818u    /* RO  BAR0 reads received, incl. this read */
#define PIPS_REG_PIO_STATUS     0x81Cu    /* RO */
#define PIPS_REG_MEM_BASE       0x820u    /* RO  routing_table: DSP device 1 memory window */
#define PIPS_REG_MEM_LIMIT      0x824u    /* RO */
#define PIPS_REG_PF_BASE_LO     0x828u    /* RO  ... prefetchable window */
#define PIPS_REG_PF_BASE_HI     0x82Cu    /* RO */
#define PIPS_REG_PF_LIMIT_LO    0x830u    /* RO */
#define PIPS_REG_PF_LIMIT_HI    0x834u    /* RO */
#define PIPS_REG_CTRL(n)        (0x840u + 4u * (unsigned)(n))   /* RW, n = 0..7, not wired yet */
#define PIPS_REG_WIN_BASE_LO    0x860u    /* RW  AXI address of BAR0+0x4000, [31:2] ([1:0] read 0) */
#define PIPS_REG_WIN_BASE_HI    0x864u    /* RW  [63:32] */
#define PIPS_REG_WIN_STATUS     0x868u    /* RW1C */
#define PIPS_REG_WIN_ERR_LO     0x86Cu    /* RO  AXI address of the last failed window access */
#define PIPS_REG_WIN_ERR_HI     0x870u    /* RO */
#define PIPS_REG_LOG_BASE_LO    0x874u    /* RO  DDR address of the telemetry log region (v2.1+) */
#define PIPS_REG_LOG_BASE_HI    0x878u    /* RO  0 */
#define PIPS_REG_LOG_BYTES      0x87Cu    /* RO  log region size in bytes; 0 = not configured */

#define PIPS_ID_VALUE           0x50495053u   /* "PIPS" */
#define PIPS_VERSION_VALUE      0x00020001u   /* map v2.1 */
#define PIPS_VERSION_MAJOR(v)   ((uint32_t)(v) >> 16)
#define PIPS_VERSION_MINOR(v)   ((uint32_t)(v) & 0xFFFFu)

/* BUS_NUM */
#define PIPS_BUS_PRIMARY(v)     ((uint32_t)(v) & 0xFFu)
#define PIPS_BUS_SECONDARY(v)   (((uint32_t)(v) >> 8) & 0xFFu)
#define PIPS_BUS_SUBORDINATE(v) (((uint32_t)(v) >> 16) & 0xFFu)

/* CQ_SPLIT: what the PCIe core reported for the last TLP on each side */
#define PIPS_SPLIT_PIO_APERTURE(v) ((uint32_t)(v) & 0x3Fu)
#define PIPS_SPLIT_PIO_BAR_ID(v)   (((uint32_t)(v) >> 8) & 0x7u)
#define PIPS_SPLIT_PIO_SEEN        (1u << 15)
#define PIPS_SPLIT_SW_APERTURE(v)  (((uint32_t)(v) >> 16) & 0x3Fu)
#define PIPS_SPLIT_SW_BAR_ID(v)    (((uint32_t)(v) >> 24) & 0x7u)
#define PIPS_SPLIT_SW_SEEN         (1u << 31)

/* PIO_STATUS */
#define PIPS_PIO_ST_CC_OVERFLOW (1u << 0)     /* sticky, must stay 0 */

/* WIN_STATUS: bits [4:0] sticky, write 1 to clear; bit 8 live */
#define PIPS_WIN_ST_RD_ERR      (1u << 0)     /* AXI read error response */
#define PIPS_WIN_ST_WR_ERR      (1u << 1)     /* AXI write error response */
#define PIPS_WIN_ST_TIMEOUT     (1u << 2)     /* no AXI response in time */
#define PIPS_WIN_ST_RD_SHORT    (1u << 3)     /* read went past its 64-byte block */
#define PIPS_WIN_ST_DROPPED     (1u << 4)     /* access dropped, AXI still busy after a timeout */
#define PIPS_WIN_ST_STICKY      0x1Fu
#define PIPS_WIN_ST_BUSY        (1u << 8)     /* read-only */

/* ------------------------------------------------------------------ AXI map (through the window) */
#define PIPS_AXI_REGFILE        0xA4000000ull /* axil4_regfile_0, 64 KB segment, 16 regs (64 B, repeats every 0x40) */
#define PIPS_AXI_DMA_LOG        0xA4010000ull /* axi_dma_log register space, 64 KB */
#define PIPS_AXI_DDR_BASE       0x00000000ull /* DDR4 through axi_noc_0 */
#define PIPS_AXI_DDR_SIZE       0x80000000ull /* 2 GB */

/* Batcher / logger config: axil4_regfile_0 reg0 at PIPS_AXI_REGFILE + 0x0
 * One field per byte lane; reserved bits read back what was written, write them 0. */
#define PIPS_BATCH_CFG_OFF      0x0u
#define PIPS_BATCH_DEPTH_SHIFT  0                       /* depth_threshold, 8 bits */
#define PIPS_BATCH_DEPTH_MASK   (0xFFu << PIPS_BATCH_DEPTH_SHIFT)
#define PIPS_BATCH_TIME_SHIFT   8                       /* time_threshold, 8 bits */
#define PIPS_BATCH_TIME_MASK    (0xFFu << PIPS_BATCH_TIME_SHIFT)
#define PIPS_BATCH_MRD          (1u << 16)              /* batch_mrd */
#define PIPS_BATCH_LOG_ENABLE   (1u << 24)              /* log_enable, rising edge arms a recording */
#define PIPS_BATCH_CFG_RESET    0x00000001u             /* depth 1, everything else 0 */

/* Batcher drain config: axil4_regfile_0 reg1 at PIPS_AXI_REGFILE + 0x4 (design ID >= 0x0A03;
 * older builds read 0 and ignore writes). Same byte-lane rule as reg0.
 * drain_depth_cap 0: one drain sends every packet in the FIFO when it starts (reset value)
 *                 1: one drain sends at most depth_threshold packets (0 counts as 1)
 * Safe to change at any time; a drain in progress keeps the size it started with. */
#define PIPS_BATCH_DRAIN_OFF        0x4u
#define PIPS_BATCH_DRAIN_DEPTH_CAP  (1u << 0)           /* drain_depth_cap */
#define PIPS_BATCH_DRAIN_RESET      0x00000000u
#define PIPS_DESIGN_ID_DRAIN_CFG    0x0A03u             /* first build with reg1 */

/* Page batcher (design ID >= 0x0A06: axi4_mwr_batch_pp, PAGE_BATCH 1), decoded by
 * pips_batch_ctrl_0 (FPGA repo src/switch/pips_batch_ctrl.v; pips.tcl above it).
 * Every field's 0 is its power-on value, so writing 0 restores the default.
 * reg2 at PIPS_AXI_REGFILE + 0x8: completion size per input. An MWr whose Dword Count
 *   is <= the threshold is a completion (control lane; a fence: that input's older data
 *   leaves first). 0 = 16 DW. Erring high only costs batching; a completion taken for
 *   data would lose the fence. MSI writes are caught by address whatever the threshold.
 * reg3 at PIPS_AXI_REGFILE + 0xC: mode and arbitration.
 *   page_batch_en 1 = batch per page (address >> 12), with per-device age order, a
 *                 completion lane and an overflow; 0 = one in-order FIFO per input with
 *                 axi4_mwr_batch's rules (the FIFO is the whole 1536-row array). A change
 *                 takes effect once that input's batcher is empty.
 *   ctrl_push_off 0 = a waiting completion makes every batch ahead of it eligible to drain
 *   grant_quantum beats one input may send in a turn while the other waits; 0 = no limit
 * batch_mrd (reg0 [16]) is tied off inside axi4_mwr_batch_pp: writable, no effect. */
#define PIPS_DESIGN_ID_PAGE_BATCH   0x0A06u   /* first build with reg2/reg3 and the status below */
#define PIPS_PB_THR_OFF             0x8u
#define PIPS_PB_THR0_SHIFT          0         /* ctrl_dw_thr_0, in0, 11 bits */
#define PIPS_PB_THR1_SHIFT          16        /* ctrl_dw_thr_1, in1, 11 bits */
#define PIPS_PB_THR_MAX             0x7FFu
#define PIPS_PB_THR_DEFAULT         16u       /* what a 0 field means (CTRL_DW_THR_DEFAULT) */
#define PIPS_PB_CFG_OFF             0xCu
#define PIPS_PB_EN                  (1u << 0)                 /* page_batch_en */
#define PIPS_PB_CTRL_PUSH_OFF       (1u << 8)                 /* ctrl_push_off */
#define PIPS_PB_QUANTUM_SHIFT       16                        /* grant_quantum, 12 bits */
#define PIPS_PB_QUANTUM_MAX         0xFFFu
/* Status, read-only. Reading 0x24 returns the sticky flags and CLEARS them, clears the
 * batcher's own status and latches 0x28/0x2C, so one 0x24 read closes a period; read
 * 0x28/0x2C after it. Saturating 16-bit counts; waits in 250 MHz cycles (4 ns). */
#define PIPS_PB_STAT_FLAGS_OFF      0x24u
#define PIPS_PB_STAT_OVF0           (1u << 0)                 /* in0 spilled to its overflow */
#define PIPS_PB_STAT_OVF1           (1u << 1)
#define PIPS_PB_STAT_STUCK          (1u << 2)                 /* liveness watchdog fired */
#define PIPS_PB_STAT_OVF_COUNT_OFF  0x28u                     /* [15:0] in0, [31:16] in1 */
#define PIPS_PB_STAT_MRD_WAIT_OFF   0x2Cu                     /* [15:0] in0, [31:16] in1 */

/* reg4 at PIPS_AXI_REGFILE + 0x10 (design >= 0x0A07): batcher rate caps, one byte per port,
 * n beats per 256-cycle window = n x 62.5 MB/s (n x 0.5 Gb/s of beats; header beats and partial
 * last beats count whole), 0 = uncapped (the power-on value). A loose token bucket
 * (axis_rate_cap.v): a port is held only between TLPs, never mid-packet, and MRd and completions
 * are held like data. The input caps sit ahead of the ingress stamp, so a log's pkt_wait
 * excludes their hold; the out cap sits after the output tap, so its hold is part of pkt_wait. */
#define PIPS_DESIGN_ID_RATE_CAP     0x0A07u   /* first build with reg4 and the counters below */
#define PIPS_RCAP_OFF               0x10u
#define PIPS_RCAP_IN0_SHIFT         0         /* rate_cap_0, in0 = s_axis_0 = downstream path one */
#define PIPS_RCAP_IN1_SHIFT         8         /* rate_cap_1, in1 = s_axis_1 = downstream path zero */
#define PIPS_RCAP_OUT_SHIFT         16        /* rate_cap_out, out = USP RQ */
#define PIPS_RCAP_MAX               0xFFu
#define PIPS_RCAP_WIN_CYCLES        256u      /* CAP_WIN_LOG2 8 */
/* Counters (design >= 0x0A07), read-only, free-running 32-bit, wrap (17.2 s of counted cycles
 * at 250 MHz), no read side effect: take differences, often enough not to miss a wrap. */
#define PIPS_BP_CYCLES_0_OFF        0x30u     /* in0 had a beat waiting and was refused, any reason */
#define PIPS_BP_CYCLES_1_OFF        0x34u
#define PIPS_CAP_HOLD_0_OFF         0x38u     /* the part of bp_cycles_0 where in0's rate cap was closed */
#define PIPS_CAP_HOLD_1_OFF         0x3Cu

/* axil4_regfile_0 layout (pips.tcl, comment above axil4_regfile_0):
 *   0x00        batcher config, RW (above)
 *   0x04        batcher drain config, RW (above)
 *   0x08        page batcher thresholds, RW (design >= 0x0A06; before, reserved, read 0)
 *   0x0C        page batcher config, RW (design >= 0x0A06; before, reserved, read 0)
 *   0x10        batcher rate caps, RW (design >= 0x0A07; before, reserved, read 0)
 *   0x14 - 0x1C reserved, read 0
 *   0x20 - 0x3F read-only range; writes are ignored (OKAY, WIN_STATUS stays 0)
 *     0x20      DESIGN_ID: [15:0] build identifier (pips.tcl pips_design_id), [31:16] 0
 *     0x24-0x2C page batcher status (design >= 0x0A06, above; before, reserved, read 0)
 *     0x30-0x3C refused / rate-cap-held cycle counters (design >= 0x0A07; before, reserved, read 0)
 * The design ID goes up by one with every FPGA design update: compare it with the build you expect. */
#define PIPS_REGFILE_RO_OFF     0x20u
#define PIPS_DESIGN_ID_OFF      0x20u
#define PIPS_DESIGN_ID(v)       ((uint32_t)(v) & 0xFFFFu)
#define PIPS_DESIGN_ID_FIRST    0x0A02u       /* first build that has the field; older builds read DECERR (0xFFFFFFFF) */

/* AXI DMA S2MM registers at PIPS_AXI_DMA_LOG (PG021 layout).
 * NOT YET CONFIRMED against PG021 for axi_dma 7.1 / on hardware - check before use. */
#define PIPS_DMA_S2MM_DMACR     0x30u
#define PIPS_DMA_S2MM_DMASR     0x34u
#define PIPS_DMA_S2MM_DA        0x48u
#define PIPS_DMA_S2MM_DA_MSB    0x4Cu         /* unused: c_addr_width = 32 */
#define PIPS_DMA_S2MM_LENGTH    0x58u         /* write starts the transfer; read = bytes written */
#define PIPS_DMA_CR_RS          (1u << 0)
#define PIPS_DMA_CR_RESET       (1u << 2)
#define PIPS_DMA_SR_HALTED      (1u << 0)
#define PIPS_DMA_SR_IDLE        (1u << 1)
#define PIPS_DMA_SR_INT_ERR     (1u << 4)
#define PIPS_DMA_SR_SLV_ERR     (1u << 5)
#define PIPS_DMA_SR_DEC_ERR     (1u << 6)
#define PIPS_DMA_SR_IOC         (1u << 12)    /* write 1 to clear */
#define PIPS_DMA_SR_ERR_IRQ     (1u << 14)

/* Telemetry log as built (pips.tcl): DMA_LOG = 1, LOG_TDATA_WIDTH = 128.
 * Region base and size: read PIPS_REG_LOG_BASE_LO / PIPS_REG_LOG_BYTES at run time; the constant
 * below is only the value at the time of writing (pips.tcl pips_log_region_bytes). The DMA can
 * only write inside [LOG_BASE, LOG_BASE + LOG_BYTES rounded up to a power of two). */
#define PIPS_LOG_REGION_BYTES   4194304u      /* program S2MM_LENGTH = LOG_BYTES */
#define PIPS_LOG_RECORD_BYTES   16u
#define PIPS_LOG_DA_ALIGN       16u           /* S2MM_DA alignment (no DRE / unaligned transfers) */

/* Record format: choose by design ID (README section 7; telemetry_dma_format.md section 4).
 *   >= PIPS_DESIGN_ID_LOG_V2: one record per TLP leaving the batcher; port = the input it came in
 *                             on (IN0/IN1), pkt_wait u16 at 0x0C, pkt_tag at 0x0F, AT in pkt_type[5:4].
 *   <  PIPS_DESIGN_ID_LOG_V2: three-port format; records for IN0, IN1 and OUT, pkt_tag at 0x0C,
 *                             AT at 0x0D, no pkt_wait.
 * Info byte (0x0E) and trailer are the same in both. */
#define PIPS_DESIGN_ID_LOG_V2   0x0A04u       /* first build with the v2 (output-only) record format */
#define PIPS_LOG_PORT_IN0       0u            /* requests from downstream port one (10ee:b348) */
#define PIPS_LOG_PORT_IN1       1u            /* requests from downstream port zero (10ee:b148) */
#define PIPS_LOG_PORT_OUT       2u            /* older format only: batched stream sent to the host */

/* ------------------------------------------------------------------ background read engine
 * pips_bg_rd_0 at PIPS_AXI_BG (design ID >= 0x0A08; on older builds the segment is unmapped and
 * window reads fail with WIN_STATUS set). 64 KB, 32-bit registers, 32-bit writes only (wstrb is
 * ignored), unused offsets read 0, nothing returns DECERR. Same addresses from XSCT.
 * Specs: Fast-and-Safe-IO-Memory-Protection docs/PIPS-BG-READ-ENGINE.md and
 * PIPS-0A08-ASSUMPTION-TEST.md; deviations: FPGA repo 0A08_UPGRADE_PLAN.md section 2 (H1-H16).
 * 64-bit counters 0x100-0x184 read the SNAPSHOT (write CTRL.SNAPSHOT first); the test extension
 * counters at 0x220/0x244/0x24C/0x2EC/0x2F4 read LIVE: read LO first, it latches HI for the read of
 * HI that follows. Timing unit: one cycle = 4 ns (250 MHz). */
#define PIPS_AXI_BG                 0xA4020000ull
#define PIPS_DESIGN_ID_BG           0x0A08u             /* first build with the engine (test build) */

#define PIPS_BG_ID                  0x000u   /* RO "RIDP" on 0x0A08, "BGRD" on the engine-only build */
#define PIPS_BG_ID_TEST             0x52494450u
#define PIPS_BG_ID_ENGINE           0x42475244u
#define PIPS_BG_VERSION             0x004u   /* RO [31:16] major, [15:0] minor; 0x00010000 */
#define PIPS_BG_CAPS                0x008u   /* RO [9:0] tags 256, [19:16] log2 table 13, [23:20] log2 trace 12,
                                              *    [29:24] log2 histogram bins 6, [30] NP gating, [31] log tap */
#define PIPS_BG_BUS                 0x00Cu   /* RO [7:0] primary, [15:8] secondary, [23:16] subordinate */
#define PIPS_BG_CTRL                0x010u   /* RW, reset 0x404 */
#define PIPS_BG_STATUS              0x014u   /* RO */
#define PIPS_BG_RID                 0x018u   /* RW [15:0] slot 0 RID; RO [31:16] RID_LATCHED */
#define PIPS_BG_BASE_LO             0x01Cu   /* RW IOVA [31:12] ([11:0] read 0) */
#define PIPS_BG_BASE_HI             0x020u   /* RW IOVA [63:32] */
#define PIPS_BG_FIRST               0x024u   /* RW first page index (pattern) */
#define PIPS_BG_STRIDE              0x028u   /* RW pages between pattern pages, reset 1 */
#define PIPS_BG_WS                  0x02Cu   /* RW pattern pages / table entries used, reset 1 */
#define PIPS_BG_SEED                0x030u   /* RW LFSR seed, reset 1 */
#define PIPS_BG_OFFSET              0x034u   /* RW byte offset in the page [11:2] */
#define PIPS_BG_READ_DW             0x038u   /* RW DWs per read 1-16, reset 1 */
#define PIPS_BG_INTERVAL            0x03Cu   /* RW live, min cycles between issues [15:0] */
#define PIPS_BG_MAX_OUT             0x040u   /* RW live, outstanding reads 1-256, reset 1 */
#define PIPS_BG_NPH_RESERVE         0x044u   /* RW live, issue only while nph_av > this, reset 2 */
#define PIPS_BG_COUNT_LO            0x048u   /* RW reads to issue then DRAIN, 0 = no limit */
#define PIPS_BG_COUNT_HI            0x04Cu
#define PIPS_BG_TIMEOUT             0x050u   /* RW cycles, reset 0x10000 (262 us); below 256 means 256 */
#define PIPS_BG_BACKING             0x054u   /* RW data check backing pages, power of two, 0 = no compare */
#define PIPS_BG_HIST_SHIFT          0x058u   /* RW bin = min(latency >> shift, 63), reset 3 */
#define PIPS_BG_TRACE_SKIP          0x05Cu   /* RW trace holds sequence numbers SKIP .. SKIP+4095 */

/* CTRL bits. Start = write RUN 1 while it reads 0 (IDLE); stop = write RUN 0 while it reads 1.
 * RUN reads back the request and drops to 0 when the engine is IDLE again, so a read-modify-write
 * of CTRL (e.g. to change ARB live) never starts a run by accident. */
#define PIPS_BG_CTRL_RUN            (1u << 0)
#define PIPS_BG_CTRL_CLEAR          (1u << 1)    /* self-clearing; see README section 12 for what it clears */
#define PIPS_BG_CTRL_STOP_ON_ERR    (1u << 2)    /* reset 1 */
#define PIPS_BG_CTRL_SNAPSHOT       (1u << 3)    /* self-clearing: latch 0x100-0x18C at once */
#define PIPS_BG_CTRL_ARB_SHIFT      4            /* [5:4] live: 0 idle-fill, 1 round robin, 2 engine first */
#define PIPS_BG_CTRL_ARB_MASK       (3u << 4)
#define PIPS_BG_CTRL_SRC_TABLE      (1u << 6)
#define PIPS_BG_CTRL_ORDER_RANDOM   (1u << 7)
#define PIPS_BG_CTRL_DATA_CHECK     (1u << 8)
#define PIPS_BG_CTRL_CLEAR_ON_START (1u << 10)   /* reset 1; adds the 4096-cycle trace sweep (~16 us) to START */
#define PIPS_BG_CTRL_TRACE_EN       (1u << 11)
#define PIPS_BG_CTRL_FC_GATE_OFF    (1u << 12)   /* live: ignore nph_av */
#define PIPS_BG_CTRL_SINK_RIDTAG    (1u << 13)   /* required with a device-ID slot (F2) */

/* STATUS fields */
#define PIPS_BG_STATE(v)            ((uint32_t)(v) & 3u)          /* 0 IDLE, 1 RUN, 2 DRAIN, 3 START */
#define PIPS_BG_ST_IDLE             0u
#define PIPS_BG_ST_RUN              1u
#define PIPS_BG_ST_DRAIN            2u
#define PIPS_BG_ST_START            3u
#define PIPS_BG_STS_ERR_STOP        (1u << 8)
#define PIPS_BG_STS_TIMEOUT         (1u << 9)
#define PIPS_BG_STS_UNEXPECTED      (1u << 10)
#define PIPS_BG_STS_CFG_ERR         (1u << 11)
#define PIPS_BG_CFG_CODE(v)         (((uint32_t)(v) >> 12) & 0xFu)
#define PIPS_BG_STS_CLEARING        (1u << 16)
#define PIPS_BG_STS_MISMATCH        (1u << 17)
#define PIPS_BG_STS_COUNT_DONE      (1u << 18)
#define PIPS_BG_STS_TABLE_WR_RUN    (1u << 19)
#define PIPS_BG_STS_CLEAR_REFUSED   (1u << 20)
#define PIPS_BG_STS_SINK_ARMED      (1u << 21)   /* RID_LATCHED != 0: the sink takes those completions */
#define PIPS_BG_STS_LEAK            (1u << 22)   /* LEAK_CPL went non-zero: stop and investigate */
#define PIPS_BG_STS_CLASH           (1u << 23)
#define PIPS_BG_QUARANTINED(v)      ((uint32_t)(v) >> 24)         /* saturating at 255 */

/* Config error codes (STATUS[15:12]) */
#define PIPS_BG_CFG_RID             1u    /* RID not allowed (slot used by the run) */
#define PIPS_BG_CFG_ZERO            2u    /* WS or STRIDE 0 */
#define PIPS_BG_CFG_WS_POW2         3u    /* random order, WS not a power of two */
#define PIPS_BG_CFG_TABLE_WS        4u    /* table mode, WS > 8192 */
#define PIPS_BG_CFG_READ_DW         5u    /* READ_DW 0 or > 16, or OFFSET + 4*READ_DW crosses 64 bytes */
#define PIPS_BG_CFG_MAX_OUT         6u    /* MAX_OUT 0 / > 256 / > tag window */
#define PIPS_BG_CFG_SEED            7u    /* SEED 0 with random order */
#define PIPS_BG_CFG_BACKING         8u    /* data check: BACKING not a power of two, or OFFSET != 0 */
#define PIPS_BG_CFG_RANGE           9u    /* FIRST + (WS-1)*STRIDE >= 2^40 */
#define PIPS_BG_CFG_NOT_IDLE        10u   /* start while not IDLE (ignored) */
#define PIPS_BG_CFG_TABLE_SLOT      11u   /* a table entry in 0..WS-1 names a slot whose RID is 0 */
#define PIPS_BG_CFG_QUAR_RID        12u   /* tags quarantined and a latched RID would change */

/* Counters (snapshot; 64-bit pairs LO at off, HI at off + 4) */
#define PIPS_BG_CYCLES              0x100u
#define PIPS_BG_RUN_CYCLES          0x108u
#define PIPS_BG_ISSUED              0x110u
#define PIPS_BG_CPL_SC              0x118u
#define PIPS_BG_CPL_UR              0x120u
#define PIPS_BG_CPL_CA              0x128u
#define PIPS_BG_CPL_OTHER           0x130u
#define PIPS_BG_CPL_POISONED        0x138u
#define PIPS_BG_CPL_MALFORMED       0x140u
#define PIPS_BG_CPL_UNEXPECTED      0x148u
#define PIPS_BG_TIMEOUTS            0x150u
#define PIPS_BG_LAT_SUM             0x158u
#define PIPS_BG_LAT_MIN             0x160u   /* 32-bit, 0xFFFFFFFF until the first completion */
#define PIPS_BG_LAT_MAX             0x164u   /* 32-bit */
#define PIPS_BG_STALL_ARB           0x168u
#define PIPS_BG_STALL_TAGS          0x170u
#define PIPS_BG_STALL_FC            0x178u
#define PIPS_BG_DATA_MISMATCH       0x180u
#define PIPS_BG_OUTSTANDING         0x188u   /* live */
#define PIPS_BG_OUT_MAX             0x18Cu   /* snapshot */
#define PIPS_BG_LAST_CPL            0x190u   /* live [7:0] tag, [10:8] status, [11] poisoned, [15:12] error code, [28:16] byte count */
#define PIPS_BG_LAST_DATA           0x194u   /* live first DW of the last SC completion */
#define PIPS_BG_LAST_ERR_PAGE       0x198u   /* live */
#define PIPS_BG_LAST_ERR_SEQ        0x19Cu   /* live */

/* Test extensions (0x0A08) */
#define PIPS_BG_RID_SLOT(n)         (0x200u + 4u * (unsigned)(n))   /* n = 1..3: [15:0] RID, [31:16] latched */
#define PIPS_BG_TAG_WIN             0x210u   /* [7:0] lo, [15:8] hi (inclusive), [16] enable */
#define PIPS_BG_UNSAFE_KEY          0x214u   /* write PIPS_BG_UNSAFE_MAGIC; reads [0] unlocked */
#define PIPS_BG_UNSAFE_MAGIC        0x53504F46u   /* "SPOF"; cleared when the engine returns to IDLE, by CLEAR, reset */
#define PIPS_BG_CLASH               0x218u   /* [15:0] count, [23:16] last tag, [24] input (0 = in0) */
#define PIPS_BG_LEAK_CPL            0x220u   /* live 64-bit, must stay 0 */
#define PIPS_BG_LEAK_LAST           0x228u   /* [15:0] RID, [23:16] tag, [24] path (0 = dsp0) */
#define PIPS_BG_CENSUS_CTRL         0x240u   /* write [0] 1 = clear census, [1] freeze */
#define PIPS_BG_IN0_MRD             0x244u   /* live 64-bit */
#define PIPS_BG_IN1_MRD             0x24Cu   /* live 64-bit */
#define PIPS_BG_IN_TAG_MAX          0x254u   /* [7:0] in0, [15:8] in1 */
#define PIPS_BG_WIN_HITS            0x258u   /* device MRds with a tag in TAG_WIN lo..hi (enable bit ignored) */
#define PIPS_BG_IN0_TAGS            0x260u   /* 8 words, bit t of the 256-bit map = tag t seen */
#define PIPS_BG_IN1_TAGS            0x280u
#define PIPS_BG_CPL0_TAGS           0x2A0u   /* completions down router path dsp0 */
#define PIPS_BG_CPL1_TAGS           0x2C0u
#define PIPS_BG_RC_STRADDLE         0x2E0u   /* must stay 0 */
#define PIPS_BG_RQ_STRADDLE         0x2E4u   /* must stay 0 */
#define PIPS_BG_TFC                 0x2E8u   /* [3:0] nph_av, [7:4] npd_av, [11:8] min nph_av since FC_CLEAR, [31] present */
#define PIPS_BG_HOL_ENGINE          0x2ECu   /* live 64-bit */
#define PIPS_BG_HOL_DEVICE          0x2F4u   /* live 64-bit */
#define PIPS_BG_FC_CLEAR            0x2FCu   /* write 1: clear 0x2E0-0x2F8 */

/* Memories */
#define PIPS_BG_HIST                0x0400u  /* 64 x u32 bins, saturating */
#define PIPS_BG_CAP_WPTR            0x0FF0u  /* [5:0] next index, [31:8] entries ever written */
#define PIPS_BG_CAP                 0x1000u  /* 64 entries x 32 B: DW0-2 descriptor, DW3-4 payload, latency, seq, [1:0] slot [8] late */
#define PIPS_BG_TRACE               0x4000u  /* 4096 x u32 = one 16 KB window page */
#define PIPS_BG_TABLE               0x8000u  /* 8192 x u32 = two window pages; writes only in IDLE */
#define PIPS_BG_TRACE_LAT(v)        ((uint32_t)(v) & 0xFFFFu)        /* 0xFFFF = saturated or timed out */
#define PIPS_BG_TRACE_STATUS(v)     (((uint32_t)(v) >> 16) & 7u)
#define PIPS_BG_TRACE_POISONED      (1u << 19)
#define PIPS_BG_TRACE_TIMED_OUT     (1u << 20)
#define PIPS_BG_TRACE_MISMATCH      (1u << 21)
#define PIPS_BG_TRACE_VALID         (1u << 31)
#define PIPS_BG_TABLE_ENTRY(page, slot) (((uint32_t)(page) & 0x3FFFFFFFu) | ((uint32_t)(slot) << 30))

/* Requester IDs the engine accepts (bus numbers from PIPS_BG_BUS) */
#define PIPS_BG_RID_DSP1(sec)       ((uint16_t)(((sec) & 0xFFu) << 8))               /* sec:00.0, above in0 */
#define PIPS_BG_RID_DSP0(sec)       ((uint16_t)((((sec) & 0xFFu) << 8) | (1u << 3)))  /* sec:01.0, above in1 */
#define PIPS_BG_RID_USP(pri)        ((uint16_t)(((pri) & 0xFFu) << 8))               /* pri:00.0, negative control */

/* ------------------------------------------------------------------ access helpers
 * bar = base of the mmap()ed BAR0 (UC mapping of sysfs resource0).
 * Every access is a single naturally aligned 32-bit volatile load or store. */
static inline uint32_t pips_rd32(volatile void *bar, uint32_t off)
{
    return *(volatile uint32_t *)((volatile uint8_t *)bar + off);
}

static inline void pips_wr32(volatile void *bar, uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)((volatile uint8_t *)bar + off) = val;
}

/* Point the window at the 16 KB page holding axi_addr; returns the BAR0 offset of axi_addr. */
static inline uint32_t pips_win_select(volatile void *bar, uint64_t axi_addr)
{
    uint64_t page = axi_addr & ~(uint64_t)(PIPS_WIN_SIZE - 1u);
    pips_wr32(bar, PIPS_REG_WIN_BASE_LO, (uint32_t)page);
    pips_wr32(bar, PIPS_REG_WIN_BASE_HI, (uint32_t)(page >> 32));
    return PIPS_WIN_OFF + (uint32_t)(axi_addr & (PIPS_WIN_SIZE - 1u) & ~3u);
}

/* One 32-bit AXI read / write through the window (axi_addr 4-byte aligned).
 * A failed read returns 0xFFFFFFFF; check PIPS_REG_WIN_STATUS to tell a real value from an error. */
static inline uint32_t pips_axi_rd32(volatile void *bar, uint64_t axi_addr)
{
    return pips_rd32(bar, pips_win_select(bar, axi_addr));
}

static inline void pips_axi_wr32(volatile void *bar, uint64_t axi_addr, uint32_t val)
{
    pips_wr32(bar, pips_win_select(bar, axi_addr), val);
}

#endif /* PIPS_REGS_H */
