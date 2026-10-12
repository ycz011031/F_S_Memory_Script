/*
 * pips_sim.c - software model of the PIPS BAR0, for testing the pips tool
 * and the scripts without hardware: `make check`. Not used on a testbed.
 *
 * Models what the tool relies on: BAR0 registers and counters, BRAM and its
 * aliases, the AXI window with its error reporting, the regfile (reg0,
 * DESIGN_ID, reserved registers, repeating every 0x40), the AXI DMA S2MM
 * registers in direct register mode, 2 GB
 * of DDR, and a logger that writes TLP records and a trailer on log_enable
 * edges. Timing, AXI timeouts and the PIO's limits (F2) are not modelled.
 *
 * State lives in files so it survives across pips invocations, as the
 * hardware does: $PIPS_SIM_STATE (default /tmp/pips-sim.state) and a sparse
 * 2 GB DDR image next to it ($PIPS_SIM_STATE.ddr). Delete both to "power
 * cycle". $PIPS_SIM_RECORDS (default 1000) is how many TLPs a recording sees;
 * 262143 or more fills the 4 MiB region. Every $PIPS_SIM_DROP_EVERY-th
 * record (default 500, 0 for none) is a dropped-TLP record.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "pips_regs.h"

#define SIM_MAGIC       0x5053494Du
#define LOG_BYTES       4194304u            /* pips.tcl pips_log_region_bytes, base 0 */
#define DMACR_RESET_VAL 0x00010002u
#define BUS_NUM_VAL     0x009a9897u         /* primary 97, secondary 98, subordinate 9a */
#define DESIGN_ID       PIPS_DESIGN_ID_FIRST

struct state {
    uint32_t magic;
    uint32_t scratch, mwr, mrd, ctrl[8];
    uint32_t win_lo, win_hi, win_st, err_lo, err_hi;
    uint32_t cfg, dmacr, dmasr, da, len;
    uint32_t xfer;      /* a transfer is programmed and waits for stream data */
    uint32_t rec;       /* recording */
    uint32_t nrec, ndrop;
    uint32_t tail;      /* bytes the logger holds that the DMA has not taken */
    uint8_t bram[PIPS_BRAM_SIZE];
};

static struct state *S;
static uint8_t *ddr;

static void *map_file(const char *path, size_t size)
{
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    void *p;

    if (fd < 0 || ftruncate(fd, (off_t)size)) {
        perror(path);
        exit(1);
    }
    p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        perror(path);
        exit(1);
    }
    close(fd);
    return p;
}

void sim_open(void)
{
    const char *p = getenv("PIPS_SIM_STATE");
    char d[4096];

    if (!p || !*p)
        p = "/tmp/pips-sim.state";
    snprintf(d, sizeof d, "%s.ddr", p);
    S = map_file(p, sizeof *S);
    ddr = map_file(d, PIPS_AXI_DDR_SIZE);
    if (S->magic != SIM_MAGIC) {
        memset(S, 0, sizeof *S);
        S->magic = SIM_MAGIC;
        S->cfg = PIPS_BATCH_CFG_RESET;
        S->dmacr = DMACR_RESET_VAL;
        S->dmasr = PIPS_DMA_SR_HALTED;
    }
}

int sim_cfg_read(unsigned off, void *buf, size_t n)
{
    uint8_t c[64] = { 0 };

    c[4] = 0x06;        /* COMMAND: Mem+ BusMaster+ */
    c[0x18] = BUS_NUM_VAL & 0xFF;
    c[0x19] = (BUS_NUM_VAL >> 8) & 0xFF;
    c[0x1a] = (BUS_NUM_VAL >> 16) & 0xFF;
    if (off + n > sizeof c)
        return -1;
    memcpy(buf, c + off, n);
    return 0;
}

/* ------------------------------------------------------------ logger + DMA */
static void dma_complete(uint32_t bytes)
{
    S->len = bytes;
    S->xfer = 0;
    S->dmasr |= PIPS_DMA_SR_IDLE | PIPS_DMA_SR_IOC;
}

static void put_rec(uint32_t slot, const uint8_t r[16])
{
    memcpy(ddr + S->da + 16u * slot, r, 16);
}

/* A plausible TLP mix: in0/in1 device writes and reads, out = batched writes. */
static void make_rec(uint32_t i, uint8_t r[16])
{
    uint32_t port = i % 3;
    uint64_t addr = 0x100000000ull + 64ull * i;
    int mwr = port == 2 || (i & 4);

    const char *e = getenv("PIPS_SIM_DROP_EVERY");
    uint32_t every = e ? (uint32_t)strtoul(e, NULL, 0) : 500;

    memset(r, 0, 16);
    if (every && i % every == every - 1) {   /* a dropped-TLP record (0: none) */
        r[14] = 0x84 | port;
        S->ndrop++;
        return;
    }
    memcpy(r, &addr, 8);
    r[8] = mwr ? 5 : 1;                 /* beats */
    r[9] = (uint8_t)(i % 7);            /* gap */
    r[10] = mwr ? 1 : 0;                /* MWr / MRd */
    r[11] = mwr ? 64 : 0;               /* payload DW */
    r[12] = (uint8_t)i;
    r[14] = 0x80 | port;
}

static void put_trailer(uint32_t slot, uint8_t reason)
{
    uint8_t t[16] = { 0 };
    uint32_t dur = S->nrec * 3 + 40;

    memcpy(t, &S->nrec, 4);
    memcpy(t + 4, &S->ndrop, 4);
    memcpy(t + 8, &dur, 4);
    t[12] = reason;
    t[14] = 0x88;
    put_rec(slot, t);
}

static void log_edge(uint32_t old, uint32_t now)
{
    int was = !!(old & PIPS_BATCH_LOG_ENABLE), is = !!(now & PIPS_BATCH_LOG_ENABLE);

    if (!was && is && !S->rec && !S->tail) {
        const char *e = getenv("PIPS_SIM_RECORDS");
        uint32_t want = e ? (uint32_t)strtoul(e, NULL, 0) : 1000, max, i;
        uint8_t r[16];

        S->rec = 1;
        S->nrec = S->ndrop = 0;
        if (!S->xfer)
            return;                     /* DMA not running: nothing gets through */
        max = S->len / 16 - 1;
        for (i = 0; i < want && i < max; i++) {
            make_rec(i, r);
            put_rec(i, r);
        }
        S->nrec = i;
        if (want >= max) {              /* region full */
            put_trailer(max, 2);
            dma_complete(S->len);
            S->rec = 0;
        }
    } else if (was && !is && S->rec) {
        S->rec = 0;
        if (S->xfer) {
            put_trailer(S->nrec, 1);
            dma_complete(16 * (S->nrec + 1));
        } else {
            S->tail = 16 * (S->nrec + 1);   /* waits for the next arm */
        }
    }
}

/* ------------------------------------------------------------ AXI targets */
static uint32_t axi_read(uint64_t a, int *err)
{
    if (a >= PIPS_AXI_REGFILE && a < PIPS_AXI_REGFILE + 0x10000) {
        switch (a & 0x3F) {             /* 16 registers, repeating every 0x40 */
        case PIPS_BATCH_CFG_OFF: return S->cfg;
        case PIPS_DESIGN_ID_OFF: return DESIGN_ID;
        default: return 0;
        }
    } else if (a >= PIPS_AXI_DMA_LOG && a < PIPS_AXI_DMA_LOG + 0x10000) {
        switch (a & 0xFFFF) {
        case PIPS_DMA_S2MM_DMACR: return S->dmacr;
        case PIPS_DMA_S2MM_DMASR: return S->dmasr;
        case PIPS_DMA_S2MM_DA: return S->da;
        case PIPS_DMA_S2MM_LENGTH: return S->len;
        default: return 0;
        }
    } else if (a < PIPS_AXI_DDR_SIZE) {
        uint32_t v;
        memcpy(&v, ddr + a, 4);
        return v;
    }
    *err = 1;
    return 0xFFFFFFFFu;
}

static int axi_write(uint64_t a, uint32_t v)
{
    if (a >= PIPS_AXI_REGFILE && a < PIPS_AXI_REGFILE + 0x10000) {
        uint32_t old = S->cfg;
        if (a & 0x3F)
            return 0;                   /* read-only registers: ignored, OKAY */
        S->cfg = v;
        log_edge(old, v);
        return 0;
    }
    if (a >= PIPS_AXI_DMA_LOG && a < PIPS_AXI_DMA_LOG + 0x10000) {
        switch (a & 0xFFFF) {
        case PIPS_DMA_S2MM_DMACR:
            if (v & PIPS_DMA_CR_RESET) {
                S->dmacr = DMACR_RESET_VAL;
                S->dmasr = PIPS_DMA_SR_HALTED;
                S->da = S->len = S->xfer = 0;
            } else {
                S->dmacr = v;
                if (v & PIPS_DMA_CR_RS)
                    S->dmasr &= ~PIPS_DMA_SR_HALTED;
                else
                    S->dmasr |= PIPS_DMA_SR_HALTED;
            }
            break;
        case PIPS_DMA_S2MM_DMASR:
            S->dmasr &= ~(v & 0x7000u);
            break;
        case PIPS_DMA_S2MM_DA:
            S->da = v;
            break;
        case PIPS_DMA_S2MM_LENGTH:
            if (!(S->dmacr & PIPS_DMA_CR_RS) || (S->dmasr & PIPS_DMA_SR_HALTED))
                break;
            S->len = v;
            S->dmasr &= ~PIPS_DMA_SR_IDLE;
            if ((uint64_t)S->da + v > LOG_BYTES) {     /* outside the narrowed aperture */
                S->dmasr |= PIPS_DMA_SR_DEC_ERR | PIPS_DMA_SR_HALTED | PIPS_DMA_SR_ERR_IRQ;
                break;
            }
            S->xfer = 1;
            if (S->tail) {
                put_trailer(S->tail / 16 - 1, 1);
                dma_complete(S->tail);
                S->tail = 0;
            }
            break;
        }
        return 0;
    }
    if (a < PIPS_AXI_DDR_SIZE) {
        memcpy(ddr + a, &v, 4);
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------ BAR0 */
static uint32_t reg_read(uint32_t off)
{
    switch (off) {
    case PIPS_REG_ID: return PIPS_ID_VALUE;
    case PIPS_REG_VERSION: return PIPS_VERSION_VALUE;
    case PIPS_REG_SCRATCH: return S->scratch;
    case PIPS_REG_BUS_NUM: return BUS_NUM_VAL;
    case PIPS_REG_CQ_SPLIT: return PIPS_SPLIT_PIO_SEEN | 15u;
    case PIPS_REG_MWR_COUNT: return S->mwr;
    case PIPS_REG_MRD_COUNT: return S->mrd;
    case PIPS_REG_WIN_BASE_LO: return S->win_lo;
    case PIPS_REG_WIN_BASE_HI: return S->win_hi;
    case PIPS_REG_WIN_STATUS: return S->win_st;
    case PIPS_REG_WIN_ERR_LO: return S->err_lo;
    case PIPS_REG_WIN_ERR_HI: return S->err_hi;
    case PIPS_REG_LOG_BYTES: return LOG_BYTES;
    }
    if (off >= PIPS_REG_CTRL(0) && off < PIPS_REG_CTRL(8))
        return S->ctrl[(off - PIPS_REG_CTRL(0)) / 4];
    return 0;
}

static void reg_write(uint32_t off, uint32_t v)
{
    switch (off) {
    case PIPS_REG_SCRATCH: S->scratch = v; return;
    case PIPS_REG_WIN_BASE_LO: S->win_lo = v & ~3u; return;
    case PIPS_REG_WIN_BASE_HI: S->win_hi = v; return;
    case PIPS_REG_WIN_STATUS: S->win_st &= ~(v & PIPS_WIN_ST_STICKY); return;
    }
    if (off >= PIPS_REG_CTRL(0) && off < PIPS_REG_CTRL(8))
        S->ctrl[(off - PIPS_REG_CTRL(0)) / 4] = v;
}

static uint64_t win_addr(uint32_t off)
{
    return ((uint64_t)S->win_hi << 32 | S->win_lo) + (off - PIPS_WIN_OFF);
}

static void win_fail(uint64_t a, uint32_t bit)
{
    S->win_st |= bit;
    S->err_lo = (uint32_t)a;
    S->err_hi = (uint32_t)(a >> 32);
}

static uint32_t rd32(uint32_t off)
{
    uint32_t v;

    if (off >= PIPS_WIN_OFF) {
        int err = 0;
        uint64_t a = win_addr(off);
        v = axi_read(a, &err);
        if (err)
            win_fail(a, PIPS_WIN_ST_RD_ERR);
        return v;
    }
    off &= 0xFFF;                       /* 0x1000-0x3FFF alias 0x0000-0x0FFF */
    if (off < PIPS_BRAM_SIZE) {
        memcpy(&v, S->bram + off, 4);
        return v;
    }
    return reg_read(off);
}

static void wr32(uint32_t off, uint32_t v)
{
    if (off >= PIPS_WIN_OFF) {
        uint64_t a = win_addr(off);
        if (axi_write(a, v))
            win_fail(a, PIPS_WIN_ST_WR_ERR);
        return;
    }
    off &= 0xFFF;
    if (off < PIPS_BRAM_SIZE)
        memcpy(S->bram + off, &v, 4);
    else
        reg_write(off, v);
}

/* One TLP per call; MRD_COUNT includes the read that returns it. */
uint32_t sim_rd32(uint32_t off) { S->mrd++; return rd32(off); }
void sim_wr32(uint32_t off, uint32_t v) { S->mwr++; wr32(off, v); }

uint64_t sim_rd64(uint32_t off)
{
    S->mrd++;
    return rd32(off) | (uint64_t)rd32(off + 4) << 32;
}

void sim_wr64(uint32_t off, uint64_t v)
{
    S->mwr++;
    wr32(off, (uint32_t)v);
    wr32(off + 4, (uint32_t)(v >> 32));
}

void sim_wr8(uint32_t off, uint8_t v)
{
    uint32_t w, sh = (off & 3) * 8;

    S->mwr++;
    w = rd32(off & ~3u);
    w = (w & ~(0xFFu << sh)) | (uint32_t)v << sh;
    wr32(off & ~3u, w);
}
