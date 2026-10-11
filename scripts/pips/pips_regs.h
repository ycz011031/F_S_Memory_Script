/*
 * pips_regs.h - PIPS host register map, BAR0 map v2.1
 *
 * Source of truth (FPGA repo Programmable-Intelligent-PCIe-Switch):
 *   BAR0 map and WIN_* semantics : src/pio_pips/pips_pio.v (header comment)
 *   AXI address map              : pips.tcl, assign_bd_address lines for pips_pio_0/m_axi
 *   Batcher config bit fields    : pips.tcl, comment above "Create instance: xlslice_0"
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
#define PIPS_AXI_REGFILE        0xA4000000ull /* axil4_regfile_0, 64 KB, NUM_REGS = 1 */
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
#define PIPS_LOG_PORT_IN0       0u            /* requests from downstream port one (10ee:b348) */
#define PIPS_LOG_PORT_IN1       1u            /* requests from downstream port zero (10ee:b148) */
#define PIPS_LOG_PORT_OUT       2u            /* batched stream sent to the host */

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
