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

/* axil4_regfile_0 layout (pips.tcl, comment above axil4_regfile_0):
 *   0x00        batcher config, RW (above)
 *   0x04        batcher drain config, RW (above)
 *   0x08        page batcher thresholds, RW (design >= 0x0A06; before, reserved, read 0)
 *   0x0C        page batcher config, RW (design >= 0x0A06; before, reserved, read 0)
 *   0x10 - 0x1C reserved, read 0
 *   0x20 - 0x3F read-only range; writes are ignored (OKAY, WIN_STATUS stays 0)
 *     0x20      DESIGN_ID: [15:0] build identifier (pips.tcl pips_design_id), [31:16] 0
 *     0x24-0x2C page batcher status (design >= 0x0A06, above; before, reserved, read 0)
 *     0x30-0x3C reserved, read 0
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
